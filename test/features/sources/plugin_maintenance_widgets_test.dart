import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/sources/widgets/plugin_maintenance_widgets.dart';

import 'plugin_maintenance_fixture.dart';

void main() {
  late MaintenanceApi api;
  late SourcesController sources;
  setUp(() {
    api = MaintenanceApi();
    sources = SourcesController(api);
  });
  tearDown(() {
    sources.dispose();
    api.close();
  });

  Future<void> open(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(FluentApp(
        theme: buildQingJuanTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: ScaffoldPage(
            content: Center(
                child: PluginMaintenanceButton(
                    plugin: maintainedPlugin, controller: sources)))));
    await tester.tap(find.text('插件维护'));
    await tester.pumpAndSettle();
  }

  testWidgets('dialog has explicit check and a separate rollback confirmation',
      (tester) async {
    await open(tester);
    expect(api.checks, 0);
    expect(find.text('运行自检'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('check-plugin')));
    await tester.pumpAndSettle();
    expect(find.text('接口兼容性检查通过'), findsOneWidget);
    expect(find.text('可回退版本：1.0.0'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rollback-plugin')));
    await tester.pumpAndSettle();
    expect(api.rollbacks, 0);
    expect(find.text('版本：1.1.0 → 1.0.0'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-plugin-rollback')));
    await tester.pumpAndSettle();
    expect(api.rollbacks, 1);
    expect(find.text('回退完成'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('switching backend invalidates an open rollback confirmation',
      (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('check-plugin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rollback-plugin')));
    await tester.pumpAndSettle();
    sources.resetForBackendSwitch();
    await tester.pumpAndSettle();
    expect(find.text('版本：1.1.0 → 1.0.0'), findsNothing);
    final confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirm-plugin-rollback')));
    expect(confirm.onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('后端已切换'), findsOneWidget);
    expect(find.text('接口兼容性检查通过'), findsNothing);
    expect(api.rollbacks, 0);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('maintenance report and actions fit a narrow window at 200% text',
      (tester) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, scale: 2);
    await tester.tap(find.byKey(const ValueKey('check-plugin')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('rollback-plugin')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });
}
