import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/reader/reader_progress.dart';

void main() {
  test('saving immediately after an idle flush persists the new position',
      () async {
    final writes = <int>[];
    final api = ApiClient(() => 'https://position.example.test',
        client: MockClient((request) async {
      writes.add((jsonDecode(request.body) as Map)['pageIndex'] as int);
      return http.Response('{}', 200);
    }));
    final writer = ReaderProgressWriter(api, 'position-book');
    addTearDown(api.close);
    addTearDown(writer.dispose);
    final idleFlush = writer.flush();
    await writer.save(_position(3));
    await idleFlush;
    expect(writes, [3]);
  });

  testWidgets(
      'retry after a failed request sends only the latest queued position',
      (tester) async {
    final firstResponse = Completer<http.Response>();
    final writes = <int>[];
    final api = ApiClient(() => 'https://position.example.test',
        client: MockClient((request) async {
      writes.add((jsonDecode(request.body) as Map)['pageIndex'] as int);
      return writes.length == 1
          ? firstResponse.future
          : http.Response('{}', 200);
    }));
    final writer = ReaderProgressWriter(api, 'position-book',
        retryDelay: const Duration(milliseconds: 500));
    addTearDown(api.close);
    addTearDown(writer.dispose);
    unawaited(writer.save(_position(0)));
    await tester.pump();
    unawaited(writer.save(_position(2)));
    unawaited(writer.save(_position(4)));
    firstResponse.complete(http.Response('{"detail":"unavailable"}', 503));
    await tester.pump();
    expect(writes, [0]);
    await tester.pump(const Duration(milliseconds: 500));
    expect(writes, [0, 4]);
  });

  testWidgets(
      'changing backend drops pending retries from the previous context',
      (tester) async {
    var backend = 'https://old.example.test';
    final requestedHosts = <String>[];
    final api = ApiClient(() => backend, client: MockClient((request) async {
      requestedHosts.add(request.url.host);
      return http.Response('{"detail":"unavailable"}', 503);
    }));
    final writer = ReaderProgressWriter(api, 'position-book',
        retryDelay: const Duration(milliseconds: 500));
    addTearDown(api.close);
    addTearDown(writer.dispose);
    unawaited(writer.save(_position(4)));
    await tester.pump();
    backend = 'https://new.example.test';
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 2));
    expect(requestedHosts, ['old.example.test']);
  });
}

ReadingProgress _position(int page) =>
    ReadingProgress(chapterIndex: 2, scrollRatio: page / 10, pageIndex: page);
