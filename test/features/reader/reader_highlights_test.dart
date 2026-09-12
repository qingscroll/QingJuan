import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/features/reader/annotations_page.dart';
import 'package:qingjuan/features/reader/reader_page.dart';

import '../../helpers/reliability_harness.dart';
import 'annotation_highlights_test.dart' show highlightJson, underlinedText;
import 'annotations_controller_test.dart' show response;
import 'reader_annotations_test.dart'
    show openAnnotationReader, annotationChapter;

void main() {
  for (final (mobile, flow) in [
    (false, ReaderFlowMode.continuous),
    (true, ReaderFlowMode.continuous),
    (true, ReaderFlowMode.paged),
  ]) {
    testWidgets(
        'persistent underline survives reopen/edit and disappears on delete mobile=$mobile flow=$flow',
        (tester) async {
      Map<String, dynamic>? saved =
          highlightJson('\ue000😀needle 正文。', 'needle', 3);
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.method == 'PATCH') {
          saved = {
            ...saved!,
            ...jsonDecode(request.body) as Map<String, dynamic>,
            'revision': 2
          };
          return response(saved!);
        }
        if (request.method == 'DELETE') {
          saved = null;
          return response({'status': 'ok'});
        }
        if (request.url.path.endsWith('/annotations')) {
          final query = request.url.queryParameters;
          return response(saved != null &&
                  query['kind'] == 'note' &&
                  (query['chapterIndex'] == null ||
                      query['chapterIndex'] == '1') &&
                  (query['mode'] == null || query['mode'] == 'original')
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
      await harness.scope.appState.setReaderFlowMode(flow);
      Future<void> openNotes() async {
        await tester
            .tap(find.byKey(const f.ValueKey('reader-annotations-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('笔记').first);
        await tester.pumpAndSettle();
      }

      Future<void> backToReader() async {
        f.Navigator.of(tester.element(find.byType(AnnotationsPage))).pop();
        await tester.pumpAndSettle();
      }

      for (var opening = 0; opening < 2; opening++) {
        await openAnnotationReader(tester, harness, mobile);
        expect(readerUnderlines(tester), contains('needle'));
        if (opening == 0) {
          await tester.pumpWidget(const f.SizedBox());
          await tester.pump(const Duration(seconds: 1));
        }
      }
      await openNotes();
      await tester.ensureVisible(find.text('编辑'));
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const f.ValueKey('annotation-note')), '编辑后的想法');
      f.FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存记录'));
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      expect(saved!['note'], '编辑后的想法');
      await backToReader();
      expect(readerUnderlines(tester), contains('needle'));
      await openNotes();
      await tester.ensureVisible(find.text('删除'));
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(saved, isNull);
      await backToReader();
      expect(readerUnderlines(tester), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const f.SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}

String readerUnderlines(WidgetTester tester) => tester
        .widgetList<f.Widget>(find.descendant(
            of: find.byType(ReaderPage),
            matching: find.byWidgetPredicate(
                (widget) => widget is f.SelectableText || widget is f.Text)))
        .map((widget) {
      final span = widget is f.SelectableText
          ? widget.textSpan
          : (widget as f.Text).textSpan;
      return span == null ? '' : underlinedText(span);
    }).join();
