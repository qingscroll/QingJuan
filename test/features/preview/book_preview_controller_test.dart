import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/preview/book_preview_controller.dart';

import 'preview_fixtures.dart';

void main() {
  test('metadata keeps directory order restrictions and source status', () {
    final metadata = BookPreview.fromJson(previewMetadata);
    expect(metadata.chapters.map((chapter) => chapter.index), [1, 2, 3]);
    expect(metadata.chapters.last.accessRestricted, isTrue);
    expect(metadata.chapters.first.url, endsWith('/1'));
    expect(metadata.sourceStatusLabel, '连载中');
    final legacy = BookPreview.fromJson({'title': '旧服务作品'});
    expect(legacy.chapters, isEmpty);
    expect(legacy.sourceStatusLabel, '状态未知');
  });

  test('preview and reading never send imports progress or annotations',
      () async {
    final requests = <http.Request>[];
    final api = ApiClient(() => 'https://backend.test',
        client: MockClient((request) async {
      requests.add(request);
      return previewJson(request.url.path.endsWith('/chapter')
          ? previewContent(jsonDecode(request.body)['chapterIndex'] as int)
          : previewMetadata);
    }));
    final library = LibraryController(api);
    final controller = BookPreviewController(library, payload: previewPayload);
    addTearDown(() {
      controller.dispose();
      library.dispose();
      api.close();
    });
    await controller.load();
    await controller.loadChapter(2);
    expect(controller.chapter?.chapter.index, 2);
    expect(requests.map((request) => request.url.path),
        ['/api/v1/books/preview', '/api/v1/books/preview/chapter']);
    expect(jsonDecode(requests.last.body), {
      'book': previewPayload,
      'chapterIndex': 2,
      'expectedChapterUrl': 'https://books.example.test/mist/2'
    });
    await controller.loadChapter(3);
    expect(requests, hasLength(3));
    expect(controller.chapter?.chapter.index, 3);
    expect(controller.chapterError, isNull);
    await controller.loadChapter(4);
    expect(requests, hasLength(3));
    expect(library.books, isEmpty);
    expect(library.linkJob, isNull);
  });

  test('source denial on a flagged chapter stays visible and can retry',
      () async {
    var reads = 0;
    final requests = <http.Request>[];
    final api = ApiClient(() => 'https://backend.test',
        client: MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/chapter')) {
        reads++;
        return reads == 1
            ? previewJson({'detail': '来源账号尚未获得本章访问权限'}, 403)
            : previewJson(previewContent(3));
      }
      return previewJson(previewMetadata);
    }));
    final library = LibraryController(api);
    final controller = BookPreviewController(library, payload: previewPayload);
    addTearDown(() {
      controller.dispose();
      library.dispose();
      api.close();
    });
    await controller.load();
    await controller.loadChapter(3);
    expect(controller.chapter, isNull);
    expect(controller.chapterError, contains('来源账号尚未获得本章访问权限'));
    await controller.loadChapter(3);
    expect(controller.chapterError, isNull);
    expect(controller.chapter?.chapter.index, 3);
    expect(
        requests
            .every((request) => request.url.path.contains('/books/preview')),
        isTrue);
    expect(library.books, isEmpty);
    expect(library.linkJob, isNull);
  });

  test('failed metadata and chapter can retry without importing', () async {
    var previewCalls = 0;
    var chapterCalls = 0;
    final api = ApiClient(() => 'https://backend.test',
        client: MockClient((request) async {
      if (request.url.path.endsWith('/chapter')) {
        chapterCalls++;
        return chapterCalls == 1
            ? previewJson({'detail': '试读链接已失效'}, 404)
            : previewJson(previewContent(1));
      }
      previewCalls++;
      return previewCalls == 1
          ? previewJson({'detail': '书源暂不可用'}, 400)
          : previewJson(previewMetadata);
    }));
    final library = LibraryController(api);
    final controller = BookPreviewController(library, payload: previewPayload);
    addTearDown(() {
      controller.dispose();
      library.dispose();
      api.close();
    });
    await controller.load();
    expect(controller.error, contains('书源暂不可用'));
    await controller.load();
    expect(controller.error, isNull);
    await controller.loadChapter(1);
    expect(controller.chapterError, contains('试读链接已失效'));
    await controller.loadChapter(1);
    expect(controller.chapterError, isNull);
    expect(controller.chapter, isNotNull);
    expect(library.linkJob, isNull);
  });

  test(
      'directory conflict preserves preview and refresh uses updated chapter URL',
      () async {
    var directoryVersion = 1;
    final expectedUrls = <String>[];
    final api = ApiClient(() => 'https://backend.test',
        client: MockClient((request) async {
      if (request.url.path.endsWith('/chapter')) {
        final expected =
            jsonDecode(request.body)['expectedChapterUrl'] as String;
        expectedUrls.add(expected);
        return expected.endsWith('/old')
            ? previewJson({'detail': '书源目录已变化，请返回预览页重新加载目录'}, 409)
            : previewJson(previewContent(1));
      }
      return previewJson({
        ...previewMetadata,
        'chapters': [
          {
            'title': '潮汐带来的信',
            'url':
                'https://books.example.test/${directoryVersion == 1 ? 'old' : 'new'}'
          }
        ]
      });
    }));
    final library = LibraryController(api);
    final controller = BookPreviewController(library, payload: previewPayload);
    addTearDown(() {
      controller.dispose();
      library.dispose();
      api.close();
    });
    await controller.load();
    await controller.loadChapter(1);
    expect(controller.chapter, isNull);
    expect(controller.chapterError, contains('目录已变化'));
    expect(controller.preview, isNotNull);
    directoryVersion = 2;
    await controller.load();
    await controller.loadChapter(1);
    expect(expectedUrls,
        ['https://books.example.test/old', 'https://books.example.test/new']);
    expect(controller.chapter, isNotNull);
    expect(library.linkJob, isNull);
  });

  test('legacy directory omits expected URL and automatic update omits enabled',
      () async {
    final bodies = <Map<String, dynamic>>[];
    final api = ApiClient(() => 'https://backend.test',
        client: MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return previewJson(request.url.path.endsWith('/chapter')
          ? previewContent(1)
          : {'bookId': 'one'});
    }));
    addTearDown(api.close);
    await api.previewChapter(previewPayload, 1, expectedChapterUrl: '');
    await api.configureBookUpdates('one',
        expectedRevision: 2, intervalHours: 6, autoDownload: false);
    await api.configureBookUpdates('one',
        expectedRevision: 3,
        enabled: false,
        intervalHours: 6,
        autoDownload: false);
    expect(bodies.first.containsKey('expectedChapterUrl'), isFalse);
    expect(bodies[1].containsKey('enabled'), isFalse);
    expect(bodies[2]['enabled'], isFalse);
  });

  test('failed explicit add retains preview and can retry', () async {
    var imports = 0;
    final api = ApiClient(() => 'https://backend.test',
        client: MockClient((request) async {
      if (request.url.path.endsWith('/preview')) {
        return previewJson(previewMetadata);
      }
      if (request.url.path.endsWith('/books')) {
        return previewJson([importedPreviewBook]);
      }
      if (request.method != 'POST') {
        return previewJson(completedPreviewImport());
      }
      imports++;
      return imports == 1
          ? previewJson({'detail': '书源暂不可用'}, 400)
          : previewJson(completedPreviewImport());
    }));
    final library = LibraryController(api);
    final controller = BookPreviewController(library, payload: previewPayload);
    addTearDown(() {
      controller.dispose();
      library.dispose();
      api.close();
    });
    await controller.load();
    expect(await controller.addToLibrary(), isNull);
    expect(controller.importError, contains('书源暂不可用'));
    expect(controller.preview?.title, '雾海书简');
    expect(controller.importing, isFalse);
    expect((await controller.addToLibrary())?.id, 'imported-mist');
    expect(controller.importError, isNull);
    expect(imports, 2);
  });

  for (final stage in ['metadata', 'chapter']) {
    test('context switch rejects a late $stage response and further actions',
        () async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final api = ApiClient(() => 'https://backend.test',
          client: MockClient((request) async {
        calls++;
        if (stage == 'metadata' || request.url.path.endsWith('/chapter')) {
          return pending.future;
        }
        return previewJson(previewMetadata);
      }));
      final library = LibraryController(api);
      final controller =
          BookPreviewController(library, payload: previewPayload);
      addTearDown(() {
        controller.dispose();
        library.dispose();
        api.close();
      });
      if (stage == 'chapter') await controller.load();
      final load =
          stage == 'chapter' ? controller.loadChapter(1) : controller.load();
      library.resetForBackendSwitch();
      pending.complete(previewJson(
          stage == 'chapter' ? previewContent(1) : previewMetadata));
      await load;
      final before = calls;
      await controller.addToLibrary();
      await controller.load();
      await controller.loadChapter(1);
      expect(controller.invalidated, isTrue);
      expect(controller.preview, isNull);
      expect(controller.chapter, isNull);
      expect(calls, before);
    });
  }

  test('same-url instance change invalidates even without library reset',
      () async {
    var instance = 'one';
    final api = ApiClient(() => 'https://backend.test',
        client: MockClient((_) async => previewJson(previewMetadata)));
    final library = LibraryController(api);
    final controller = BookPreviewController(library,
        payload: previewPayload, isCurrentContext: () => instance == 'one');
    addTearDown(() {
      controller.dispose();
      library.dispose();
      api.close();
    });
    await controller.load();
    instance = 'two';
    controller.checkContext();
    expect(controller.invalidated, isTrue);
    expect(controller.preview, isNull);
  });

  test('duplicate add clicks create one import and then reuse the saved book',
      () async {
    final pending = Completer<http.Response>();
    var imports = 0;
    final api = ApiClient(() => 'https://backend.test',
        client: MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/link-jobs')) {
        imports++;
        return pending.future;
      }
      if (request.url.path.endsWith('/books')) {
        return previewJson([importedPreviewBook]);
      }
      return previewJson(completedPreviewImport());
    }));
    final library = LibraryController(api);
    final controller = BookPreviewController(library, payload: previewPayload);
    addTearDown(() {
      controller.dispose();
      library.dispose();
      api.close();
    });
    final first = controller.addToLibrary();
    expect(controller.importing, isTrue);
    expect(await controller.addToLibrary(), isNull);
    pending.complete(previewJson(completedPreviewImport()));
    final book = await first;
    expect(book?.id, 'imported-mist');
    expect(controller.existingBook?.id, 'imported-mist');
    expect((await controller.addToLibrary())?.id, 'imported-mist');
    expect(imports, 1);
  });

  test('existing library source opens without another import', () async {
    var calls = 0;
    final api =
        ApiClient(() => 'https://backend.test', client: MockClient((_) async {
      calls++;
      return previewJson({});
    }));
    final library = LibraryController(api)
      ..books = [Book.fromJson(importedPreviewBook)]
      ..state = LoadState.ready;
    final controller = BookPreviewController(library, payload: {
      ...previewPayload,
      'sourceUrl': '${previewPayload['sourceUrl']}#read'
    });
    addTearDown(() {
      controller.dispose();
      library.dispose();
      api.close();
    });
    expect((await controller.addToLibrary())?.id, 'imported-mist');
    expect(calls, 0);
  });

  test('preview image urls use current backend credentials only on same origin',
      () async {
    final api = ApiClient(() => 'https://backend.test',
        token: () => 'connection',
        userToken: () => 'session',
        client: MockClient((_) async => previewJson(previewContent(1, images: [
              '/api/v1/books/preview/assets/opaque/0',
              'books/preview/assets/opaque/1',
              'https://other.test/image.png',
            ]))));
    addTearDown(api.close);
    final content = await api.previewChapter(previewPayload, 1);
    expect(content.imageSources.first,
        'https://backend.test/api/v1/books/preview/assets/opaque/0');
    expect(content.imageSources[1],
        'https://backend.test/api/v1/books/preview/assets/opaque/1');
    expect(
        api.headersForUrl(content.imageSources.first)['X-QingJuan-User-Token'],
        'session');
    expect(api.headersForUrl(content.imageSources.last), isEmpty);
    expect(content.mode, 'original');
  });
}
