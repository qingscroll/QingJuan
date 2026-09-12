import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    directory = await Directory.systemTemp.createTemp('qj-offline-download-');
    api = _DownloadApi();
    store = OfflineCacheStore(directory: () async => directory);
    controller = OfflineReadingController(api, store);
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

  test(
      'stopping a partial download exposes saved chapters without manual refresh',
      () async {
    final operation = controller.download(offlineDetail(), {1, 2}, 'original');
    await api.secondStarted.future;
    expect(controller.completed, 1);
    await controller.cancelDownload();
    expect(controller.books.single.indices('original'), [1]);
    expect(api.secondResponse.isCompleted, isFalse,
        reason:
            'The saved chapter is available before the cancelled network request returns.');
    api.secondResponse.complete(offlineContent(index: 2));
    await operation;
    final persisted = await store.list(offlineIdentity);
    expect(persisted.single.indices('original'), [1]);
    expect(controller.books.single.indices('original'), [1]);
    expect(controller.bytesUsed, await store.bytesUsed(offlineIdentity));
    expect(controller.downloading, isFalse);
  });

  test('clearing a downloading book cannot recreate it from the late chapter',
      () async {
    await store.saveChapter(offlineIdentity, offlineDetail(), offlineContent(),
        imageLoader: (_) async => [1], isCurrent: () => true);
    await controller.refresh();
    final operation = controller.download(offlineDetail(), {2}, 'original');
    await api.secondStarted.future;
    await controller.remove('offline-book');
    expect(controller.books, isEmpty);
    api.secondResponse.complete(offlineContent(index: 2));
    await operation;
    expect(await store.list(offlineIdentity), isEmpty);
    expect(controller.books, isEmpty);
    expect(controller.downloading, isFalse);
  });

  test('clearing another book preserves the active download', () async {
    final operation = controller.download(offlineDetail(), {2}, 'original');
    await api.secondStarted.future;
    await controller.remove('other-book');
    expect(controller.downloading, isTrue);
    api.secondResponse.complete(offlineContent(index: 2));
    await operation;
    expect(controller.books.single.indices('original'), [2]);
  });

  test('an old cancellation cannot clear the result of a later download',
      () async {
    final previous = controller.download(offlineDetail(), {2}, 'original');
    await api.secondStarted.future;
    await controller.cancelDownload();
    await controller.download(offlineDetail(), {1}, 'original');
    expect(controller.books.single.indices('original'), [1]);
    final bytes = controller.bytesUsed;
    api.secondResponse.complete(offlineContent(index: 2));
    await previous;
    expect(controller.books.single.indices('original'), [1]);
    expect(controller.bytesUsed, bytes);
    expect(controller.error, isNull);
    expect(controller.completed, 1);
    expect(controller.downloading, isFalse);
  });
}

class _DownloadApi extends ApiClient {
  _DownloadApi() : super(() => 'https://isolated.example.test');
  final secondStarted = Completer<void>();
  final secondResponse = Completer<ChapterContent>();
  @override
  Future<ChapterContent> fetchChapter(String bookId, int index,
      {String mode = 'translated', bool prefetch = false}) async {
    if (index == 2) {
      secondStarted.complete();
      return secondResponse.future;
    }
    return offlineContent(index: index, mode: mode);
  }
}
