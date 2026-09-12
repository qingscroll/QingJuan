import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/reading_progress_pending.dart';
import 'package:qingjuan/features/reader/reader_progress_store.dart';
import 'package:qingjuan/core/models/offline_cache.dart';
import 'package:qingjuan/features/offline/offline_cache_store.dart';
import 'package:qingjuan/features/offline/offline_codec.dart';
import 'offline_fixtures.dart';

void main() {
  late Directory directory;
  late OfflineCacheStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('qingjuan-offline-');
    store = OfflineCacheStore(directory: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));
  Future<void> save({String mode = 'original', int index = 1}) =>
      store.saveChapter(offlineIdentity, offlineDetail(),
          offlineContent(mode: mode, index: index),
          imageLoader: (_) async => [1, 2, 3], isCurrent: () => true);

  test(
      'restart retains complete chapter and local images without source credentials',
      () async {
    await store.saveChapter(
        offlineIdentity,
        offlineDetail(),
        offlineContent(images: [
          'https://backend.test/api/v1/books/offline-book/assets/image?DO_NOT_PERSIST'
        ]),
        imageLoader: (_) async => [1, 2, 3],
        isCurrent: () => true);
    store = OfflineCacheStore(directory: () async => directory);
    final content =
        await store.loadChapter(offlineIdentity, 'offline-book', 1, 'original');
    expect(
        await File.fromUri(Uri.parse(content.imageSources.single))
            .readAsBytes(),
        [1, 2, 3]);
    expect((await store.list(offlineIdentity)).single.detail.book.sourceUrl,
        isEmpty);
    await for (final file in directory.list(recursive: true)) {
      if (file is File && file.path.endsWith('.json')) {
        expect(await file.readAsString(), isNot(contains('DO_NOT_PERSIST')));
      }
    }
  });

  test(
      'instances accounts and modes are isolated and clearing affects selected copies only',
      () async {
    await save();
    await save(mode: 'translated');
    await save(index: 2);
    for (final identity in [
      const OfflineIdentity(
          connectionKey: 'other',
          instanceId: 'instance-two',
          ownerId: 'owner-one',
          displayName: '',
          versioning: true),
      const OfflineIdentity(
          connectionKey: 'other',
          instanceId: 'instance-one',
          ownerId: 'owner-two',
          displayName: '',
          versioning: true),
    ]) {
      expect(await store.list(identity), isEmpty);
    }
    final bytes = await store.bytesUsed(offlineIdentity);
    await store.remove(offlineIdentity, 'offline-book',
        indices: {1}, mode: 'original');
    expect((await store.list(offlineIdentity)).single.chapters.length, 2);
    await expectLater(
        store.loadChapter(offlineIdentity, 'offline-book', 1, 'original'),
        throwsA(isA<OfflineCacheException>()
            .having((e) => e.message, 'message', contains('尚未保存'))));
    expect(
        (await store.loadChapter(
                offlineIdentity, 'offline-book', 1, 'translated'))
            .mode,
        'translated');
    expect(await store.bytesUsed(offlineIdentity), lessThan(bytes));
    await store.remove(offlineIdentity, 'offline-book');
    expect(await store.list(offlineIdentity), isEmpty);
  });

  test('failed image or cancelled identity never publishes partial replacement',
      () async {
    await save();
    final blocked = Completer<List<int>>();
    var current = true;
    final writing = store.saveChapter(offlineIdentity, offlineDetail(),
        offlineContent(text: '尚未提交的新正文', images: ['image']),
        imageLoader: (_) => blocked.future, isCurrent: () => current);
    // The old snapshot remains readable while the new chapter is staged.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    current = false;
    blocked.complete([1]);
    await writing;
    expect(
        (await store.loadChapter(
                offlineIdentity, 'offline-book', 1, 'original'))
            .content,
        '此处是本机保存的正文。');
    await expectLater(
        store.saveChapter(
            offlineIdentity, offlineDetail(), offlineContent(images: ['image']),
            imageLoader: (_) async =>
                throw const FileSystemException('test fault'),
            isCurrent: () => true),
        throwsA(isA<FileSystemException>()));
    expect((await store.list(offlineIdentity)).single.chapters.length, 1);
    expect(
        await directory
            .list(recursive: true)
            .any((f) => f.path.contains('staging-')),
        isFalse);
  });

  test('capacity failure leaves prior cache intact and rejects empty images',
      () async {
    await save();
    final small = OfflineCacheStore(
        directory: () async => directory,
        limitBytes: await store.bytesUsed(offlineIdentity) + 1);
    await expectLater(
        small.saveChapter(
            offlineIdentity, offlineDetail(), offlineContent(index: 2),
            imageLoader: (_) async => [1], isCurrent: () => true),
        throwsA(isA<OfflineCacheException>()));
    await expectLater(
        store.saveChapter(
            offlineIdentity, offlineDetail(), offlineContent(images: ['image']),
            imageLoader: (_) async => [], isCurrent: () => true),
        throwsA(isA<OfflineCacheException>()));
    expect((await store.list(offlineIdentity)).single.chapters.length, 1);
  });

  test('identity pointer matches credential fingerprint and forget is durable',
      () async {
    await store.remember(offlineIdentity);
    expect(await store.recall('other-credentials'), isNull);
    expect((await store.recall(offlineIdentity.connectionKey))?.ownerId,
        offlineIdentity.ownerId);
    await store.forget(offlineIdentity.connectionKey);
    expect(await store.recall(offlineIdentity.connectionKey), isNull);
  });

  test(
      'new downloads cannot regress confirmed position and content cleanup preserves outbox',
      () async {
    await save();
    await store.saveChapter(
        offlineIdentity,
        offlineWithProgress(
            offlineDetail(),
            const ReadingProgress(
                chapterIndex: 2, scrollRatio: .6, revision: 5)),
        offlineContent(),
        imageLoader: (_) async => [],
        isCurrent: () => true);
    await save(index: 2);
    expect(
        (await store.find(offlineIdentity, 'offline-book'))
            ?.detail
            .progress
            .revision,
        5);
    final outbox = FileReaderProgressStore(
        instanceId: offlineIdentity.instanceId,
        ownerId: offlineIdentity.ownerId,
        bookId: 'offline-book',
        directory: () async => directory);
    await outbox.save(const PendingReadingProgress(
        baseRevision: 5,
        queued: ReadingProgress(chapterIndex: 1, scrollRatio: .1)));
    await store.remove(offlineIdentity, 'offline-book');
    expect((await outbox.load())?.localPosition?.chapterIndex, 1);
  });

  test(
      'corrupt metadata can be explicitly cleared without parsing the broken manifest',
      () async {
    await save();
    final manifests = await directory
        .list(recursive: true)
        .where((file) => file is File && file.path.contains('manifest-'))
        .cast<File>()
        .toList();
    await manifests.single.writeAsString('{');
    await expectLater(store.list(offlineIdentity), throwsFormatException);
    await store.clear(offlineIdentity);
    expect(await store.list(offlineIdentity), isEmpty);
  });
}
