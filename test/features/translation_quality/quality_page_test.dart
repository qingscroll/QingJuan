import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/features/translation_quality/translation_quality_page.dart';

import '../../helpers/reliability_harness.dart';
import 'quality_fixture.dart';

void main() {
  late ReliabilityHarness harness;
  int calls = 0, saves = 0;
  late Map<String, dynamic> current;
  setUp(() async {
    calls = saves = 0;
    current = chapterJson();
    harness = await ReliabilityHarness.create(MockClient((request) async {
      Object body;
      if (request.url.path.endsWith('/glossary')) {
        body = glossaryJson;
      } else if (request.url.path.endsWith('/retranslate')) {
        calls++;
        body = suggestionJson;
      } else if (request.url.path.contains('/history/')) {
        body = {...historyJson, 'text': '历史译文'};
      } else if (request.url.path.endsWith('/translation/chapters/1')) {
        if (request.method == 'PUT') {
          saves++;
          current = chapterJson(
              text: (jsonDecode(request.body) as Map)['text'] as String,
              revision: 1);
        }
        body = current;
      } else {
        body = [];
      }
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  });
  tearDown(() => harness.dispose());

  testWidgets(
      'model suggestion is previewed then applied to draft and saved separately',
      (tester) async {
    await tester.pumpWidget(harness.widget(
        const TranslationQualityPage(bookId: 'quality-book', chapterIndex: 1)));
    await tester.pumpAndSettle();
    expect(calls, 0);
    final original = tester
        .widget<f.TextBox>(find.byKey(const f.ValueKey('quality-source')))
        .controller!;
    final draft = tester
        .widget<f.TextBox>(find.byKey(const f.ValueKey('quality-draft')))
        .controller!;
    original.selection = const f.TextSelection(baseOffset: 2, extentOffset: 7);
    draft.selection =
        f.TextSelection(baseOffset: 0, extentOffset: draft.text.length);
    await tester
        .ensureVisible(find.byKey(const f.ValueKey('quality-retranslate')));
    await tester.tap(find.byKey(const f.ValueKey('quality-retranslate')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(saves, 0);
    expect(draft.text, '旧译文内容');
    await tester.scrollUntilVisible(
        find.byKey(const f.ValueKey('quality-apply-suggestion')), 160,
        scrollable: find
            .descendant(
                of: find.byKey(const f.ValueKey('translation-quality-scroll')),
                matching: find.byType(f.Scrollable))
            .first);
    await tester.pumpAndSettle();
    expect(
        tester
            .getCenter(find.byKey(const f.ValueKey('quality-apply-suggestion')))
            .dy,
        lessThan(
            tester.view.physicalSize.height / tester.view.devicePixelRatio));
    await tester.tap(find.byKey(const f.ValueKey('quality-apply-suggestion')));
    await tester.pumpAndSettle();
    expect(draft.text, '你好');
    expect(saves, 0);
    await tester.ensureVisible(find.byKey(const f.ValueKey('quality-save')));
    await tester.tap(find.byKey(const f.ValueKey('quality-save')));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets(
      'backend switch clears draft and invalidates an open history confirmation',
      (tester) async {
    await tester.pumpWidget(harness.widget(
        const TranslationQualityPage(bookId: 'quality-book', chapterIndex: 1)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史版本'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('版本 0 · 初始译文'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const f.ValueKey('quality-restore')));
    await tester.tap(find.byKey(const f.ValueKey('quality-restore')));
    await tester.pumpAndSettle();
    harness.scope.library.resetForBackendSwitch();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<f.FilledButton>(
                find.byKey(const f.ValueKey('quality-confirm')))
            .onPressed,
        isNull);
    expect(find.textContaining('将恢复版本 0'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byKey(const f.ValueKey('quality-draft')), findsNothing);
    expect(find.text('账号或后端已切换，请返回书库重新打开。'), findsOneWidget);
    expect(saves, 0);
  });

  for (final mobile in [false, true]) {
    testWidgets(
        'quality forms fit 360px at 200% text (${mobile ? 'Material' : 'Fluent'})',
        (tester) async {
      tester.view.physicalSize = const f.Size(360, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(harness.widget(
          TranslationQualityPage(
              bookId: 'quality-book', chapterIndex: 1, mobile: mobile),
          mobile: mobile,
          textScale: 2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('术语表'));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const f.ValueKey('quality-add-term')));
      await tester.tap(find.byKey(const f.ValueKey('quality-add-term')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(mobile ? find.byType(m.AlertDialog) : find.byType(f.ContentDialog),
          findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });
  }
}
