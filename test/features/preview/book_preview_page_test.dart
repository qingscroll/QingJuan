import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/detail/book_detail_page.dart';
import 'package:qingjuan/features/preview/book_preview_page.dart';
import 'package:qingjuan/mobile/mobile_app.dart';
import 'package:qingjuan/shared/responsive.dart';

import '../../helpers/reliability_harness.dart';
import '../../helpers/ui_review_capture.dart';
import 'preview_fixtures.dart';

void main() {
  setUpAll(loadUiReviewFonts);
  for (final configuration in [
    (name: 'desktop', mobile: false, size: const f.Size(1280, 900), scale: 1.0),
    (name: 'mobile', mobile: true, size: const f.Size(390, 844), scale: 1.0),
    (
      name: 'desktop-200',
      mobile: false,
      size: const f.Size(640, 900),
      scale: 2.0
    ),
    (
      name: 'mobile-200',
      mobile: true,
      size: const f.Size(320, 900),
      scale: 2.0
    ),
  ]) {
    testWidgets('${configuration.name} reads source before explicit import',
        (tester) async {
      _size(tester, configuration.size);
      final requests = <http.Request>[];
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/preview/chapter')) {
          return previewJson(
              previewContent(jsonDecode(request.body)['chapterIndex'] as int));
        }
        if (request.url.path.endsWith('/preview')) {
          return previewJson(previewMetadata);
        }
        if (request.url.path.endsWith('/link-jobs')) {
          return previewJson(completedPreviewImport());
        }
        if (request.url.path.endsWith('/books')) {
          return previewJson([importedPreviewBook]);
        }
        throw StateError(
            'Unexpected request ${request.method} ${request.url.path}');
      }));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities = {'previewReading': true};
      final boundary = f.GlobalKey();
      await tester.pumpWidget(f.RepaintBoundary(
          key: boundary,
          child: harness.widget(
              UiPlatformScope(
                  platform: configuration.mobile
                      ? f.TargetPlatform.android
                      : f.TargetPlatform.windows,
                  child: const BookPreviewPage(payload: previewPayload)),
              mobile: configuration.mobile,
              textScale: configuration.scale)));
      await tester.pumpAndSettle();
      expect(find.text('作者：林间 · 远行'), findsOneWidget);
      expect(find.text('长小说 · 3 章 · 连载中'), findsOneWidget);
      expect(find.text(previewSynopsis), findsOneWidget);
      await captureUi(tester, boundary, 'preview-${configuration.name}-detail');
      await tester.ensureVisible(find.text('开始试读'));
      await tester.tap(find.text('开始试读'));
      await tester.pumpAndSettle();
      expect(find.byKey(const f.ValueKey('preview-chapter-content')),
          findsOneWidget);
      await captureUi(
          tester, boundary, 'preview-${configuration.name}-reading');
      final firstParagraph = find.text('潮水退去，信封静静躺在旧书店的门前。');
      await tester.ensureVisible(firstParagraph);
      expect(firstParagraph, findsOneWidget);
      await tester
          .ensureVisible(find.byKey(const f.ValueKey('preview-next-chapter')));
      await tester.tap(find.byKey(const f.ValueKey('preview-next-chapter')));
      await tester.pumpAndSettle();
      expect(find.text('原文试读 · 第 2 章'), findsOneWidget);
      await tester
          .ensureVisible(find.byKey(const f.ValueKey('preview-next-chapter')));
      await tester.tap(find.byKey(const f.ValueKey('preview-next-chapter')));
      await tester.pumpAndSettle();
      expect(find.text('原文试读 · 第 3 章'), findsOneWidget);
      await tester.ensureVisible(
          find.byKey(const f.ValueKey('preview-previous-chapter')));
      await tester
          .tap(find.byKey(const f.ValueKey('preview-previous-chapter')));
      await tester.pumpAndSettle();
      expect(find.text('原文试读 · 第 2 章'), findsOneWidget);
      expect(
          requests
              .every((request) => request.url.path.contains('/books/preview')),
          isTrue);
      expect(harness.scope.library.books, isEmpty);
      await tester.ensureVisible(
          find.byKey(const f.ValueKey('preview-library-action')));
      await tester.tap(find.byKey(const f.ValueKey('preview-library-action')));
      await tester.pumpAndSettle();
      expect(find.text('打开作品'), findsOneWidget);
      expect(
          requests.where((request) => request.url.path.endsWith('/link-jobs')),
          hasLength(1));
      expect(
          requests.any((request) =>
              request.url.path.contains('progress') ||
              request.url.path.contains('annotation')),
          isFalse);
      await tester.tap(find.byKey(const f.ValueKey('preview-back')));
      await tester.pumpAndSettle();
      expect(find.text('作品预览'), findsOneWidget);
      expect(find.text('打开作品'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
        variant: TargetPlatformVariant.only(configuration.mobile
            ? f.TargetPlatform.android
            : f.TargetPlatform.windows));
  }

  for (final mobile in [false, true]) {
    testWidgets(
        'flagged directory entries remain readable on ${mobile ? 'mobile' : 'desktop'}',
        (tester) async {
      _size(tester, mobile ? const f.Size(390, 844) : const f.Size(1280, 900));
      final readIndexes = <int>[];
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.url.path.endsWith('/chapter')) {
          final index = jsonDecode(request.body)['chapterIndex'] as int;
          readIndexes.add(index);
          return previewJson(previewContent(index));
        }
        return previewJson({
          ...previewMetadata,
          'chapters': [
            for (final chapter in previewMetadata['chapters'] as List)
              {...chapter as Map<String, dynamic>, 'accessRestricted': true}
          ]
        });
      }));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities = {'previewReading': true};
      await tester.pumpWidget(harness.widget(
          UiPlatformScope(
              platform:
                  mobile ? f.TargetPlatform.android : f.TargetPlatform.windows,
              child: const BookPreviewPage(payload: previewPayload)),
          mobile: mobile));
      await tester.pumpAndSettle();
      expect(find.text('开始试读'), findsOneWidget);
      expect(find.text('需要书源授权，暂不可试读'), findsNothing);
      final chapter = find.byKey(const f.ValueKey('preview-chapter-3'));
      await tester.ensureVisible(chapter);
      await tester.tap(chapter);
      await tester.pumpAndSettle();
      expect(find.text('原文试读 · 第 3 章'), findsOneWidget);
      expect(readIndexes, [3]);
      expect(harness.scope.library.books, isEmpty);
      expect(harness.scope.library.linkJob, isNull);
      expect(tester.takeException(), isNull);
    },
        variant: TargetPlatformVariant.only(
            mobile ? f.TargetPlatform.android : f.TargetPlatform.windows));
  }

  testWidgets('legacy capability shows directory but never imports for reading',
      (tester) async {
    _size(tester, const f.Size(1280, 900));
    final requests = <http.Request>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      requests.add(request);
      return previewJson(previewMetadata);
    }));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget(const UiPlatformScope(
        platform: f.TargetPlatform.windows,
        child: BookPreviewPage(payload: previewPayload))));
    await tester.pumpAndSettle();
    expect(find.text('当前服务支持作品预览；升级后端后可直接试读章节。'), findsOneWidget);
    expect(find.text('开始试读'), findsNothing);
    final chapter = find.byKey(const f.ValueKey('preview-chapter-1'));
    await tester.ensureVisible(chapter);
    expect(tester.widget<f.Button>(chapter).onPressed, isNull);
    expect(requests, hasLength(1));
    expect(harness.scope.library.linkJob, isNull);
  }, variant: TargetPlatformVariant.only(f.TargetPlatform.windows));

  testWidgets('late chapter is hidden after same URL instance changes',
      (tester) async {
    _size(tester, const f.Size(1280, 900));
    final pending = Completer<http.Response>();
    var calls = 0;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      calls++;
      return request.url.path.endsWith('/chapter')
          ? pending.future
          : previewJson(previewMetadata);
    }));
    addTearDown(harness.dispose);
    harness.scope.backend.capabilities = {'previewReading': true};
    harness.scope.backend.instanceId = 'instance-a';
    await tester.pumpWidget(harness.widget(const UiPlatformScope(
        platform: f.TargetPlatform.windows,
        child: BookPreviewPage(payload: previewPayload))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始试读'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    harness.scope.backend.instanceId = 'instance-b';
    harness.scope.appState.notifyListeners();
    await tester.pump();
    pending.complete(previewJson(previewContent(1)));
    await tester.pumpAndSettle();
    expect(find.text('账号或服务已切换，请返回列表重新打开预览。'), findsOneWidget);
    expect(find.text('潮水退去，信封静静躺在旧书店的门前。'), findsNothing);
    expect(
        find.byKey(const f.ValueKey('preview-library-action')), findsNothing);
    await tester.tap(find.byKey(const f.ValueKey('preview-back')));
    await tester.pumpAndSettle();
    expect(find.text('账号或服务已切换，请返回列表重新打开预览。'), findsOneWidget);
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(f.TargetPlatform.windows));

  testWidgets('existing book opens library detail without another import',
      (tester) async {
    _size(tester, const f.Size(1280, 900));
    final requests = <http.Request>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/preview')) {
        return previewJson(previewMetadata);
      }
      if (request.url.path.endsWith('/imported-mist')) {
        return previewJson({'book': importedPreviewBook, 'chapters': []});
      }
      throw StateError('Unexpected request ${request.url}');
    }));
    addTearDown(harness.dispose);
    harness.scope.backend.capabilities = {'previewReading': true};
    await tester.pumpWidget(harness.widget(UiPlatformScope(
        platform: f.TargetPlatform.windows,
        child: BookPreviewPage(
            payload: previewPayload,
            existingBook: Book.fromJson(importedPreviewBook)))));
    await tester.pumpAndSettle();
    expect(find.text('打开作品'), findsOneWidget);
    await tester.tap(find.byKey(const f.ValueKey('preview-library-action')));
    await tester.pumpAndSettle();
    expect(find.byType(BookDetailPage), findsOneWidget);
    expect(
        requests
            .where((request) => request.method != 'GET')
            .map((request) => request.url.path),
        ['/api/v1/books/preview']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(f.TargetPlatform.windows));

  testWidgets('mobile manga image failure reloads temporary chapter assets',
      (tester) async {
    _size(tester, const f.Size(390, 844));
    var loads = 0;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/chapter')) {
        loads++;
        return previewJson(previewContent(1,
            images: ['/api/v1/books/preview/assets/session-$loads/0']));
      }
      return previewJson({...previewMetadata, 'bookKind': '漫画'});
    }));
    addTearDown(harness.dispose);
    harness.scope.backend.capabilities = {'previewReading': true};
    await tester.pumpWidget(harness.widget(
        const UiPlatformScope(
            platform: f.TargetPlatform.android,
            child: BookPreviewPage(payload: previewPayload)),
        mobile: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始试读'));
    await tester.pumpAndSettle();
    final error = find.text('第 1 张图片暂时无法读取');
    await tester.ensureVisible(error);
    expect(error, findsOneWidget);
    expect(find.text('试读图片链接可能已过期，请检查连接后重新加载本章。'), findsOneWidget);
    final retry = find.widgetWithText(m.OutlinedButton, '重新加载本章').last;
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(harness.scope.library.books, isEmpty);
    expect(harness.scope.library.linkJob, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(f.TargetPlatform.android));

  for (final scale in [1.0, 2.0]) {
    testWidgets('actual mobile theme preview and reading at scale $scale',
        (tester) async {
      _size(tester, f.Size(scale == 1 ? 390 : 320, 900));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.url.path.endsWith('/preview')) {
          return previewJson(previewMetadata);
        }
        if (request.url.path.endsWith('/chapter')) {
          return previewJson(previewContent(1));
        }
        return previewJson([]);
      }));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities = {'previewReading': true};
      final navigator = f.GlobalKey<f.NavigatorState>();
      final boundary = f.GlobalKey();
      await tester.pumpWidget(f.RepaintBoundary(
          key: boundary,
          child: harness.widget(MobileQingJuanApp(navigatorKey: navigator),
              textScale: scale)));
      await tester.pumpAndSettle();
      unawaited(navigator.currentState!.push<void>(m.MaterialPageRoute(
          builder: (context) => const UiPlatformScope(
              platform: f.TargetPlatform.android,
              child: BookPreviewPage(payload: previewPayload)))));
      await tester.pumpAndSettle();
      final name = scale == 1 ? 'mobile' : 'mobile-200';
      await captureUi(tester, boundary, 'preview-$name-detail');
      await tester.ensureVisible(find.text('开始试读'));
      await tester.tap(find.text('开始试读'));
      await tester.pumpAndSettle();
      await captureUi(tester, boundary, 'preview-$name-reading');
      expect(find.text('潮水退去，信封静静躺在旧书店的门前。'), findsOneWidget);
      expect(harness.scope.library.linkJob, isNull);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(f.TargetPlatform.android));
  }

  testWidgets('navigation captures workspace before its first frame',
      (tester) async {
    var requests = 0;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      requests++;
      return previewJson(previewMetadata);
    }));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget(UiPlatformScope(
        platform: f.TargetPlatform.windows,
        child: f.Builder(
            builder: (context) => f.Button(
                child: const f.Text('查看内容'),
                onPressed: () {
                  unawaited(showBookPreview(context, payload: previewPayload));
                  harness.scope.library.resetForBackendSwitch();
                })))));
    await tester.tap(find.text('查看内容'));
    await tester.pumpAndSettle();
    expect(find.text('账号或服务已切换，请返回列表重新打开预览。'), findsOneWidget);
    expect(
        find.byKey(const f.ValueKey('preview-library-action')), findsNothing);
    expect(requests, 0);
  }, variant: TargetPlatformVariant.only(f.TargetPlatform.windows));
}

void _size(WidgetTester tester, f.Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
