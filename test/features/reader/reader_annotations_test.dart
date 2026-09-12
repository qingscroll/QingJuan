import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/reader/reader_page.dart';
import 'package:qingjuan/features/reader/annotations_page.dart';
import 'package:qingjuan/mobile/mobile_app.dart';
import 'package:qingjuan/shared/responsive.dart';

import '../../helpers/reliability_harness.dart';
import 'annotations_controller_test.dart' show response;
import 'annotation_highlights_test.dart' show highlightJson, underlinedText;

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
        'reader opens annotation search and jumps to requested chapter mobile=$mobile',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize =
          mobile ? const f.Size(390, 844) : const f.Size(1100, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final chapterReads = <String>[];
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.url.path.endsWith('/search-text')) {
          return response({
            'offsetEncoding': 'utf-16',
            'results': [
              {
                'chapterTitle': '第二章',
                'snippet': '😀needle',
                'contentHash': 'hash',
                'position': {
                  'chapterIndex': 2,
                  'contentMode': 'original',
                  'characterOffset': 3,
                  'anchorType': 'top',
                  'layoutKey': 'search-utf16-v1:hash'
                }
              }
            ]
          });
        }
        if (request.url.path.endsWith('/annotations')) return response([]);
        if (request.url.path.contains('/chapters/')) {
          chapterReads.add(request.url.path);
          return response(
              annotationChapter(int.parse(request.url.pathSegments.last)));
        }
        return response({});
      }));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities
          .addAll({'readingAnnotations': true, 'cachedTextSearch': true});
      await harness.scope.appState.setReaderFlowMode(ReaderFlowMode.continuous);
      await openAnnotationReader(tester, harness, mobile);
      await tester
          .tap(find.byKey(const f.ValueKey('reader-annotations-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('正文搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const f.ValueKey('cached-text-query')), 'needle');
      f.FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索正文'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('阅读此处'));
      await tester.tap(find.text('阅读此处'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(find.textContaining('第 2 / 2 章'), findsWidgets);
      expect(chapterReads.any((path) => path.endsWith('/2')), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const f.SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets(
        'continuous reader selection creates note at exact UTF16 offset mobile=$mobile',
        (tester) async {
      final creates = <Map<String, dynamic>>[];
      Map<String, dynamic>? saved;
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.url.path.endsWith('/annotations')) {
          if (request.method == 'POST') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            creates.add(body);
            saved = {
              ...highlightJson('\ue000😀needle 正文。', 'needle', 3),
              ...body
            };
            return response(saved!);
          }
          return response(
              saved != null && request.url.queryParameters['kind'] == 'note'
                  ? [saved]
                  : []);
        }
        if (request.url.path.contains('/chapters/')) {
          return response(
              annotationChapter(int.parse(request.url.pathSegments.last)));
        }
        return response({});
      }));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities['readingAnnotations'] = true;
      await harness.scope.appState.setReaderFlowMode(ReaderFlowMode.continuous);
      await openAnnotationReader(tester, harness, mobile);
      final editor =
          tester.state<f.EditableTextState>(find.byType(f.EditableText).first);
      final text = editor.textEditingValue.text;
      final start = text.indexOf('needle');
      expect(start, greaterThanOrEqualTo(0));
      editor.userUpdateTextEditingValue(
          editor.textEditingValue.copyWith(
              selection:
                  TextSelection(baseOffset: start, extentOffset: start + 6)),
          f.SelectionChangedCause.longPress);
      editor.showToolbar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('记笔记'));
      await tester.pumpAndSettle();
      expect(find.text('摘录：needle'), findsOneWidget);
      await tester.enterText(
          find.byKey(const f.ValueKey('annotation-note')), '读书想法');
      f.FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
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
      expect(creates.single['quote'], 'needle');
      expect(creates.single['position']['characterOffset'], 3);
      expect(creates.single['position']['contentMode'], 'original');
      f.Navigator.of(tester.element(find.byType(AnnotationsPage))).pop();
      await tester.pumpAndSettle();
      expect(
          tester
              .widgetList<f.SelectableText>(find.byType(f.SelectableText))
              .any((widget) =>
                  widget.textSpan != null &&
                  underlinedText(widget.textSpan!).contains('needle')),
          isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const f.SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets(
      'paged Android reader selection opens a note with its page anchor',
      (tester) async {
    Map<String, dynamic>? saved;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/annotations')) {
        if (request.method == 'POST') {
          saved = {
            ...highlightJson('\ue000😀needle 正文。', '', 1),
            ...jsonDecode(request.body) as Map<String, dynamic>
          };
          return response(saved!);
        }
        return response(
            saved != null && request.url.queryParameters['kind'] == 'note'
                ? [saved]
                : []);
      }
      if (request.url.path.contains('/chapters/')) {
        return response(
            annotationChapter(int.parse(request.url.pathSegments.last)));
      }
      return response({});
    }));
    addTearDown(harness.dispose);
    harness.scope.backend.capabilities['readingAnnotations'] = true;
    await harness.scope.appState.setReaderFlowMode(ReaderFlowMode.paged);
    await openAnnotationReader(tester, harness, true);
    final region = tester
        .state<f.SelectableRegionState>(find.byType(f.SelectableRegion).first);
    region.selectAll(f.SelectionChangedCause.toolbar);
    await tester.pumpAndSettle();
    await tester.tap(find.text('记笔记'));
    await tester.pumpAndSettle();
    expect(find.textContaining('摘录：😀needle 正文。'), findsOneWidget);
    await tester.enterText(
        find.byKey(const f.ValueKey('annotation-note')), '分页想法');
    f.FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存记录'));
    await tester.tap(find.text('保存记录'));
    await tester.pumpAndSettle();
    expect(saved!['position']['characterOffset'], 1);
    f.Navigator.of(tester.element(find.byType(AnnotationsPage))).pop();
    await tester.pumpAndSettle();
    expect(
        tester.widgetList<f.Text>(find.byType(f.Text)).any((widget) =>
            widget.textSpan != null &&
            underlinedText(widget.textSpan!).contains('😀needle')),
        isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const f.SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}

