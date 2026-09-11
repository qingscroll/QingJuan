import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/app/qingjuan_app.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/core/models/settings.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/core/updates/app_update_controller.dart';
import 'package:qingjuan/core/updates/app_update_service.dart';
import 'package:qingjuan/core/updates/app_release.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('startup checks for updates without a configured backend',
      (tester) async {
    final appState = AppState(await SharedPreferences.getInstance(),
        localBackendSupported: false);
    final api = ApiClient(() => appState.backendUrl,
        client: MockClient(
            (_) async => throw StateError('No backend request expected')));
    final backend = BackendConnectionManager(api, isConfigured: () => false);
    final auth = AuthController(api, const _EmptyUserSessionStore(),
        backendUrl: () => appState.backendUrl);
    final updateService = _StartupUpdateService();
    final updates = AppUpdateController(
        windows: true,
        versionLoader: () async => '2.1.1+41',
        exitForInstall: () async {},
        service: updateService);
    await tester.pumpWidget(QingJuanApp.testing(
        appState: appState,
        api: api,
        backend: backend,
        auth: auth,
        library: LibraryController(api),
        sources: SourcesController(api),
        tasks: TasksController(api),
        settings: SettingsController(api),
        updates: updates));
    await tester.pumpAndSettle();
    expect(updateService.checks, 1);
    expect(updates.status, UpdateStatus.available, reason: updates.error);
    expect(find.text('青卷 2.2.0 已发布'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('remote workspace waits for login and resets after logout',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'qingjuan.backend.remote.url',
      'https://qingjuan.example.test',
    );
    await preferences.setString('qingjuan.backendMode', 'remote');
    final appState = AppState(
      preferences,
      initialRemoteBackendToken: 'connection-token',
    );
    late AuthController auth;
    final requestedPaths = <String>[];
    final api = ApiClient(
      () => appState.backendUrl,
      token: () => appState.backendToken,
      userToken: () => auth.userToken,
      onUserSessionExpired: () => auth.invalidateSession(),
      client: MockClient((request) async {
        requestedPaths.add(request.url.path);
        switch (request.url.path) {
          case '/api/v1/meta':
            return _jsonResponse(<String, dynamic>{
              'service': 'qingjuan-backend',
              'apiVersion': '1',
              'appVersion': '2.0.0',
              'instanceId': 'instance-1',
              'capabilities': <String, bool>{
                'multiUser': true,
                'translationModelCheck': false,
              },
            });
          case '/api/v1/auth/login':
            return _jsonResponse(<String, dynamic>{
              'token': 'user-token',
              'user': _userJson,
            });
          case '/api/v1/auth/registration-policy':
            return _jsonResponse(<String, dynamic>{
              'emailRequired': true,
              'emailVerificationRequired': false,
              'identityBadgeRequired': false,
              'githubLoginEnabled': false,
            });
          case '/api/v1/auth/logout':
            return http.Response('', 204);
          case '/api/v1/books':
            return _jsonResponse(<Map<String, dynamic>>[_bookJson]);
          case '/api/v1/sources':
          case '/api/v1/plugins':
          case '/api/v1/tasks':
            return _jsonResponse(<Object>[]);
          case '/api/v1/settings':
            return _jsonResponse(TranslationSettings.defaults().toJson());
          default:
            return _jsonResponse(
              <String, String>{'detail': 'unexpected ${request.url.path}'},
              404,
            );
        }
      }),
    );
    final backend = BackendConnectionManager(
      api,
      isConfigured: () => appState.hasBackendConnection,
    );
    auth = AuthController(
      api,
      const _EmptyUserSessionStore(),
      backendUrl: () => appState.backendUrl,
    );
    final library = LibraryController(api);
    final sources = SourcesController(api);
    final tasks = TasksController(api);
    final settings = SettingsController(api);

    await tester.pumpWidget(
      QingJuanApp.testing(
        appState: appState,
        api: api,
        backend: backend,
        auth: auth,
        library: library,
        sources: sources,
        tasks: tasks,
        settings: settings,
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));

    expect(auth.status, UserAuthStatus.anonymous);
    expect(appState.section, AppSection.settings);
    expect(
      requestedPaths,
      <String>['/api/v1/meta', '/api/v1/auth/registration-policy'],
    );
    expect(library.state, LoadState.idle);

    await tester.enterText(
      find.byKey(const ValueKey('auth-username')),
      'reader',
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-password')),
      'secret',
    );
    await tester.tap(find.byKey(const ValueKey('auth-submit')));
    await tester.pump(const Duration(milliseconds: 900));

    expect(auth.isAuthenticated, isTrue);
    expect(library.state, LoadState.ready);
    expect(library.books.single.id, 'book-1');
    expect(
        requestedPaths,
        containsAll(<String>[
          '/api/v1/books',
          '/api/v1/sources',
          '/api/v1/plugins',
          '/api/v1/tasks',
          '/api/v1/settings',
        ]));

    await tester.tap(find.byKey(const ValueKey('my-profile-card')));
    await tester.pumpAndSettle();
    expect(find.text('账号管理'), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-logout')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auth-logout')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(auth.status, UserAuthStatus.anonymous);
    expect(library.state, LoadState.idle);
    expect(library.books, isEmpty);
    expect(tasks.tasks, isEmpty);
    expect(appState.section, AppSection.settings);
  });

  testWidgets('restores the user session before checking the server model',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'qingjuan.backend.remote.url',
      'https://qingjuan.example.test',
    );
    await preferences.setString('qingjuan.backendMode', 'remote');
    final appState = AppState(
      preferences,
      initialRemoteBackendToken: 'connection-token',
    );
    late AuthController auth;
    final requestedPaths = <String>[];
    final api = ApiClient(
      () => appState.backendUrl,
      token: () => appState.backendToken,
      userToken: () => auth.userToken,
      onUserSessionExpired: () => auth.invalidateSession(),
      client: MockClient((request) async {
        requestedPaths.add(request.url.path);
        switch (request.url.path) {
          case '/api/v1/meta':
            return _jsonResponse(<String, dynamic>{
              'service': 'qingjuan-backend',
              'apiVersion': '1',
              'appVersion': '2.0.0',
              'instanceId': 'instance-1',
              'capabilities': <String, bool>{
                'multiUser': true,
                'translationModelCheck': true,
              },
            });
          case '/api/v1/auth/session':
            expect(
                request.headers['X-QingJuan-User-Token'], 'stored-user-token');
            return _jsonResponse(_userJson);
          case '/api/v1/translation-model/check':
            expect(
                request.headers['X-QingJuan-User-Token'], 'stored-user-token');
            return _jsonResponse(<String, dynamic>{
              'enabled': true,
              'configured': true,
              'available': true,
              'status': 'ready',
              'model': 'server-model',
              'supportsVision': false,
              'checkedAt': '2026-08-21T00:00:00Z',
              'latencyMs': 12,
              'message': '模型可用',
              'cached': false,
            });
          case '/api/v1/books':
            return _jsonResponse(<Map<String, dynamic>>[_bookJson]);
          case '/api/v1/sources':
          case '/api/v1/plugins':
          case '/api/v1/tasks':
            return _jsonResponse(<Object>[]);
          case '/api/v1/settings':
            return _jsonResponse(TranslationSettings.defaults().toJson());
          default:
            return _jsonResponse(<String, String>{'detail': 'unexpected'}, 404);
        }
      }),
    );
    final backend = BackendConnectionManager(
      api,
      isConfigured: () => appState.hasBackendConnection,
    );
    auth = AuthController(
      api,
      const _StoredUserSessionStore(),
      backendUrl: () => appState.backendUrl,
    );

    await tester.pumpWidget(
      QingJuanApp.testing(
        appState: appState,
        api: api,
        backend: backend,
        auth: auth,
        library: LibraryController(api),
        sources: SourcesController(api),
        tasks: TasksController(api),
        settings: SettingsController(api),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(auth.isAuthenticated, isTrue);
    expect(
      requestedPaths.take(3),
      <String>[
        '/api/v1/meta',
        '/api/v1/auth/session',
        '/api/v1/translation-model/check',
      ],
    );
    expect(
      backend.translationModelCheck?.status,
      TranslationModelCheckStatus.ready,
    );
  });

  testWidgets('initial restart outage reconnects and restores the user session',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'qingjuan.backend.remote.url',
      'https://qingjuan.example.test',
    );
    await preferences.setString('qingjuan.backendMode', 'remote');
    final appState = AppState(
      preferences,
      initialRemoteBackendToken: 'connection-token',
    );
    late AuthController auth;
    var metaRequests = 0;
    final requestedPaths = <String>[];
    final api = ApiClient(
      () => appState.backendUrl,
      token: () => appState.backendToken,
      userToken: () => auth.userToken,
      connectionRevision: () => appState.backendConnectionRevision,
      onUserSessionExpired: () => auth.invalidateSession(),
      client: MockClient((request) async {
        requestedPaths.add(request.url.path);
        switch (request.url.path) {
          case '/api/v1/meta':
            metaRequests += 1;
            if (metaRequests == 1) {
              return _jsonResponse(
                  <String, String>{'detail': 'restarting'}, 503);
            }
            return _jsonResponse(<String, dynamic>{
              'service': 'qingjuan-backend',
              'apiVersion': '1',
              'appVersion': '2.0.0',
              'instanceId': 'instance-after-restart',
              'capabilities': <String, bool>{
                'multiUser': true,
                'translationModelCheck': false,
              },
            });
          case '/api/v1/auth/session':
            expect(
                request.headers['X-QingJuan-User-Token'], 'stored-user-token');
            return _jsonResponse(_userJson);
          case '/api/v1/books':
            return _jsonResponse(<Map<String, dynamic>>[_bookJson]);
          case '/api/v1/sources':
          case '/api/v1/plugins':
          case '/api/v1/tasks':
            return _jsonResponse(<Object>[]);
          case '/api/v1/settings':
            return _jsonResponse(TranslationSettings.defaults().toJson());
          case '/api/v1/devices/heartbeat':
            return http.Response('', 204);
          default:
            return _jsonResponse(<String, String>{'detail': 'unexpected'}, 404);
        }
      }),
    );
    final backend = BackendConnectionManager(
      api,
      isConfigured: () => appState.hasBackendConnection,
      heartbeatInterval: const Duration(milliseconds: 5),
    );
    auth = AuthController(
      api,
      const _StoredUserSessionStore(),
      backendUrl: () => appState.backendUrl,
    );
    final library = LibraryController(api);

    await tester.pumpWidget(
      QingJuanApp.testing(
        appState: appState,
        api: api,
        backend: backend,
        auth: auth,
        library: library,
        sources: SourcesController(api),
        tasks: TasksController(api),
        settings: SettingsController(api),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(metaRequests, greaterThanOrEqualTo(2));
    expect(backend.status, BackendStatus.ready);
    expect(auth.isAuthenticated, isTrue);
    expect(requestedPaths, contains('/api/v1/auth/session'));
    expect(library.state, LoadState.ready);
    expect(library.books.single.id, 'book-1');
  });
}

