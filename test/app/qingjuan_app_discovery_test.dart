import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/app/qingjuan_app.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/core/models/settings.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/discovery/discovery_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('same-account reconnect discards old recommendations and reloads',
      (tester) async {
    final fixture = await DiscoveryAppFixture.create(tester);
    final discovery = fixture.discovery(tester);
    final previousRequests = fixture.channelRequests;
    final staleResponse = Completer<http.Response>();
    fixture.nextChannelResponse = staleResponse;
    final refreshing = discovery.refresh();
    await tester.pump();
    expect(discovery.contentState, LoadState.loading);

    final restoredToken = Completer<String?>();
    fixture.sessions.nextRead = restoredToken;
    await fixture.backend.ensureReady();
    await tester.pump();
    expect(fixture.auth.status, UserAuthStatus.restoring);
    expect(discovery.sites, isEmpty);
    expect(discovery.contentState, LoadState.idle);

    staleResponse.complete(channelResponse('旧连接的推荐'));
    await refreshing;
    restoredToken.complete('stored-user-token');
    await pumpUntil(tester, () => discovery.contentState == LoadState.ready);
    expect(fixture.auth.isAuthenticated, isTrue);
    expect(discovery.result?.items.single.title, '当前推荐');
    expect(fixture.channelRequests, greaterThan(previousRequests + 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reconnect refreshes previously visited discovery while hidden',
      (tester) async {
    final fixture = await DiscoveryAppFixture.create(tester);
    final discovery = fixture.discovery(tester);
    final previousRequests = fixture.channelRequests;
    fixture.appState.selectSection(AppSection.search);
    await tester.pump();

    final restoredToken = Completer<String?>();
    fixture.sessions.nextRead = restoredToken;
    await fixture.backend.ensureReady();
    await tester.pump();
    expect(discovery.sitesState, LoadState.idle);
    restoredToken.complete('stored-user-token');
    await pumpUntil(tester, () => discovery.contentState == LoadState.ready);

    expect(fixture.appState.section, AppSection.search);
    expect(fixture.channelRequests, greaterThan(previousRequests));
    expect(discovery.result?.items.single.title, '当前推荐');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'session expiry during activation clears discovery and permits relogin',
      (tester) async {
    final fixture = await DiscoveryAppFixture.create(tester);
    final discovery = fixture.discovery(tester);
    final unauthorized = Completer<http.Response>();
    fixture.nextChannelResponse = unauthorized;
    await fixture.backend.ensureReady();
    await pumpUntil(tester, () => discovery.contentState == LoadState.loading);
    unauthorized.complete(jsonResponse({'detail': '登录已过期'}, 401));
    await pumpUntil(tester, () => discovery.sitesState == LoadState.idle);

    expect(fixture.auth.status, UserAuthStatus.anonymous);
    expect(discovery.sites, isEmpty);
    expect(discovery.result, isNull);
    expect(discovery.contentState, LoadState.idle);
    expect(fixture.library.books, isEmpty);

    await fixture.auth.login(username: 'reader', password: 'secret');
    await pumpUntil(tester, () => fixture.library.state == LoadState.ready);
    fixture.appState.selectSection(AppSection.discovery);
    await pumpUntil(tester, () => discovery.contentState == LoadState.ready);
    expect(discovery.result?.items.single.title, '当前推荐');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'logout clears the active recommendations and rejects a late response',
      (tester) async {
    final fixture = await DiscoveryAppFixture.create(tester);
    final discovery = fixture.discovery(tester);
    final delayed = Completer<http.Response>();
    fixture.nextChannelResponse = delayed;
    final refreshing = discovery.refresh();
    await tester.pump();
    await fixture.auth.logout();
    await tester.pump();
    delayed.complete(channelResponse('已登出账号的推荐'));
    await refreshing;
    expect(discovery.sitesState, LoadState.idle);
    expect(discovery.contentState, LoadState.idle);
    expect(discovery.sites, isEmpty);
    expect(discovery.result, isNull);
    expect(tester.takeException(), isNull);
  });
}

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 60 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(condition(), isTrue,
      reason: 'The expected discovery state did not arrive');
}

class DiscoveryAppFixture {
  DiscoveryAppFixture(this.appState) {
    api = ApiClient(
      () => appState.backendUrl,
      token: () => appState.backendToken,
      userToken: () => auth.userToken,
      connectionRevision: () => appState.backendConnectionRevision,
      onUserSessionExpired: () => auth.invalidateSession(),
      client: MockClient(respond),
    );
    auth = AuthController(api, sessions, backendUrl: () => appState.backendUrl);
    backend = BackendConnectionManager(api, isConfigured: () => true);
    library = LibraryController(api);
  }

  final AppState appState;
  final sessions = DelayedSessionStore();
  late final ApiClient api;
  late final AuthController auth;
  late final BackendConnectionManager backend;
  late final LibraryController library;
  Completer<http.Response>? nextChannelResponse;
  int channelRequests = 0;

  static Future<DiscoveryAppFixture> create(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        'qingjuan.backend.remote.url', 'https://qingjuan.example.test');
    await preferences.setString('qingjuan.backendMode', 'remote');
    final fixture = DiscoveryAppFixture(
        AppState(preferences, initialRemoteBackendToken: 'connection-token'));
    fixture.appState.selectSection(AppSection.discovery);
    await tester.pumpWidget(QingJuanApp.testing(
      appState: fixture.appState,
      api: fixture.api,
      backend: fixture.backend,
      auth: fixture.auth,
      library: fixture.library,
      sources: SourcesController(fixture.api),
      tasks: TasksController(fixture.api),
      settings: SettingsController(fixture.api),
    ));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await pumpUntil(tester,
        () => fixture.discovery(tester).contentState == LoadState.ready);
    await tester.pump(const Duration(milliseconds: 300));
    return fixture;
  }

  DiscoveryController discovery(WidgetTester tester) =>
      tester.widget<AppScope>(find.byType(AppScope)).discovery;

  Future<http.Response> respond(http.Request request) async {
    switch (request.url.path) {
      case '/api/v1/meta':
        return jsonResponse({
          'service': 'qingjuan-backend',
          'apiVersion': '1',
          'appVersion': '2.0.0',
          'instanceId': 'discovery-test',
          'capabilities': {'multiUser': true, 'translationModelCheck': false}
        });
      case '/api/v1/auth/session':
        return jsonResponse(userJson);
      case '/api/v1/auth/login':
        return jsonResponse({'token': 'new-user-token', 'user': userJson});
      case '/api/v1/auth/registration-policy':
        return jsonResponse({
          'emailRequired': true,
          'emailVerificationRequired': false,
          'identityBadgeRequired': false,
          'githubLoginEnabled': false
        });
      case '/api/v1/auth/logout':
        return http.Response('', 204);
      case '/api/v1/books':
        return jsonResponse([
          {
            'id': 'book-1',
            'title': '个人作品',
            'sourceUrl': 'https://books.example/book',
            'bookKind': '长小说',
            'language': '中文',
            'status': 'ready',
            'chapterCount': 1,
            'translated': false,
            'localPath': '',
            'updatedAt': '',
            'synopsis': ''
          }
        ]);
      case '/api/v1/sources':
      case '/api/v1/plugins':
      case '/api/v1/tasks':
        return jsonResponse([]);
      case '/api/v1/settings':
        return jsonResponse(TranslationSettings.defaults().toJson());
      case '/api/v1/discovery/sites':
        return jsonResponse({
          'sites': [
            {
              'site': 'qidian',
              'site_name': '起点',
              'channels': [
                {
                  'site': 'qidian',
                  'key': 'home',
                  'kind': 'recommend',
                  'name': '编辑推荐'
                }
              ]
            }
          ]
        });
      case '/api/v1/discovery/sites/qidian/channels/home':
        channelRequests += 1;
        final pending = nextChannelResponse;
        nextChannelResponse = null;
        return pending == null ? channelResponse('当前推荐') : pending.future;
      default:
        return jsonResponse({'detail': 'unexpected ${request.url.path}'}, 404);
    }
  }
}

class DelayedSessionStore implements UserSessionStore {
  Completer<String?>? nextRead;

  @override
  Future<void> deleteToken() async {}

  @override
  Future<String?> readToken(String backendUrl) async {
    final pending = nextRead;
    nextRead = null;
    return pending == null ? 'stored-user-token' : pending.future;
  }

  @override
  Future<void> writeToken(
      {required String backendUrl, required String token}) async {}
}

const userJson = {
  'id': 'user-1',
  'username': 'reader',
  'displayName': '读者',
  'role': 'user',
  'status': 'active',
  'createdAt': '',
  'lastLoginAt': ''
};

http.Response channelResponse(String title) => jsonResponse({
      'site': 'qidian',
      'channel': 'home',
      'kind': 'recommend',
      'items': [
        {'site': 'qidian', 'title': title, 'url': 'https://books.example/book'}
      ],
    });

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );
