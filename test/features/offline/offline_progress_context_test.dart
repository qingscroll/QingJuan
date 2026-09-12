import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/reading_progress_pending.dart';
import 'package:qingjuan/features/offline/offline_cache_store.dart';
import 'package:qingjuan/features/offline/offline_reading_controller.dart';
import 'package:qingjuan/features/reader/reader_progress_store.dart';

void main() {
  for (final status in [200, 409, 503]) {
    test('returning to an offline identity survives old HTTP $status',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('qj-progress-context-');
      var url = 'https://original.test';
      var connectionRevision = 0;
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final api = ApiClient(() => url,
          connectionRevision: () => connectionRevision,
          client: MockClient((request) async {
            if (request.method == 'PUT') {
              expect(request.url.host, 'original.test');
              started.complete();
              return response.future;
            }
            return http.Response(
                jsonEncode(readingProgressJson(_position(1, 0))), 200);
          }));
      final cache = OfflineCacheStore(directory: () async => directory);
      final controller = OfflineReadingController(api, cache);
      addTearDown(() async {
        controller.dispose();
        api.close();
        await directory.delete(recursive: true);
      });
      final detail = BookDetail.fromJson({
        'book': {'id': 'book', 'title': '离线书', 'chapterCount': 4},
        'progress': {'lastChapterIndex': 1, 'revision': 0},
        'chapters': [
          for (var i = 1; i <= 4; i++) {'index': i, 'title': '第$i章'}
        ]
      });
      final progressStore = FileReaderProgressStore(
          instanceId: 'instance',
          ownerId: 'owner',
          bookId: 'book',
          directory: () async => directory);
      await controller.activate(
          connectionKey: 'original-fingerprint',
          instanceId: 'instance',
          ownerId: 'owner',
          displayName: '测试',
          versioning: true);
      final oldWriter = controller.writerFor(detail);
      final saving = oldWriter.save(_position(2));
      await started.future;
      final operationId = (await progressStore.load())!.sending!.operationId;
      url = 'https://other.test';
      connectionRevision++;
      await controller.deactivate();
      url = 'https://original.test';
      connectionRevision++;
      await controller.restore(
          connectionKey: 'original-fingerprint', allowStoredIdentity: true);
      expect(controller.online, isFalse);
      expect(oldWriter.isCurrentContext, isFalse);
      final current = controller.writerFor(detail);
      await current.save(_position(4));
      expect((await progressStore.load())?.localPosition?.chapterIndex, 4);

      response.complete(http.Response(
          jsonEncode(switch (status) {
            200 => readingProgressJson(_position(2, 1)),
            409 => {
                'detail': {
                  'code': 'reading_progress_conflict',
                  'current': readingProgressJson(_position(3, 1))
                }
              },
            _ => {'detail': 'temporarily unavailable'},
          }),
          status));
      await saving;

      final restarted = OfflineReadingController(api, cache);
      addTearDown(restarted.dispose);
      await restarted.restore(
          connectionKey: 'original-fingerprint', allowStoredIdentity: true);
      final reopened = restarted.writerFor(detail);
      await reopened.ready;
      expect(reopened.localPosition?.chapterIndex, 4);
      expect(reopened.conflict, isNull);
      expect((await progressStore.load())?.sending?.operationId, operationId,
          reason:
              'The unconfirmed operation remains available for idempotent replay.');
    });
  }
}

ReadingProgress _position(int chapter, [int? revision]) => ReadingProgress(
    chapterIndex: chapter,
    scrollRatio: .4,
    contentMode: 'original',
    revision: revision);
