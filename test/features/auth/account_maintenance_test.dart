import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/features/auth/account_maintenance_controller.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';

void main() {
  test(
      'password change includes second factor and clears all local login state',
      () async {
    final harness = await _harness((request) async {
      expect(request.url.path, '/api/v1/auth/account/password');
      expect(jsonDecode(request.body), {
        'currentPassword': 'current-password',
        'newPassword': 'changed-password',
        'code': 'recovery-code'
      });
      expect(request.headers['X-QingJuan-User-Token'], 'session-token');
      return http.Response('', 204);
    });
    final controller = harness.controller;
    expect(
        await controller.changePassword(
            currentPassword: 'current-password',
            newPassword: 'changed-password',
            code: 'recovery-code'),
        isTrue);
    expect(controller.completed, isTrue);
    expect(controller.invalidated, isFalse);
    expect(harness.auth.isAuthenticated, isFalse);
    expect(harness.auth.userToken, isEmpty);
    expect(harness.store.token, isNull);
  });

  test('wrong current password leaves session usable and allows retry',
      () async {
    var attempts = 0;
    final harness = await _harness((request) async {
      attempts++;
      return _json({'detail': '密码不正确'}, 403);
    });
    expect(
        await harness.controller.changePassword(
            currentPassword: 'wrong', newPassword: 'changed-password'),
        isFalse);
    expect(harness.controller.error, contains('密码不正确'));
    expect(harness.auth.isAuthenticated, isTrue);
    expect(harness.controller.busy, isFalse);
    expect(attempts, 1);
  });

  test(
      'backend switch discards a late password result and never logs out new account',
      () async {
    final pending = Completer<http.Response>();
    final harness = await _harness((_) => pending.future);
    final mutation = harness.controller.changePassword(
        currentPassword: 'current-password', newPassword: 'changed-password');
    await Future<void>.delayed(Duration.zero);
    await harness.auth.clearForBackendSwitch();
    pending.complete(http.Response('', 204));
    expect(await mutation, isFalse);
    expect(harness.controller.invalidated, isTrue);
    expect(harness.controller.completed, isFalse);
    expect(harness.controller.message, isNull);
  });

  test(
      'reset never forwards a user session and blocks repeated mail dispatch during cooldown',
      () async {
    var calls = 0;
    final harness = await _harness((request) async {
      calls++;
      expect(request.headers.containsKey('X-QingJuan-User-Token'), isFalse);
      expect(request.headers['Authorization'], 'Bearer connection-token');
      expect(request.url.path, '/api/v1/auth/password-reset/request');
      return _json({
        'accepted': true,
        'resendAfterSeconds': 60,
        'expiresInSeconds': 600,
        'message': '如果邮箱符合条件将发送邮件。'
      }, 202);
    }, authenticated: false);
    expect(await harness.controller.sendReset(email: 'reader@example.test'),
        isTrue);
    expect(harness.controller.resendSeconds, 60);
    expect(await harness.controller.sendReset(email: 'reader@example.test'),
        isFalse);
    expect(calls, 1);
  });

  test(
      'session list loads metadata and revokes one session without signing out current user',
      () async {
    final harness = await _harness((request) async {
      if (request.url.path.endsWith('/maintenance')) {
        return _json({
          'email': 'reader@example.test',
          'emailVerified': true,
          'emailServiceAvailable': true
        });
      }
      if (request.method == 'DELETE') {
        expect(request.url.path, '/api/v1/auth/account/sessions/other-session');
        return http.Response('', 204);
      }
      return _json({
        'sessions': [
          {
            'id': 'current-session',
            'platform': 'windows',
            'createdAt': '2026-09-11T00:00:00Z',
            'expiresAt': '2026-10-11T00:00:00Z',
            'lastSeenAt': '2026-09-11T00:00:00Z',
            'current': true
          },
          {
            'id': 'other-session',
            'platform': 'android',
            'createdAt': '2026-09-11T00:00:00Z',
            'expiresAt': '2026-10-11T00:00:00Z',
            'lastSeenAt': '2026-09-11T00:00:00Z',
            'current': false
          },
        ]
      });
    });
    await harness.controller.load();
    expect(harness.controller.account?.emailVerified, isTrue);
    expect(harness.controller.sessions.map((item) => item.platformLabel),
        ['Windows 设备', 'Android 设备']);
    expect(await harness.controller.revoke(harness.controller.sessions.last),
        isTrue);
    expect(harness.controller.sessions.single.current, isTrue);
    expect(harness.auth.isAuthenticated, isTrue);
  });

  test('disposing while request is pending does not retain secrets or notify',
      () async {
    final pending = Completer<http.Response>();
    final harness = await _harness((_) => pending.future);
    final mutation = harness.controller.changePassword(
        currentPassword: 'current-password', newPassword: 'changed-password');
    await Future<void>.delayed(Duration.zero);
    harness.controller.dispose();
    harness.controllerDisposed = true;
    pending.complete(http.Response('', 204));
    expect(await mutation, isFalse);
    expect(harness.controller.completed, isFalse);
    expect(harness.auth.isAuthenticated, isTrue);
  });

  test('anonymous same-backend refresh invalidates a pending reset request',
      () async {
    final pending = Completer<http.Response>();
    final harness = await _harness((_) => pending.future, authenticated: false);
    final dispatch = harness.controller.sendReset(email: 'reader@example.test');
    await Future<void>.delayed(Duration.zero);
    await harness.auth.initializeForCurrentBackend(multiUser: true);
    pending.complete(_json({
      'accepted': true,
      'resendAfterSeconds': 60,
      'expiresInSeconds': 600,
      'message': '邮件已请求'
    }, 202));
    expect(await dispatch, isFalse);
    expect(harness.controller.invalidated, isTrue);
    expect(harness.controller.message, isNull);
    expect(harness.controller.resendSeconds, 0);
  });
}

http.Response _json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Future<_Harness> _harness(Future<http.Response> Function(http.Request) handler,
    {bool authenticated = true}) async {
  late AuthController auth;
  final api = ApiClient(() => 'https://qingjuan.example.test',
      token: () => 'connection-token',
      userToken: () => auth.userToken,
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/session') {
          return _json({
            'id': 'reader',
            'username': 'reader',
            'displayName': 'Reader',
            'role': 'user',
            'status': 'active',
            'createdAt': '2026-01-01T00:00:00Z',
            'email': 'reader@example.test'
          });
        }
        return handler(request);
      }));
  final store = _Store()..token = authenticated ? 'session-token' : null;
  auth = AuthController(api, store,
      backendUrl: () => 'https://qingjuan.example.test');
  await auth.initializeForCurrentBackend(multiUser: true);
  final harness =
      _Harness(api, auth, store, AccountMaintenanceController(auth));
  addTearDown(() {
    if (!harness.controllerDisposed) harness.controller.dispose();
    auth.dispose();
    api.close();
  });
  return harness;
}

class _Harness {
  _Harness(this.api, this.auth, this.store, this.controller);
  final ApiClient api;
  final AuthController auth;
  final _Store store;
  final AccountMaintenanceController controller;
  bool controllerDisposed = false;
}

class _Store implements UserSessionStore {
  String? token;
  @override
  Future<void> deleteToken() async {
    token = null;
  }

  @override
  Future<String?> readToken(String backendUrl) async => token;
  @override
  Future<void> writeToken(
      {required String backendUrl, required String token}) async {
    this.token = token;
  }
}
