import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/offline/offline_cache_store.dart';
import 'package:qingjuan/features/offline/offline_reading_controller.dart';

import 'offline_fixtures.dart';

void main() {
  late Directory directory;
  late _DownloadApi api;
  late OfflineCacheStore store;
  late OfflineReadingController controller;
  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('qj-offline-publication-');
    api = _DownloadApi();
    store = OfflineCacheStore(directory: () async => directory);
    controller = OfflineReadingController(api, store);
    await store.saveChapter(offlineIdentity, offlineDetail(),
        offlineContent(text: 'previous cached text'),
        imageLoader: (_) async => [1], isCurrent: () => true);
    await controller.activate(
        connectionKey: offlineIdentity.connectionKey,
        instanceId: offlineIdentity.instanceId,
        ownerId: offlineIdentity.ownerId,
        displayName: offlineIdentity.displayName,
        versioning: true);
  });
  tearDown(() async {
    controller.dispose();
    api.close();
    await directory.delete(recursive: true);
  });

  Future<List<String>> savedPaths() async => (await directory
      .list(recursive: true)
      .map((entry) => path.relative(entry.path, from: directory.path))
      .toList())
    ..sort();

  test(
      'stop during manifest write preserves published cache and removes staging',
      () async {
    final previousPaths = await savedPaths();
    final previousBytes = controller.bytesUsed;
    final pause = _ManifestWritePause();
    final download = IOOverrides.runWithIOOverrides(
        () => controller.download(offlineDetail(), {1}, 'original'), pause);
    await pause.written.future;
    final cancellation = controller.cancelDownload();
    pause.resume.complete();
    await Future.wait([download, cancellation]);

    final saved =
        await store.loadChapter(offlineIdentity, 'offline-book', 1, 'original');
    expect(saved.content, 'previous cached text');
    expect(await savedPaths(), previousPaths,
        reason:
            'Keep the published manifest and bundle; remove all new files.');
    expect(controller.completed, 0);
    expect(controller.downloading, isFalse);
    expect(controller.books.single.indices('original'), [1]);
    expect(controller.bytesUsed, previousBytes);
    expect(controller.error, isNull);

    await controller.download(offlineDetail(), {1}, 'original');
    expect(
        (await store.loadChapter(
                offlineIdentity, 'offline-book', 1, 'original'))
            .content,
        'replacement cached text');
    expect(controller.completed, 1);
  });

  test(
      'remove during manifest write waits for cleanup and leaves no cached book',
      () async {
    final pause = _ManifestWritePause();
    final download = IOOverrides.runWithIOOverrides(
        () => controller.download(offlineDetail(), {1}, 'original'), pause);
    await pause.written.future;
    final removal = controller.remove('offline-book');
    pause.resume.complete();
    await Future.wait([download, removal]);

    expect(await store.list(offlineIdentity), isEmpty);
    expect(controller.books, isEmpty);
    expect(controller.downloading, isFalse);
    expect(controller.bytesUsed, await store.bytesUsed(offlineIdentity));
    expect(controller.error, isNull);
    expect(
        (await savedPaths()).where((entry) =>
            entry.contains('staging-') ||
            entry.endsWith('writing.json') ||
            entry.endsWith('content.json')),
        isEmpty);
  });
}

class _DownloadApi extends ApiClient {
  _DownloadApi() : super(() => 'https://isolated.example.test');
  @override
  Future<ChapterContent> fetchChapter(String bookId, int index,
          {String mode = 'translated', bool prefetch = false}) async =>
      offlineContent(index: index, mode: mode, text: 'replacement cached text');
}

// Retain real filesystem I/O but pause after the temporary manifest is durable,
// before the caller can rename it into the published snapshot.
final class _ManifestWritePause extends IOOverrides {
  final written = Completer<void>();
  final resume = Completer<void>();

  @override
  File createFile(String name) {
    final file = super.createFile(name);
    return path.basename(name) == 'writing.json'
        ? _PausedManifest(file, this)
        : file;
  }
}

class _PausedManifest implements File {
  _PausedManifest(this.file, this.pause);
  final File file;
  final _ManifestWritePause pause;

  @override
  Future<File> writeAsString(String contents,
      {FileMode mode = FileMode.write,
      Encoding encoding = utf8,
      bool flush = false}) async {
    await file.writeAsString(contents,
        mode: mode, encoding: encoding, flush: flush);
    if (!pause.written.isCompleted) {
      pause.written.complete();
      await pause.resume.future;
    }
    return this;
  }

  @override
  Future<File> rename(String newPath) => file.rename(newPath);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);

  @override
  Future<bool> exists() => file.exists();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
