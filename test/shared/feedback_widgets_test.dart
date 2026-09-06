import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/mobile/mobile_state.dart';
import 'package:qingjuan/shared/feedback_widgets.dart';
import 'package:qingjuan/shared/responsive.dart';

void main() {
  for (final label in ['正在加载作品详情', '正在打开章节']) {
    testWidgets('Android loading keeps $label only for screen readers',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _sharedHarness(TargetPlatform.android, LoadingView(label: label)),
        );

        expect(find.text(label), findsNothing);
        expect(find.byType(fluent.ProgressRing), findsOneWidget);
        expect(
          tester.getSemantics(find.bySemanticsLabel(label)),
          matchesSemantics(label: label, isLiveRegion: true),
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('Windows loading still displays $label', (tester) async {
      await tester.pumpWidget(
        _sharedHarness(TargetPlatform.windows, LoadingView(label: label)),
      );

      expect(find.text(label), findsOneWidget);
      expect(find.byType(fluent.ProgressRing), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mobile list loading has no visible text but announces status',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(const miuix.MiuixThemeController(
        child: MaterialApp(
          home: Scaffold(body: MobileLoadingView('正在加载书库')),
        ),
      ));

      expect(find.text('正在加载书库'), findsNothing);
      expect(find.byType(miuix.MiuixInfiniteProgressIndicator), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('正在加载书库')),
        matchesSemantics(label: '正在加载书库', isLiveRegion: true),
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('mobile loading changes preserve visible error recovery',
      (tester) async {
    var retries = 0;
    await tester.pumpWidget(_sharedHarness(
      TargetPlatform.android,
      ErrorView(message: '连接已中断', onRetry: () => retries++),
    ));

    expect(find.text('暂时无法加载'), findsOneWidget);
    expect(find.text('连接已中断'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(tester.takeException(), isNull);
  });
}

Widget _sharedHarness(TargetPlatform platform, Widget child) =>
    fluent.FluentApp(
      home: UiPlatformScope(
        platform: platform,
        child: fluent.NavigationView(content: child),
      ),
    );
