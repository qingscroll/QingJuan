import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/backend/lan_backend_share.dart';

Future<void> main() async {
  // Real sockets exercise authentication, streaming and revocation together.
  final addresses = await LanBackendShare.discoverAddresses();
  final skip =
      addresses.isEmpty ? 'No private IPv4 adapter on this host' : false;
  late LanBackendShare share;
  late HttpServer upstream;
  late HttpClient client;
  late String baseUrl;
  late String token;
  late List<HttpRequest> received;
  late Uri upstreamUri;
  setUp(() async {
    share = LanBackendShare();
    received = [];
    client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstreamUri = Uri.parse('http://127.0.0.1:${upstream.port}');
    upstream.listen((request) async {
      received.add(request);
      if (request.uri.path == '/api/v1/meta') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'service': 'qingjuan-backend',
          'apiVersion': '1',
          'instanceId': 'same-pc',
          'capabilities': {'multiUser': false}
        }));
      } else if (request.uri.path == '/api/v1/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('location', 'https://example.com/');
      } else if (request.uri.path == '/api/v1/file') {
        request.response.statusCode = 206;
        request.response.headers
            .set('content-type', 'application/octet-stream');
        request.response.headers.set('content-range', 'bytes 0-3/10');
        request.response.add([0, 128, 255, 10]);
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'body': await utf8.decoder.bind(request).join(),
          'query': request.uri.queryParameters,
          'authorization': request.headers.value('authorization'),
          'cookie': request.headers.value('cookie'),
          'userToken': request.headers.value('x-qingjuan-user-token'),
          'localRequest': request.headers.value('x-qingjuan-local-request'),
          'idempotencyKey': request.headers.value('idempotency-key'),
          'host': request.headers.value('host'),
        }));
      }
      await request.response.close();
    });
    if (addresses.isNotEmpty) {
      final link = await share.start(
          address: addresses.first.address, port: 0, upstream: upstreamUri);
      baseUrl = link.url;
      token = link.token;
    }
  });
  tearDown(() async {
    await share.stop();
    share.dispose();
    client.close(force: true);
    await upstream.close(force: true);
  });

  Future<HttpClientResponse> request(String path,
      {String? credential, String method = 'GET', String? body}) async {
    final outgoing = await client.openUrl(method, Uri.parse('$baseUrl$path'));
    outgoing.followRedirects = false;
    if (credential != null) {
      outgoing.headers.set('authorization', 'Bearer $credential');
    }
    outgoing.headers.set('cookie', 'must-not-forward');
    outgoing.headers.set('x-qingjuan-user-token', 'must-not-forward');
    outgoing.headers.set('idempotency-key', 'test-operation');
    if (body != null) outgoing.write(body);
    return outgoing.close();
  }

  test('bridge rejects missing/wrong credentials and non API routes', () async {
    for (final credential in [null, 'wrong-token']) {
      final response = await request('/api/v1/meta', credential: credential);
      expect(response.statusCode, 401);
      await response.drain<void>();
    }
    for (final path in [
      '/admin/',
      '/healthz',
      '/site-login/shaoniandream',
      '/api/v1/../../admin/'
    ]) {
      final response = await request(path, credential: token);
      expect(response.statusCode, 404);
      await response.drain<void>();
    }
    expect(received, isEmpty);
  }, skip: skip);

  test('metadata identifies the same backend and advertises desktop sharing',
      () async {
    final response = await request('/api/v1/meta', credential: token);
    expect(response.statusCode, 200);
    final meta = jsonDecode(await utf8.decoder.bind(response).join());
    expect(meta['instanceId'], 'same-pc');
    expect(meta['capabilities'], {'multiUser': false, 'desktopSharing': true});
    expect(response.headers.value('cache-control'), 'no-store');
  }, skip: skip);

  test('writes preserve data and query while isolating forwarded credentials',
      () async {
    final response = await request('/api/v1/books/progress?name=%E4%B9%A6&n=1',
        credential: token, method: 'PUT', body: '{"progress":0.6}');
    expect(response.statusCode, 200);
    final body = jsonDecode(await utf8.decoder.bind(response).join());
    expect(body['body'], '{"progress":0.6}');
    expect(body['query'], {'name': '书', 'n': '1'});
    expect(body['authorization'], isNull);
    expect(body['cookie'], isNull);
    expect(body['userToken'], isNull);
    expect(body['localRequest'], '1');
    expect(body['idempotencyKey'], 'test-operation');
    expect(body['host'], '127.0.0.1:${upstream.port}');
  }, skip: skip);

  test('binary range responses stream unchanged and redirects cannot escape',
      () async {
    final file = await request('/api/v1/file', credential: token);
    expect(file.statusCode, 206);
    expect(file.headers.value('content-range'), 'bytes 0-3/10');
    expect(await file.fold<List<int>>([], (all, bytes) => all..addAll(bytes)),
        [0, 128, 255, 10]);
    final redirect = await request('/api/v1/redirect', credential: token);
    expect(redirect.statusCode, 502);
    expect(redirect.headers.value('location'), isNull);
    await redirect.drain<void>();
  }, skip: skip);

  test('regenerating rotates credentials and stopping closes the listener',
      () async {
    final previousToken = token;
    final port = Uri.parse(baseUrl).port;
    final next = await share.start(
        address: addresses.first.address, port: port, upstream: upstreamUri);
    expect(next.token, isNot(previousToken));
    final rejected = await request('/api/v1/meta', credential: previousToken);
    expect(rejected.statusCode, 401);
    await rejected.drain<void>();
    await share.stop();
    expect(share.connection, isNull);
    expect(share.isSharing, isFalse);
    await expectLater(request('/api/v1/meta', credential: next.token),
        throwsA(anyOf(isA<SocketException>(), isA<HttpException>())));
  }, skip: skip);

  test('stopping during startup cannot reopen a cancelled listener', () async {
    final starting = share.start(
        address: addresses.first.address, port: 0, upstream: upstreamUri);
    final rejected = expectLater(starting, throwsStateError);
    await share.stop();
    await rejected;
    expect(share.isSharing, isFalse);
    expect(share.connection, isNull);
  }, skip: skip);
}
