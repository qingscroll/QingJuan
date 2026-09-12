import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/library/book_updates_page.dart';
import 'package:qingjuan/mobile/mobile_app.dart';

import '../../helpers/reliability_harness.dart';
import '../../helpers/ui_review_capture.dart';

void main() {
  setUpAll(loadUiReviewFonts);
  for (final mobile in [false, true]) {
    testWidgets(
        'serial updates can be acknowledged and configured at 200 percent mobile=$mobile',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize =
          mobile ? const f.Size(390, 844) : const f.Size(1100, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <http.Request>[];
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/ack')) {
          return _json(
              {..._state, 'newChapterCount': 0, 'acknowledgedChapterIndex': 8});
        }
        if (request.method == 'PUT') {
          return _json({'detail': '其他设备已修改追更设置，请重新加载'}, 409);
        }
        return _json(_state);
      }));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities['bookUpdates'] = true;
      await tester.pumpWidget(harness.widget(
          BookUpdatesPage(bookId: 'book', mobile: mobile),
          mobile: mobile,
          textScale: 2));
      await tester.pumpAndSettle();
      expect(find.text('发现 2 章更新'), findsOneWidget);
      expect(find.text('连载中'), findsOneWidget);
      expect(find.text('定时检查更新'), findsNothing);
      await tester.ensureVisible(find.text('标记更新已看'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('标记更新已看'));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.last.body), {'throughChapterIndex': 8});
      expect(find.text('暂无未确认的新章节'), findsOneWidget);
      final interval = find.byKey(const f.ValueKey('book-update-interval'));
      await tester.ensureVisible(interval);
      await tester.enterText(interval, '0');
      f.FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存追更设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存追更设置'));
      await tester.pumpAndSettle();
      expect(find.text('检查间隔应为 1 到 168 小时'), findsOneWidget);
      expect(requests.where((request) => request.method == 'PUT'), isEmpty);
      await tester.ensureVisible(interval);
      await tester.enterText(interval, '12');
      f.FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存追更设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存追更设置'));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.last.body),
          {'expectedRevision': 3, 'intervalHours': 12, 'autoDownload': false});
      expect(find.text('其他设备已修改追更设置，请重新加载'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(tester.takeException(), isNull);
      harness.scope.library.resetForBackendSwitch();
      await tester.pumpAndSettle();
      expect(find.text('账号或服务已切换，请返回书库重新打开作品。'), findsOneWidget);
      expect(find.text('12'), findsNothing);
      expect(find.text('保存追更设置'), findsNothing);
    });
  }

  testWidgets('old backend has no serial-update requests', (tester) async {
    final requests = <http.Request>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      requests.add(request);
      return _json({});
    }));
    addTearDown(harness.dispose);
    await tester
        .pumpWidget(harness.widget(const BookUpdatesPage(bookId: 'book')));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('当前服务尚不支持连载追更，请更新后端后重试。'), findsOneWidget);
  });

  for (final mobile in [false, true]) {
    for (final status in ['ongoing', 'completed', 'unknown', 'unsupported']) {
      testWidgets('backend status $status is read only mobile=$mobile',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize =
            mobile ? const f.Size(390, 900) : const f.Size(1100, 900);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final requests = <http.Request>[];
        final harness =
            await ReliabilityHarness.create(MockClient((request) async {
          requests.add(request);
          return _json({
            ..._state,
            'enabled': status != 'completed' && status != 'unsupported',
            'sourceStatus': status == 'unsupported' ? 'unknown' : status,
            'supported': status != 'unsupported',
            if (status == 'unsupported')
              'unsupportedReason': '此来源只提供下载链接，无法检查目录',
          });
        }));
        addTearDown(harness.dispose);
        harness.scope.backend.capabilities['bookUpdates'] = true;
        await tester.pumpWidget(harness.widget(
            BookUpdatesPage(bookId: 'book', mobile: mobile),
            mobile: mobile,
            textScale: 2));
        await tester.pumpAndSettle();
        expect(
            find.text(switch (status) {
              'ongoing' => '连载中',
              'completed' => '已完结',
              _ => '连载状态待确认',
            }),
            findsOneWidget);
        expect(find.text('定时检查更新'), findsNothing);
        expect(find.text('启用追更'), findsNothing);
        if (status == 'unsupported') {
          expect(find.text('此来源只提供下载链接，无法检查目录'), findsOneWidget);
          await tester.ensureVisible(find.text('立即检查更新'));
          await tester.tap(find.text('立即检查更新'));
          await tester.pumpAndSettle();
          expect(
              requests.where((request) => request.method == 'POST'), isEmpty);
        }
        expect(tester.takeException(), isNull);
        harness.scope.library.resetForBackendSwitch();
        await tester.pumpWidget(const f.SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('new chapter filter uses durable summary and resets with account',
      (tester) async {
    final harness = await ReliabilityHarness.create(
        MockClient((_) async => _json([_state])));
    addTearDown(harness.dispose);
    harness.scope.library.serials.enabled = true;
    harness.scope.library.books = [
      Book.fromJson({'id': 'book', 'title': '追更作品'}),
      Book.fromJson({'id': 'other', 'title': '其他作品'})
    ];
    await harness.scope.library.serials.load();
    harness.scope.library.setOnlyNewUpdates(true);
    expect(harness.scope.library.filteredBooks.single.id, 'book');
    harness.scope.library.resetForBackendSwitch();
    expect(harness.scope.library.onlyNewUpdates, isFalse);
    expect(harness.scope.library.serials.records, isEmpty);
  });

  for (final mobile in [false, true]) {
    testWidgets(
        'legacy serial service keeps manual check and disables preferences mobile=$mobile',
        (tester) async {
      final requests = <http.Request>[];
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        requests.add(request);
        return _json({'bookId': 'book', 'enabled': true, 'intervalHours': 6});
      }));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities['bookUpdates'] = true;
      await tester.pumpWidget(harness.widget(
          BookUpdatesPage(bookId: 'book', mobile: mobile),
          mobile: mobile));
      await tester.pumpAndSettle();
      expect(find.text('连载状态待确认'), findsOneWidget);
      expect(find.text('连载中'), findsNothing);
      expect(find.text('当前服务未提供自动连载判断，仍可手动检查目录更新。'), findsOneWidget);
      await tester.ensureVisible(find.text('保存追更设置'));
      await tester.tap(find.text('保存追更设置'));
      await tester.pumpAndSettle();
      expect(requests.where((request) => request.method == 'PUT'), isEmpty);
      await tester.ensureVisible(find.text('立即检查更新'));
      await tester.tap(find.text('立即检查更新'));
      await tester.pumpAndSettle();
      expect(
          requests
              .any((request) => request.url.path.endsWith('/updates/check')),
          isTrue);
      harness.scope.library.resetForBackendSwitch();
      await tester.pumpWidget(const f.SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('automatic serial status screenshot mobile=$mobile',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize =
          mobile ? const f.Size(420, 950) : const f.Size(1050, 850);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harness = await ReliabilityHarness.create(
          MockClient((request) async => request.url.path.contains('updates')
              ? _json({
                  ..._state,
                  'lastCheckedAt': '2026-09-12T02:00:00Z',
                  'sourceStatusCheckedAt': '2026-09-12T02:00:00Z',
                  'nextCheckAt': '2026-09-12T08:00:00Z',
                })
              : _json([])));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities['bookUpdates'] = true;
      final boundary = f.GlobalKey();
      f.Widget page = BookUpdatesPage(bookId: 'book', mobile: mobile);
      if (!mobile) {
        page = f.FluentTheme(
            data: buildQingJuanTheme(f.Brightness.light,
                platform: f.TargetPlatform.windows),
            child: page);
      }
      if (mobile) {
        final navigator = f.GlobalKey<f.NavigatorState>();
        await tester.pumpWidget(
            harness.widget(MobileQingJuanApp(navigatorKey: navigator)));
        await tester.pumpAndSettle();
        unawaited(navigator.currentState!.push<void>(m.MaterialPageRoute(
            builder: (_) => f.RepaintBoundary(key: boundary, child: page))));
      } else {
        await tester.pumpWidget(
            harness.widget(f.RepaintBoundary(key: boundary, child: page)));
      }
      await tester.pumpAndSettle();
      expect(find.text('连载中'), findsOneWidget);
      expect(find.text('定时检查更新'), findsNothing);
      await captureUi(tester, boundary,
          'book-updates-${mobile ? 'mobile' : 'desktop'}-automatic');
      harness.scope.library.resetForBackendSwitch();
      await tester.pumpWidget(const f.SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

const _state = {
  'bookId': 'book',
  'enabled': true,
  'automatic': true,
  'supported': true,
  'sourceStatus': 'ongoing',
  'intervalHours': 6,
  'autoDownload': false,
  'revision': 3,
  'newChapterCount': 2,
  'latestChapterIndex': 8,
  'acknowledgedChapterIndex': 6
};
http.Response _json(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status,
        headers: {'content-type': 'application/json'});
