import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/features/auth/account_maintenance_form.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/shared/responsive.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
        'reset form validates confirmation and clears secrets on $platform',
        (tester) async {
      if (platform == TargetPlatform.android) {
        tester.view.physicalSize = const Size(320, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }
      var resets = 0;
      final api = ApiClient(() => 'https://qingjuan.example.test',
          client: MockClient((request) async {
        if (request.url.path.endsWith('/request')) {
          return _json({
            'accepted': true,
            'resendAfterSeconds': 60,
            'expiresInSeconds': 600,
            'message': '如果邮箱符合条件将发送验证码。'
          }, 202);
        }
        expect(jsonDecode(request.body), {
          'email': 'reader@example.test',
          'emailCode': '12345678',
          'newPassword': 'replacement-password',
          'code': 'recovery-code'
        });
        resets++;
        return http.Response('', 204);
      }));
      final auth = AuthController(api, _Store(),
          backendUrl: () => 'https://qingjuan.example.test');
      await auth.initializeForCurrentBackend(multiUser: true);
      addTearDown(() {
        auth.dispose();
        api.close();
      });
      await _mount(
          tester, auth, platform, AccountMaintenanceMode.resetPassword);
      await _enter(tester, 'account-reset-email', 'reader@example.test');
      await _tap(tester, 'account-send-email-code');
      await _enter(tester, 'account-email-code', '12345678');
      await _enter(tester, 'account-second-factor', 'recovery-code');
      await _enter(tester, 'account-new-password', 'replacement-password');
      await _enter(tester, 'account-confirm-password', 'different-password');
      await _tap(tester, 'account-maintenance-submit');
      expect(resets, 0);
      expect(find.text('新密码需至少 12 个字符，且两次输入必须一致'), findsOneWidget);
      await _enter(tester, 'account-confirm-password', 'replacement-password');
      await _tap(tester, 'account-maintenance-submit');
      expect(resets, 1);
      expect(find.text('密码已重置，所有旧会话已退出，请使用新密码登录。'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-new-password')), findsNothing);
      expect(find.text('replacement-password'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('password form stays open while its mutation is in flight',
      (tester) async {
    final gate = Completer<http.Response>();
    final api = ApiClient(() => 'https://qingjuan.example.test',
        client: MockClient((_) => gate.future));
    final auth = AuthController(api, _Store(),
        backendUrl: () => 'https://qingjuan.example.test');
    await auth.initializeForCurrentBackend(multiUser: true);
    addTearDown(() {
      auth.dispose();
      api.close();
    });
    await _mount(
        tester, auth, TargetPlatform.windows, AccountMaintenanceMode.password);
    await _enter(tester, 'account-current-password', 'current-password');
    await _enter(tester, 'account-new-password', 'replacement-password');
    await _enter(tester, 'account-confirm-password', 'replacement-password');
    await tester.ensureVisible(
        find.byKey(const ValueKey('account-maintenance-submit')));
    await tester.tap(find.byKey(const ValueKey('account-maintenance-submit')));
    await tester.pump();
    final close =
        tester.widget<fluent.Button>(find.widgetWithText(fluent.Button, '关闭'));
    expect(close.onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const ValueKey('account-new-password')), findsOneWidget);
    gate.complete(http.Response('', 204));
    await tester.pumpAndSettle();
    expect(find.text('密码已修改，所有旧会话已退出，请重新登录。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _mount(WidgetTester tester, AuthController auth,
    TargetPlatform platform, AccountMaintenanceMode mode) async {
  Widget button(BuildContext context) => fluent.Button(
      key: const ValueKey('open'),
      onPressed: () => unawaited(
          showAccountMaintenanceForm(context: context, auth: auth, mode: mode)),
      child: const Text('打开'));
  final child = platform == TargetPlatform.android
      ? MiuixThemeController(
          child: fluent.FluentTheme(
              data: fluent.FluentThemeData(),
              child: MaterialApp(
                  builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: const TextScaler.linear(1.8)),
                      child: child!),
                  home: Scaffold(body: Builder(builder: button)))))
      : fluent.FluentApp(home: Builder(builder: button));
  await tester.pumpWidget(UiPlatformScope(platform: platform, child: child));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

class _Store implements UserSessionStore {
  @override
  Future<void> deleteToken() async {}
  @override
  Future<String?> readToken(String backendUrl) async => null;
  @override
  Future<void> writeToken(
      {required String backendUrl, required String token}) async {}
}
