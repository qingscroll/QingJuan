import 'dart:math' as math;

import 'package:flutter/widgets.dart';

// 段首标记只用于在分页字符串中保留“这里开始一个新段落”的信息。
// 渲染前必须把它替换为固定宽度 WidgetSpan，不能把不可见字符直接交给
// TextAlign.justify；Android 字体整形可能拉伸这类字符并造成段首漂移。
const String readerParagraphStartMarker = '\uE000';
const String _legacyReaderFirstLineIndent = '\u3164\u3164';

List<String> readerParagraphsForLayout(
  List<String> paragraphs,
  String fallback,
) {
  final source = paragraphs.isNotEmpty
      ? paragraphs
      : fallback.replaceAll('\r\n', '\n').split(RegExp(r'\n+'));
  return source
      .map(_normalizeReaderParagraph)
      .whereType<String>()
      .toList(growable: false);
}

String? _normalizeReaderParagraph(String paragraph) {
  var body = paragraph.trim();
  while (body.startsWith(readerParagraphStartMarker)) {
    body = body.substring(readerParagraphStartMarker.length).trimLeft();
  }
  while (body.startsWith(_legacyReaderFirstLineIndent)) {
    body = body.substring(_legacyReaderFirstLineIndent.length).trimLeft();
  }
  if (body.isEmpty) return null;
  return '$readerParagraphStartMarker$body';
}

TextSpan readerTextSpanForLayout(
  String text, {
  required double fontSize,
  TextScaler textScaler = TextScaler.noScaling,
  double? paragraphSpacing,
}) {
  final children = <InlineSpan>[];
  void appendText(String value) {
    if (paragraphSpacing == null) {
      children.add(TextSpan(text: value));
      return;
    }
    final paragraphs = value.split('\n\n');
    for (var index = 0; index < paragraphs.length; index++) {
      if (paragraphs[index].isNotEmpty) {
        children.add(TextSpan(text: paragraphs[index]));
      }
      if (index < paragraphs.length - 1) {
        children.add(const TextSpan(text: '\n'));
        // A blank line carries the paragraph gap independently of body leading.
        // Pagination uses this identical span so a font-size change cannot clip
        // the final line or drop text at a page boundary.
        children.add(TextSpan(
          text: '\n',
          style: TextStyle(height: paragraphSpacing / fontSize),
        ));
      }
    }
  }

  var start = 0;
  while (start < text.length) {
    final markerIndex = text.indexOf(readerParagraphStartMarker, start);
    if (markerIndex < 0) {
      appendText(text.substring(start));
      break;
    }
    if (markerIndex > start) {
      appendText(text.substring(start, markerIndex));
    }
    children.add(
      WidgetSpan(
        child: SizedBox(
          width: textScaler.scale(fontSize) * 2,
          height: 0,
        ),
      ),
    );
    start = markerIndex + readerParagraphStartMarker.length;
  }
  if (children.isEmpty && text.isNotEmpty) {
    children.add(TextSpan(text: text));
  }
  return TextSpan(children: children);
}

String readerTextForPagination(
  List<String> paragraphs,
  String fallback,
) =>
    readerParagraphsForLayout(paragraphs, fallback).join('\n\n');

int estimateReaderPageCharacters(
  Size viewport,
  double fontSize, {
  double lineHeight = 1.85,
}) {
  final usableWidth = math.max(120.0, viewport.width - 48);
  final usableHeight = math.max(180.0, viewport.height - 170);
  final charactersPerLine = math.max(10, (usableWidth / fontSize).floor());
  final linesPerPage = math.max(
    6,
    (usableHeight / (fontSize * math.max(1.2, lineHeight))).floor(),
  );
  return math.max(80, (charactersPerLine * linesPerPage * 0.9).floor());
}

List<String> paginateReaderText(String text, int targetCharacters) {
  if (text.isEmpty) return const <String>[''];
  final target = math.max(40, targetCharacters);
  final pages = <String>[];
  var start = 0;
  while (start < text.length) {
    var end = math.min(text.length, start + target);
    if (end < text.length) {
      final searchStart = math.min(end, start + (target * 0.72).floor());
      for (var index = end - 1; index >= searchStart; index--) {
        if (_isBreakCharacter(text.codeUnitAt(index))) {
          end = index + 1;
          break;
        }
      }
    }
    pages.add(text.substring(start, end));
    start = end;
  }
  return pages;
}

