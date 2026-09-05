import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/shell/app_shell.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/shared/app_surface.dart';
import 'package:qingjuan/shared/desktop_title_bar.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('phone uses five-item bottom navigation', (tester) async {
    final harness = await _Harness.create(const Size(390, 844));
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const ValueKey('mobile-app-bar')), findsNothing);
    expect(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
      findsOneWidget,
    );
    expect(find.text('我的'), findsOneWidget);
    final navigation = tester.widget<SizedBox>(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
    );
    expect(navigation.height, 82);
    final glassFinder =
        find.byKey(const ValueKey('mobile-bottom-navigation-glass'));
    final glass = tester.widget<AppGlassSurface>(glassFinder);
    expect(glass.borderRadius, 22);
    expect(glass.blurSigma, 16);
    expect(
      tester.getSize(glassFinder).width,
      lessThan(tester
          .getSize(find.byKey(
            const ValueKey('mobile-bottom-navigation'),
          ))
          .width),
    );
    expect(
      find.descendant(
        of: glassFinder,
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    expect(find.byType(NavigationView), findsNothing);
    for (final section in <AppSection>[
      AppSection.library,
      AppSection.search,
      AppSection.sources,
      AppSection.tasks,
      AppSection.settings,
    ]) {
      expect(
        find.byKey(ValueKey<String>('mobile-navigation-${section.name}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('phone navigation switches primary workspace', (tester) async {
    final harness = await _Harness.create(const Size(390, 844));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(
      find.byKey(const ValueKey('mobile-navigation-tasks')),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(harness.appState.section, AppSection.tasks);
    expect(find.text('任务'), findsWidgets);
  });

  testWidgets('phone tool pages use the shared reading-app visual hierarchy',
      (tester) async {
    final harness = await _Harness.create(const Size(390, 844));
    addTearDown(harness.dispose);
    harness.sources.state = LoadState.empty;
    harness.tasks.state = LoadState.empty;

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(
      find.byKey(const ValueKey('mobile-navigation-search')),
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text('搜索书籍'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mobile-navigation-sources')),
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text('暂未配置书源'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mobile-navigation-tasks')),
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text('任务概览'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mobile-navigation-settings')),
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(
      find.byKey(const ValueKey('mobile-my-dashboard')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('my-profile-card')), findsOneWidget);
    expect(find.text('我的阅读'), findsOneWidget);
    expect(find.text('设置与服务'), findsOneWidget);
    expect(find.text('账户与服务器'), findsNothing);
    expect(find.byKey(const ValueKey('settings-plugins-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unconfigured phone opens data pages with connection guidance',
      (tester) async {
    final harness = await _Harness.create(
      const Size(390, 844),
      configured: false,
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 600));

    expect(harness.appState.section, AppSection.settings);
    expect(
      find.byKey(const ValueKey('mobile-my-dashboard')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('my-feature-backend')),
      findsOneWidget,
    );

    for (final section in <AppSection>[
      AppSection.library,
      AppSection.search,
      AppSection.sources,
      AppSection.tasks,
    ]) {
      await tester.tap(
        find.byKey(ValueKey<String>('mobile-navigation-${section.name}')),
      );
      await tester.pump(const Duration(milliseconds: 150));

      expect(harness.appState.section, section);
      expect(
        find.byKey(ValueKey<String>('backend-required-${section.name}')),
        findsOneWidget,
      );
    }

    await tester.tap(
      find.byKey(const ValueKey('backend-required-open-settings')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(harness.appState.section, AppSection.settings);
  });

  testWidgets('anonymous Linux user is gated from personal workspace pages',
      (tester) async {
    final harness = await _Harness.create(
      const Size(390, 844),
      multiUser: true,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('auth-required-library')),
      findsOneWidget,
    );
    expect(find.text('请先登录 Linux 后端'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('auth-required-open-account')),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(harness.appState.section, AppSection.settings);
    expect(find.byKey(const ValueKey('auth-login-tab')), findsOneWidget);
    expect(find.byKey(const ValueKey('auth-register-tab')), findsOneWidget);
  });

  testWidgets('tablet uses persistent Fluent navigation pane', (tester) async {
    final harness = await _Harness.create(
      const Size(1280, 800),
      targetPlatform: TargetPlatform.windows,
      backendMode: BackendConnectionMode.local,
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 600));

    final view = tester.widget<NavigationView>(find.byType(NavigationView));
    expect(view.pane?.displayMode, PaneDisplayMode.open);
    expect(view.pane?.items, hasLength(7));
    expect(view.pane?.footerItems, hasLength(1));
    expect(find.byKey(const ValueKey('tablet-navigation')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-app-bar')), findsNothing);
    expect(find.byKey(const ValueKey('desktop-title-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('window-minimize')), findsOneWidget);
    expect(find.byKey(const ValueKey('window-maximize')), findsOneWidget);
    expect(find.byKey(const ValueKey('window-close')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('navigation-pane-resizer')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('navigation-pane-toggle')),
      findsOneWidget,
    );
    final sourceItem = view.pane!.items[2] as PaneItem;
    final pluginItem = view.pane!.items[3] as PaneItem;
    expect((sourceItem.title as Text).data, '书源管理');
    expect((pluginItem.title as Text).data, '插件配置');
    expect(
      view.pane?.items
          .whereType<PaneItem>()
          .map((item) => item.title)
          .whereType<Text>()
          .map((text) => text.data),
      contains('漫画翻译'),
    );
  });

  testWidgets('switching to Linux remote hides client plugin management',
      (tester) async {
    final harness = await _Harness.create(
      const Size(1280, 800),
      targetPlatform: TargetPlatform.windows,
      backendMode: BackendConnectionMode.local,
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 600));

    harness.appState.selectSection(AppSection.plugins);
    await tester.pump(const Duration(milliseconds: 180));
    expect(harness.appState.section, AppSection.plugins);
    expect(find.text('插件配置'), findsWidgets);

    await harness.appState.selectBackendMode(BackendConnectionMode.remote);
    await tester.pump(const Duration(milliseconds: 180));

    final view = tester.widget<NavigationView>(find.byType(NavigationView));
    expect(view.pane?.items, hasLength(6));
    expect(
      view.pane?.items
          .whereType<PaneItem>()
          .map((item) => item.title)
          .whereType<Text>()
          .map((text) => text.data),
      isNot(contains('插件配置')),
    );
    expect(harness.appState.section, AppSection.settings);
    expect(find.byKey(const ValueKey('settings-plugins-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow Windows keeps Fluent desktop navigation', (tester) async {
    final harness = await _Harness.create(
      const Size(620, 720),
      targetPlatform: TargetPlatform.windows,
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 600));

    final view = tester.widget<NavigationView>(find.byType(NavigationView));
    expect(view.pane?.displayMode, PaneDisplayMode.compact);
    expect(
        find.byKey(const ValueKey('mobile-bottom-navigation')), findsNothing);
    expect(find.byKey(const ValueKey('tablet-navigation')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-title-bar')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('navigation-pane-resizer')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone settings opens cross-platform project information',
      (tester) async {
    MethodCall? clipboardCall;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboardCall = call;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final harness = await _Harness.create(const Size(390, 844));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(
      find.byKey(const ValueKey('mobile-navigation-settings')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const ValueKey('settings-about-button')));
    await tester.pumpAndSettle();

    expect(find.text('关于青卷'), findsOneWidget);
    expect(find.text('Windows 10 / 11 · Android 8.0+'), findsOneWidget);
    expect(find.text('https://github.com/Tavre/QingJuan'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 600));
    expect(harness.appState.section, AppSection.settings);

    await tester.tap(find.byKey(const ValueKey('settings-about-button')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const ValueKey('copy-https://github.com/Tavre/QingJuan'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('GitHub 地址已复制'), findsOneWidget);
    expect(clipboardCall?.method, 'Clipboard.setData');
  });

  testWidgets('phone shell supports dark theme and 200 percent text scaling',
      (tester) async {
    final harness = await _Harness.create(
      const Size(390, 844),
      textScaler: const TextScaler.linear(2),
      brightness: Brightness.dark,
    );
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 600));

    expect(
        find.byKey(const ValueKey('mobile-bottom-navigation')), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('mobile-navigation-settings')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('mobile-my-dashboard')),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('my-feature-about')),
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.takeException(), isNull);
  });

  testWidgets('book card handles a long CJK title without overflowing',
      (tester) async {
    final harness = await _Harness.create(
      const Size(390, 844),
      textScaler: const TextScaler.linear(1.5),
      books: const <Book>[
        Book(
          id: 'long-title',
          title: '[Aliceholic13]花火制服コスで竜マ＆バイオナナ的非常长作品标题',
          sourceUrl: '',
          kind: '漫画',
          language: '中文',
          status: '已导入',
          chapterCount: 120,
          translated: true,
          synopsis: '',
          lastReadChapterIndex: 99,
        ),
      ],
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.textContaining('[Aliceholic13]'), findsWidgets);
    expect(
      find.byKey(const ValueKey('continue-reading-card')),
      findsOneWidget,
    );
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
    expect(tester.takeException(), isNull);
  });
}

class _Harness {
  _Harness({
    required this.widget,
    required this.appState,
    required this.api,
    required this.backend,
    required this.auth,
    required this.library,
    required this.sources,
    required this.tasks,
    required this.settings,
  });

  static Future<_Harness> create(
    Size viewport, {
    bool configured = true,
    List<Book> books = const <Book>[],
    TextScaler textScaler = TextScaler.noScaling,
    Brightness brightness = Brightness.light,
    TargetPlatform targetPlatform = TargetPlatform.android,
    BackendConnectionMode backendMode = BackendConnectionMode.remote,
    bool multiUser = false,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    if (configured) {
      await preferences.setString(
        'qingjuan.backendUrl',
        'https://qingjuan.example.test',
      );
    }
    await preferences.setString('qingjuan.backendMode', backendMode.name);
    final appState = AppState(
      preferences,
      initialRemoteBackendToken: configured ? 'test-token' : '',
      localBackendSupported: targetPlatform == TargetPlatform.windows,
    );
    final api = ApiClient(() => appState.backendUrl);
    final backend = BackendConnectionManager(
      api,
      isConfigured: () => appState.hasBackendConnection,
    )
      ..status = configured ? BackendStatus.ready : BackendStatus.unconfigured
      ..multiUserEnabled = multiUser;
    final auth = multiUser
        ? AuthController(
            api,
            const _EmptyUserSessionStore(),
            backendUrl: () => appState.backendUrl,
          )
        : AuthController.localAdministrator(api);
    if (multiUser) {
      await auth.initializeForCurrentBackend(multiUser: true);
    }
    final library = LibraryController(api);
    if (books.isNotEmpty) {
      library.books = books;
      library.state = LoadState.ready;
    }
    final sources = SourcesController(api);
    final tasks = TasksController(api);
    final settings = SettingsController(api);
    final widget = AppScope(
      appState: appState,
      api: api,
      backend: backend,
      auth: auth,
      library: library,
      sources: sources,
      tasks: tasks,
      settings: settings,
      child: FluentApp(
        theme: buildQingJuanTheme(brightness, platform: targetPlatform),
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(size: viewport, textScaler: textScaler),
          child: UiPlatformScope(
            platform: targetPlatform,
            child: DesktopWindowFrame(
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
        home: const AppShell(),
      ),
    );
    return _Harness(
      widget: widget,
      appState: appState,
      api: api,
      backend: backend,
      auth: auth,
      library: library,
      sources: sources,
      tasks: tasks,
      settings: settings,
    );
  }

  final Widget widget;
  final AppState appState;
  final ApiClient api;
  final BackendConnectionManager backend;
  final AuthController auth;
  final LibraryController library;
  final SourcesController sources;
  final TasksController tasks;
  final SettingsController settings;

  Future<void> dispose() async {
    library.dispose();
    sources.dispose();
    tasks.dispose();
    settings.dispose();
    auth.dispose();
    await backend.dispose();
    api.close();
    appState.dispose();
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
