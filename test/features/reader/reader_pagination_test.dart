import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/features/reader/reader_pagination.dart';

void main() {
  test('reader paragraphs use one stable two-character first-line indent', () {
    final paragraphs = readerParagraphsForLayout(const <String>[
      '  第一段。  ',
      '\u3000\u3000第二段。',
      '   ',
    ], '');

    expect(paragraphs, const <String>[
      '$readerParagraphStartMarker第一段。',
      '$readerParagraphStartMarker第二段。',
    ]);
    expect(
      readerTextForPagination(paragraphs, ''),
      '$readerParagraphStartMarker第一段。\n\n'
      '$readerParagraphStartMarker第二段。',
    );
  });

  test('reader span replaces paragraph markers with a fixed layout indent', () {
    const fontSize = 20.0;
    const textScaler = TextScaler.linear(1.3);
    final span = readerTextSpanForLayout(
      '$readerParagraphStartMarker正文。',
      fontSize: fontSize,
      textScaler: textScaler,
    );
    final indent = span.children!.first as WidgetSpan;
    final indentBox = indent.child as SizedBox;

    expect(indentBox.width, textScaler.scale(fontSize) * 2);
    expect(indentBox.height, 0);
    expect(span.toPlainText(includePlaceholders: false), '正文。');
    expect(
      span.children!.whereType<TextSpan>().map((part) => part.text).join(),
      '正文。',
    );
  });

  testWidgets(
    'justified short and wrapped paragraphs keep fixed first-line geometry',
    (tester) async {
      const fontSize = 20.0;
      const shortBody = '正文。';
      const longBody = '正文需要足够长并自动换行，用于验证两端对齐时首行缩进不会漂移，换行续行仍回到正文左边界。';

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: <Widget>[
              SizedBox(
                width: 180,
                child: Text.rich(
                  key: const ValueKey('short-reader-paragraph'),
                  readerTextSpanForLayout(
                    '$readerParagraphStartMarker$shortBody',
                    fontSize: fontSize,
                  ),
                  textAlign: TextAlign.justify,
                  style: const TextStyle(fontSize: fontSize),
                ),
              ),
              SizedBox(
                width: 180,
                child: Text.rich(
                  key: const ValueKey('long-reader-paragraph'),
                  readerTextSpanForLayout(
                    '$readerParagraphStartMarker$longBody',
                    fontSize: fontSize,
                  ),
                  textAlign: TextAlign.justify,
                  style: const TextStyle(fontSize: fontSize),
                ),
              ),
            ],
          ),
        ),
      );

      RenderParagraph paragraphFor(ValueKey<String> key) =>
          tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.byKey(key),
              matching: find.byType(RichText),
            ),
          );

      final shortParagraph = paragraphFor(
        const ValueKey<String>('short-reader-paragraph'),
      );
      final longParagraph = paragraphFor(
        const ValueKey<String>('long-reader-paragraph'),
      );
      final shortFirst = shortParagraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 1, extentOffset: 2),
          )
          .single;
      final longFirst = longParagraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 1, extentOffset: 2),
          )
          .single;
      final continuation =
          List<int>.generate(longBody.length - 1, (index) => 2 + index)
              .map(
                (offset) => longParagraph.getBoxesForSelection(
                  TextSelection(baseOffset: offset, extentOffset: offset + 1),
                ),
              )
              .where((boxes) => boxes.isNotEmpty)
              .map((boxes) => boxes.first)
              .firstWhere((box) => box.top > longFirst.top + 1);

      expect(shortFirst.left, closeTo(fontSize * 2, 0.01));
      expect(longFirst.left, closeTo(shortFirst.left, 0.01));
      expect(continuation.left, closeTo(0, 0.01));
    },
  );

  test('pagination preserves the complete chapter text in order', () {
    final text = List<String>.generate(
      80,
      (index) => '第 ${index + 1} 段内容，应该完整保留。',
    ).join('\n');

    final pages = paginateReaderText(text, 120);

    expect(pages, hasLength(greaterThan(1)));
    expect(pages.join(), text);
    expect(pages.every((page) => page.isNotEmpty), isTrue);
  });

  test('two-em paragraph spacing is measured without losing page-end text', () {
    const fontSize = 20.0;
    const paragraphSpacing = fontSize * 2;
    const style = TextStyle(fontSize: fontSize, height: 1.8);
    final text = readerTextForPagination(
      List<String>.generate(12, (index) => '第${index + 1}段正文。'),
      '',
    );

    TextPainter layout(String value) {
      final span = readerTextSpanForLayout(
        value,
        fontSize: fontSize,
        paragraphSpacing: paragraphSpacing,
      );
      final painter = TextPainter(
        text: TextSpan(style: style, children: span.children),
        textDirection: TextDirection.ltr,
      );
      final markerCount = readerParagraphStartMarker.allMatches(value).length;
      painter.setPlaceholderDimensions(
        List<PlaceholderDimensions>.filled(
          markerCount,
          const PlaceholderDimensions(
            size: Size(fontSize * 2, 0),
            alignment: PlaceholderAlignment.bottom,
          ),
        ),
      );
      return painter..layout(maxWidth: 300);
    }

    final twoParagraphs = readerTextForPagination(const <String>[
      '第一段。',
      '第二段。',
    ], '');
    final metrics = layout(twoParagraphs).computeLineMetrics();
    expect(metrics, hasLength(3));
    expect(metrics[1].height, closeTo(paragraphSpacing, 0.01));

    final pages = paginateReaderTextForLayout(
      text,
      maxWidth: 300,
      pageHeight: 180,
      firstPageHeight: 120,
      style: style,
      paragraphSpacing: paragraphSpacing,
    );
    expect(pages.join(), text);
    expect(pages, hasLength(greaterThan(1)));
    for (var index = 0; index < pages.length; index++) {
      expect(
        layout(pages[index]).height,
        lessThanOrEqualTo((index == 0 ? 120 : 180) + 0.01),
      );
    }
  });

  test('a page continuation does not repeat the paragraph indent', () {
    final text = readerTextForPagination(<String>[
      List<String>.filled(150, '字').join(),
    ], '');

    final pages = paginateReaderText(text, 40);

    expect(pages, hasLength(greaterThan(1)));
    expect(pages.first.startsWith(readerParagraphStartMarker), isTrue);
    expect(
      pages
          .skip(1)
          .every((page) => !page.startsWith(readerParagraphStartMarker)),
      isTrue,
    );
  });

  test('page capacity responds to viewport size and font size', () {
    final compact = estimateReaderPageCharacters(const Size(360, 640), 24);
    final spacious = estimateReaderPageCharacters(const Size(800, 1200), 18);

    expect(compact, greaterThanOrEqualTo(80));
    expect(spacious, greaterThan(compact));
  });

  test('relaxed line spacing fits fewer characters per page', () {
    final compact = estimateReaderPageCharacters(
      const Size(390, 844),
      19,
      lineHeight: 1.62,
    );
    final relaxed = estimateReaderPageCharacters(
      const Size(390, 844),
      19,
      lineHeight: 2.04,
    );

    expect(relaxed, lessThan(compact));
  });

  test('layout pagination moves a wrapped page-end line to the next page', () {
    const fontSize = 20.0;
    const lineHeight = 1.5;
    const pageHeight = fontSize * lineHeight * 2;
    const style = TextStyle(
      fontSize: fontSize,
      height: lineHeight,
      letterSpacing: 0.12,
    );
    final text = readerTextForPagination(<String>[
      List<String>.filled(80, '正文').join(),
    ], '');

    final pages = paginateReaderTextForLayout(
      text,
      maxWidth: 120,
      pageHeight: pageHeight,
      style: style,
    );

    expect(pages, hasLength(greaterThan(1)));
    expect(pages.join(), text);
    for (final page in pages) {
      final span = readerTextSpanForLayout(page, fontSize: fontSize);
      final painter = TextPainter(
        text: TextSpan(style: style, children: span.children),
        textAlign: TextAlign.justify,
        textDirection: TextDirection.ltr,
      );
      final markerCount = readerParagraphStartMarker.allMatches(page).length;
      if (markerCount > 0) {
        painter.setPlaceholderDimensions(
          List<PlaceholderDimensions>.filled(
            markerCount,
            const PlaceholderDimensions(
              size: Size(fontSize * 2, 0),
              alignment: PlaceholderAlignment.bottom,
            ),
          ),
        );
      }
      painter.layout(maxWidth: 120);
      expect(painter.height, lessThanOrEqualTo(pageHeight + 0.01));
    }
  });
}
