import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/core/models/offline_cache.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/offline/offline_cache_store.dart';
import 'package:qingjuan/features/offline/offline_reading_controller.dart';
import 'package:qingjuan/features/offline/offline_workspace_binding.dart';

class _Sessions implements UserSessionStore {
  String? token = 'session-one';
  @override
  Future<String?> readToken(String backendUrl) async => token;
  @override
  Future<void> deleteToken() async {
    token = null;
  }

  @override
  Future<void> writeToken(
      {required String backendUrl, required String token}) async {
    this.token = token;
  }
}

class _Store extends OfflineCacheStore {
  final identities = <String, OfflineIdentity>{};
  @override
  Future<void> remember(OfflineIdentity identity) async {
    identities[identity.connectionKey] = identity;
  }

  @override
  Future<OfflineIdentity?> recall(String key) async => identities[key];
  @override
  Future<void> forget(String key) async {
    identities.remove(key);
  }

  @override
  Future<List<OfflineBook>> list(OfflineIdentity identity) async => [];
  @override
  Future<int> bytesUsed(OfflineIdentity identity) async => 0;
}

class _Offline extends OfflineReadingController {
  _Offline(super.api, super.store);
  @override
  Future<void> replayPending() async {}
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;
  late ApiClient api;
  late AuthController auth;
  late BackendConnectionManager backend;
  late _Store store;
  late _Sessions sessions;
  late _Offline offline;
  late OfflineWorkspaceBinding binding;
  Completer<http.Response>? logout;
  var instance = 'instance-one';
  var desktopSharing = false;

  setUp(() async {
    instance = 'instance-one';
    desktopSharing = false;
    SharedPreferences.setMockInitialValues(
        {'qingjuan.backend.remote.url': 'https://backend.test'});
    app = AppState(await SharedPreferences.getInstance(),
        initialRemoteBackendToken: 'connection-one');
    sessions = _Sessions();
    api = ApiClient(() => app.backendUrl,
        token: () => app.backendToken,
        userToken: () => auth.userToken,
        connectionRevision: () => app.backendConnectionRevision,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/logout')) {
            return logout?.future ?? Future.value(http.Response('', 204));
          }
          if (request.url.path.endsWith('/meta')) {
            return http.Response(
                jsonEncode({
                  'service': 'qingjuan-backend',
                  'apiVersion': '1',
                  'instanceId': instance,
                  'capabilities': {
                    'multiUser': !desktopSharing,
                    'desktopSharing': desktopSharing,
                    'readingProgressVersioning': true
                  },
                }),
                200);
          }
          return http.Response(
              jsonEncode({
                'id': 'reader-one',
                'username': 'reader',
                'role': 'user',
                'status': 'active'
              }),
              200);
        }));
    auth = AuthController(api, sessions, backendUrl: () => app.backendUrl);
    await auth.initializeForCurrentBackend(multiUser: true);
    backend = BackendConnectionManager(api, isConfigured: () => true)
      ..status = BackendStatus.ready
      ..instanceId = 'instance-one'
      ..capabilities = {'multiUser': true, 'readingProgressVersioning': true};
    store = _Store();
    offline = _Offline(api, store);
    binding = OfflineWorkspaceBinding(
        app: app, backend: backend, auth: auth, offline: offline);
    await settle();
  });
  tearDown(() async {
    binding.dispose();
    offline.dispose();
    auth.dispose();
    await backend.dispose();
    api.close();
    app.dispose();
    logout = null;
  });

  test('logout hides cached identity before its network request returns',
      () async {
    expect(offline.identity?.ownerId, 'reader-one');
    expect(store.identities.keys.single, isNot(contains('session-one')));
    logout = Completer();
    final operation = auth.logout();
    await settle();
    expect(offline.identity, isNull);
    expect(store.identities, isEmpty);
    logout!.complete(http.Response('', 204));
    await operation;
  });

  test(
      'desktop sharing at unchanged URL and credentials must rebind a new instance',
      () async {
    desktopSharing = true;
    await auth.initializeForCurrentBackend(multiUser: false);
    await backend.probeRemoteHealth();
    await settle();
    expect(offline.identity?.instanceId, 'instance-one');
    expect(offline.identity?.ownerId, 'user-admin');
    final previous = offline.identity!;
    expect(offline.online, isTrue);
    instance = 'instance-two';
    await backend.probeRemoteHealth();
    await auth.initializeForCurrentBackend(multiUser: false);
    await settle();
    expect(offline.identity?.connectionKey, previous.connectionKey);
    expect(offline.identity?.instanceId, 'instance-two');
    expect(offline.identity?.ownerId, 'user-admin');
    expect(offline.online, isTrue);
  });

  test('offline restart restores only the matching credential fingerprint',
      () async {
    binding.dispose();
    offline.dispose();
    auth.dispose();
    backend.status = BackendStatus.failed;
    auth = AuthController(api, sessions, backendUrl: () => app.backendUrl);
    offline = _Offline(api, store);
    binding = OfflineWorkspaceBinding(
        app: app, backend: backend, auth: auth, offline: offline);
    await settle();
    expect(offline.identity?.ownerId, 'reader-one');
    expect(offline.online, isFalse);
    binding.dispose();
    offline.dispose();
    sessions.token = 'different-account-session';
    offline = _Offline(api, store);
    binding = OfflineWorkspaceBinding(
        app: app, backend: backend, auth: auth, offline: offline);
    await settle();
    expect(offline.identity, isNull);
  });

  test(
      'changed connection cannot reuse a previous successful handshake or account',
      () async {
    await app.applyBackendConnection(
        mode: BackendConnectionMode.remote,
        remoteUrl: 'https://backend.test',
        remoteToken: 'connection-two');
    await settle();
    expect(offline.identity, isNull);
    await backend.ensureReady();
    expect(backend.status, BackendStatus.ready, reason: backend.message);
    await settle();
    expect(offline.identity, isNull);
    await auth.initializeForCurrentBackend(multiUser: true);
    await settle();
    expect(offline.identity?.ownerId, 'reader-one');
    expect(offline.online, isTrue);
    expect(store.identities.length, 2);
  });
}
