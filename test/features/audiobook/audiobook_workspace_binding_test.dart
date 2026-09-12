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
import 'package:qingjuan/core/models/audiobook_position.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/audiobook/audiobook_coordinator.dart';
import 'package:qingjuan/features/audiobook/audiobook_position_store.dart';
import 'package:qingjuan/features/audiobook/audiobook_workspace_binding.dart';
import 'audiobook_background_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;
  late ApiClient api;
  late AuthController auth;
  late BackendConnectionManager backend;
  late AudiobookCoordinator coordinator;
  late AudiobookWorkspaceBinding binding;
  late BackgroundEngine engine;
  late _Sessions sessions;
  var instance = 'instance-one';
  var owner = 'owner-one';
  var online = true;
  Completer<http.Response>? logout;

  setUp(() async {
    instance = 'instance-one';
    owner = 'owner-one';
    online = true;
    logout = null;
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
          if (request.url.path.endsWith('/meta')) {
            if (!online) return http.Response('unavailable', 503);
            return http.Response(
                jsonEncode({
                  'service': 'qingjuan-backend',
                  'apiVersion': '1',
                  'instanceId': instance,
                  'capabilities': {'multiUser': true}
                }),
                200);
          }
          if (request.url.path.endsWith('/logout')) {
            return logout?.future ?? http.Response('', 204);
          }
          if (request.url.path.endsWith('/devices/heartbeat')) {
            return http.Response('', 204);
          }
          return http.Response(
              jsonEncode({
                'id': owner,
                'username': 'reader',
                'role': 'user',
                'status': 'active'
              }),
              200);
        }));
    auth = AuthController(api, sessions, backendUrl: () => app.backendUrl);
    await auth.initializeForCurrentBackend(multiUser: true);
    backend = BackendConnectionManager(api, isConfigured: () => true);
    await backend.ensureReady();
    engine = BackgroundEngine();
    coordinator = AudiobookCoordinator(
        engineFactory: (_) => engine,
        initializePlatform: (_) async => BackgroundRuntime(),
        positionStore: (instance, owner, book) => _Positions());
    binding = AudiobookWorkspaceBinding(
        app: app,
        api: api,
        backend: backend,
        auth: auth,
        coordinator: coordinator);
    final apiCurrent = api.captureContextGuard();
    final workspace = auth.workspaceIdentity;
    final server = backend.instanceId;
    await coordinator.open(
        instanceId: server,
        ownerId: auth.user!.id,
        detail: backgroundDetail,
        loadChapter: (index, mode) async => backgroundContent(index, mode),
        isCurrentContext: () =>
            apiCurrent() &&
            workspace == auth.workspaceIdentity &&
            server == backend.instanceId &&
            auth.canAccessWorkspace);
    unawaited(coordinator.play());
    await _settle();
    expect(coordinator.current!.isPlaying, isTrue);
  });
  tearDown(() async {
    binding.dispose();
    await coordinator.close();
    auth.dispose();
    await backend.dispose();
    api.close();
    app.dispose();
  });

  test('temporary heartbeat outage preserves the verified playing session',
      () async {
    final current = coordinator.current!;
    online = false;
    await backend.probeRemoteHealth();
    await _settle();
    expect(backend.status, BackendStatus.failed);
    expect(auth.isAuthenticated, isTrue);
    expect(coordinator.current, same(current));
    expect(current.isPlaying, isTrue);
    expect(current.chunks, isNotEmpty);
    expect(engine.disposals, 0);
  });

  test(
      'same URL same owner with a new backend instance invalidates old playback',
      () async {
    final previous = coordinator.current!;
    final workspace = auth.workspaceIdentity;
    instance = 'instance-two';
    await backend.probeRemoteHealth();
    await _settle();
    expect(auth.workspaceIdentity, workspace);
    expect(coordinator.current, isNull);
    expect(previous.isClosed, isTrue);
    expect(previous.chunks, isEmpty);
    expect(engine.disposals, 1);
    await previous.play();
    expect(engine.spoken, hasLength(1));
  });

  test('logout immediately hides session before the revoke request finishes',
      () async {
    final previous = coordinator.current!;
    logout = Completer<http.Response>();
    final operation = auth.logout();
    expect(coordinator.current, isNull);
    await _settle();
    expect(previous.isClosed, isTrue);
    expect(previous.chunks, isEmpty);
    logout!.complete(http.Response('', 204));
    await operation;
  });

  test('switching credentials at the same URL stops the old engine', () async {
    final previous = coordinator.current!;
    await app.saveRemoteBackendConnection(
        url: app.backendUrl, token: 'new-connection');
    expect(coordinator.current, isNull);
    await _settle();
    expect(previous.isClosed, isTrue);
    expect(engine.disposals, 1);
  });

  test(
      'backend switch hides old playback before secure credential deletion finishes',
      () async {
    final previous = coordinator.current!;
    sessions.deleting = Completer<void>();
    final operation = auth.clearForBackendSwitch();
    expect(coordinator.current, isNull);
    await _settle();
    expect(previous.isClosed, isTrue);
    expect(previous.chunks, isEmpty);
    sessions.deleting!.complete();
    await operation;
  });

  test(
      'restoring a different account cannot reuse the earlier listening session',
      () async {
    final previous = coordinator.current!;
    owner = 'owner-two';
    sessions.token = 'user-session-two';
    final operation = auth.initializeForCurrentBackend(multiUser: true);
    expect(coordinator.current, isNull);
    await operation;
    await _settle();
    expect(auth.user!.id, 'owner-two');
    expect(previous.isClosed, isTrue);
    expect(previous.chunks, isEmpty);
  });
}

Future<void> _settle() async {
  for (var index = 0; index < 12; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Sessions implements UserSessionStore {
  String? token = 'user-session-one';
  Completer<void>? deleting;
  @override
  Future<String?> readToken(String backendUrl) async => token;
  @override
  Future<void> deleteToken() async {
    token = null;
    await deleting?.future;
  }

  @override
  Future<void> writeToken(
      {required String backendUrl, required String token}) async {
    this.token = token;
  }
}

class _Positions implements AudiobookPositionStore {
  @override
  Future<AudiobookPosition?> load() async => null;
  @override
  Future<void> save(AudiobookPosition position) async {}
}
