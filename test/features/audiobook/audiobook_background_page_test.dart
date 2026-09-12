import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart' as material;
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/features/audiobook/audiobook_controller.dart';
import 'package:qingjuan/features/audiobook/audiobook_page.dart';
import 'package:qingjuan/features/audiobook/audiobook_sleep_timer.dart';
import 'package:qingjuan/features/audiobook/audiobook_coordinator.dart';
import 'package:qingjuan/features/audiobook/audiobook_position_store.dart';
import 'package:qingjuan/features/audiobook/audiobook_resume_entry.dart';
import 'package:qingjuan/core/models/audiobook_position.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'audiobook_background_fixtures.dart';

void main() {
  testWidgets(
      'mobile resume entry uses Material controls at 320px and 200 percent text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final coordinator = AudiobookCoordinator(
        engineFactory: (_) => BackgroundEngine(),
        initializePlatform: (_) async => BackgroundRuntime(),
        positionStore: (instance, owner, book) => _NoopStore());
    await coordinator.open(
        instanceId: 'instance',
        ownerId: 'owner',
        detail: backgroundDetail,
        loadChapter: (index, mode) async => backgroundContent(index, mode),
        isCurrentContext: () => true);
    var opened = false;
    await tester.pumpWidget(material.MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: material.Scaffold(
            body: AudiobookResumeEntry(
                coordinator: coordinator,
                mobile: true,
                onOpen: (_) {
                  opened = true;
                }))));
    await tester.pumpAndSettle();
    expect(find.byType(material.IconButton), findsNWidgets(2));
    await tester.tap(find.text('听书 · 听书测试'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
    await coordinator.stopAndClear();
    await tester.pumpAndSettle();
    expect(find.text('听书 · 听书测试'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await coordinator.close();
  });
  testWidgets('shared player survives page exit and hides closed session body',
      (tester) async {
    final engine = BackgroundEngine();
    final controller = AudiobookController(
        detail: backgroundDetail,
        engine: engine,
        loadChapter: (index, mode) async =>
            backgroundContent(index, mode, text: '只属于当前账号的正文'));
    await controller.initialize();
    final playing = controller.play();
    await tester.pumpWidget(FluentApp(
        home: AudiobookPage(
            detail: backgroundDetail,
            loadChapter: controller.loadChapter,
            controller: controller)));
    await tester.pumpAndSettle();
    expect(find.text('只属于当前账号的正文'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(controller.isPlaying, isTrue);
    expect(engine.disposals, 0);
    await tester.pumpWidget(FluentApp(
        home: AudiobookPage(
            detail: backgroundDetail,
            loadChapter: controller.loadChapter,
            controller: controller)));
    await controller.shutdown();
    await tester.pumpAndSettle();
    expect(find.text('只属于当前账号的正文'), findsNothing);
    expect(find.text('听书会话已结束或身份已切换'), findsOneWidget);
    await playing;
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    expect(engine.disposals, 1);
  });

  testWidgets('sleep timer settings fit narrow Android at large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final timer = AudiobookSleepTimer(onElapsed: () async {});
    addTearDown(timer.dispose);
    await tester.pumpWidget(FluentApp(
        theme: buildQingJuanTheme(Brightness.dark,
            platform: TargetPlatform.android),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!),
        home: UiPlatformScope(
            platform: TargetPlatform.android,
            child: AudiobookPage(
                detail: backgroundDetail,
                engine: BackgroundEngine(),
                sleepTimer: timer,
                loadChapter: (index, mode) async =>
                    backgroundContent(index, mode, text: '测试正文')))));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(FluentIcons.settings));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('设置定时停止'));
    await tester.tap(find.byType(ComboBox<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 分钟后停止'));
    await tester.pumpAndSettle();
    expect(timer.deadline, isNotNull);
    expect(tester.takeException(), isNull);
    timer.set(null);
  });
}

class _NoopStore implements AudiobookPositionStore {
  @override
  Future<AudiobookPosition?> load() async => null;
  @override
  Future<void> save(AudiobookPosition position) async {}
}
