import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/models/reading_annotation.dart';
import 'package:qingjuan/features/reader/annotation_highlights.dart';
import 'package:qingjuan/features/reader/annotation_selection.dart';
import 'package:qingjuan/features/reader/reader_pagination.dart';

void main() {
  const text = '\ue000😀first\n\n\ue000第二段needle';
  List<TextRange> resolve(List<ReadingAnnotation> notes,
          {String body = text}) =>
      annotationHighlightRanges(body, notes,
          bookId: 'book', chapterIndex: 1, mode: 'original');

  test(
      'UTF16 ranges include cross-paragraph selections without changing markers',
      () {
    const quote = '😀first\n\n第二段';
    final offset = preciseSelectedOffset(text, '\ufffc$quote');
    expect(offset, 1);
    expect(resolve([highlightNote(text, quote, offset!)]),
        [TextRange(start: 1, end: text.indexOf('needle'))]);
    final span =
        readerTextSpanForLayout(text, fontSize: 20, paragraphSpacing: 17);
    final marked = underlineAnnotationSpans(
        span, resolve([highlightNote(text, quote, offset)]));
    expect(marked.toPlainText(), span.toPlainText());
    expect(underlinedText(marked), quote);
  });

  test(
      'stale content, wrong mode/chapter, missing hashes and surrogate cuts are never drawn',
      () {
    final valid = highlightJson(text, '😀first', 1);
    for (final changes in [
      {'contentHash': null},
      {'contentHash': 'old'},
      {'contentChanged': true},
      {'bookId': 'other'},
      {'kind': 'bookmark'},
      {
        'position': {
          ...valid['position'] as Map<String, dynamic>,
          'chapterIndex': 2
        }
      },
      {
        'position': {
          ...valid['position'] as Map<String, dynamic>,
          'contentMode': 'translated'
        }
      },
      {
        'position': {
          ...valid['position'] as Map<String, dynamic>,
          'characterOffset': 2
        }
      },
      {'quote': 'different'},
    ]) {
      expect(
          resolve([
            ReadingAnnotation.fromJson({...valid, ...changes})
          ]),
          isEmpty);
    }
    expect(resolve([ReadingAnnotation.fromJson(valid)], body: '$text changed'),
        isEmpty);
  });

  test(
      'legacy repeated quotes and unresolved selections cannot draw at a guessed page start',
      () {
    const repeated = '\ue000needle and needle';
    final precise = highlightJson(repeated, 'needle', 1);
    expect(preciseSelectedOffset(repeated, 'needle'), isNull);
    for (final layout in [
      'selected-text-utf16-v1',
      unresolvedAnnotationLayout,
      null
    ]) {
      expect(
          annotationHighlightRanges(
              repeated,
              [
                ReadingAnnotation.fromJson({
                  ...precise,
                  'position': {
                    ...precise['position'] as Map<String, dynamic>,
                    'layoutKey': layout
                  }
                })
              ],
              bookId: 'book',
              chapterIndex: 1,
              mode: 'original'),
          isEmpty);
    }
    expect(
        annotationHighlightRanges(
            repeated, [ReadingAnnotation.fromJson(precise)],
            bookId: 'book', chapterIndex: 1, mode: 'original'),
        [const TextRange(start: 1, end: 7)]);
    final legacy = highlightJson(text, 'needle', text.indexOf('needle'));
    expect(
        resolve([
          ReadingAnnotation.fromJson({
            ...legacy,
            'position': {
              ...legacy['position'] as Map<String, dynamic>,
              'layoutKey': 'selected-text-utf16-v1'
            }
          })
        ]),
        [TextRange(start: text.indexOf('needle'), end: text.length)]);
  });

  test('overlapping notes merge and spans clip at exact page boundaries', () {
    const body = '\ue000abcdefghij';
    final ranges = annotationHighlightRanges(body,
        [highlightNote(body, 'bcdef', 2), highlightNote(body, 'efghi', 5)],
        bookId: 'book', chapterIndex: 1, mode: 'original');
    expect(ranges, [const TextRange(start: 2, end: 10)]);
    final page = readerTextSpanForLayout(body.substring(6), fontSize: 20);
    expect(underlinedText(underlineAnnotationSpans(page, ranges, offset: 6)),
        'fghi');
  });

  testWidgets(
      'underline preserves line boxes, paragraph gaps and UTF16 selection at 200% scale',
      (tester) async {
    const body = '\ue000😀正文需要足够长并换行，以核对划线前后的分页几何。\n\n\ue000第二段正文。';
    final plain = readerTextSpanForLayout(body,
        fontSize: 18,
        textScaler: const TextScaler.linear(2),
        paragraphSpacing: 15);
    final marked =
        underlineAnnotationSpans(plain, [const TextRange(start: 1, end: 21)]);
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SingleChildScrollView(
            child: Column(children: [
          for (final (index, span) in [plain, marked].indexed)
            SizedBox(
                width: 290,
                child: Text.rich(span,
                    key: ValueKey('geometry-$index'),
                    textScaler: const TextScaler.linear(2),
                    textAlign: TextAlign.justify,
                    style: const TextStyle(fontSize: 18, height: 1.65)))
        ]))));
    RenderParagraph paragraph(int index) => tester.renderObject(find.descendant(
        of: find.byKey(ValueKey('geometry-$index')),
        matching: find.byType(RichText)));
    final before = paragraph(0), after = paragraph(1);
    expect(after.size, before.size);
    expect(after.text.toPlainText(), before.text.toPlainText());
    for (var offset = 1; offset < body.length; offset++) {
      final selection =
          TextSelection(baseOffset: offset, extentOffset: offset + 1);
      expect(after.getBoxesForSelection(selection).map((b) => b.toRect()),
          before.getBoxesForSelection(selection).map((b) => b.toRect()));
    }
  });
}

Map<String, dynamic> highlightJson(String text, String quote, int offset) => {
      'id': 'saved',
      'bookId': 'book',
      'kind': 'note',
      'label': '笔记',
      'quote': quote,
      'note': '想法',
      'revision': 1,
      'createdAt': '',
      'updatedAt': '',
      'contentHash': sha256.convert(utf8.encode(text)).toString(),
      'position': {
        'chapterIndex': 1,
        'contentMode': 'original',
        'characterOffset': offset,
        'layoutKey': preciseAnnotationLayout
      }
    };

ReadingAnnotation highlightNote(String text, String quote, int offset) =>
    ReadingAnnotation.fromJson(highlightJson(text, quote, offset));

String underlinedText(InlineSpan span, [bool inherited = false]) {
  if (span is! TextSpan) return '';
  final marked =
      span.style?.decoration?.contains(TextDecoration.underline) ?? inherited;
  return '${marked ? span.text ?? '' : ''}${(span.children ?? []).map((part) => underlinedText(part, marked)).join()}';
}
