import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';

void main() {
  test('downloadUrlToFile authenticates only same-origin backend assets',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-api-download-');
    addTearDown(() => temporary.delete(recursive: true));
    final requests = <http.Request>[];
    final api = ApiClient(
      () => 'https://backend.example.test',
      token: () => 'connection-secret',
      userToken: () => 'user-secret',
      deviceHeaders: () => const <String, String>{
        'X-QingJuan-Device-Id': 'device-1',
        'X-QingJuan-Device-Token': 'device-secret',
      },
      client: MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(<int>[1, 2, 3], 200);
      }),
    );
    addTearDown(api.close);

    final backendTarget = File(
      '${temporary.path}${Platform.pathSeparator}backend.png',
    );
    final externalTarget = File(
      '${temporary.path}${Platform.pathSeparator}external.png',
    );
    await api.downloadUrlToFile(
      '/books/book-1/assets/images/page.png',
      backendTarget.path,
    );
    await api.downloadUrlToFile(
      'https://cdn.example.test/images/page.png',
      externalTarget.path,
    );

    expect(requests, hasLength(2));
    expect(
      requests.first.url.toString(),
      'https://backend.example.test/api/v1/books/book-1/assets/images/page.png',
    );
    expect(
      requests.first.headers,
      containsPair('authorization', 'Bearer connection-secret'),
    );
    expect(
      requests.first.headers,
      containsPair('x-qingjuan-user-token', 'user-secret'),
    );
    expect(
      requests.first.headers,
      containsPair('x-qingjuan-device-id', 'device-1'),
    );
    expect(
      requests.first.headers,
      containsPair('x-qingjuan-device-token', 'device-secret'),
    );
    expect(requests.last.url.host, 'cdn.example.test');
    expect(requests.last.headers, isEmpty);
    expect(await backendTarget.readAsBytes(), <int>[1, 2, 3]);
    expect(await externalTarget.readAsBytes(), <int>[1, 2, 3]);
  });

  test('downloadUrlToFile replaces atomically and removes sidecars', () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-api-atomic-');
    addTearDown(() => temporary.delete(recursive: true));
    final target = File('${temporary.path}${Platform.pathSeparator}page.jpg');
    await target.writeAsBytes(<int>[1, 2, 3]);
    final api = ApiClient(
      () => 'http://127.0.0.1:19453',
      client: MockClient(
        (_) async => http.Response.bytes(<int>[9, 8, 7, 6], 200),
      ),
    );
    addTearDown(api.close);

    await api.downloadUrlToFile(
      '/books/book-1/assets/page.jpg',
      target.path,
    );

    expect(await target.readAsBytes(), <int>[9, 8, 7, 6]);
    expect(await File('${target.path}.qingjuan-part').exists(), isFalse);
    expect(await File('${target.path}.qingjuan-backup').exists(), isFalse);
  });

  test('downloadUrlToFile preserves the old file when streaming fails',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-api-failure-');
    addTearDown(() => temporary.delete(recursive: true));
    final target = File('${temporary.path}${Platform.pathSeparator}page.png');
    await target.writeAsBytes(<int>[4, 5, 6]);
    final api = ApiClient(
      () => 'http://127.0.0.1:19453',
      client: _StreamingClient(
        Stream<List<int>>.multi((controller) {
          controller.add(<int>[9, 9]);
          controller.addError(StateError('connection interrupted'));
          controller.close();
        }),
      ),
    );
    addTearDown(api.close);

    await expectLater(
      api.downloadUrlToFile(
        '/books/book-1/assets/page.png',
        target.path,
      ),
      throwsA(isA<StateError>()),
    );

    expect(await target.readAsBytes(), <int>[4, 5, 6]);
    expect(await File('${target.path}.qingjuan-part').exists(), isFalse);
    expect(await File('${target.path}.qingjuan-backup').exists(), isFalse);
  });

  test('downloadUrlToFile restores an interrupted replacement before retrying',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-api-recovery-');
    addTearDown(() => temporary.delete(recursive: true));
    final target = File('${temporary.path}${Platform.pathSeparator}page.png');
    final backup = File('${target.path}.qingjuan-backup');
    await backup.writeAsBytes(<int>[4, 5, 6]);
    final api = ApiClient(
      () => 'http://127.0.0.1:19453',
      client: _StreamingClient(
        Stream<List<int>>.error(StateError('connection interrupted')),
      ),
    );
    addTearDown(api.close);

    await expectLater(
      api.downloadUrlToFile(
        '/books/book-1/assets/page.png',
        target.path,
      ),
      throwsA(isA<StateError>()),
    );

    expect(await target.readAsBytes(), <int>[4, 5, 6]);
    expect(await backup.exists(), isFalse);
    expect(await File('${target.path}.qingjuan-part').exists(), isFalse);
  });

  test('backup cleanup failure does not fail a committed download', () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-api-cleanup-');
    addTearDown(() => temporary.delete(recursive: true));
    final target = File('${temporary.path}${Platform.pathSeparator}page.jpg');
    final backup = File('${target.path}.qingjuan-backup');
    await target.writeAsBytes(<int>[1, 2, 3]);
    final api = ApiClient(
      () => 'http://127.0.0.1:19453',
      client: MockClient(
        (_) async => http.Response.bytes(<int>[9, 8, 7], 200),
      ),
      deleteDownloadBackup: (_) async {
        throw const FileSystemException('simulated locked backup');
      },
    );
    addTearDown(api.close);

    await api.downloadUrlToFile(
      '/books/book-1/assets/page.jpg',
      target.path,
    );

    expect(await target.readAsBytes(), <int>[9, 8, 7]);
    expect(await backup.readAsBytes(), <int>[1, 2, 3]);
    expect(await File('${target.path}.qingjuan-part').exists(), isFalse);
  });
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.stream);

  final Stream<List<int>> stream;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      stream,
      200,
      contentLength: 4,
      request: request,
    );
  }
}
