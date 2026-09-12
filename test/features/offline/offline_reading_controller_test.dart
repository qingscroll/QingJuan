import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/reading_progress_pending.dart';
import 'package:qingjuan/features/offline/offline_cache_store.dart';
import 'package:qingjuan/features/offline/offline_reading_controller.dart';
import 'package:qingjuan/features/reader/reader_progress_store.dart';
import 'offline_fixtures.dart';

void main() {
  late Directory directory;
  late OfflineCacheStore store;
  late _ProgressApi api;
  late OfflineReadingController controller;
  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('qingjuan-offline-controller-');
    store = OfflineCacheStore(directory: () async => directory);
    api = _ProgressApi();
    controller = OfflineReadingController(api, store);
    await store.remember(offlineIdentity);
  });
  tearDown(() async {
    controller.dispose();
    api.close();
    await directory.delete(recursive: true);
  });
  Future<void> activate() => controller.activate(
      connectionKey: offlineIdentity.connectionKey,
      instanceId: offlineIdentity.instanceId,
      ownerId: offlineIdentity.ownerId,
      displayName: offlineIdentity.displayName,
      versioning: true);

  test(
      'offline saves survive restart then startup scans and submits only this identity',
      () async {
    await controller.restore(
        connectionKey: offlineIdentity.connectionKey,
        allowStoredIdentity: true);
    final writer = controller.writerFor(offlineDetail());
    await writer.save(const ReadingProgress(
        chapterIndex: 2, scrollRatio: .3, contentMode: 'original'));
    expect(api.writes, 0);
    final other = FileReaderProgressStore(
        instanceId: 'other-instance',
        ownerId: offlineIdentity.ownerId,
        bookId: 'other-book',
        directory: () async => directory);
    await other.save(const PendingReadingProgress(
        baseRevision: 0,
        queued: ReadingProgress(chapterIndex: 1, scrollRatio: 0)));
    controller.dispose();
    controller = OfflineReadingController(api, store);
    await activate();
    expect(api.writes, 1);
    expect(api.progress.chapterIndex, 2);
    expect(
        await FileReaderProgressStore.pendingBooks(
            instanceId: offlineIdentity.instanceId,
            ownerId: offlineIdentity.ownerId,
            directory: () async => directory),
        isEmpty);
    expect((await other.load())?.localPosition, isNotNull);
    controller.dispose();
    controller = OfflineReadingController(api, store);
    await controller.restore(
        connectionKey: offlineIdentity.connectionKey,
        allowStoredIdentity: true);
    final restored = controller.writerFor(offlineDetail());
    await restored.ready;
    expect(restored.hasPending, isFalse);
    expect(restored.restoredPosition?.chapterIndex, 2);
    expect(restored.confirmedPosition?.revision, 1);
    expect(api.writes, 1);
  });

  test('startup conflict retains local position until explicit server choice',
      () async {
    await controller.restore(
        connectionKey: offlineIdentity.connectionKey,
        allowStoredIdentity: true);
    await controller
        .writerFor(offlineDetail())
        .save(const ReadingProgress(chapterIndex: 1, scrollRatio: .5));
    controller.dispose();
    controller = OfflineReadingController(api, store);
    api.progress =
        const ReadingProgress(chapterIndex: 2, scrollRatio: .7, revision: 2);
    await activate();
    final writer = controller.pendingWriters.values.single;
    expect(writer.conflict?.revision, 2);
    expect(api.writes, 0);
    expect(writer.localPosition?.chapterIndex, 1);
    await writer.useServer();
    expect(writer.hasPending, isFalse);
    expect(api.writes, 0);
    controller.dispose();
    controller = OfflineReadingController(api, store);
    await controller.restore(
        connectionKey: offlineIdentity.connectionKey,
        allowStoredIdentity: true);
    final restored = controller.writerFor(offlineDetail());
    await restored.ready;
    expect(restored.restoredPosition?.chapterIndex, 2);
    expect(restored.hasPending, isFalse);
  });

  test(
      'one deleted book keeps its outbox and visible error without blocking other books',
      () async {
    final records = <String, FileReaderProgressStore>{};
    for (final id in ['first-book', 'second-book']) {
      final record = FileReaderProgressStore(
          instanceId: offlineIdentity.instanceId,
          ownerId: offlineIdentity.ownerId,
          bookId: id,
          directory: () async => directory);
      records[id] = record;
      await record.save(const PendingReadingProgress(
          baseRevision: 0,
          queued: ReadingProgress(chapterIndex: 2, scrollRatio: .4)));
    }
    final order = await FileReaderProgressStore.pendingBooks(
        instanceId: offlineIdentity.instanceId,
        ownerId: offlineIdentity.ownerId,
        directory: () async => directory);
    final deleted = order.first;
    final healthy = order.last;
    final batchApi = _BatchProgressApi()..blocked.add(deleted);
    addTearDown(batchApi.close);
    controller.dispose();
    controller = OfflineReadingController(batchApi, store);
    await activate();
    expect(batchApi.submitted, [healthy]);
    expect(controller.replayErrors[deleted], contains('作品已删除'));
    expect((await records[deleted]!.load())?.localPosition, isNotNull);
    expect(await records[healthy]!.load(), isNull);
    batchApi.blocked.clear();
    await controller.replayPending();
    expect(batchApi.submitted, [healthy, deleted]);
    expect(controller.replayErrors, isEmpty);
    expect(await records[deleted]!.load(), isNull);
  });

  test(
      'different credentials and logout hide cached identity without erasing its books',
      () async {
    await store.saveChapter(offlineIdentity, offlineDetail(), offlineContent(),
        imageLoader: (_) async => [1], isCurrent: () => true);
    await controller.restore(
        connectionKey: 'new-session-fingerprint', allowStoredIdentity: true);
    expect(controller.identity, isNull);
    expect(controller.books, isEmpty);
    await controller.restore(
        connectionKey: offlineIdentity.connectionKey,
        allowStoredIdentity: true);
    expect(controller.books.length, 1);
    await controller.deactivate(forgetIdentity: true);
    expect(controller.identity, isNull);
    expect(controller.books, isEmpty);
    await controller.restore(
        connectionKey: offlineIdentity.connectionKey,
        allowStoredIdentity: true);
    expect(controller.identity, isNull);
    expect((await store.list(offlineIdentity)).length, 1);
  });

  test('switching identity while a chapter is in flight cannot publish it',
      () async {
    await activate();
    final response = Completer<ChapterContent>();
    api.chapterResponse = response.future;
    final saving = controller.download(offlineDetail(), {1}, 'original');
    await Future<void>.delayed(Duration.zero);
    await controller.deactivate();
    response.complete(offlineContent());
    await saving;
    expect(await store.list(offlineIdentity), isEmpty);
    expect(controller.books, isEmpty);
  });

  test(
      'translated fallback is rejected instead of marking original as translated cache',
      () async {
    await activate();
    api.chapterResponse = Future.value(offlineContent(mode: 'original'));
    await controller.download(offlineDetail(), {1}, 'translated');
    expect(controller.error, contains('译文尚未就绪'));
    expect(await store.list(offlineIdentity), isEmpty);
  });
}

