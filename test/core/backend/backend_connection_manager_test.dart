import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/backend/local_backend_process.dart';
import 'package:qingjuan/core/models/settings.dart';

void main() {
  test('remote client accepts authenticated desktop sharing and heartbeat',
      () async {
    final api = ApiClient(() => 'http://192.168.1.20:19454',
        token: () => 'shared-token',
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer shared-token');
          return http.Response(
              jsonEncode({
                'service': 'qingjuan-backend',
                'apiVersion': '1',
                'capabilities': {'multiUser': false, 'desktopSharing': true},
              }),
              200);
        }));
    final manager = BackendConnectionManager(api, isConfigured: () => true);
    await manager.testRemoteConnection(
        baseUrl: 'http://192.168.1.20:19454', token: 'shared-token');
    await manager.ensureReady();
    expect(manager.status, BackendStatus.ready);
    expect(manager.multiUserEnabled, isFalse);
    expect(manager.message, 'PC 局域网后端已连接');
    await manager.probeRemoteHealth();
    expect(manager.status, BackendStatus.ready);
    await manager.dispose();
    api.close();
  });
  test('unconfigured client does not make a network request', () async {
    final api = ApiClient(
      () => '',
      client: MockClient((request) async {
        fail('unconfigured client must not request ${request.url}');
      }),
    );
    final manager = BackendConnectionManager(
      api,
      isConfigured: () => false,
    );

    await manager.ensureReady();

    expect(manager.status, BackendStatus.unconfigured);
    expect(manager.message, contains('Linux 后端'));
    await manager.dispose();
    api.close();
  });

  test('connection failure never falls back to a local process', () async {
    final api = ApiClient(
      () => 'https://qingjuan.example.test',
      token: () => 'invalid-token',
      client: MockClient((request) async {
        expect(request.url.path, '/api/v1/meta');
        return http.Response('{"detail":"连接凭据无效"}', 401);
      }),
    );
    final manager = BackendConnectionManager(
      api,
      isConfigured: () => true,
    );

    await manager.ensureReady();

    expect(manager.status, BackendStatus.failed);
    expect(manager.message, contains('Linux 后端连接失败'));
    await manager.dispose();
    api.close();
  });

  test('invalid persisted address fails before making a request', () async {
    final api = ApiClient(
      () => 'http://127.0.0.1:19453',
      client: MockClient((request) async {
        fail('invalid address must not request ${request.url}');
      }),
    );
    final manager = BackendConnectionManager(
      api,
      isConfigured: () => true,
      validateConfiguration: () => throw const FormatException('不能使用手机回环地址'),
    );

    await manager.ensureReady();

    expect(manager.status, BackendStatus.failed);
    expect(manager.message, contains('不能使用手机回环地址'));
    await manager.dispose();
    api.close();
  });

  test('local mode starts the Windows lifecycle without requiring a token',
      () async {
    final api = ApiClient(
      () => 'http://127.0.0.1:19453',
      client: MockClient((request) async {
        fail('fake local lifecycle should provide metadata directly');
      }),
    );
    final lifecycle = _FakeLocalBackendLifecycle(
      meta: <String, dynamic>{
        'service': 'qingjuan-backend',
        'apiVersion': '1',
        'capabilities': <String, dynamic>{},
      },
    );
    final manager = BackendConnectionManager(
      api,
      isConfigured: () => false,
      isLocal: () => true,
      localBackend: lifecycle,
    );

    await manager.ensureReady();

    expect(manager.status, BackendStatus.ready);
    expect(manager.message, contains('本机后端已连接'));
    expect(lifecycle.ensureCalls, 1);
    await manager.dispose();
    expect(lifecycle.stopCalls, 1);
    api.close();
  });

  test('local startup failure remains local and reports a diagnostic',
      () async {
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    final lifecycle = _FakeLocalBackendLifecycle(
      error: StateError('未找到随包后端'),
    );
    final manager = BackendConnectionManager(
      api,
      isConfigured: () => true,
      isLocal: () => true,
      localBackend: lifecycle,
    );

    await manager.ensureReady();

    expect(manager.status, BackendStatus.failed);
    expect(manager.message, contains('未找到随包后端'));
    expect(manager.message, isNot(contains('Linux 后端')));
    await manager.dispose();
    api.close();
  });

  test('remote mode stops an owned local process before connecting', () async {
    final api = ApiClient(() => '');
    final lifecycle = _FakeLocalBackendLifecycle();
    final manager = BackendConnectionManager(
      api,
      isConfigured: () => false,
      isLocal: () => false,
      localBackend: lifecycle,
    );

    await manager.ensureReady();

    expect(manager.status, BackendStatus.unconfigured);
    expect(lifecycle.stopCalls, 1);
    await manager.dispose();
    api.close();
  });

  test('remote server without multi-user capability is rejected', () async {
    final api = ApiClient(
      () => 'https://qingjuan.example.test',
      token: () => 'connection-token',
      client: MockClient((request) async => http.Response(
            '{"service":"qingjuan-backend","apiVersion":"1",'
            '"capabilities":{}}',
            200,
          )),
    );
    final manager = BackendConnectionManager(api, isConfigured: () => true);

    await manager.ensureReady();

    expect(manager.status, BackendStatus.failed);
    expect(manager.message, contains('不支持多用户书架'));
    expect(manager.multiUserEnabled, isFalse);
    await manager.dispose();
    api.close();
  });

  test('ready connection defers model check until the user session is ready',
      () async {
    final requestedPaths = <String>[];
    final api = ApiClient(
      () => 'https://qingjuan.example.test',
      token: () => 'connection-token',
      client: MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path == '/api/v1/meta') {
          return http.Response(
            '{"service":"qingjuan-backend","apiVersion":"1",'
            '"capabilities":{"translationModelCheck":true,"multiUser":true}}',
            200,
          );
        }
        expect(request.method, 'POST');
        expect(request.url.queryParameters['force'], 'false');
        return http.Response.bytes(
          utf8.encode(
            '{"enabled":true,"configured":true,"available":true,'
            '"status":"ready","model":"server-model","supportsVision":false,'
            '"checkedAt":"2030-01-01T00:00:00Z","latencyMs":24,'
            '"message":"自检通过","cached":false}',
          ),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    final manager = BackendConnectionManager(api, isConfigured: () => true);

    await manager.ensureReady();

    expect(manager.status, BackendStatus.ready);
    expect(manager.translationModelCheck, isNull);
    expect(manager.message, 'Linux 后端已连接');
    expect(requestedPaths, <String>['/api/v1/meta']);

    await manager.checkTranslationModel();

    expect(manager.translationModelCheck?.status,
        TranslationModelCheckStatus.ready);
    expect(manager.translationModelCheck?.model, 'server-model');
    expect(requestedPaths,
        <String>['/api/v1/meta', '/api/v1/translation-model/check']);
    await manager.dispose();
    api.close();
  });

  test('model check failure keeps reading connection ready with warning',
      () async {
    final api = ApiClient(
      () => 'https://qingjuan.example.test',
      token: () => 'connection-token',
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/meta') {
          return http.Response(
            '{"service":"qingjuan-backend","apiVersion":"1",'
            '"capabilities":{"translationModelCheck":true,"multiUser":true}}',
            200,
          );
        }
        return http.Response.bytes(
          utf8.encode(
            '{"enabled":true,"configured":true,"available":false,'
            '"status":"failed","model":"server-model","supportsVision":false,'
            '"checkedAt":"2030-01-01T00:00:00Z","latencyMs":null,'
            '"message":"翻译服务自检超时","cached":false}',
          ),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    final manager = BackendConnectionManager(api, isConfigured: () => true);

    await manager.ensureReady();
    await manager.checkTranslationModel();

    expect(manager.status, BackendStatus.ready);
    expect(manager.translationModelCheck?.available, isFalse);
    expect(manager.translationModelCheck?.message, contains('翻译服务自检超时'));
    expect(manager.message, 'Linux 后端已连接');
    await manager.dispose();
    api.close();
  });

  test('heartbeat reports an interrupted restart and recovers automatically',
      () async {
    var metaRequests = 0;
    final api = ApiClient(
      () => 'https://qingjuan.example.test',
      token: () => 'connection-token',
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/devices/heartbeat') {
          return http.Response('', 204);
        }
        expect(request.url.path, '/api/v1/meta');
        metaRequests += 1;
        if (metaRequests == 2) {
          return http.Response('{"detail":"restarting"}', 503);
        }
        return http.Response(
          '{"service":"qingjuan-backend","apiVersion":"1",'
          '"capabilities":{"translationModelCheck":true,"multiUser":true}}',
          200,
        );
      }),
    );
    final manager = BackendConnectionManager(api, isConfigured: () => true);
    var notifications = 0;
    manager.addListener(() => notifications += 1);

    await manager.ensureReady();
    await manager.probeRemoteHealth();

    expect(manager.status, BackendStatus.failed);
    expect(manager.message, contains('等待服务恢复'));

    await manager.probeRemoteHealth();

    expect(manager.status, BackendStatus.ready);
    expect(manager.message, 'Linux 后端已连接');
    expect(notifications, greaterThanOrEqualTo(4));
    await manager.dispose();
    api.close();
  });

  test('an initial restart failure keeps probing until the backend recovers',
      () async {
    var metaRequests = 0;
    final recovered = Completer<void>();
    final api = ApiClient(
      () => 'https://qingjuan.example.test',
      token: () => 'connection-token',
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/devices/heartbeat') {
          return http.Response('', 204);
        }
        metaRequests += 1;
        if (metaRequests == 1) {
          return http.Response('{"detail":"restarting"}', 503);
        }
        return http.Response(
          '{"service":"qingjuan-backend","apiVersion":"1",'
          '"capabilities":{"translationModelCheck":true,"multiUser":true}}',
          200,
        );
      }),
    );
    final manager = BackendConnectionManager(
      api,
      isConfigured: () => true,
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    manager.addListener(() {
      if (manager.status == BackendStatus.ready && !recovered.isCompleted) {
        recovered.complete();
      }
    });

    await manager.ensureReady();
    expect(manager.status, BackendStatus.failed);

    await recovered.future.timeout(const Duration(seconds: 1));

    expect(manager.status, BackendStatus.ready);
    expect(manager.readyEpoch, 1);
    expect(metaRequests, greaterThanOrEqualTo(2));
    await manager.dispose();
    api.close();
  });

  test('failed replacement probe preserves the active healthy connection',
      () async {
    final api = ApiClient(
      () => 'https://old.example.test',
      token: () => 'old-token',
      client: MockClient((request) async {
        if (request.url.host == 'old.example.test') {
          return http.Response(
            '{"service":"qingjuan-backend","apiVersion":"1",'
            '"capabilities":{"multiUser":true,"oldServer":true}}',
            200,
          );
        }
        return http.Response(
          '{"detail":"连接凭据无效"}',
          401,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    final manager = BackendConnectionManager(api, isConfigured: () => true);
    await manager.ensureReady();

    await expectLater(
      manager.testRemoteConnection(
        baseUrl: 'https://new.example.test',
        token: 'new-token',
      ),
      throwsA(isA<Exception>()),
    );

    expect(manager.status, BackendStatus.ready);
    expect(manager.message, contains('已连接'));
    expect(manager.capabilities['oldServer'], isTrue);
    expect(manager.translationModelCheck, isNull);
    await manager.dispose();
    api.close();
  });

  test('a delayed model check cannot overwrite a replacement backend result',
      () async {
    var backendUrl = 'https://old.example.test';
    final oldModelGate = Completer<void>();
    final api = ApiClient(
      () => backendUrl,
      token: () => 'connection-token',
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/meta') {
          return http.Response(
            '{"service":"qingjuan-backend","apiVersion":"1",'
            '"capabilities":{"translationModelCheck":true,"multiUser":true}}',
            200,
          );
        }
        if (request.url.path == '/api/v1/translation-model/check') {
          if (request.url.host == 'old.example.test') {
            await oldModelGate.future;
          }
          final model = request.url.host == 'old.example.test'
              ? 'old-model'
              : 'new-model';
          return http.Response(
            '{"enabled":true,"configured":true,"available":true,'
            '"status":"ready","model":"$model","supportsVision":false,'
            '"checkedAt":"2030-01-01T00:00:00Z","latencyMs":12,'
            '"message":"自检通过","cached":false}',
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response('', 204);
      }),
    );
    final manager = BackendConnectionManager(api, isConfigured: () => true);

    await manager.ensureReady();
    final oldCheck = manager.checkTranslationModel();
    await Future<void>.delayed(Duration.zero);
    backendUrl = 'https://new.example.test';
    await manager.ensureReady();
    await manager.checkTranslationModel();
    oldModelGate.complete();
    await oldCheck;

    expect(manager.translationModelCheck?.model, 'new-model');
    expect(manager.translationModelCheckInProgress, isFalse);
    await manager.dispose();
    api.close();
  });

  test('a delayed old connection cannot overwrite the replacement backend',
      () async {
    var backendUrl = 'https://old.example.test';
    final oldResponseGate = Completer<void>();
    final api = ApiClient(
      () => backendUrl,
      token: () => 'connection-token',
      client: MockClient((request) async {
        if (request.url.host == 'old.example.test') {
          await oldResponseGate.future;
          return http.Response(
            '{"service":"qingjuan-backend","apiVersion":"1",'
            '"capabilities":{"multiUser":true,"oldServer":true}}',
            200,
          );
        }
        return http.Response(
          '{"service":"qingjuan-backend","apiVersion":"1",'
          '"capabilities":{"multiUser":true,"newServer":true}}',
          200,
        );
      }),
    );
    final manager = BackendConnectionManager(api, isConfigured: () => true);

    final oldConnection = manager.ensureReady();
    await Future<void>.delayed(Duration.zero);
    backendUrl = 'https://new.example.test';
    await manager.ensureReady();
    oldResponseGate.complete();
    await oldConnection;

    expect(manager.status, BackendStatus.ready);
    expect(manager.capabilities['newServer'], isTrue);
    expect(manager.capabilities.containsKey('oldServer'), isFalse);
    await manager.dispose();
    api.close();
  });
}

class _FakeLocalBackendLifecycle implements LocalBackendLifecycle {
  _FakeLocalBackendLifecycle({this.meta, this.error});

  final Map<String, dynamic>? meta;
  final Object? error;
  int ensureCalls = 0;
  int stopCalls = 0;

  @override
  Future<Map<String, dynamic>> ensureRunning(ApiClient api) async {
    ensureCalls += 1;
    if (error != null) throw error!;
    return meta ??
        <String, dynamic>{
          'service': 'qingjuan-backend',
          'apiVersion': '1',
          'capabilities': <String, dynamic>{},
        };
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }
}