Future<void> openAnnotationReader(
    WidgetTester tester, ReliabilityHarness harness, bool mobile) async {
  final reader = ReaderPage(
      detail: _detail, initialChapterIndex: 1, initialMode: 'original');
  if (mobile) {
    final nav = f.GlobalKey<f.NavigatorState>();
    final scope = harness.scope;
    await tester.pumpWidget(UiPlatformScope(
        platform: f.TargetPlatform.android,
        child: AppScope(
            appState: scope.appState,
            api: scope.api,
            backend: scope.backend,
            auth: scope.auth,
            library: scope.library,
            discovery: scope.discovery,
            sources: scope.sources,
            tasks: scope.tasks,
            settings: scope.settings,
            child: MobileQingJuanApp(navigatorKey: nav))));
    await tester.pumpAndSettle();
    nav.currentState!.push(m.MaterialPageRoute<void>(builder: (_) => reader));
  } else {
    await tester.pumpWidget(harness.widget(
        UiPlatformScope(platform: f.TargetPlatform.windows, child: reader)));
  }
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

final _detail = BookDetail.fromJson({
  'book': {'id': 'book', 'title': '测试作品', 'bookKind': '长小说', 'chapterCount': 2},
  'chapters': [
    {'index': 1, 'title': '第一章'},
    {'index': 2, 'title': '第二章'}
  ],
  'progress': {'lastChapterIndex': 1, 'lastContentMode': 'original'}
});
Map<String, dynamic> annotationChapter(int index) => {
      'chapter': {'index': index, 'title': index == 1 ? '第一章' : '第二章'},
      'content': '😀needle 正文。',
      'paragraphs': ['😀needle 正文。'],
      'mode': 'original',
      'imageSources': [],
      'pageTranslations': [],
      'translatedAvailable': false
    };
