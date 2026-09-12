import 'dart:async';
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/features/preview/book_preview_page.dart';
import 'package:qingjuan/mobile/mobile_app.dart';
import 'package:qingjuan/shared/responsive.dart';

import '../../helpers/reliability_harness.dart';
import '../../helpers/ui_review_capture.dart';
import 'preview_fixtures.dart';

void main() {
  setUpAll(loadUiReviewFonts);
  for (final mobile in [false, true]) {
    for (final appBrightness in [f.Brightness.light, f.Brightness.dark]) {
      final platform =
          mobile ? f.TargetPlatform.android : f.TargetPlatform.windows;
      final name = '${mobile ? 'mobile' : 'desktop'}-${appBrightness.name}';
      testWidgets('$name keeps trial reading on the application theme',
          (tester) async {
        final size = mobile ? const f.Size(390, 900) : const f.Size(1280, 900);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final chapterResponse = Completer<http.Response>();
        final harness =
            await ReliabilityHarness.create(MockClient((request) async {
          if (request.url.path.endsWith('/preview/chapter')) {
            return chapterResponse.future;
          }
          if (request.url.path.endsWith('/preview')) {
            return previewJson(previewMetadata);
          }
          return previewJson([]);
        }));
        addTearDown(harness.dispose);
        await harness.scope.appState.setReaderPaletteMode(
            appBrightness == f.Brightness.dark
                ? ReaderPaletteMode.parchment
                : ReaderPaletteMode.night);
        await harness.scope.appState.setThemeMode(
            appBrightness == f.Brightness.dark
                ? AppThemeMode.dark
                : AppThemeMode.light);
        harness.scope.backend.capabilities = {'previewReading': true};
        final boundary = f.GlobalKey();
        final navigator = f.GlobalKey<f.NavigatorState>();
        const preview = BookPreviewPage(payload: previewPayload);
        await tester.pumpWidget(f.RepaintBoundary(
            key: boundary,
            child: f.ValueListenableBuilder<f.ThemeMode>(
                valueListenable: harness.scope.appState.themeModeListenable,
                builder: (context, mode, _) => harness.widget(
                    mobile
                        ? MobileQingJuanApp(navigatorKey: navigator)
                        : UiPlatformScope(platform: platform, child: preview),
                    brightness: mode == f.ThemeMode.dark
                        ? f.Brightness.dark
                        : f.Brightness.light))));
        await tester.pumpAndSettle();
        if (mobile) {
          unawaited(navigator.currentState!.push<void>(m.MaterialPageRoute(
              builder: (_) =>
                  UiPlatformScope(platform: platform, child: preview))));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(find.text('开始试读'));
        await tester.pumpAndSettle();
        final back = find.byKey(const f.ValueKey('preview-back'));
        final navigationPoint =
            f.Offset(size.width - 72, tester.getCenter(back).dy);
        final leftPoint = f.Offset(4, size.height - 70);
        final rightPoint = f.Offset(size.width - 4, size.height - 70);
        final framePoints = [navigationPoint, leftPoint, rightPoint];
        final detailColors = await _samplePixels(tester, boundary, framePoints);
        final appTheme = f.FluentTheme.of(tester.element(back));
        final material = mobile ? m.Theme.of(tester.element(back)) : null;
        final navigationColor = _textColor(tester, find.text('作品预览'));
        final primary = find.byKey(const f.ValueKey('preview-library-action'));
        final detailPrimaryFill = (await _samplePixels(tester, boundary,
                [tester.getRect(primary).centerLeft + const f.Offset(8, 0)]))
            .single;
        await captureUi(tester, boundary, 'preview-app-theme-$name-detail');

        await tester.tap(find.text('开始试读'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final content = find.byKey(const f.ValueKey('preview-chapter-content'));
        expect(content, findsOneWidget);
        final contentRect = tester.getRect(content);
        final readingPoints = [
          ...framePoints,
          contentRect.topLeft + const f.Offset(8, 8),
        ];
        expect(await _samplePixels(tester, boundary, readingPoints),
            [...detailColors, detailColors[1]],
            reason:
                'Trial reading keeps the app navigation and background colors even while loading.');
        expect(f.FluentTheme.of(tester.element(back)), same(appTheme));
        if (mobile) {
          final progress = find.byType(m.CircularProgressIndicator);
          expect(progress, findsOneWidget);
          expect(m.Theme.of(tester.element(progress)), material);
        } else {
          final progress = find.byType(f.ProgressRing);
          expect(progress, findsOneWidget);
          expect(f.FluentTheme.of(tester.element(progress)).accentColor,
              appTheme.accentColor);
        }

        chapterResponse.complete(previewJson(previewContent(1)));
        await tester.pumpAndSettle();
        final subtitle = tester.widget<f.Text>(find.text('原文试读 · 第 1 章'));
        expect(
            subtitle.style?.color,
            mobile
                ? material!.textTheme.bodySmall?.color
                : appTheme.typography.caption?.color);
        final paragraph = find.text('潮水退去，信封静静躺在旧书店的门前。');
        final paragraphColor = _textColor(tester, paragraph);
        expect(
            paragraphColor,
            mobile
                ? material!.textTheme.bodyMedium?.color
                : appTheme.typography.body?.color);
        expect(_contrast(paragraphColor, detailColors[1]), greaterThan(4.5));
        final navigationText = _textColor(tester, find.text('试读 · 潮汐带来的信'));
        expect(navigationText, navigationColor);

        final next = find.byKey(const f.ValueKey('preview-next-chapter'));
        final nextText = _textColor(tester, next);
        expect(_contrast(nextText, detailColors[1]), greaterThan(4.5));
        final primaryRect = tester.getRect(primary);
        final primaryFill = (await _samplePixels(tester, boundary,
                [primaryRect.centerLeft + const f.Offset(8, 0)]))
            .single;
        expect(_contrast(_textColor(tester, primary), primaryFill),
            greaterThan(4.5),
            reason: 'The main action remains readable on the app theme.');
        expect(primaryFill, detailPrimaryFill,
            reason: 'The same action keeps the same app color on both pages.');
        await captureUi(tester, boundary, 'preview-app-theme-$name-reading');

        // A saved reader palette must not override live app theme changes.
        final changedBrightness = appBrightness == f.Brightness.dark
            ? f.Brightness.light
            : f.Brightness.dark;
        await harness.scope.appState.setThemeMode(
            changedBrightness == f.Brightness.dark
                ? AppThemeMode.dark
                : AppThemeMode.light);
        await tester.pumpAndSettle();
        final changedTheme = f.FluentTheme.of(tester.element(back));
        expect(changedTheme.brightness, changedBrightness);
        final changedColors =
            await _samplePixels(tester, boundary, readingPoints);
        expect(changedColors[1], isNot(detailColors[1]));
        expect(changedColors[3], changedColors[1]);
        expect(_contrast(_textColor(tester, paragraph), changedColors[1]),
            greaterThan(4.5));

        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(find.text('开始试读'), findsOneWidget);
        expect(await _samplePixels(tester, boundary, framePoints),
            changedColors.take(3).toList(),
            reason: 'Both pages keep the current app theme after returning.');
        expect(f.FluentTheme.of(tester.element(back)).brightness,
            changedBrightness);
        if (mobile) {
          expect(
              m.Theme.of(tester.element(back)).brightness, changedBrightness);
        }
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(platform));
    }
  }
}

f.Color _textColor(WidgetTester tester, Finder root) {
  final widget = tester.widget<f.Widget>(root.first);
  if (widget is f.EditableText) return widget.style.color!;
  if (widget is f.RichText) return widget.text.style!.color!;
  final editable =
      find.descendant(of: root, matching: find.byType(f.EditableText));
  if (editable.evaluate().isNotEmpty) {
    return tester.widget<f.EditableText>(editable.first).style.color!;
  }
  final rich = find.descendant(of: root, matching: find.byType(f.RichText));
  return tester.widget<f.RichText>(rich.first).text.style!.color!;
}

double _contrast(f.Color foreground, f.Color background) {
  final visible = f.Color.alphaBlend(foreground, background).computeLuminance();
  final backing = background.computeLuminance();
  return visible > backing
      ? (visible + .05) / (backing + .05)
      : (backing + .05) / (visible + .05);
}

Future<List<f.Color>> _samplePixels(
    WidgetTester tester, f.GlobalKey key, List<f.Offset> globalPoints) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final points = globalPoints.map(boundary.globalToLocal).toList();
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return points.map((point) {
        final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
        return f.Color.fromARGB(
            pixels!.getUint8(offset + 3),
            pixels.getUint8(offset),
            pixels.getUint8(offset + 1),
            pixels.getUint8(offset + 2));
      }).toList();
    } finally {
      image.dispose();
    }
  }))!;
}
