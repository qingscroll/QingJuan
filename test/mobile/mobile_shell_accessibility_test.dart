import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/mobile/mobile_app.dart';
import 'package:qingjuan/mobile/mobile_theme.dart';
import 'package:qingjuan/mobile/mobile_search_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'compact capsule keeps 48 dp targets with large text and reduced effects',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MiuixThemeController(
      colorSchemeMode: MiuixColorSchemeMode.dark,
      lightColors: qjMobileLightColors(),
      darkColors: qjMobileDarkColors(),
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                highContrast: true,
                disableAnimations: true,
                padding: const EdgeInsets.only(bottom: 24)),
            child: child!),
        home: Scaffold(
            bottomNavigationBar: MobileBottomNavigation(
                section: AppSection.library, onSelected: (_) {})),
      ),
    ));
    await tester.pumpAndSettle();
    for (final section in MobileHomeShell.primarySections) {
      final target = find.byKey(ValueKey('mobile-navigation-${section.name}'));
      final size = tester.getSize(target);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(tester.getBottomLeft(target).dy, lessThanOrEqualTo(716));
    }
    for (final filter
        in tester.widgetList<BackdropFilter>(find.byType(BackdropFilter))) {
      expect(filter.enabled, isFalse);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet navigation remains reachable with the keyboard open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 350);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });
    SharedPreferences.setMockInitialValues(<String, Object>{
      'qingjuan.backend.remote.url': 'https://reading.example.test',
      'qingjuan.backendMode': 'remote',
    });
    final app = AppState(
      await SharedPreferences.getInstance(),
      initialRemoteBackendToken: 'fixture',
    );
    final api = ApiClient(
      () => app.backendUrl,
      client: MockClient((_) async => http.Response('[]', 200)),
    );
    final backend = BackendConnectionManager(api, isConfigured: () => true)
      ..status = BackendStatus.ready;
    final auth = AuthController.localAdministrator(api);
    final library = LibraryController(api)..state = LoadState.empty;
    final sources = SourcesController(api);
    final tasks = TasksController(api);
    final settings = SettingsController(api);
    addTearDown(() {
      app.dispose();
      api.close();
      backend.dispose();
      auth.dispose();
      library.dispose();
      sources.dispose();
      tasks.dispose();
      settings.dispose();
    });
    await tester.pumpWidget(
      AppScope(
        appState: app,
        api: api,
        backend: backend,
        auth: auth,
        library: library,
        sources: sources,
        tasks: tasks,
        settings: settings,
        child: const MobileQingJuanApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final mine = find.byKey(const ValueKey('mobile-navigation-settings'));
    await tester.ensureVisible(mine);
    await tester.tap(mine);
    await tester.pumpAndSettle();
    expect(app.section, AppSection.settings);
    expect(tester.takeException(), isNull);

    // An offstage shelf selection must not intercept another page's route.
    tester.view.resetViewInsets();
    library.books = <Book>[
      Book.fromJson(<String, dynamic>{'id': 'one', 'title': '一册故事'}),
    ];
    library.state = LoadState.ready;
    library.setQuery(' ');
    app.selectSection(AppSection.library);
    await tester.pumpAndSettle();
    final rail = find.byWidgetPredicate(
        (widget) => widget is SizedBox && widget.width == 96);
    expect(tester.getSize(rail).height, 700);
    await tester.longPress(
      find.byKey(const ValueKey('mobile-library-book-one')),
    );
    await tester.pumpAndSettle();
    expect(find.text('选择作品'), findsOneWidget);
    app.selectSection(AppSection.search);
    await tester.pumpAndSettle();
    final navigator = Navigator.of(
      tester.element(find.byType(MobileSearchPage)),
    );
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('二级页面')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('二级页面'), findsNothing);
    expect(app.section, AppSection.search);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(app.section, AppSection.library);
    expect(find.text('选择作品'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each mobile destination exposes an accessible tap action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      AppSection? selected;
      await tester.pumpWidget(
        MiuixThemeController(
          lightColors: qjMobileLightColors(),
          darkColors: qjMobileDarkColors(),
          child: MaterialApp(
            home: Scaffold(
              bottomNavigationBar: MobileBottomNavigation(
                section: AppSection.library,
                onSelected: (value) => selected = value,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final node = tester.getSemantics(find.bySemanticsLabel('发现'));
      expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
      tester.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          nodeId: node.id,
          viewId: tester.view.viewId,
          type: ui.SemanticsAction.tap,
        ),
      );
      await tester.pump();
      expect(selected, AppSection.search);
    } finally {
      handle.dispose();
    }
  });
}
