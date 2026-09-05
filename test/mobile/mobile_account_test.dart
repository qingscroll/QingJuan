import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/models/source.dart';
import 'package:qingjuan/core/models/task.dart';
import 'package:qingjuan/core/models/user_account.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/mobile/mobile_app.dart';
import 'package:qingjuan/mobile/mobile_auth_page.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _capture = bool.fromEnvironment('QINGJUAN_CAPTURE_MOBILE_UI');
final _previewKey = GlobalKey();

void main() {
  setUpAll(() async {
    // Optional local CJK fonts improve preview PNGs without making test
    // execution depend on fonts installed on a particular host.
    if (!_capture) return;
    final fontManifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json'))
            as List<dynamic>;
    for (final entry in fontManifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(entry['family'] as String);
      for (final font
          in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    for (final family in <String>[
      'Roboto',
      'Segoe UI Variable Text',
      'Segoe UI Variable Display',
      'Ahem',
    ]) {
      await (FontLoader(
        family,
      )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes))))
          .load();
    }
  });

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{
        'qingjuan.backend.remote.url': 'https://test.example',
        'qingjuan.backendMode': 'remote',
      }));
  testWidgets('mobile account submits login and preserves two factor challenge',
      (tester) async {
    var loginCount = 0;
    var verificationCount = 0;
    final fixture = await _Fixture.create((request) async {
      if (request.url.path.endsWith('registration-policy')) {
        return _json({'emailRequired': true});
      }
      if (request.url.path.endsWith('/auth/login')) {
        loginCount++;
        expect(jsonDecode(request.body),
            {'username': 'reader', 'password': 'a-test-password'});
        return _json({
          'requiresTwoFactor': true,
          'challengeToken': 'challenge',
          'expiresInSeconds': 300
        });
      }
      if (request.url.path.endsWith('/auth/login/2fa')) {
        verificationCount++;
        expect(jsonDecode(request.body),
            {'challengeToken': 'challenge', 'code': '123456'});
        return _json({
          'token': 'user-token',
          'user': {
            'id': 'reader',
            'username': 'reader',
            'displayName': '阅读者',
            'role': 'user',
            'status': 'active',
            'createdAt': ''
          }
        });
      }
      throw StateError('Unexpected request ${request.url.path}');
    });
    addTearDown(fixture.dispose);
    await _mountAccount(tester, fixture);
    await tester.enterText(find.byType(TextField).at(0), 'reader');
    await tester.enterText(find.byType(TextField).at(1), 'a-test-password');
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();
    expect(loginCount, 1);
    expect(find.text('验证你的身份'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.widgetWithText(FilledButton, '验证并登录'));
    await tester.pumpAndSettle();
    expect(verificationCount, 1);
    expect(fixture.auth.isAuthenticated, isTrue);
    expect(find.byKey(const ValueKey('auth-account-security')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'mobile security recovers a loading error and opens a full 2FA page',
      (tester) async {
    var loads = 0;
    final fixture = await _Fixture.create((request) async {
      if (request.url.path.endsWith('registration-policy')) {
        return _json({'emailRequired': true});
      }
      if (request.url.path.endsWith('/account/security')) {
        loads++;
        if (loads == 1) {
          return http.Response('{"detail":"temporarily unavailable"}', 400,
              headers: {'content-type': 'application/json'});
        }
        return _json({
          'github': {'available': false, 'bound': false},
          'twoFactor': {'enabled': false, 'recoveryCodesRemaining': 0}
        });
      }
      throw StateError('Unexpected request ${request.url.path}');
    });
    addTearDown(fixture.dispose);
    fixture.auth
      ..status = UserAuthStatus.authenticated
      ..user = UserAccount.fromJson({
        'id': 'reader',
        'username': 'reader',
        'displayName': '阅读者',
        'role': 'user',
        'status': 'active',
        'createdAt': ''
      });
    await _mountAccount(tester, fixture, largeText: true);
    await tester
        .ensureVisible(find.byKey(const ValueKey('auth-account-security')));
    await tester.tap(find.byKey(const ValueKey('auth-account-security')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('account-security-error')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    await _savePreview(tester, 'security-320-light');
    await fixture.app.setThemeMode(AppThemeMode.dark);
    await tester.pumpAndSettle();
    await _savePreview(tester, 'security-320-dark');
    expect(
        find.byKey(const ValueKey('account-security-ready')), findsOneWidget);
    await tester.ensureVisible(
        find.byKey(const ValueKey('account-security-2fa-enable')));
    await tester.tap(find.byKey(const ValueKey('account-security-2fa-enable')));
    await tester.pumpAndSettle();
    expect(find.text('开启两步验证'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await _savePreview(tester, 'security-2fa-320-dark');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'registration obeys server requirements and posts only required credentials',
      (tester) async {
    var registrationCount = 0;
    final fixture = await _Fixture.create((request) async {
      if (request.url.path.endsWith('registration-policy')) {
        return _json({
          'emailRequired': true,
          'emailVerificationRequired': true,
          'identityBadgeRequired': true
        });
      }
      if (request.url.path.endsWith('/auth/register')) {
        registrationCount++;
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['emailCode'], '123456');
        expect(payload['identityBadge'], 'reader-badge');
        return _json({
          'token': 'user-token',
          'user': {
            'id': 'reader',
            'username': 'reader',
            'displayName': '阅读者',
            'role': 'user',
            'status': 'active',
            'createdAt': ''
          }
        });
      }
      throw StateError('Unexpected request ${request.url.path}');
    });
    addTearDown(fixture.dispose);
    await _mountAccount(tester, fixture, largeText: true);
    await tester.ensureVisible(find.text('没有账号，创建一个'));
    await tester.tap(find.text('没有账号，创建一个'));
    await tester.pumpAndSettle();
    expect(find.text('邮箱验证码'), findsOneWidget);
    expect(find.text('身份牌'), findsOneWidget);
    final values = [
      'reader',
      '阅读者',
      'reader@example.test',
      'a-test-password',
      'a-test-password',
      '123456',
      'reader-badge'
    ];
    for (var index = 0; index < values.length; index++) {
      await tester.ensureVisible(find.byType(TextField).at(index));
      await tester.enterText(find.byType(TextField).at(index), values[index]);
    }
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '创建账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '创建账号'));
    await tester.pumpAndSettle();
    expect(registrationCount, 1);
    expect(fixture.auth.isAuthenticated, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _mountAccount(WidgetTester tester, _Fixture fixture,
    {bool largeText = false}) async {
  tester.view.physicalSize = Size(largeText ? 320 : 390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  fixture.app.selectSection(AppSection.settings);
  final navigation = GlobalKey<NavigatorState>();
  await tester.pumpWidget(RepaintBoundary(
      key: _previewKey,
      child: UiPlatformScope(
          platform: TargetPlatform.android,
          child: AppScope(
            appState: fixture.app,
            api: fixture.api,
            backend: fixture.backend,
            auth: fixture.auth,
            library: fixture.library,
            sources: fixture.sources,
            tasks: fixture.tasks,
            settings: fixture.settings,
            child: MediaQuery(
                data: MediaQueryData(
                    textScaler: TextScaler.linear(largeText ? 1.8 : 1)),
                child: MobileQingJuanApp(navigatorKey: navigation)),
          ))));
  await tester.pumpAndSettle();
  unawaited(navigation.currentState!.push<void>(
      MaterialPageRoute<void>(builder: (_) => const MobileAccountPage())));
  await tester.pumpAndSettle();
}

class _SessionStore implements UserSessionStore {
  String? token;
  @override
  Future<String?> readToken(String backendUrl) async => token;
  @override
  Future<void> writeToken(
      {required String backendUrl, required String token}) async {
    this.token = token;
  }

  @override
  Future<void> deleteToken() async {
    token = null;
  }
}

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8'
    });

Map<String, Object> _source(bool enabled) => <String, Object>{
      'id': 'source-1',
      'name': '测试书源',
      'baseUrl': 'https://source.example',
      'description': '测试书源说明',
      'enabled': enabled,
      'supported': true,
      'status': 'ready',
      'statusMessage': '',
      'tags': <String>[],
    };

Map<String, Object> _task(String status) => <String, Object>{
      'id': 'task-1',
      'bookId': 'book-1',
      'taskType': 'download',
      'status': status,
      'totalCount': 2,
      'completedCount': status == 'completed' ? 2 : 0,
      'progress': status == 'completed' ? 1.0 : 0.0,
      'message': '',
    };

class _Fixture {
  _Fixture(this.app, this.api) {
    backend = BackendConnectionManager(api, isConfigured: () => true);
    auth = AuthController(api, _SessionStore(),
        backendUrl: () => 'https://test.example');
    backend
      ..status = BackendStatus.ready
      ..multiUserEnabled = true;
    library = LibraryController(api)..state = LoadState.ready;
    sources = SourcesController(api)
      ..state = LoadState.ready
      ..sources = <BookSource>[BookSource.fromJson(_source(true))];
    tasks = TasksController(api)
      ..state = LoadState.ready
      ..tasks = <BookTask>[BookTask.fromJson(_task('failed'))];
    settings = SettingsController(api);
  }

  static Future<_Fixture> create(
      Future<http.Response> Function(http.Request) handler) async {
    final fixture = _Fixture(
        AppState(await SharedPreferences.getInstance(),
            initialRemoteBackendToken: 'test-token'),
        ApiClient(() => 'https://test.example', client: MockClient(handler)));
    await fixture.auth.initializeForCurrentBackend(multiUser: true);
    return fixture;
  }

  final AppState app;
  final ApiClient api;
  late final BackendConnectionManager backend;
  late final AuthController auth;
  late final LibraryController library;
  late final SourcesController sources;
  late final TasksController tasks;
  late final SettingsController settings;

  void dispose() {
    tasks.dispose();
    sources.dispose();
    library.dispose();
    settings.dispose();
    auth.dispose();
    backend.dispose();
    app.dispose();
    api.close();
  }
}

Future<void> _savePreview(WidgetTester tester, String name) async {
  if (!_capture) return;
  await tester.pumpAndSettle();
  final boundary =
      _previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/mobile-ui-preview');
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}
