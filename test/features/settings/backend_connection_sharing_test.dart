import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_link.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/settings/widgets/backend_share_card.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/mobile/mobile_app.dart';
import 'package:qingjuan/mobile/mobile_my_page.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _capture = bool.fromEnvironment('QINGJUAN_CAPTURE_CONNECTION_UI');
final _previewKey = GlobalKey();

void main() {
  setUpAll(() async {
    if (!_capture) return;
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final entry in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(entry['family'] as String);
      for (final asset
          in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(asset['asset'] as String));
      }
      await loader.load();
    }
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (!await font.exists()) return;
    final data = ByteData.sublistView(await font.readAsBytes());
    for (final name in [
      'Roboto',
      'Segoe UI',
      'Segoe UI Variable Text',
      'Segoe UI Variable Display',
      'Ahem'
    ]) {
      await (FontLoader(name)..addFont(Future.value(data))).load();
    }
  });

  setUp(() => SharedPreferences.setMockInitialValues({
        'qingjuan.backend.remote.url': 'https://saved.example',
        'qingjuan.backendMode': 'remote',
      }));

  testWidgets(
      'desktop shares saved connection and removes stale QR after switching',
      (tester) async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    String? clipboard;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    tester.view.physicalSize = const Size(760, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RepaintBoundary(
        key: _previewKey,
        child: fixture.scope(
          fluent.FluentApp(
              debugShowCheckedModeBanner: false,
              theme: buildQingJuanTheme(Brightness.light,
                  platform: TargetPlatform.windows),
              home: const UiPlatformScope(
                  platform: TargetPlatform.windows,
                  child: fluent.ScaffoldPage(
                      content: SingleChildScrollView(
                          padding: EdgeInsets.all(24),
                          child: BackendShareCard())))),
        )));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    await tester.tap(find.byKey(const ValueKey('generate-backend-qr')));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('copy-backend-link')));
    await tester.pumpAndSettle();
    expect(BackendConnectionLink.parse(clipboard!).token,
        fixture.app.backendToken);
    expect(BackendConnectionLink.parse(clipboard!).url, fixture.app.backendUrl);
    await _savePreview(tester, 'desktop-connection-qr');
    await fixture.app.applyBackendConnection(
        mode: BackendConnectionMode.remote,
        remoteUrl: 'https://replacement.example',
        remoteToken: 'replacement-token');
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final fail in [false, true]) {
    testWidgets(
        'mobile imported link ${fail ? 'keeps previous connection when verification fails' : 'connects to shared PC after verification'}',
        (tester) async {
      final fixture = await _Fixture.create(failConnection: fail);
      addTearDown(fixture.dispose);
      final navigation = GlobalKey<NavigatorState>();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(RepaintBoundary(
          key: _previewKey,
          child: fixture.scope(
            UiPlatformScope(
                platform: TargetPlatform.android,
                child: MobileQingJuanApp(navigatorKey: navigation)),
          )));
      await tester.pumpAndSettle();
      const link = BackendConnectionLink(
          url: 'http://192.168.1.20:19454', token: 'pc-share-token');
      unawaited(showMobileConnectionPage(
          navigation.currentState!.overlay!.context,
          connectionLink: link));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scan-backend-qr')), findsOneWidget);
      expect(find.byKey(const ValueKey('paste-backend-link')), findsOneWidget);
      expect(
          tester
              .widget<TextField>(
                  find.byKey(const ValueKey('linux-backend-url')))
              .controller!
              .text,
          link.url);
      expect(fixture.app.backendUrl, 'https://saved.example');
      expect(fixture.requests, isEmpty);
      await _savePreview(tester, 'mobile-connection-import');
      await tester
          .ensureVisible(find.byKey(const ValueKey('save-backend-connection')));
      await tester.tap(find.byKey(const ValueKey('save-backend-connection')));
      await tester.pumpAndSettle();
      expect(fixture.requests.first.headers['Authorization'],
          'Bearer ${link.token}');
      expect(fixture.requests.first.url.toString(), '${link.url}/api/v1/meta');
      if (fail) {
        expect(fixture.app.backendUrl, 'https://saved.example');
        expect(fixture.app.backendToken, 'saved-token');
        expect(find.text('连接未成功'), findsOneWidget);
      } else {
        expect(fixture.app.backendUrl, link.url);
        expect(fixture.app.backendToken, link.token);
        expect(fixture.backend.multiUserEnabled, isFalse);
        expect(fixture.auth.canAccessWorkspace, isTrue);
        expect(find.text('继续登录'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await fixture.dispose();
    });
  }
}

class _Fixture {
  _Fixture(this.app, {required bool failConnection}) {
    api = ApiClient(() => app.backendUrl,
        token: () => app.backendToken,
        client: MockClient((request) async {
          requests.add(request);
          return failConnection
              ? http.Response('{"detail":"invalid token"}', 401)
              : http.Response(
                  jsonEncode({
                    'service': 'qingjuan-backend',
                    'apiVersion': '1',
                    'capabilities': {'multiUser': false, 'desktopSharing': true}
                  }),
                  200);
        }));
    backend = BackendConnectionManager(api,
        isConfigured: () => app.hasBackendConnection)
      ..status = BackendStatus.ready;
    auth = AuthController.localAdministrator(api,
        backendUrl: () => app.backendUrl);
    library = LibraryController(api);
    sources = SourcesController(api);
    tasks = TasksController(api);
    settings = SettingsController(api);
    app.selectSection(AppSection.settings);
  }
  static Future<_Fixture> create({bool failConnection = false}) async =>
      _Fixture(
        AppState(await SharedPreferences.getInstance(),
            initialRemoteBackendToken: 'saved-token'),
        failConnection: failConnection,
      );
  final AppState app;
  final requests = <http.Request>[];
  late final ApiClient api;
  late final BackendConnectionManager backend;
  late final AuthController auth;
  late final LibraryController library;
  late final SourcesController sources;
  late final TasksController tasks;
  late final SettingsController settings;
  bool _disposed = false;

  Widget scope(Widget child) => AppScope(
      appState: app,
      api: api,
      backend: backend,
      auth: auth,
      library: library,
      sources: sources,
      tasks: tasks,
      settings: settings,
      child: child);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    tasks.dispose();
    sources.dispose();
    library.dispose();
    settings.dispose();
    auth.dispose();
    await backend.dispose();
    app.dispose();
    api.close();
  }
}

Future<void> _savePreview(WidgetTester tester, String name) async {
  if (!_capture) return;
  final boundary =
      _previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/connection-ui-preview');
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}
