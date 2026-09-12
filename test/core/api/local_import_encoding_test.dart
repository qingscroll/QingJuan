import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/features/library/library_controller.dart';

void main() {
  test('local import carries selected encoding and translation into upload',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('qj-import-encoding-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/book.txt')
        .writeAsBytes([0xa4, 0xa4, 0xa4, 0xe5]);
    var uploads = 0;
    final api = ApiClient(() => 'https://backend.test',
        client: MockClient.streaming((request, body) async {
      if (request.method == 'GET') {
        return http.StreamedResponse(Stream.value(utf8.encode('[]')), 200);
      }
      uploads++;
      expect(request.url.path, '/api/v1/books/import-local');
      final bytes = await body.toBytes();
      final payload = latin1.decode(bytes);
      expect(payload, contains('name="textEncoding"\r\n\r\nbig5'));
      expect(payload, contains('name="needTranslation"\r\n\r\ntrue'));
      expect(payload, contains(latin1.decode([0xa4, 0xa4, 0xa4, 0xe5])));
      return http.StreamedResponse(
          Stream.value(utf8.encode('{"id":"imported","title":"book"}')), 200);
    }));
    addTearDown(api.close);
    final library = LibraryController(api);
    addTearDown(library.dispose);
    final book = await library.importLocal(
        filePath: file.path,
        kind: '长小说',
        language: '中文',
        translate: true,
        textEncoding: 'big5');
    expect(book.id, 'imported');
    expect(uploads, 1);
    expect(library.importProgress, isNull);
  });
}
