import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/reading_progress_pending.dart';
import 'package:qingjuan/features/reader/reader_progress_store.dart';
import 'package:qingjuan/features/reader/reader_progress_writer.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('qingjuan-progress-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  FileReaderProgressStore store(
          {String owner = 'reader', String instance = 'instance'}) =>
      FileReaderProgressStore(
          instanceId: instance,
          ownerId: owner,
          bookId: 'book',
          directory: () async => directory);

  test('a disposed page writer cannot replace a reopened reader snapshot',
      () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final api =
        ApiClient(() => 'https://reader.test', client: MockClient((_) async {
      started.complete();
      return response.future;
    }));
    addTearDown(api.close);
    final previous = ReaderProgressWriter(api, 'book',
        versioning: true, initialProgress: _position(1, 0), store: store());
    final saving = previous.save(_position(2));
    await started.future;
    previous.dispose();
    final reopened = ReaderProgressWriter(api, 'book',
        versioning: true,
        initialProgress: _position(1, 0),
        store: store(),
        canSync: () => false);
    addTearDown(reopened.dispose);
    await reopened.save(_position(4));
    response.complete(_json(_position(2, 1)));
    await saving;
    expect((await store().load())?.localPosition?.chapterIndex, 4);
  });

  test(
      'disposing immediately after capturing the final position keeps it durable',
      () async {
    final api = ApiClient(() => 'https://reader.test',
        client: MockClient((_) async => _json(_position(4, 1))));
    addTearDown(api.close);
    final writer = ReaderProgressWriter(api, 'book',
        versioning: true,
        initialProgress: _position(1, 0),
        store: store(),
        canSync: () => false);
    final saving = writer.save(_position(4));
    writer.dispose();
    await saving;
    expect((await store().load())?.localPosition?.chapterIndex, 4);
  });

  test(
      'latest position is durable while a previous network request is still in flight',
      () async {
    final first = Completer<http.Response>();
    final started = Completer<void>();
    final client = ApiClient(() => 'https://reader.test',
        client: MockClient((request) async {
      final pending = await store().load();
      expect(pending?.sending?.operationId,
          (jsonDecode(request.body) as Map)['operationId']);
      started.complete();
      return first.future;
    }));
    final writer = ReaderProgressWriter(client, 'book',
        versioning: true,
        initialProgress: _position(1, 0),
        store: store(),
        retryDelay: const Duration(hours: 1));
    final initial = writer.save(_position(2));
    await started.future;
    final latest = writer.save(_position(4));
    // The store shares an IO queue, so this read follows the queued save.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final snapshot = await store().load();
    expect(snapshot?.queued?.chapterIndex, 4);
    expect(snapshot?.sending?.position.chapterIndex, 2);
    first.complete(http.Response('{"detail":"offline"}', 503));
    await Future.wait([initial, latest]);
    writer.dispose();
    client.close();

    final bodies = <Map>[];
    final restoredApi = ApiClient(() => 'https://reader.test',
        client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      bodies.add(body);
      return _json(_position(body['chapterIndex'] as int, bodies.length));
    }));
    final restored = ReaderProgressWriter(restoredApi, 'book',
        versioning: true, initialProgress: _position(1, 0), store: store());
    await restored.ready;
    expect(restored.restoredPosition?.chapterIndex, 4);
    await restored.flush();
    expect(bodies.map((body) => body['chapterIndex']), [2, 4]);
    expect(bodies.map((body) => body['expectedRevision']), [0, 1]);
    expect(bodies.first['operationId'], snapshot!.sending!.operationId);
    expect(await store().load(), isNull);
    restored.dispose();
    restoredApi.close();
  });

  test(
      'old replay receipt cannot lower a newer observed server revision or lose local progress',
      () async {
    await store().save(PendingReadingProgress(
        baseRevision: 0,
        sending: PendingProgressWrite(
            operationId: 'persisted-operation-1',
            expectedRevision: 0,
            position: _position(2))));
    final api = ApiClient(() => 'https://reader.test',
        client: MockClient((_) async => _json(_position(2, 1))));
    final writer = ReaderProgressWriter(api, 'book',
        versioning: true, initialProgress: _position(8, 7), store: store());
    await writer.flush();
    expect(writer.revision, 7);
    expect(writer.conflict?.chapterIndex, 8);
    expect(writer.localPosition?.chapterIndex, 2);
    expect((await store().load())?.localPosition?.chapterIndex, 2);
    writer.dispose();
    api.close();
  });

  test(
      'conflict is retained across restart and keeping local explicitly rebases latest pending',
      () async {
    final bodies = <Map>[];
    final api = ApiClient(() => 'https://reader.test',
        client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      bodies.add(body);
      if (bodies.length == 1) return _conflict(_position(8, 7));
      expect(body['expectedRevision'], 7);
      return _json(_position(body['chapterIndex'] as int, 8));
    }));
    final writer = ReaderProgressWriter(api, 'book',
        versioning: true, initialProgress: _position(1, 2), store: store());
    await writer.save(_position(3));
    await writer.save(_position(4));
    expect(bodies.length, 1);
    writer.dispose();
    final restored = ReaderProgressWriter(api, 'book',
        versioning: true, initialProgress: _position(8, 7), store: store());
    await restored.ready;
    expect(restored.conflict?.revision, 7);
    expect(restored.localPosition?.chapterIndex, 4);
    expect(await restored.keepLocal(), isTrue);
    expect(bodies.last['chapterIndex'], 4);
    expect(await store().load(), isNull);
    restored.dispose();
    api.close();
  });

  test(
      'choosing server checks the displayed version before discarding pending data',
      () async {
    final api = ApiClient(() => 'https://reader.test',
        client: MockClient((request) async {
      if (request.method == 'PUT') return _conflict(_position(7, 5));
      return _json(_position(4, 6));
    }));
    final writer = ReaderProgressWriter(api, 'book',
        versioning: true, initialProgress: _position(1, 2), store: store());
    await writer.save(_position(3));
    expect(await writer.useServer(), isNull);
    expect(writer.conflict?.revision, 6);
    expect(writer.localPosition?.chapterIndex, 3);
    expect(await store().load(), isNotNull);
    expect((await writer.useServer())?.chapterIndex, 4);
    expect(await store().load(), isNull);
    writer.dispose();
    api.close();
  });

  test(
      'pending files isolate backend instances and accounts and recover from torn writes',
      () async {
    final entry = PendingReadingProgress(baseRevision: 2, queued: _position(4));
    await store().save(entry);
    expect(await store(owner: 'another-reader').load(), isNull);
    expect(await store(instance: 'another-instance').load(), isNull);
    final file = await directory
        .list(recursive: true)
        .where((entity) => entity is File)
        .cast<File>()
        .first;
    await File('${file.parent.path}/writing.json').writeAsString('{broken');
    expect((await store().load())?.queued?.chapterIndex, 4);
    final text = await file.readAsString();
    expect(text, isNot(contains('token')));
    expect(text, isNot(contains('https://')));
    await store().save(null);
    expect(await store().load(), isNull);
  });

  test(
      'disk failure prevents submission and retries acknowledged cleanup without replaying HTTP',
      () async {
    final disk = _FaultStore()..fail = true;
    var requests = 0;
    final api =
        ApiClient(() => 'https://reader.test', client: MockClient((_) async {
      requests++;
      disk.fail = true;
      return _json(_position(3, 1));
    }));
    final writer = ReaderProgressWriter(api, 'book',
        versioning: true, initialProgress: _position(1, 0), store: disk);
    await writer.save(_position(3));
    expect(requests, 0);
    expect(writer.localPosition?.chapterIndex, 3);
    disk.fail = false;
    await writer.flush();
    expect(requests, 1);
    expect(writer.syncError, isNotNull);
    expect(disk.entry?.sending, isNotNull);
    disk.fail = false;
    await writer.flush();
    expect(requests, 1);
    expect(disk.entry, isNull);
    expect(writer.syncError, isNull);
    writer.dispose();
    api.close();
  });

  test('legacy backend flow neither opens the outbox nor sends CAS fields',
      () async {
    final disk = _FaultStore()..fail = true;
    final api = ApiClient(() => 'https://reader.test',
        client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      expect(body.containsKey('expectedRevision'), isFalse);
      expect(body.containsKey('operationId'), isFalse);
      return http.Response('{}', 200);
    }));
    final writer = ReaderProgressWriter(api, 'book', store: disk);
    await writer.save(_position(3));
    expect(disk.loads, 0);
    expect(disk.saves, 0);
    writer.dispose();
    api.close();
  });
}

class _FaultStore implements ReaderProgressStore {
  PendingReadingProgress? entry;
  bool fail = false;
  int loads = 0;
  int saves = 0;
  @override
  Future<PendingReadingProgress?> load() async {
    loads++;
    return entry;
  }

  @override
  Future<void> save(PendingReadingProgress? value) async {
    saves++;
    if (fail) throw const FileSystemException('simulated full disk');
    entry = value;
  }
}

ReadingProgress _position(int chapter, [int? revision]) => ReadingProgress(
    chapterIndex: chapter,
    scrollRatio: 0.25,
    pageIndex: 1,
    pageCount: 4,
    revision: revision);
http.Response _json(ReadingProgress value) =>
    http.Response(jsonEncode(readingProgressJson(value)), 200,
        headers: {'content-type': 'application/json'});
http.Response _conflict(ReadingProgress value) => http.Response(
    jsonEncode({
      'detail': {
        'code': 'reading_progress_conflict',
        'message': '进度冲突',
        'current': readingProgressJson(value)
      }
    }),
    409,
    headers: {'content-type': 'application/json'});
