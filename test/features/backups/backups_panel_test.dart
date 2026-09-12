import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/features/backups/backups_controller.dart';
import 'package:qingjuan/features/backups/backups_panel.dart';

import 'backups_controller_test.dart' show BackupTestApi, artifact;

void main() {
  late BackupTestApi api;
  late BackupsController controller;
  setUp(() {
    api = BackupTestApi();
    controller = BackupsController(api, onRestored: () async {})
      ..setContext(revision: 1, enabled: true);
  });
  tearDown(() {
    controller.dispose();
    api.close();
  });

  Widget panel({Future<String?> Function()? picker, double scale = 1}) =>
      FluentApp(
        theme: buildQingJuanTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: ScaffoldPage(
            content: SingleChildScrollView(
                child: BackupsPanel(
          controller: controller,
          selectFile: picker ?? () async => 'source.zip',
          saveLocation: (_) async => 'saved.zip',
        ))),
      );

  testWidgets(
      'create remains disabled until acknowledgment and save uses chosen location',
      (tester) async {
    await tester.pumpWidget(panel());
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('backup-create')))
            .onPressed,
        isNull);
    await tester
        .tap(find.byKey(const ValueKey('backup-sensitive-acknowledgment')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-create')));
    await tester.pumpAndSettle();
    expect(api.creates, 1);
    await tester
        .ensureVisible(find.byKey(ValueKey('backup-save-${artifact.id}')));
    await tester.tap(find.byKey(ValueKey('backup-save-${artifact.id}')));
    await tester.pumpAndSettle();
    expect(api.downloadedPath, 'saved.zip');
    expect(find.textContaining('完整性校验'), findsOneWidget);
  });

  testWidgets(
      'preflight shows counts, explicit confirmation and completed result',
      (tester) async {
    await tester.pumpWidget(panel());
    await tester.tap(find.byKey(const ValueKey('backup-select-file')));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前书籍 1 本，备份中 3 本'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('backup-review-restore')));
    await tester.pumpAndSettle();
    expect(find.text('书籍：当前 1 → 备份 3'), findsOneWidget);
    expect(find.text('• 翻译设置和插件'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('backup-confirm-restore')))
            .onPressed,
        isNull);
    await tester.ensureVisible(
        find.byKey(const ValueKey('backup-restore-acknowledgment')));
    await tester
        .tap(find.byKey(const ValueKey('backup-restore-acknowledgment')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-confirm-restore')));
    await tester.pumpAndSettle();
    expect(api.restores, 1);
    expect(find.textContaining('书库、任务和设置已刷新'), findsOneWidget);
  });

  testWidgets(
      'backend switch clears an open confirmation and forbids its restore',
      (tester) async {
    await tester.pumpWidget(panel());
    await tester.tap(find.byKey(const ValueKey('backup-select-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup-review-restore')));
    await tester.pumpAndSettle();
    controller.setContext(revision: 2, enabled: false);
    await tester.pumpAndSettle();
    expect(find.text('书籍：当前 1 → 备份 3'), findsNothing);
    expect(find.textContaining('后端已切换或预检已失效'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('backup-confirm-restore')))
            .onPressed,
        isNull);
    expect(api.restores, 0);
  });

  testWidgets(
      'file picker response after backend switch never uploads to the new source',
      (tester) async {
    final pending = Completer<String?>();
    await tester.pumpWidget(panel(picker: () => pending.future));
    await tester.tap(find.byKey(const ValueKey('backup-select-file')));
    controller.setContext(revision: 2, enabled: true);
    pending.complete('old.zip');
    await tester.pumpAndSettle();
    expect(api.inspections, 0);
  });

  testWidgets('narrow Windows panel remains scrollable at 200 percent text',
      (tester) async {
    tester.view.physicalSize = const Size(480, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await controller.load();
    await tester.pumpWidget(panel(scale: 2));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(ValueKey('backup-save-${artifact.id}')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
