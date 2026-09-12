import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';

void main() {
  test(
      'metadata PATCH sends a single versioned mutation and preserves null resets',
      () async {
    var calls = 0;
    final api = ApiClient(() => 'https://server.test',
        client: MockClient((request) async {
      calls++;
      expect(request.method, 'PATCH');
      expect(jsonDecode(request.body), {'title': null, 'expectedRevision': 3});
      return http.Response('{"detail":"conflict"}', 409);
    }));
    addTearDown(api.close);
    await expectLater(
        api.updateBookMetadata('book',
            expectedRevision: 3, changes: {'title': null}),
        throwsA(isA<ApiException>()));
    expect(calls, 1);
  });

  test('offline images authenticate same backend assets without redirects',
      () async {
    var calls = 0;
    final api = ApiClient(() => 'https://server.test/qj',
        token: () => 'connection',
        userToken: () => 'session',
        client: MockClient((request) async {
          calls++;
          expect(request.url.path, '/qj/api/v1/books/book/assets/images/1.jpg');
          expect(request.followRedirects, isFalse);
          expect(request.headers['X-QingJuan-User-Token'], 'session');
          return http.Response.bytes([1, 2, 3], 200);
        }));
    addTearDown(api.close);
    expect(await api.fetchOfflineImage('/books/book/assets/images/1.jpg'),
        [1, 2, 3]);
    for (final bad in [
      'https://elsewhere.test/api/v1/books/book/assets/1.jpg',
      '/books/book/progress',
      '/books/book/assets/%2e%2e/private',
      '/books/book/assets/%2fprivate'
    ]) {
      await expectLater(
          api.fetchOfflineImage(bad), throwsA(isA<ApiException>()));
    }
    expect(calls, 1);
  });

  test(
      'offline images enforce streaming size limit when Content-Length is absent',
      () async {
    final api = ApiClient(() => 'https://server.test',
        client:
            MockClient.streaming((request, _) async => http.StreamedResponse(
                Stream.fromIterable([
                  [1, 2],
                  [3, 4]
                ]),
                200)));
    addTearDown(api.close);
    await expectLater(
        api.fetchOfflineImage('/books/book/assets/1.jpg', maximumBytes: 3),
        throwsA(isA<ApiException>()));
  });

  test(
      'offline images discard late results after account switch and reject redirects',
      () async {
    var session = 'first';
    final pending = Completer<http.Response>();
    final api = ApiClient(() => 'https://server.test',
        userToken: () => session, client: MockClient((_) => pending.future));
    addTearDown(api.close);
    final result = api.fetchOfflineImage('/books/book/assets/1.jpg');
    session = 'second';
    pending.complete(http.Response.bytes([1], 200));
    await expectLater(result, throwsA(isA<ApiException>()));
    final redirects = ApiClient(() => 'https://server.test',
        client: MockClient((_) async => http.Response('', 302,
            headers: {'location': 'https://elsewhere.test'})));
    addTearDown(redirects.close);
    await expectLater(redirects.fetchOfflineImage('/books/book/assets/1.jpg'),
        throwsA(isA<ApiException>()));
  });
}
