import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/reader/reader_progress.dart';

void main() {
  test('same layout restores the exact page instead of the old ratio', () {
    const saved = ReadingProgress(
        chapterIndex: 4,
        scrollRatio: .9,
        pageIndex: 2,
        pageCount: 5,
        layoutKey: 'layout',
        contentMode: 'original',
        characterOffset: 9);
    expect(
        readerRestoredPage(saved, const ['aa', 'bb', 'cc', 'dd', 'ee'],
            layoutKey: 'layout', contentMode: 'original'),
        2);
    expect(
        readerRestoredPage(saved, const ['aabb', 'ccdd', 'ee'],
            layoutKey: 'larger-font', contentMode: 'original'),
        2);
  });

  test('legacy ratio and changed content mode have bounded fallbacks', () {
    const saved = ReadingProgress(chapterIndex: 1, scrollRatio: .5);
    expect(
        readerRestoredPage(saved, const ['a', 'b', 'c'],
            layoutKey: 'layout', contentMode: 'translated'),
        1);
    const original = ReadingProgress(
        chapterIndex: 1,
        scrollRatio: .5,
        pageIndex: 9,
        contentMode: 'original',
        characterOffset: 999);
    expect(
        readerRestoredPage(original, const ['a', 'b', 'c'],
            layoutKey: 'layout', contentMode: 'translated'),
        1);
  });

  test('slow progress requests are serialized and intermediate pages coalesced',
      () async {
    final firstResponse = Completer<http.Response>();
    final pages = <int?>[];
    final api =
        ApiClient(() => 'https://example.test', client: MockClient((request) {
      pages.add((jsonDecode(request.body) as Map)['pageIndex'] as int?);
      return pages.length == 1
          ? firstResponse.future
          : Future.value(http.Response('{}', 200));
    }));
    final writer = ReaderProgressWriter(api, 'book');
    addTearDown(api.close);
    addTearDown(writer.dispose);
    unawaited(writer.save(
        const ReadingProgress(chapterIndex: 1, scrollRatio: 0, pageIndex: 0)));
    await Future<void>.delayed(Duration.zero);
    unawaited(writer.save(
        const ReadingProgress(chapterIndex: 1, scrollRatio: .2, pageIndex: 1)));
    final done = writer.save(
        const ReadingProgress(chapterIndex: 2, scrollRatio: .4, pageIndex: 4));
    expect(pages, [0]);
    firstResponse.complete(http.Response('{}', 200));
    await done;
    expect(pages, [0, 4]);
  });

  test('queued progress cannot write to another account or backend', () async {
    var backend = 'https://one.example.test';
    final requests = <http.Request>[];
    final api = ApiClient(() => backend, client: MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    }));
    final writer = ReaderProgressWriter(api, 'book');
    backend = 'https://two.example.test';
    await writer.save(const ReadingProgress(chapterIndex: 2, scrollRatio: .3));
    expect(requests, isEmpty);
    writer.dispose();
    api.close();
  });
}
