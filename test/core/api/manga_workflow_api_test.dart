import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';

void main() {
  test('runImageWorkflow sends camelCase multipart contract and parses result',
      () async {
    final temporary = await Directory.systemTemp.createTemp('qingjuan-api-');
    addTearDown(() => temporary.delete(recursive: true));
    final source = File('${temporary.path}${Platform.pathSeparator}page.jpg');
    final translated =
        File('${temporary.path}${Platform.pathSeparator}translated.jpg');
    await source.writeAsBytes(<int>[1, 2, 3]);
    await translated.writeAsBytes(<int>[4, 5, 6]);

    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/images/workflow');
      expect(request.headers['content-type'], contains('multipart/form-data'));
      final body = utf8.decode(request.bodyBytes, allowMalformed: true);
      expect(body, contains('name="mode"'));
      expect(body, contains('replace_translation'));
      expect(body, contains('name="project"'));
      expect(body, contains('"regions"'));
      expect(body, contains('name="companion"'));
      expect(body, contains('name="upscaleFactor"'));
      expect(body, contains('name="translatedFile"'));
      expect(body, contains('translated.jpg'));
      return http.Response(
        jsonEncode(<String, dynamic>{
          'mode': 'replace_translation',
          'imageKey': 'page.jpg',
          'mimeType': 'image/png',
          'outputImageBase64': base64Encode(<int>[9, 8, 7]),
          'project': <String, dynamic>{
            'regions': <dynamic>[],
            'original_width': 100,
            'original_height': 200,
          },
          'projectDocument': <String, dynamic>{
            'page.jpg': <String, dynamic>{'regions': <dynamic>[]},
          },
          'original': <String, dynamic>{'0': '原文'},
          'translated': <String, dynamic>{'0': '译文'},
          'diagnostics': <String, dynamic>{'stage': 'done'},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = ApiClient(
      () => 'http://127.0.0.1:19453',
      client: client,
    );
    addTearDown(api.close);

    final result = await api.runImageWorkflow(
      filePath: source.path,
      mode: 'replace_translation',
      project: <String, dynamic>{'regions': <dynamic>[]},
      companion: <String, dynamic>{'0': '译文'},
      translatedFilePath: translated.path,
      upscaleFactor: 4,
    );

    expect(result.mode, 'replace_translation');
    expect(result.imageKey, 'page.jpg');
    expect(result.outputImageBase64, isNotEmpty);
    expect(result.translated, <String, dynamic>{'0': '译文'});
    expect(result.diagnostics['stage'], 'done');
  });

  test('runImageWorkflow forwards an abort trigger to the HTTP client',
      () async {
    final temporary = await Directory.systemTemp.createTemp('qingjuan-abort-');
    addTearDown(() => temporary.delete(recursive: true));
    final source = File('${temporary.path}${Platform.pathSeparator}page.png');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final abort = Completer<void>();
    final client = MockClient.streaming((request, bodyStream) async {
      expect(request, isA<http.AbortableMultipartRequest>());
      final abortable = request as http.AbortableMultipartRequest;
      expect(abortable.abortTrigger, same(abort.future));
      await abortable.abortTrigger;
      throw http.RequestAbortedException(request.url);
    });
    final api = ApiClient(
      () => 'http://127.0.0.1:19453',
      client: client,
    );
    addTearDown(api.close);

    final request = api.runImageWorkflow(
      filePath: source.path,
      mode: 'normal',
      abortTrigger: abort.future,
    );
    abort.complete();

    await expectLater(request, throwsA(isA<http.RequestAbortedException>()));
  });

  test('saveMangaBookshelfTranslation sends a sorted chapter batch', () async {
    late Map<String, dynamic> payload;
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(
        request.url.path,
        '/api/v1/books/book-1/chapters/7/manga-translation',
      );
      expect(request.headers['content-type'], contains('application/json'));
      payload = Map<String, dynamic>.from(
        jsonDecode(request.body) as Map,
      );
      return http.Response(
        '{}',
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    });
    final api = ApiClient(
      () => 'http://127.0.0.1:19453',
      client: client,
    );
    addTearDown(api.close);

    await api.saveMangaBookshelfTranslation(
      bookId: 'book-1',
      chapterIndex: 7,
      targetLanguage: '中文',
      pages: <Map<String, dynamic>>[
        <String, dynamic>{
          'pageNumber': 2,
          'outputImageBase64': 'page-2',
          'project': <String, dynamic>{'regions': <dynamic>[]},
          'pageTranslation': '第二页',
        },
        <String, dynamic>{
          'pageNumber': 1,
          'outputImageBase64': 'page-1',
          'project': <String, dynamic>{'regions': <dynamic>[]},
          'pageTranslation': '第一页',
        },
      ],
    );

    expect(payload['targetLanguage'], '中文');
    final pages = (payload['pages'] as List).cast<Map<String, dynamic>>();
    expect(pages.map((page) => page['pageNumber']), <int>[1, 2]);
    expect(pages.first.keys, <String>[
      'pageNumber',
      'outputImageBase64',
      'project',
      'pageTranslation',
    ]);
  });
}
