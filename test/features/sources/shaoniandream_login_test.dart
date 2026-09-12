import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/core/api/browser_login_response.dart';
import 'package:qingjuan/core/models/site_plugin.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/sources/widgets/plugin_browser_login_dialog.dart';
import 'package:qingjuan/features/sources/widgets/plugin_settings_widgets.dart';

const plugin = SitePlugin(
    id: 'shaoniandream',
    name: '少年梦阅读',
    description: '',
    category: 'novel',
    domains: ['shaoniandream.com'],
    bookKinds: ['长小说'],
    tags: [],
    capabilities: ['account_login', 'browser_login'],
    enabled: true,
    defaultEnabled: true,
    version: '1.1.0');

Map<String, dynamic> flowJson() => {
      'flowId': 'flow-1',
      'browserToken': List.filled(43, 'a').join(),
      'expiresAt': DateTime.now()
          .add(const Duration(minutes: 5))
          .toUtc()
          .toIso8601String(),
      'verificationUrl': 'https://untrusted.example/',
    };

void main() {
  test('login errors read message and hint without validation input', () {
    final response = http.Response(
        jsonEncode({
          'detail': {
            'status': 0,
            'code': 'upstream_error',
            'msg': '少年梦暂时不可用',
            'hint': '请重新加载验证',
            'errors': [
              {'input': 'secret-password'}
            ],
          },
        }),
        502,
        headers: {'content-type': 'application/json; charset=utf-8'});
    expect(
        () => decodeBrowserLoginResponse(response),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', '少年梦暂时不可用\n请重新加载验证')
            .having((e) => e.statusCode, 'status', 502)));
    expect(
        () => decodeBrowserLoginResponse(
            http.Response('<html>secret</html>', 502)),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', isNot(contains('secret')))));
    expect(() => decodeBrowserLoginResponse(http.Response('[]', 200)),
        throwsA(isA<ApiException>()));
  });

  testWidgets('structured login failure is actionable in the dialog',
      (tester) async {
    final api = ApiClient(() => 'https://reader.example',
        client: MockClient((request) async => http.Response(
            jsonEncode({
              'detail': {
                'code': 'plugin_disabled',
                'msg': '少年梦插件尚未启用',
                'hint': '请先在插件配置中启用少年梦',
                'errors': [
                  {'input': 'secret-password'}
                ]
              }
            }),
            409,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    final controller = SourcesController(api);
    await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
            content: PluginBrowserLoginDialog(
                plugin: plugin, controller: controller))));
    await tester.pump();
    expect(find.text('少年梦插件尚未启用\n请先在插件配置中启用少年梦'), findsOneWidget);
    expect(find.textContaining('secret-password'), findsNothing);
    expect(find.byKey(const ValueKey('plugin-browser-login-retry')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    api.close();
  });

  testWidgets('exhausted attempts stop polling and offer a new flow',
      (tester) async {
    var polls = 0;
    final api = ApiClient(() => 'https://reader.example',
        client: MockClient((request) async {
      if (request.method == 'POST') {
        return http.Response(jsonEncode(flowJson()), 200);
      }
      if (request.method == 'DELETE') return http.Response('', 204);
      polls++;
      return http.Response(
          '{"status":"failed","message":"failed","loggedIn":false}', 200);
    }));
    final controller = SourcesController(api);
    await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
            content: PluginBrowserLoginDialog(
                plugin: plugin, controller: controller))));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('登录尝试次数已用完，请重新登录。'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(polls, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    controller.dispose();
    api.close();
  });

  test(
      'browser URL stays on current backend and carries no QingJuan credentials',
      () async {
    final api = ApiClient(() => 'https://reader.example/qingjuan',
        token: () => 'connection-secret',
        userToken: () => 'user-secret',
        client: MockClient((request) async {
          expect(request.url.path,
              '/qingjuan/api/v1/plugins/shaoniandream/account/login-browser');
          expect(request.headers['Authorization'], 'Bearer connection-secret');
          return http.Response(jsonEncode(flowJson()), 200);
        }));
    final flow = await api.startSitePluginBrowserLogin('shaoniandream');
    expect(flow.verificationUri.host, 'reader.example');
    expect(flow.verificationUri.path, '/qingjuan/site-login/shaoniandream');
    expect(flow.verificationUri.query, isEmpty);
    expect(flow.verificationUri.toString(), isNot(contains('secret')));
    api.close();
  });

  test(
      'account switching discards late login status and does not cancel on new backend',
      () async {
    var user = 'alice';
    final pending = Completer<http.Response>();
    var requests = 0;
    final api = ApiClient(() => 'https://reader.example',
        userToken: () => user,
        client: MockClient((request) async {
          requests++;
          return request.method == 'POST'
              ? http.Response(jsonEncode(flowJson()), 200)
              : pending.future;
        }));
    final controller = SourcesController(api)..plugins = [plugin];
    final flow = await controller.startBrowserLogin(plugin.id);
    final poll = controller.pollBrowserLogin(plugin.id, flow.flowId);
    final assertion = expectLater(poll, throwsStateError);
    user = 'bob';
    pending.complete(http.Response(
        '{"status":"success","message":"success","loggedIn":true}', 200));
    await assertion;
    expect(controller.plugins.single.accountLoggedIn, isFalse);
    await controller.cancelBrowserLogin(plugin.id, flow.flowId);
    expect(requests, 2);
    controller.dispose();
    api.close();
  });

  testWidgets(
      'password login has correct action and no unsupported bookshelf import',
      (tester) async {
    await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
            content: PluginAccountActions(
                plugin: plugin,
                onLogin: () {},
                onLogout: () {},
                onImportBookshelf: () {}))));
    expect(find.text('账号登录'), findsOneWidget);
    expect(find.text('扫码登录'), findsNothing);
    expect(find.text('一键添加账号书架'), findsNothing);
  });

  testWidgets(
      'browser login polls success and clears flow on close without showing secrets',
      (tester) async {
    var cancelled = false;
    final api = ApiClient(() => 'https://reader.example',
        client: MockClient((request) async {
      if (request.method == 'POST') {
        return http.Response(jsonEncode(flowJson()), 200);
      }
      if (request.method == 'DELETE') {
        cancelled = true;
        return http.Response('', 204);
      }
      return http.Response(
          '{"status":"success","message":"success","loggedIn":true}', 200);
    }));
    final controller = SourcesController(api)..plugins = [plugin];
    await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
            content: PluginBrowserLoginDialog(
                plugin: plugin, controller: controller))));
    await tester.pump();
    expect(find.text('打开登录页面'), findsOneWidget);
    expect(find.textContaining('aaaaaaaaaa'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('少年梦账号已登录，可以下载账号可访问的章节。'), findsOneWidget);
    expect(controller.plugins.single.accountLoggedIn, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(cancelled, isTrue);
    controller.dispose();
    api.close();
  });

  testWidgets('login creation failure offers retry', (tester) async {
    var attempts = 0;
    final api = ApiClient(() => 'https://reader.example',
        client: MockClient((request) async {
      if (request.method == 'DELETE') return http.Response('', 204);
      attempts++;
      return attempts == 1
          ? http.Response('{"detail":"unavailable"}', 409)
          : http.Response(jsonEncode(flowJson()), 200);
    }));
    final controller = SourcesController(api);
    await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
            content: PluginBrowserLoginDialog(
                plugin: plugin, controller: controller))));
    await tester.pump();
    expect(find.byKey(const ValueKey('plugin-browser-login-retry')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plugin-browser-login-retry')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('打开登录页面'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    controller.dispose();
    api.close();
  });
}
