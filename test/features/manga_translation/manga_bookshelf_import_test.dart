import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/features/manga_translation/manga_bookshelf_import.dart';

void main() {
  test('imports selected manga chapters as ordered original pages', () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-bookshelf-import-');
    addTearDown(() => temporary.delete(recursive: true));
    final chapterRequests = <Uri>[];
    final assetRequests = <Uri>[];
    final progress = <MangaBookshelfImportProgress>[];
    final api = ApiClient(
      () => 'https://backend.example.test',
      token: () => 'connection-secret',
      userToken: () => 'user-secret',
      client: MockClient((request) async {
        final uri = request.url;
        if (uri.path == '/api/v1/books/book-1') {
          return _jsonResponse(_mangaDetail);
        }
        if (uri.path == '/api/v1/books/book-1/chapters/2') {
          chapterRequests.add(uri);
          return _jsonResponse(
            _chapterPayload(
              index: 2,
              title: '第二/话',
              images: const <String>[
                '/books/book-1/assets/source/chapter-2/b.webp',
                '/books/book-1/assets/source/chapter-2/a.jpg',
              ],
            ),
          );
        }
        if (uri.path == '/api/v1/books/book-1/chapters/10') {
          chapterRequests.add(uri);
          return _jsonResponse(
            _chapterPayload(
              index: 10,
              title: '第十话',
              images: const <String>[
                '/books/book-1/assets/source/chapter-10/page.png',
              ],
            ),
          );
        }
        if (uri.path.contains('/api/v1/books/book-1/assets/')) {
          assetRequests.add(uri);
          expect(
            request.headers,
            containsPair('authorization', 'Bearer connection-secret'),
          );
          expect(
            request.headers,
            containsPair('x-qingjuan-user-token', 'user-secret'),
          );
          return http.Response.bytes(
            utf8.encode(uri.path),
            200,
            headers: const <String, String>{'content-type': 'image/png'},
          );
        }
        return _jsonResponse(<String, Object?>{'detail': 'not found'}, 404);
      }),
    );
    addTearDown(api.close);
    final importer = MangaBookshelfImporter(
      api,
      resolveApplicationSupportDirectory: () async => temporary,
    );
    final request = MangaBookshelfImportRequest(
      workspaceIdentity: 'https://backend.example.test:user-1',
      bookId: 'book-1',
      bookTitle: '测试漫画',
      language: '日文',
      chapterIndexes: const <int>[10, 2, 10],
    );

    final first = await importer.importBook(
      request,
      onProgress: progress.add,
    );

    expect(chapterRequests.map((uri) => uri.path), <String>[
      '/api/v1/books/book-1/chapters/2',
      '/api/v1/books/book-1/chapters/10',
    ]);
    for (final uri in chapterRequests) {
      expect(uri.queryParameters['mode'], 'original');
      expect(uri.queryParameters['prefetch'], 'true');
    }
    expect(assetRequests, hasLength(3));
    expect(first.chapterCount, 2);
    expect(first.bookId, 'book-1');
    expect(
      first.filePaths
          .map((file) => path.relative(file, from: first.sourceRoot)),
      <String>[
        path.join('source', '0002-第二_话', 'page-0001.webp'),
        path.join('source', '0002-第二_话', 'page-0002.jpg'),
        path.join('source', '0010-第十话', 'page-0001.png'),
      ],
    );
    expect(
      first.filePaths.map((filePath) {
        final target = first.pageTargets[_pathKey(filePath)]!;
        return '${target.bookId}:${target.chapterIndex}:${target.pageNumber}';
      }),
      <String>['book-1:2:1', 'book-1:2:2', 'book-1:10:1'],
    );
    expect(progress.last.completedPages, 3);
    expect(progress.last.totalPages, 3);
    for (final filePath in first.filePaths) {
      expect(await File(filePath).exists(), isTrue, reason: filePath);
    }

    final project = File(
      path.join(
        path.dirname(first.filePaths.first),
        'manga_translator_work',
        'json',
        'page-0001_translations.json',
      ),
    );
    await project.parent.create(recursive: true);
    await project.writeAsString('{"regions":[]}');
    final stalePage = File(
      path.join(path.dirname(first.filePaths.first), 'page-0099.jpg'),
    );
    await stalePage.writeAsBytes(<int>[0]);
    chapterRequests.clear();
    assetRequests.clear();

    final second = await importer.importBook(request);

    expect(second.sourceRoot, first.sourceRoot);
    expect(second.filePaths, first.filePaths);
    expect(await project.readAsString(), '{"regions":[]}');
    expect(await stalePage.exists(), isFalse);
  });

  test('rejects non-manga books before creating an import workspace', () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-bookshelf-novel-');
    addTearDown(() => temporary.delete(recursive: true));
    var supportDirectoryRequested = false;
    var requestCount = 0;
    final api = ApiClient(
      () => 'http://127.0.0.1:19453',
      client: MockClient((request) async {
        requestCount += 1;
        expect(request.url.path, '/api/v1/books/novel-1');
        return _jsonResponse(<String, Object?>{
          ..._mangaDetail,
          'book': <String, Object?>{
            ...(_mangaDetail['book']! as Map<String, Object?>),
            'id': 'novel-1',
            'bookKind': '长小说',
          },
        });
      }),
    );
    addTearDown(api.close);
    final importer = MangaBookshelfImporter(
      api,
      resolveApplicationSupportDirectory: () async {
        supportDirectoryRequested = true;
        return temporary;
      },
    );

    await expectLater(
      importer.importBook(
        MangaBookshelfImportRequest(
          workspaceIdentity: 'local:test',
          bookId: 'novel-1',
          bookTitle: '不是漫画',
          language: '中文',
        ),
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          contains('只有漫画书籍'),
        ),
      ),
    );

    expect(requestCount, 1);
    expect(supportDirectoryRequested, isFalse);
    expect(await temporary.list().toList(), isEmpty);
  });
}

