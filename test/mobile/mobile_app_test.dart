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
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/core/models/book.dart';
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
import 'package:qingjuan/mobile/mobile_library_page.dart';
import 'package:qingjuan/mobile/mobile_my_page.dart';
import 'package:qingjuan/mobile/mobile_search_page.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _capture = bool.fromEnvironment('QINGJUAN_CAPTURE_MOBILE_UI');
final _previewBoundaryKey = GlobalKey();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'qingjuan.backend.remote.url': 'https://preview.example.test',
      'qingjuan.backendMode': 'remote',
      'qingjuan.theme': 'light',
    });
  });

  testWidgets('four mobile destinations show real pages in both themes', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await _mount(tester, fixture);
    expect(find.byType(MobileLibraryPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
      findsOneWidget,
    );
    expect(find.text('长安的荔枝'), findsWidgets);
    expect(tester.takeException(), isNull);
    await _savePreview(tester, 'library-light');

    for (final dark in <bool>[false, true]) {
      if (dark) {
        await fixture.app.setThemeMode(AppThemeMode.dark);
        await tester.pumpAndSettle();
        await _savePreview(tester, 'library-dark');
      }
      await tester.tap(find.byKey(const ValueKey('mobile-navigation-search')));
      await tester.pumpAndSettle();
      expect(fixture.app.section, AppSection.search);
      expect(find.byType(MobileSearchPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _savePreview(tester, 'store-${dark ? 'dark' : 'light'}');

      await tester.tap(find.byKey(const ValueKey('mobile-navigation-tasks')));
      await tester.pumpAndSettle();
      expect(fixture.app.section, AppSection.tasks);
      expect(tester.takeException(), isNull);
      await _savePreview(tester, 'tasks-${dark ? 'dark' : 'light'}');

      await tester.tap(
        find.byKey(const ValueKey('mobile-navigation-settings')),
      );
      await tester.pumpAndSettle();
      expect(fixture.app.section, AppSection.settings);
      expect(find.byType(MobileMyPage), findsOneWidget);
      expect(find.text('青卷读者'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _savePreview(tester, 'my-${dark ? 'dark' : 'light'}');

      await tester.tap(find.byKey(const ValueKey('mobile-navigation-library')));
      await tester.pumpAndSettle();
      expect(fixture.app.section, AppSection.library);
      expect(find.byType(MobileLibraryPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('my page persists themes and opens account and backend sheets', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    fixture.app.selectSection(AppSection.settings);
    await _mount(tester, fixture);

    await tester.ensureVisible(find.byKey(const ValueKey('my-theme-dark')));
    await tester.tap(find.byKey(const ValueKey('my-theme-dark')));
    await tester.pumpAndSettle();
    expect(fixture.app.themeMode, AppThemeMode.dark);
    expect(fixture.preferences.getString('qingjuan.theme'), 'dark');
    expect(
      Theme.of(tester.element(find.byType(MobileMyPage))).brightness,
      Brightness.dark,
    );

    await tester.tap(find.byKey(const ValueKey('my-theme-system')));
    await tester.pumpAndSettle();
    expect(fixture.app.themeMode, AppThemeMode.system);
    await tester.tap(find.byKey(const ValueKey('my-theme-light')));
    await tester.pumpAndSettle();
    expect(fixture.app.themeMode, AppThemeMode.light);

    await _showMyItem(tester, 'mobile-my-profile', delta: -300);
    await tester.tap(find.byKey(const ValueKey('mobile-my-profile')));
    await tester.pumpAndSettle();
    expect(find.text('账号管理'), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-account-security')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-logout')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _savePreview(tester, 'account-sheet-light');
    Navigator.of(tester.element(find.text('账号管理'))).pop();
    await tester.pumpAndSettle();

    await _showMyItem(tester, 'my-backend-entry');
    await tester.tap(find.byKey(const ValueKey('my-backend-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('linux-backend-url')), findsOneWidget);
    expect(find.byKey(const ValueKey('linux-backend-token')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('save-backend-connection')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _savePreview(tester, 'backend-sheet-light');
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('320 dp layout supports large text and keeps navigation usable', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    fixture.app.selectSection(AppSection.settings);
    await _mount(tester, fixture, size: const Size(320, 740), textScale: 2);
    expect(tester.takeException(), isNull);
    await _savePreview(tester, 'my-320-large-text');

    await _showMyItem(tester, 'my-theme-dark');
    await tester.tap(find.byKey(const ValueKey('my-theme-dark')));
    await tester.pumpAndSettle();
    expect(fixture.app.themeMode, AppThemeMode.dark);
    expect(tester.takeException(), isNull);
    await _savePreview(tester, 'appearance-320-large-text');

    await tester.tap(find.byKey(const ValueKey('mobile-navigation-library')));
    await tester.pumpAndSettle();
    expect(find.byType(MobileLibraryPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _savePreview(tester, 'library-320-large-text');
    await tester.tap(find.byKey(const ValueKey('mobile-navigation-search')));
    await tester.pumpAndSettle();
    expect(find.byType(MobileSearchPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _savePreview(tester, 'store-320-large-text');
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('import and source routes render in both themes', (tester) async {
    for (final dark in [false, true]) {
      final fixture = await _Fixture.create();
      if (dark) await fixture.app.setThemeMode(AppThemeMode.dark);
      await _mount(tester, fixture);
      await tester.tap(find.byKey(const ValueKey('mobile-library-add')));
      await tester.pumpAndSettle();
      await _savePreview(tester, 'import-chooser-${dark ? 'dark' : 'light'}');
      await tester.tap(find.text('作品链接'));
      await tester.pumpAndSettle();
      await _savePreview(tester, 'import-form-${dark ? 'dark' : 'light'}');
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(TextFormField).first)).pop();
      await tester.pumpAndSettle();
      fixture.sources.sources = [
        BookSource.fromJson({
          'id': 'demo-active',
          'name': '示例小说书源',
          'baseUrl': 'https://example.test',
          'description': '已导入的小说检索规则',
          'enabled': true,
          'supported': true,
          'status': 'supported'
        }),
        BookSource.fromJson({
          'id': 'demo-inactive',
          'name': '暂不可用的旧书源',
          'baseUrl': 'https://legacy.example.test',
          'description': '需要管理员更新规则',
          'enabled': false,
          'supported': false,
          'statusMessage': '当前规则缺少目录解析能力'
        }),
      ];
      fixture.app.selectSection(AppSection.sources);
      await tester.pumpAndSettle();
      await _savePreview(tester, 'sources-${dark ? 'dark' : 'light'}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    }
  });

  testWidgets('tablet keeps mobile navigation and search context across tabs', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await _mount(tester, fixture, size: const Size(1024, 768));
    expect(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
      findsNothing,
    );
    await _savePreview(tester, 'library-tablet-light');
    await tester.tap(find.byKey(const ValueKey('mobile-navigation-search')));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byType(MobileSearchPage),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '还没有提交的关键词');
    await tester.tap(find.byKey(const ValueKey('mobile-navigation-tasks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-navigation-search')));
    await tester.pumpAndSettle();
    expect(find.text('还没有提交的关键词'), findsOneWidget);
    await fixture.app.setThemeMode(AppThemeMode.dark);
    await tester.pumpAndSettle();
    await _savePreview(tester, 'search-tablet-dark');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('connection interruption preserves library and offers recovery', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    fixture.backend.status = BackendStatus.failed;
    await _mount(tester, fixture);
    expect(find.text('连接中断 · 已保留当前内容'), findsOneWidget);
    expect(find.text('长安的荔枝'), findsWidgets);
    await _savePreview(tester, 'connection-interrupted-light');
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets(
    'expired session leads directly to login and keyboard hides navigation',
    (tester) async {
      final fixture = await _Fixture.create();
      fixture.auth.status = UserAuthStatus.anonymous;
      fixture.auth.user = null;
      await _mount(tester, fixture);
      expect(find.text('登录后，继续阅读'), findsOneWidget);
      await _savePreview(tester, 'login-required-light');
      await tester.tap(find.text('登录账号'));
      await tester.pumpAndSettle();
      await _savePreview(tester, 'login-form-light');
      expect(find.byType(TextField), findsWidgets);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await _savePreview(tester, 'login-keyboard-light');
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpWidget(const SizedBox());
      fixture.dispose();
    },
  );
}

Future<void> _mount(
  WidgetTester tester,
  _Fixture fixture, {
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _previewBoundaryKey,
      child: fluent.FluentApp(
        debugShowCheckedModeBanner: false,
        home: UiPlatformScope(
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
            child: const MobileQingJuanApp(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _showMyItem(
  WidgetTester tester,
  String key, {
  double delta = 300,
}) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey<String>(key)),
    delta,
    scrollable: find
        .descendant(
          of: find.byType(MobileMyPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _savePreview(WidgetTester tester, String name) async {
  if (!_capture) return;
  await tester.pumpAndSettle();
  final boundary = _previewBoundaryKey.currentContext!.findRenderObject()!
      as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/mobile-ui-preview');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class _Fixture {
  _Fixture(
    this.preferences,
    this.app,
    this.api,
    this.backend,
    this.auth,
    this.library,
    this.sources,
    this.tasks,
    this.settings,
  );

  final SharedPreferences preferences;
  final AppState app;
  final ApiClient api;
  final BackendConnectionManager backend;
  final AuthController auth;
  final LibraryController library;
  final SourcesController sources;
  final TasksController tasks;
  final SettingsController settings;

  static Future<_Fixture> create() async {
    final preferences = await SharedPreferences.getInstance();
    final app = AppState(
      preferences,
      initialRemoteBackendToken: 'preview-token',
    );
    final api = ApiClient(
      () => app.backendUrl,
      client: MockClient((request) async {
        if (request.url.path.endsWith('registration-policy')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'emailRequired': true,
              'emailVerificationRequired': false,
              'identityBadgeRequired': false,
              'githubLoginEnabled': false,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response(
          '[]',
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    final backend = BackendConnectionManager(
      api,
      isConfigured: () => app.hasBackendConnection,
    )
      ..status = BackendStatus.ready
      ..multiUserEnabled = true
      ..message = 'Linux 后端已连接';
    final auth = AuthController(
      api,
      const _MemorySessionStore(),
      backendUrl: () => app.backendUrl,
    )
      ..status = UserAuthStatus.authenticated
      ..user = const UserAccount(
        id: 'preview-user',
        username: 'reader',
        displayName: '青卷读者',
        role: 'user',
        status: 'active',
        createdAt: '2026-01-01',
        email: 'reader@example.test',
      );
    final books = <Book>[
      for (final (index, title) in <String>[
        '长安的荔枝',
        '瓦尔登湖',
        '小王子',
        '人间草木',
        '月亮与六便士',
        '山茶文具店',
      ].indexed)
        Book.fromJson(<String, dynamic>{
          'id': 'preview-book-$index',
          'title': title,
          'sourceUrl': 'https://preview.example.test/books/$index',
          'bookKind': '长小说',
          'language': '中文',
          'status': '已就绪',
          'chapterCount': 24,
          if (index == 0) 'lastReadAt': '2026-09-05T10:00:00Z',
          if (index == 0) 'lastReadChapterIndex': 5,
          'synopsis': '一段关于生活、远行与自我发现的故事。放慢脚步，在文字之间遇见另一种人生。',
        }),
    ];
    final library = LibraryController(api)
      ..books = books
      ..state = LoadState.ready;
    final sources = SourcesController(api)
      ..state = LoadState.ready
      ..results = <SourceSearchResult>[
        for (final book in books.take(4))
          SourceSearchResult(
            title: book.title,
            author: '示例作者',
            synopsis: book.synopsis,
            sourceUrl: book.sourceUrl,
            sourceId: 'preview-source',
            sourceName: '示例书源',
            kind: book.kind,
            language: book.language,
          ),
      ];
    final tasks = TasksController(api)
      ..state = LoadState.ready
      ..tasks = <BookTask>[
        for (final (index, status) in [
          'running',
          'failed',
          'completed',
        ].indexed)
          BookTask.fromJson(<String, dynamic>{
            'id': 'visual-task-$index',
            'bookId': books[index].id,
            'taskType': index == 0 ? 'download' : 'translate',
            'status': status,
            'totalCount': 24,
            'completedCount': index == 2 ? 24 : 9,
            'progress': index == 2 ? 100 : 37.5,
            'message': index == 0
                ? '正在下载第 10 章'
                : index == 1
                    ? '翻译服务暂时不可用'
                    : '全部章节已完成',
            if (index == 1) 'error': '翻译服务连接超时，请检查服务后重试。',
            'updatedAt': '2026-09-05T10:00:00Z',
          }),
      ];
    return _Fixture(
      preferences,
      app,
      api,
      backend,
      auth,
      library,
      sources,
      tasks,
      SettingsController(api),
    );
  }

  void dispose() {
    auth.dispose();
    backend.dispose();
    library.dispose();
    sources.dispose();
    tasks.dispose();
    settings.dispose();
    app.dispose();
    api.close();
  }
}

class _MemorySessionStore implements UserSessionStore {
  const _MemorySessionStore();

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
