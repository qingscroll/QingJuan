import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/features/reader/annotation_highlights.dart';
import 'package:qingjuan/features/reader/reader_page_selection.dart';
import 'package:qingjuan/features/reader/reader_pagination.dart';

import 'annotation_highlights_test.dart' show highlightNote;

void main() {
  test(
      'observed cross-fragment offsets support reversed ranges and reject conflicting candidates',
      () {
    const text = '\ue000😀needle 第一段。\n\n\ue000😀needle 第二段。';
    const quote = 'needle 第一段。\n\n😀needle';
    for (final (start, end) in [(3, 24), (24, 3)]) {
      expect(pageSelectionAnchor(text, start, end, selectedQuote: quote),
          (offset: 3, quote: quote));
    }
    expect(pageSelectionAnchor('\ue000aaaa', 1, 2, selectedQuote: 'a'), isNull);
    expect(
        pageSelectionAnchor(text, 3, 24, selectedQuote: 'unrelated'), isNull);
  });
  for (final (backward, crossParagraph) in [
    (false, false),
    (true, false),
    (false, true),
  ]) {
    testWidgets(
        'paged selection maps repeated words and empty indent spans backward=$backward crossParagraph=$crossParagraph',
        (tester) async {
      const text = '\ue000😀needle 第一段。\n\n\ue000😀needle 第二段。';
      final second = text.lastIndexOf('needle');
      final start = crossParagraph ? text.indexOf('needle') : second;
      final end = second + 6;
      final expectedQuote = text.substring(start, end).replaceAll('\ue000', '');
      int? savedOffset;
      String? savedQuote;
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
              body: SizedBox(
                  width: 340,
                  child: ReaderPageSelection(
                      text: text,
                      enabled: true,
                      onNote: (quote, offset) {
                        savedOffset = offset;
                        savedQuote = quote;
                      },
                      child: Text.rich(
                          readerTextSpanForLayout(text,
                              fontSize: 20, paragraphSpacing: 17),
                          key: const ValueKey('page-body'),
                          style:
                              const TextStyle(fontSize: 20, height: 1.6)))))));
      final paragraph = tester.renderObject<RenderParagraph>(find.descendant(
          of: find.byKey(const ValueKey('page-body')),
          matching: find.byType(RichText)));
      Offset point(int offset) {
        final box = paragraph
            .getBoxesForSelection(
                TextSelection(baseOffset: offset, extentOffset: offset + 1))
            .single;
        return paragraph
            .localToGlobal(Offset(box.left + .1, (box.top + box.bottom) / 2));
      }

      final gesture = await tester.startGesture(point(backward ? end : start),
          kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveTo(point(backward ? start : end));
      await gesture.up();
      await tester.pumpAndSettle();
      final listener =
          tester.widget<SelectionListener>(find.byType(SelectionListener));
      final range = listener.selectionNotifier.selection.range!;
      // Both zero-width paragraph indents disappear from SelectionListener's
      // flattened coordinates, but each occupies one UTF-16 unit in page text.
      if (!crossParagraph) {
        expect({range.startOffset, range.endOffset}, {start - 2, end - 2});
      }
      final area = tester.widget<SelectionArea>(find.byType(SelectionArea));
      final state =
          tester.state<SelectableRegionState>(find.byType(SelectableRegion));
      final menu = area.contextMenuBuilder!(
              tester.element(find.byType(SelectionArea)), state)
          as AdaptiveTextSelectionToolbar;
      menu.buttonItems!.singleWhere((item) => item.label == '记笔记').onPressed!();
      await tester.pumpAndSettle();
      if (crossParagraph) {
        expect(savedQuote, contains('\n\n'));
        final actual = pageSelectionAnchor(
            text, range.startOffset, range.endOffset,
            selectedQuote: savedQuote)!;
        expect(savedOffset, actual.offset);
        expect(savedQuote, actual.quote);
        expect(text.substring(savedOffset!).replaceAll('\ue000', ''),
            startsWith(savedQuote!));
      } else {
        expect(savedQuote, expectedQuote);
        expect(savedOffset, start);
      }
      final ranges = annotationHighlightRanges(
          text, [highlightNote(text, savedQuote!, savedOffset!)],
          bookId: 'book', chapterIndex: 1, mode: 'original');
      expect(ranges.single.start, savedOffset);
      expect(
          text
              .substring(ranges.single.start, ranges.single.end)
              .replaceAll('\ue000', ''),
          savedQuote);
      expect(tester.takeException(), isNull);
    });
  }
}