http.Response _jsonResponse(Object payload, [int statusCode = 200]) {
  return http.Response(
    jsonEncode(payload),
    statusCode,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

Map<String, Object?> _chapterPayload({
  required int index,
  required String title,
  required List<String> images,
}) {
  return <String, Object?>{
    'bookId': 'book-1',
    'chapter': <String, Object?>{
      'id': 'book-1-chapter-$index',
      'index': index,
      'title': title,
      'downloaded': true,
      'translated': false,
      'wordCount': 0,
      'imageCount': images.length,
    },
    'content': '',
    'paragraphs': const <String>[],
    'mode': 'original',
    'translatedAvailable': false,
    'imageSources': images,
    'pageTranslations': const <String>[],
  };
}

final Map<String, Object?> _mangaDetail = <String, Object?>{
  'book': <String, Object?>{
    'id': 'book-1',
    'title': '测试漫画',
    'sourceUrl': 'https://source.example.test/book-1',
    'bookKind': '漫画',
    'language': '日文',
    'status': '已导入',
    'chapterCount': 2,
    'translated': false,
    'synopsis': '',
    'lastReadChapterIndex': 2,
  },
  'author': '作者',
  'synopsis': '',
  'totalWords': 0,
  'downloadedChapterCount': 2,
  'translatedChapterCount': 0,
  'progress': <String, Object?>{
    'lastChapterIndex': 2,
    'lastScrollRatio': 0,
  },
  'chapters': <Object?>[
    <String, Object?>{
      'id': 'book-1-chapter-10',
      'index': 10,
      'title': '第十话',
      'downloaded': true,
      'translated': false,
      'wordCount': 0,
      'imageCount': 1,
    },
    <String, Object?>{
      'id': 'book-1-chapter-2',
      'index': 2,
      'title': '第二/话',
      'downloaded': true,
      'translated': false,
      'wordCount': 0,
      'imageCount': 2,
    },
  ],
};

String _pathKey(String value) {
  final normalized = path.normalize(File(value).absolute.path);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}