class _BatchProgressApi extends ApiClient {
  _BatchProgressApi() : super(() => 'https://backend.test');
  final blocked = <String>{};
  final submitted = <String>[];
  @override
  Future<ReadingProgress> fetchReadingProgress(String bookId) async {
    if (blocked.contains(bookId)) {
      throw const ApiException('missing book', statusCode: 404);
    }
    return const ReadingProgress(chapterIndex: 1, scrollRatio: 0, revision: 0);
  }

  @override
  Future<ReadingProgress> saveVersionedProgress(
      String bookId, ReadingProgress value,
      {required int expectedRevision, required String operationId}) async {
    submitted.add(bookId);
    expect(expectedRevision, 0);
    return ReadingProgress(
        chapterIndex: value.chapterIndex,
        scrollRatio: value.scrollRatio,
        revision: 1);
  }
}

class _ProgressApi extends ApiClient {
  _ProgressApi() : super(() => 'https://backend.test');
  var writes = 0;
  Future<ChapterContent>? chapterResponse;
  @override
  Future<ChapterContent> fetchChapter(String bookId, int chapterIndex,
          {String mode = 'translated', bool prefetch = false}) =>
      chapterResponse ??
      Future.value(offlineContent(index: chapterIndex, mode: mode));
  ReadingProgress progress =
      const ReadingProgress(chapterIndex: 1, scrollRatio: 0, revision: 0);
  @override
  Future<ReadingProgress> fetchReadingProgress(String bookId) async => progress;
  @override
  Future<ReadingProgress> saveVersionedProgress(
      String bookId, ReadingProgress value,
      {required int expectedRevision, required String operationId}) async {
    writes++;
    expect(expectedRevision, progress.revision);
    progress = ReadingProgress(
        chapterIndex: value.chapterIndex,
        scrollRatio: value.scrollRatio,
        contentMode: value.contentMode,
        revision: expectedRevision + 1);
    return progress;
  }
}
