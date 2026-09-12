import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/features/library/import_history_page.dart';
import 'package:qingjuan/mobile/mobile_theme.dart';

import '../../helpers/reliability_harness.dart';
import '../../helpers/ui_review_capture.dart';

void main() {
  setUpAll(loadUiReviewFonts);
  testWidgets(
      'mobile import history reports server errors and retries without an empty success message',
      (tester) async {
    var failed = true;
    final harness = await ReliabilityHarness.create(MockClient(
        (request) async => failed
            ? _response({'detail': '导入记录尚未就绪，请稍后重试'}, 409)
            : _response([])));
    addTearDown(harness.dispose);
    await tester.pumpWidget(
        harness.widget(const ImportHistoryPage(mobile: true), mobile: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('导入记录尚未就绪'), findsOneWidget);
    expect(find.textContaining('还没有导入记录'), findsNothing);
    failed = false;
    await tester.tap(find.text('刷新记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有导入记录'), findsOneWidget);
  });

  testWidgets(
      'mobile import form fits 200 percent text and provides touch-sized labelled actions',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final harness =
        await ReliabilityHarness.create(MockClient((_) async => _response([])));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget(
        const ImportHistoryPage(mobile: true),
        mobile: true,
        textScale: 2));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.widgetWithText(FilledButton, '批量导入')).height,
        greaterThanOrEqualTo(48));
    await tester.tap(find.text('批量导入'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.magnifierConfiguration, TextMagnifierConfiguration.disabled);
    await tester.ensureVisible(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('作品类型')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('作品语言')), findsWidgets);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('an import error is visible even if its message is empty',
      (tester) async {
    final harness = await ReliabilityHarness.create(MockClient(
        (request) async => _response(
            request.url.queryParameters['activeOnly'] == 'true'
                ? []
                : [_failedJob])));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget(const ImportHistoryPage()));
    await tester.pumpAndSettle();
    expect(find.text('站点返回错误，请稍后重试'), findsOneWidget);
    expect(find.text('重试已加载的失败项'), findsOneWidget);
    expect(find.text('重试导入'), findsOneWidget);
  });

  testWidgets(
      'session change clears old URLs and ignores a pending submission error',
      (tester) async {
    final response = Completer<http.Response>();
    final harness = await ReliabilityHarness.create(MockClient(
        (request) async =>
            request.method == 'POST' ? response.future : _response([])));
    addTearDown(harness.dispose);
    await tester.pumpWidget(
        harness.widget(const ImportHistoryPage(mobile: true), mobile: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量导入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.test/old');
    await tester.ensureVisible(find.text('加入导入队列'));
    await tester.tap(find.text('加入导入队列'));
    await tester.pump();
    harness.scope.library.resetForBackendSwitch();
    harness.scope.library.imports.enabled = true;
    await harness.scope.library.imports.load();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('批量导入'));
    await tester.tap(find.text('批量导入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.test/new');
    response.complete(_response({'detail': '旧账号无权限'}, 403));
    await tester.pumpAndSettle();
    expect(find.text('https://example.test/old'), findsNothing);
    expect(find.text('https://example.test/new'), findsOneWidget);
    expect(find.textContaining('旧账号无权限'), findsNothing);
  });

  testWidgets(
      'logs stay collapsed, expand on request and reset on backend switch',
      (tester) async {
    final harness = await ReliabilityHarness.create(MockClient(
        (request) async => _response(
            request.url.queryParameters['activeOnly'] == 'true'
                ? []
                : [_jobWithLogs])));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget(const ImportHistoryPage()));
    await tester.pumpAndSettle();
    expect(find.text('站点返回错误，请稍后重试'), findsOneWidget);
    expect(find.text('已解析目录，正在检查章节'), findsNothing);
    expect(find.textContaining('T12:00:00Z'), findsNothing);
    expect(find.textContaining('2026年9月11日'), findsOneWidget);
    await tester.tap(find.text('查看日志 (2)'));
    await tester.pumpAndSettle();
    expect(find.text('已解析目录，正在检查章节'), findsOneWidget);
    await tester.tap(find.text('收起日志'));
    await tester.pumpAndSettle();
    expect(find.text('已解析目录，正在检查章节'), findsNothing);
    await tester.tap(find.text('查看日志 (2)'));
    await tester.pumpAndSettle();
    harness.scope.library.resetForBackendSwitch();
    harness.scope.library.imports.enabled = true;
    await harness.scope.library.imports.load();
    await tester.pumpAndSettle();
    expect(find.text('已解析目录，正在检查章节'), findsNothing);
    expect(find.text('查看日志 (2)'), findsOneWidget);
  });

  testWidgets('retry is disabled while its request is pending', (tester) async {
    final retry = Completer<http.Response>();
    var requests = 0;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.method == 'POST') {
        requests++;
        return retry.future;
      }
      return _response(request.url.queryParameters['activeOnly'] == 'true'
          ? []
          : [_failedJob]);
    }));
    addTearDown(harness.dispose);
    await tester.pumpWidget(
        harness.widget(const ImportHistoryPage(mobile: true), mobile: true));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重试导入'));
    await tester.tap(find.text('重试导入'));
    await tester.pump();
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '正在重试…'))
            .onPressed,
        isNull);
    expect(requests, 1);
    retry.complete(_response(_failedJob));
    await tester.pumpAndSettle();
    expect(find.text('重试导入'), findsOneWidget);
  });

  testWidgets('load more retains existing records and requests the next page',
      (tester) async {
    final offsets = <String?>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.queryParameters['activeOnly'] == 'true') {
        return _response([]);
      }
      final offset = request.url.queryParameters['offset'];
      offsets.add(offset);
      if (offset == '50') return _response([_completedJob('older', '更早的作品')]);
      return _response([
        for (var i = 0; i < 50; i++) _completedJob('job-$i', '作品 $i'),
      ]);
    }));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget(const ImportHistoryPage()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('加载更多记录'), 500,
        scrollable: find.byType(Scrollable).first, maxScrolls: 50);
    await Scrollable.ensureVisible(tester.element(find.text('加载更多记录')),
        alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多记录'));
    await tester.pumpAndSettle();
    expect(offsets, contains('50'));
    expect(harness.scope.library.imports.jobs.length, 51);
    expect(find.text('加载更多记录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final fixture in [
    (name: 'desktop', size: const Size(1440, 960), mobile: false, scale: 1.0),
    (name: 'mobile', size: const Size(390, 844), mobile: true, scale: 1.0),
    (
      name: 'mobile-large-text',
      size: const Size(360, 800),
      mobile: true,
      scale: 2.0
    ),
  ]) {
    testWidgets('import history ${fixture.name} remains readable and operable',
        (tester) async {
      tester.view.physicalSize = fixture.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final active = {
        ..._failedJob,
        'id': 'running',
        'status': 'running',
        'progress': 64,
        'error': null,
        'message': '正在检查章节，已处理 32 / 50 章',
        'createdAt': '2026-09-12T08:20:00Z',
        'updatedAt': '2026-09-12T08:20:00Z',
        'preview': {'title': '穿过森林的风', 'chapterCount': 50},
      };
      final harness = await ReliabilityHarness.create(MockClient(
          (request) async => _response(
              request.url.queryParameters['activeOnly'] == 'true'
                  ? [active]
                  : [active, _jobWithLogs, _completedJob('done', '长日将尽')])));
      addTearDown(harness.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: harness.widget(
            fixture.mobile
                ? Theme(
                    data: _mobileFixtureTheme(),
                    child: const ImportHistoryPage(mobile: true),
                  )
                : const ImportHistoryPage(),
            mobile: fixture.mobile,
            textScale: fixture.scale),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (!fixture.mobile) {
        final list = tester.getRect(find.byType(ListView));
        expect(list.width, lessThanOrEqualTo(1120));
        expect(list.left, greaterThanOrEqualTo(100));
      }
      await captureUi(tester, key, 'import-history-${fixture.name}');
      if (!fixture.mobile) {
        await tester.tap(find.text('批量导入'));
        await tester.pumpAndSettle();
        await captureUi(tester, key, 'import-history-desktop-form');
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
      await tester.scrollUntilVisible(find.text('重试导入'), 200,
          scrollable: find.byType(Scrollable).first);
      await Scrollable.ensureVisible(tester.element(find.text('重试导入')),
          alignment: 0.5);
      await tester.pumpAndSettle();
      expect(find.text('重试导入').hitTestable(), findsOneWidget);
      await tester.ensureVisible(find.text('查看日志 (2)'));
      await tester.tap(find.text('查看日志 (2)'));
      await tester.pumpAndSettle();
      expect(find.text('已解析目录，正在检查章节'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (fixture.mobile) {
        await Scrollable.ensureVisible(tester.element(find.text('重试导入')),
            alignment: 0.2);
        await tester.pumpAndSettle();
        await captureUi(tester, key, 'import-history-${fixture.name}-actions');
      }
      harness.scope.library.imports.reset();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

final _jobWithLogs = {
  ..._failedJob,
  'preview': {'title': '山海之间', 'chapterCount': 128},
  'logs': [
    {
      'sequence': 1,
      'level': 'info',
      'message': '已解析目录，正在检查章节',
      'createdAt': '2026-09-11T11:59:00Z'
    },
    {
      'sequence': 2,
      'level': 'error',
      'message': '站点返回错误，请稍后重试',
      'createdAt': '2026-09-11T12:00:00Z'
    },
  ],
};

Map<String, Object?> _completedJob(String id, String title) => {
      ..._failedJob,
      'id': id,
      'status': 'completed',
      'progress': 100,
      'error': null,
      'message': '导入完成',
      'book': {'id': id, 'title': title, 'chapterCount': 36, 'language': '中文'},
    };

const _failedJob = {
  'id': 'failed',
  'mode': 'import',
  'status': 'failed',
  'progress': 30,
  'message': '',
  'error': '站点返回错误，请稍后重试',
  'sourceUrl': 'https://example.test/book',
  'createdAt': '2026-09-11T12:00:00Z',
  'updatedAt': '2026-09-11T12:00:00Z'
};

ThemeData _mobileFixtureTheme() {
  final colors = qjMobileLightColors();
  final text = qjMobileTextStyles();
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: colors.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: colors.primary,
      primary: colors.primary,
      onPrimary: colors.onPrimary,
      surface: colors.surfaceContainer,
      onSurface: colors.onSurface,
      onSurfaceVariant: colors.onBackgroundVariant,
      outlineVariant: colors.dividerLine,
    ),
    textTheme: TextTheme(
      bodySmall: text.footnote1,
      bodyMedium: text.body2,
      titleMedium: text.subtitle,
      titleLarge: text.title3,
      labelLarge: text.button,
    ),
  );
}

http.Response _response(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
