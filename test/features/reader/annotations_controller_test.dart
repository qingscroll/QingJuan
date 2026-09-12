import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/reading_annotation.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/reader/annotation_selection.dart';
import 'package:qingjuan/features/reader/annotations_controller.dart';

void main() {
  late ApiClient api;
  late LibraryController library;
  late AnnotationsController controller;
  late Future<http.Response> Function(http.Request) handler;
  setUp(() {
    handler = (_) async => response([]);
    api = ApiClient(() => 'https://example.test',
        client: MockClient((request) => handler(request)));
    library = LibraryController(api);
    controller = AnnotationsController(api, library, 'book');
  });
  tearDown(() {
    controller.dispose();
    library.dispose();
    api.close();
  });

  test('older list cannot overwrite another filter or successful mutation',
      () async {
    final old = Completer<http.Response>();
    handler = (_) => old.future;
    final loading = controller.load();
    handler = (_) async => response([record('note', kind: 'note')]);
    await controller.load(filter: 'note');
    old.complete(response([record('bookmark')]));
    await loading;
    expect(controller.items.single.id, 'note');
    final stale = Completer<http.Response>();
    handler = (_) => stale.future;
    final refresh = controller.load();
    handler = (request) async => request.method == 'PATCH'
        ? response(record('note', revision: 2))
        : response([record('note', revision: 2)]);
    await controller.update(ReadingAnnotation.fromJson(record('note')),
        label: 'new', note: 'changed');
    stale.complete(response([record('stale')]));
    await refresh;
    expect(controller.items.single.revision, 2);
  });

  test('pagination passes raw offset and merges overlapping records', () async {
    final offsets = <String?>[];
    handler = (request) async {
      offsets.add(request.url.queryParameters['offset']);
      return response(offsets.length == 1
          ? List.generate(50, (i) => record('$i'))
          : [record('49'), record('50')]);
    };
    await controller.load();
    expect(controller.hasMore, isTrue);
    await controller.load(more: true);
    expect(offsets, ['0', '50']);
    expect(controller.items.length, 51);
    expect(controller.hasMore, isFalse);
  });

  test('delete revision conflict retains current record and exposes error',
      () async {
    handler = (_) async => response([record('a', revision: 4)]);
    await controller.load();
    handler = (request) async {
      expect(request.url.queryParameters['expectedRevision'], '4');
      return response({'detail': '其他设备已修改'}, 409);
    };
    expect(await controller.delete(controller.items.single), isFalse);
    expect(controller.error, contains('其他设备已修改'));
    expect(controller.items.single.id, 'a');
    expect(controller.saving, isFalse);
  });

  test(
      'duplicate save blocked and account switch discards late writes and searches',
      () async {
    final pending = Completer<http.Response>();
    var calls = 0;
    handler = (_) {
      calls++;
      return pending.future;
    };
    final write = controller.delete(ReadingAnnotation.fromJson(record('a')));
    expect(await controller.delete(ReadingAnnotation.fromJson(record('a'))),
        isFalse);
    final search = controller.search(query: 'needle');
    library.resetForBackendSwitch();
    pending.complete(response({}));
    expect(await write, isFalse);
    await search;
    expect(calls, 2);
    expect(controller.invalidated, isTrue);
    expect(controller.items, isEmpty);
    expect(controller.hits, isEmpty);
    expect(controller.searchError, isNull);
    expect(controller.searching, isFalse);
    await controller.load();
    expect(calls, 2);
  });

  test('latest search wins and continuation keeps original scope', () async {
    final old = Completer<http.Response>();
    handler = (_) => old.future;
    final stale = controller.search(query: 'old');
    handler = (_) async => response(searchResults('new', cursor: 'next'));
    await controller.search(query: 'new', mode: 'translated', chapterIndex: 3);
    old.complete(response(searchResults('old')));
    await stale;
    expect(controller.hits.single.snippet, 'new');
    handler = (request) async {
      expect(jsonDecode(request.body), {
        'query': 'new',
        'mode': 'translated',
        'limit': 50,
        'chapterIndex': 3,
        'cursor': 'next'
      });
      return response(searchResults('more'));
    };
    await controller.search(more: true);
    expect(controller.hits.map((hit) => hit.snippet), ['new', 'more']);
    expect(controller.nextCursor, isNull);
    expect(controller.scannedChapters, 2);
  });

  test(
      'invalid query or unsupported offset encoding never yields wrong anchors',
      () async {
    var calls = 0;
    handler = (_) async {
      calls++;
      return response({...searchResults('x'), 'offsetEncoding': 'bytes'});
    };
    await controller.search(query: '   ');
    expect(calls, 0);
    await controller.search(query: 'x');
    expect(controller.hits, isEmpty);
    expect(controller.searchError, contains('不支持的阅读位置格式'));
  });

  test(
      'annotation DTO retains UTF16 offset and selected repeated text uses page start',
      () {
    const progress = ReadingProgress(
        chapterIndex: 3,
        scrollRatio: .2,
        anchorType: 'paragraph',
        anchorIndex: 4,
        anchorOffsetRatio: .3,
        contentMode: 'translated',
        pageIndex: 2,
        pageCount: 5,
        characterOffset: 9007199254740991,
        layoutKey: 'layout');
    final result =
        AnnotationPosition.fromJson(const AnnotationPosition(progress).toJson())
            .progress;
    expect(result.characterOffset, progress.characterOffset);
    expect(result.anchorIndex, 4);
    expect(result.layoutKey, 'layout');
    expect(uniqueSelectedOffset('\ue000😀needle', 'needle'), 3);
    expect(uniqueSelectedOffset('needle and needle', 'needle'), 0);
    expect(annotationQuote('\ue000内容\ufffc'), '内容');
  });
}

Map<String, dynamic> record(String id,
        {String kind = 'bookmark', int revision = 1}) =>
    {
      'id': id,
      'bookId': 'book',
      'kind': kind,
      'label': id,
      'quote': '',
      'note': '',
      'position': {
        'chapterIndex': 1,
        'contentMode': 'original',
        'characterOffset': 3
      },
      'revision': revision,
      'createdAt': '',
      'updatedAt': ''
    };
Map<String, dynamic> searchResults(String snippet, {String? cursor}) => {
      'results': [
        {
          'chapterTitle': '第一章',
          'snippet': snippet,
          'contentHash': 'hash',
          'position': {
            'chapterIndex': 1,
            'contentMode': 'original',
            'characterOffset': 3
          }
        }
      ],
      'nextCursor': cursor,
      'offsetEncoding': 'utf-16',
      'scannedChapters': 1
    };
http.Response response(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status,
        headers: {'content-type': 'application/json'});