const _userJson = <String, dynamic>{
  'id': 'user-1',
  'username': 'reader',
  'displayName': '读者',
  'role': 'user',
  'status': 'active',
  'createdAt': '2026-08-21T00:00:00Z',
  'lastLoginAt': '2026-08-21T01:00:00Z',
};

const _bookJson = <String, dynamic>{
  'id': 'book-1',
  'title': '个人书架作品',
  'sourceUrl': 'https://example.test/book/1',
  'bookKind': '长小说',
  'language': '中文',
  'status': 'ready',
  'chapterCount': 1,
  'translated': false,
  'localPath': '',
  'updatedAt': '2026-08-21T00:00:00Z',
  'synopsis': '',
};

http.Response _jsonResponse(Object? body, [int statusCode = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      statusCode,
      headers: const <String, String>{'content-type': 'application/json'},
    );

class _StartupUpdateService extends AppUpdateService {
  int checks = 0;
  @override
  Future<AppRelease?> check({required bool windows}) async {
    checks++;
    return AppRelease(
        version: const AppVersion(2, 2, 0),
        notes: '',
        pageUrl: Uri.parse(
            'https://github.com/qingscroll/QingJuan/releases/tag/v2.2.0'));
  }
}

class _EmptyUserSessionStore implements UserSessionStore {
  const _EmptyUserSessionStore();

  @override
  Future<void> deleteToken() async {}

  @override
  Future<String?> readToken(String backendUrl) async => null;

  @override
  Future<void> writeToken({
    required String backendUrl,
    required String token,
  }) async {}
}

class _StoredUserSessionStore implements UserSessionStore {
  const _StoredUserSessionStore();

  @override
  Future<void> deleteToken() async {}

  @override
  Future<String?> readToken(String backendUrl) async => 'stored-user-token';

  @override
  Future<void> writeToken({
    required String backendUrl,
    required String token,
  }) async {}
}
