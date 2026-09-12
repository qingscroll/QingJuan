import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/reader/annotations_page.dart';

import '../../helpers/reliability_harness.dart';
import 'annotations_controller_test.dart' show record, response, searchResults;

const position = ReadingProgress(
    chapterIndex: 1,
    scrollRatio: 0,
    contentMode: 'original',
    characterOffset: 3);

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
        'note draft retries with same idempotency key and clears on account switch mobile=$mobile',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize =
          mobile ? const f.Size(390, 844) : const f.Size(1100, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final writes = <Map<String, dynamic>>[];
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.method == 'POST') {
          writes.add(jsonDecode(request.body) as Map<String, dynamic>);
          return response({'detail': '暂时无法保存，请重试'}, 503);
        }
        return response([]);
      }));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities['readingAnnotations'] = true;
      await tester.pumpWidget(harness.widget(
          AnnotationsPage(
              bookId: 'book',
              position: position,
              mobile: mobile,
              selectedQuote: '😀选中正文'),
          mobile: mobile,
          textScale: 2));
      await tester.pumpAndSettle();
      expect(find.text('摘录：😀选中正文'), findsOneWidget);
      final input = find.byKey(const f.ValueKey('annotation-note'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '保留我的笔记');
      f.FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        if (find.text('保存记录').evaluate().isEmpty) {
          await tester.scrollUntilVisible(find.text('保存记录'), 300,
              scrollable: find
                  .descendant(
                      of: find.byType(f.ListView).last,
                      matching: find.byType(f.Scrollable))
                  .first);
        }
        await tester.ensureVisible(find.text('保存记录'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存记录'));
        await tester.pumpAndSettle();
      }
      expect(writes.length, 2);
      expect(writes[0]['clientKey'], writes[1]['clientKey']);
      expect(writes[0]['quote'], '😀选中正文');
      expect(writes[0]['position']['characterOffset'], 3);
      expect(find.text('保留我的笔记'), findsOneWidget);
      harness.scope.library.resetForBackendSwitch();
      await tester.pumpAndSettle();
      expect(find.text('保留我的笔记'), findsNothing);
      expect(find.text('摘录：😀选中正文'), findsNothing);
      expect(find.text('账号或服务已切换，请返回阅读器重新打开。'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cached search returns selected UTF16 position mobile=$mobile',
        (tester) async {
      final requests = <http.Request>[];
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        requests.add(request);
        return response(request.url.path.endsWith('/search-text')
            ? searchResults('😀needle')
            : []);
      }));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities['cachedTextSearch'] = true;
      ReadingProgress? jumped;
      final launch = f.Builder(
          builder: (context) => mobile
              ? m.Scaffold(
                  body: m.TextButton(
                      onPressed: () async => jumped =
                          await showReadingAnnotations(context,
                              bookId: 'book',
                              position: position,
                              mobile: mobile),
                      child: const f.Text('打开')))
              : f.Button(
                  onPressed: () async => jumped = await showReadingAnnotations(
                      context,
                      bookId: 'book',
                      position: position),
                  child: const f.Text('打开')));
      await tester.pumpWidget(harness.widget(launch, mobile: mobile));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const f.ValueKey('cached-text-query')), 'needle');
      f.FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('搜索正文'));
      await tester.tap(find.text('搜索正文'));
      await tester.pumpAndSettle();
      expect(requests.length, 1);
      expect(find.textContaining('找到 1 处'), findsOneWidget);
      await tester.ensureVisible(find.text('阅读此处'));
      await tester.tap(find.text('阅读此处'));
      await tester.pumpAndSettle();
      expect(jumped!.characterOffset, 3);
      expect(jumped!.contentMode, 'original');
    });
  }

  testWidgets(
      'changed-content warning guards bookmark jump and delete uses revision',
      (tester) async {
    final requests = <http.Request>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      requests.add(request);
      return response(
          request.method == 'DELETE'
              ? {'detail': '其他设备已修改'}
              : [
                  {...record('标记', revision: 7), 'contentChanged': true}
                ],
          request.method == 'DELETE' ? 409 : 200);
    }));
    addTearDown(harness.dispose);
    harness.scope.backend.capabilities['readingAnnotations'] = true;
    await tester.pumpWidget(harness
        .widget(const AnnotationsPage(bookId: 'book', position: position)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(find.text('正文已变化'), findsOneWidget);
    await tester.tap(find.text('返回').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['expectedRevision'], '7');
    expect(find.text('其他设备已修改'), findsOneWidget);
    expect(find.text('标记'), findsOneWidget);
  });
}