List<String> paginateReaderTextForLayout(
  String text, {
  required double maxWidth,
  required double pageHeight,
  double? firstPageHeight,
  required TextStyle style,
  double? paragraphSpacing,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
  Locale? locale,
}) {
  if (text.isEmpty) return const <String>[''];
  assert(maxWidth > 0);
  assert(pageHeight > 0);

  final boundaries = <int>[0];
  var offset = 0;
  for (final rune in text.runes) {
    offset += rune > 0xFFFF ? 2 : 1;
    boundaries.add(offset);
  }

  final pages = <String>[];
  var start = 0;
  while (start < boundaries.length - 1) {
    final availableHeight =
        pages.isEmpty ? firstPageHeight ?? pageHeight : pageHeight;
    if (availableHeight <= 0) {
      pages.add('');
      continue;
    }

    final estimatedCharacters = math.max(
      1,
      ((maxWidth / math.max(1, textScaler.scale(style.fontSize ?? 14))) *
              (availableHeight /
                  math.max(
                    1,
                    textScaler.scale(style.fontSize ?? 14) *
                        (style.height ?? 1.2),
                  )) *
              1.5)
          .ceil(),
    );
    var fittingEnd = start;
    var rejectedEnd = math.min(
      boundaries.length - 1,
      start + estimatedCharacters,
    );

    bool fits(int end) => _readerTextFitsLayout(
          text.substring(boundaries[start], boundaries[end]),
          maxWidth: maxWidth,
          maxHeight: availableHeight,
          style: style,
          paragraphSpacing: paragraphSpacing,
          textScaler: textScaler,
          textDirection: textDirection,
          locale: locale,
        );

    if (fits(rejectedEnd)) {
      fittingEnd = rejectedEnd;
      while (fittingEnd < boundaries.length - 1) {
        rejectedEnd = math.min(
          boundaries.length - 1,
          start + (fittingEnd - start) * 2,
        );
        if (!fits(rejectedEnd)) break;
        fittingEnd = rejectedEnd;
      }
    }

    if (fittingEnd < boundaries.length - 1) {
      while (rejectedEnd - fittingEnd > 1) {
        final candidate = fittingEnd + (rejectedEnd - fittingEnd) ~/ 2;
        if (fits(candidate)) {
          fittingEnd = candidate;
        } else {
          rejectedEnd = candidate;
        }
      }
    }

    // Even an unusually short viewport must still make progress. Normal reader
    // layouts always fit at least one glyph; this fallback only protects custom
    // window sizes and extreme accessibility scaling from an infinite loop.
    if (fittingEnd == start) fittingEnd = start + 1;

    var pageEnd = fittingEnd;
    if (pageEnd < boundaries.length - 1) {
      final searchStart = start + ((pageEnd - start) * 0.72).floor();
      for (var index = pageEnd; index > searchStart; index--) {
        if (_isBreakCharacter(text.codeUnitAt(boundaries[index] - 1))) {
          pageEnd = index;
          break;
        }
      }
    }

    pages.add(text.substring(boundaries[start], boundaries[pageEnd]));
    start = pageEnd;
  }
  return pages;
}

bool _readerTextFitsLayout(
  String text, {
  required double maxWidth,
  required double maxHeight,
  required TextStyle style,
  double? paragraphSpacing,
  required TextScaler textScaler,
  required TextDirection textDirection,
  Locale? locale,
}) {
  final span = readerTextSpanForLayout(
    text,
    fontSize: style.fontSize ?? 14,
    textScaler: textScaler,
    paragraphSpacing: paragraphSpacing,
  );
  final painter = TextPainter(
    text: TextSpan(style: style, children: span.children),
    textAlign: TextAlign.justify,
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
  );
  final markerCount = readerParagraphStartMarker.allMatches(text).length;
  if (markerCount > 0) {
    painter.setPlaceholderDimensions(
      List<PlaceholderDimensions>.filled(
        markerCount,
        PlaceholderDimensions(
          size: Size(textScaler.scale(style.fontSize ?? 14) * 2, 0),
          alignment: PlaceholderAlignment.bottom,
        ),
      ),
    );
  }
  painter.layout(maxWidth: maxWidth);
  final fits = painter.height <= maxHeight;
  painter.dispose();
  return fits;
}

bool _isBreakCharacter(int codeUnit) =>
    codeUnit == 0x0A ||
    codeUnit == 0x3002 ||
    codeUnit == 0xFF01 ||
    codeUnit == 0xFF1F ||
    codeUnit == 0xFF1B ||
    codeUnit == 0xFF0C;
