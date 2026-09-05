import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/library/library_controller.dart';

void main() {
  test('lost mutation responses are not automatically submitted again',
      () async {
    final requests = <http.Request>[];
    final api = ApiClient(() => 'https://example.test',
        client: MockClient((request) async {
      requests.add(request);
      throw http.ClientException('response lost after acceptance');
    }));
    addTearDown(api.close);
    await expectLater(
        api.startLinkJob('import', {'sourceUrl': 'https://books.test/1'}),
        throwsA(isA<ApiException>()));
    expect(requests, hasLength(1));
    expect(requests.single.headers['Idempotency-Key'],
        matches(RegExp(r'^[a-f0-9]{32}$')));
    await expectLater(api.importBook({'sourceUrl': 'https://books.test/1'}),
        throwsA(isA<ApiException>()));
    expect(requests, hasLength(2));
  });

  test('manual retry of an uncertain link operation reuses its key', () async {
    final keys = <String?>[];
    final api = ApiClient(() => 'https://example.test',
        client: MockClient((request) async {
      if (request.method == 'POST') {
        keys.add(request.headers['Idempotency-Key']);
        if (keys.length == 1) throw http.ClientException('response lost');
      }
      return http.Response(
          jsonEncode({'id': 'job', 'mode': 'preview', 'status': 'completed'}),
          200);
    }));
    final library = LibraryController(api);
    addTearDown(library.dispose);
    addTearDown(api.close);
    const payload = {'sourceUrl': 'https://books.test/1'};
    await expectLater(
        library.startLinkJob('preview', payload), throwsA(isA<ApiException>()));
    await library.startLinkJob('preview', payload);
    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
    library.clearLinkJob();
    await library.startLinkJob('preview', payload);
    expect(keys[2], isNot(keys[1]));
  });

  test('parallel link starts cannot submit a second job before first response',
      () async {
    final response = Completer<http.Response>();
    var starts = 0;
    final api = ApiClient(() => 'https://example.test',
        client: MockClient((request) async {
      if (request.method == 'POST') {
        starts++;
        return response.future;
      }
      return http.Response('{"id":"job","status":"completed"}', 200);
    }));
    final library = LibraryController(api);
    addTearDown(library.dispose);
    addTearDown(api.close);
    final pending =
        library.startLinkJob('preview', {'sourceUrl': 'https://books.test/1'});
    await expectLater(
        library.startLinkJob('preview', {'sourceUrl': 'https://books.test/1'}),
        throwsA(isA<ApiException>()));
    response.complete(http.Response('{"id":"job","status":"completed"}', 200));
    await pending;
    expect(starts, 1);
  });

  test(
      'old terminal job does not replace the key of an unconfirmed new operation',
      () async {
    final keys = <String?>[];
    final api = ApiClient(() => 'https://example.test',
        client: MockClient((request) async {
      if (request.method == 'POST') {
        keys.add(request.headers['Idempotency-Key']);
        if (keys.length == 2) throw http.ClientException('response lost');
      }
      return http.Response(
          '{"id":"job","mode":"preview","status":"completed"}', 200);
    }));
    final library = LibraryController(api);
    addTearDown(library.dispose);
    addTearDown(api.close);
    const payload = {'sourceUrl': 'https://books.test/1'};
    await library.startLinkJob('preview', payload);
    await expectLater(
        library.startLinkJob('import', payload), throwsA(isA<ApiException>()));
    await library.startLinkJob('import', payload);
    expect(keys[1], isNot(keys[0]));
    expect(keys[2], keys[1]);
  });

  test('progress serializes exact page, layout and content anchor', () async {
    late Map<String, dynamic> body;
    final api = ApiClient(() => 'https://example.test',
        client: MockClient((request) async {
      expect(request.url.path, '/api/v1/books/book/progress');
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response('{}', 200);
    }));
    addTearDown(api.close);
    await api.saveProgress('book', 3, .25,
        pageIndex: 4,
        pageCount: 20,
        layoutKey: 'layout',
        contentMode: 'original',
        characterOffset: 1234,
        anchorType: 'paragraph',
        anchorIndex: 7,
        anchorOffsetRatio: .3);
    expect(body, {
      'chapterIndex': 3,
      'scrollRatio': .25,
      'pageIndex': 4,
      'pageCount': 20,
      'layoutKey': 'layout',
      'contentMode': 'original',
      'characterOffset': 1234,
      'anchorType': 'paragraph',
      'anchorIndex': 7,
      'anchorOffsetRatio': .3
    });
    final saved = ReadingProgress.fromJson({
      'lastChapterIndex': 3,
      'lastPageIndex': 4,
      'lastPageCount': 20,
      'lastCharacterOffset': 1234,
      'lastContentMode': 'original',
      'lastLayoutKey': 'layout'
    });
    expect(saved.pageIndex, 4);
    expect(saved.characterOffset, 1234);
    expect(
        ReadingProgress.fromJson({'lastChapterIndex': 2, 'lastScrollRatio': .5})
            .pageIndex,
        isNull);
    expect(
        Book.fromJson({'lastReadChapterIndex': 3, 'lastReadPageIndex': 4})
            .readingPositionLabel,
        '第 3 章 · 第 5 页');
  });
}
