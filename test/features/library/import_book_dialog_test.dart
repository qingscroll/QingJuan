import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/library/library_page.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/shared/mobile_sheet.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('album number can be previewed and imported as manga',
      (tester) async {
    final submitted = <Map<String, dynamic>>[];
    final harness = await _Harness.create(MockClient((request) async {
      if (request.method == 'POST') {
        submitted.add(jsonDecode(request.body) as Map<String, dynamic>);
      }
      return _jsonResponse(_jobPayload(status: 'completed', progress: 100));
    }));
    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('添加书籍'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byKey(const ValueKey('import-book-url')), '0');
    await tester.ensureVisible(find.text('预览'));
    await tester.tap(find.text('预览'));
    await tester.pump();
    expect(submitted, isEmpty);
    expect(find.textContaining('禁漫本子号（正整数）'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('import-book-url')), ' 00123456 ');
    await tester.pump();
    expect(find.textContaining('已识别为禁漫作品'), findsOneWidget);
    final kind =
        tester.widget<ComboBox<String>>(find.byType(ComboBox<String>).first);
    expect(kind.value, '漫画');
    expect(kind.onChanged, isNull);
    for (final action in <String>['预览', '导入']) {
      await tester.ensureVisible(find.text(action));
      await tester.tap(find.text(action));
      await tester.pump(const Duration(milliseconds: 200));
      final payload = submitted.last['payload'] as Map<String, dynamic>;
      expect(payload['albumId'], '123456');
      expect(payload['sourceUrl'], 'https://18comic.vip/album/123456/');
      expect(payload['bookKind'], '漫画');
      expect(payload['downloadMode'], 'all');
    }
    expect(
        submitted.map((body) => body['mode']), <String>['preview', 'import']);
    harness.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Fanqie import exposes on-demand and full download modes',
      (tester) async {
    final submitted = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.method == 'POST' &&
          request.url.path == '/api/v1/books/link-jobs') {
        submitted.add(
          Map<String, dynamic>.from(
            jsonDecode(request.body) as Map<String, dynamic>,
          ),
        );
        return _jsonResponse(_jobPayload(status: 'completed', progress: 100));
      }
      return http.Response('{}', 404);
    });
    final harness = await _Harness.create(
      client,
      connectionMode: BackendConnectionMode.remote,
    );

    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('添加书籍'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byKey(const ValueKey('import-book-url')),
      'https://fanqienovel.com/page/123456',
    );
    await tester.pump();

    expect(find.text('番茄正文获取方式'), findsOneWidget);
    expect(find.text('边看边下（默认）'), findsOneWidget);
    expect(find.textContaining('退出客户端后仍会继续'), findsOneWidget);

    await tester.ensureVisible(find.text('导入'));
    await tester.tap(find.text('导入'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      (submitted.single['payload'] as Map<String, dynamic>)['downloadMode'],
      'on_demand',
    );

    harness.library.clearLinkJob();
    await tester.pump();
    final modeSelector = tester.widget<ComboBox<String>>(
      find.byKey(const ValueKey('fanqie-download-mode')),
    );
    modeSelector.onChanged!('all');
    await tester.pump();
    await tester.ensureVisible(find.text('导入'));
    await tester.tap(find.text('导入'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      (submitted.last['payload'] as Map<String, dynamic>)['downloadMode'],
      'all',
    );

    harness.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Windows local on-demand mode keeps bounded reader prefetch',
      (tester) async {
    final harness = await _Harness.create(
      MockClient((_) async => http.Response('{}', 404)),
      localBackendSupported: true,
    );

    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('添加书籍'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.byKey(const ValueKey('import-book-url')),
      'https://fanqienovel.com/page/123456',
    );
    await tester.pump();

    expect(find.textContaining('后台预取后续 20 章'), findsOneWidget);
    expect(find.textContaining('退出客户端后仍会继续'), findsNothing);

    harness.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('link parsing dialog can collapse and reopen with live logs',
      (tester) async {
    final client = MockClient((request) async {
      if (request.method == 'POST' &&
          request.url.path == '/api/v1/books/link-jobs') {
        return _jsonResponse(_jobPayload(status: 'queued', progress: 0));
      }
      if (request.method == 'GET' &&
          request.url.path == '/api/v1/books/link-jobs/link-1') {
        return _jsonResponse(
          _jobPayload(
            status: 'running',
            progress: 35,
            logs: <Map<String, dynamic>>[
              <String, dynamic>{
                'sequence': 1,
                'level': 'info',
                'message': '正在解析章节目录',
                'createdAt': '2026-08-03 12:00:03',
              },
            ],
          ),
        );
      }
      return http.Response('{}', 404);
    });
    final harness = await _Harness.create(client);

    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('添加书籍'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('DOCX、EPUB 小说与 PDF 漫画'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('import-book-url')),
      'https://example.com/comic/1',
    );
    await tester.ensureVisible(find.text('预览'));
    await tester.tap(find.text('预览'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('实时日志'), findsOneWidget);
    expect(find.textContaining('正在解析章节目录'), findsWidgets);
    expect(find.text('收起'), findsOneWidget);

    final collapseButton = find.widgetWithText(Button, '收起');
    final collapseAction = tester.widget<Button>(collapseButton).onPressed;
    expect(collapseAction, isNotNull);
    collapseAction!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('实时日志'), findsNothing);
    expect(find.text('链接解析中'), findsOneWidget);

    await tester.tap(find.text('链接解析中'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('实时日志'), findsOneWidget);
    expect(find.textContaining('正在解析章节目录'), findsWidgets);

    harness.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android add-book flow uses the shared bottom sheet',
      (tester) async {
    final harness = await _Harness.create(
      MockClient((_) async => http.Response('{}', 404)),
      targetPlatform: TargetPlatform.android,
    );

    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('添加书籍'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(MobileSheet), findsOneWidget);
    expect(find.byType(ContentDialog), findsNothing);
    expect(find.text('网页地址、禁漫本子号或本地文件'), findsOneWidget);
    expect(tester.takeException(), isNull);

    harness.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Map<String, dynamic> _jobPayload({
  required String status,
  required double progress,
  List<Map<String, dynamic>> logs = const <Map<String, dynamic>>[],
}) =>
    <String, dynamic>{
      'id': 'link-1',
      'mode': 'preview',
      'status': status,
      'progress': progress,
      'message': status == 'running' ? '正在解析章节目录' : '等待解析',
      'logs': logs,
      'createdAt': '2026-08-03 12:00:00',
      'updatedAt': '2026-08-03 12:00:03',
    };

http.Response _jsonResponse(Map<String, dynamic> payload) => http.Response(
      jsonEncode(payload),
      200,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

class _Harness {
  _Harness({
    required this.widget,
    required this.api,
    required this.library,
    required this.sources,
    required this.tasks,
    required this.settings,
  });

  static Future<_Harness> create(
    http.Client client, {
    TargetPlatform targetPlatform = TargetPlatform.windows,
    BackendConnectionMode? connectionMode,
    bool localBackendSupported = false,
  }) async {
    final appState = AppState(
      await SharedPreferences.getInstance(),
      localBackendSupported: localBackendSupported,
    );
    if (connectionMode != null) {
      await appState.selectBackendMode(connectionMode);
    }
    final api = ApiClient(() => appState.backendUrl, client: client);
    final backend = BackendConnectionManager(api, isConfigured: () => false);
    final library = LibraryController(api);
    final sources = SourcesController(api);
    final tasks = TasksController(api);
    final settings = SettingsController(api);
    final widget = FluentApp(
      theme: buildQingJuanTheme(
        Brightness.light,
        platform: targetPlatform,
      ),
      home: UiPlatformScope(
        platform: targetPlatform,
        child: AppScope(
          appState: appState,
          api: api,
          backend: backend,
          auth: AuthController.localAdministrator(api),
          library: library,
          sources: sources,
          tasks: tasks,
          settings: settings,
          child: const LibraryPage(),
        ),
      ),
    );
    return _Harness(
      widget: widget,
      api: api,
      library: library,
      sources: sources,
      tasks: tasks,
      settings: settings,
    );
  }

  final Widget widget;
  final ApiClient api;
  final LibraryController library;
  final SourcesController sources;
  final TasksController tasks;
  final SettingsController settings;

  void dispose() {
    library.dispose();
    sources.dispose();
    tasks.dispose();
    settings.dispose();
    api.close();
  }
}
