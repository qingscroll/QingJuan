import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

import '../../core/models/reading_annotation.dart';

const preciseAnnotationLayout = 'selected-text-utf16-v2';
const unresolvedAnnotationLayout = 'selected-text-unresolved-v2';

/// The hash includes paragraph markers and two newlines, just like cached_text.py.
List<TextRange> annotationHighlightRanges(
    String text, Iterable<ReadingAnnotation> notes,
    {required String bookId, required int chapterIndex, required String mode}) {
  final hash = sha256.convert(utf8.encode(text)).toString();
  final ranges = <TextRange>[];
  final comparable = text.replaceAll('\ue000', '').replaceAll('\ufffc', '');
  for (final note in notes) {
    final position = note.position.progress;
    final offset = position.characterOffset;
    final quote = note.quote;
    if (note.kind != 'note' ||
        note.bookId != bookId ||
        position.chapterIndex != chapterIndex ||
        (position.contentMode ?? 'original') != mode ||
        note.contentChanged ||
        note.contentHash != hash ||
        quote.isEmpty ||
        offset == null ||
        offset < 0 ||
        offset >= text.length ||
        position.layoutKey == unresolvedAnnotationLayout) {
      continue;
    }
    // Older paged selections could store a page start for repeated text. Only
    // unambiguous legacy quotes are safe to restore; never search for a new anchor.
    if (position.layoutKey != preciseAnnotationLayout) {
      final first = comparable.indexOf(quote);
      if (first < 0 || comparable.indexOf(quote, first + 1) >= 0) continue;
    }
    final range = matchAnnotationQuoteAt(text, offset, quote);
    if (range != null) ranges.add(range);
  }
  ranges.sort((a, b) => a.start.compareTo(b.start));
  final merged = <TextRange>[];
  for (final range in ranges) {
    if (merged.isNotEmpty && range.start <= merged.last.end) {
      final previous = merged.removeLast();
      merged.add(TextRange(
          start: previous.start,
          end: range.end > previous.end ? range.end : previous.end));
    } else {
      merged.add(range);
    }
  }
  return List.unmodifiable(merged);
}

/// Exact anchored match, without searching elsewhere or splitting a surrogate.
TextRange? matchAnnotationQuoteAt(String text, int offset, String quote) {
  if (offset < 0 || offset >= text.length || quote.isEmpty) return null;
  var start = offset;
  while (start < text.length &&
      (text[start] == '\ue000' ||
          text[start] == '\ufffc' ||
          text[start].trim().isEmpty)) {
    start++;
  }
  var end = start, matched = 0;
  while (end < text.length && matched < quote.length) {
    final unit = text[end++];
    if (unit == '\ue000' || unit == '\ufffc') continue;
    if (unit != quote[matched]) break;
    matched++;
  }
  return matched == quote.length &&
          _boundary(text, start) &&
          _boundary(text, end)
      ? TextRange(start: start, end: end)
      : null;
}

bool _boundary(String text, int offset) =>
    offset == 0 ||
    offset == text.length ||
    !(text.codeUnitAt(offset - 1) >= 0xd800 &&
        text.codeUnitAt(offset - 1) <= 0xdbff &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff);

/// Decorate the existing layout spans. WidgetSpan placeholders, blank-line
/// heights, text, and UTF-16 offsets stay exactly the same as pagination input.
TextSpan underlineAnnotationSpans(TextSpan span, List<TextRange> ranges,
    {int offset = 0}) {
  if (ranges.isEmpty) return span;
  var cursor = offset;
  InlineSpan visit(InlineSpan item) {
    if (item is! TextSpan) {
      cursor += item.toPlainText().length;
      return item;
    }
    final children = <InlineSpan>[];
    final text = item.text ?? '';
    final start = cursor;
    final cuts = <int>{0, text.length};
    for (final range in ranges) {
      if (range.start > start && range.start < start + text.length) {
        cuts.add(range.start - start);
      }
      if (range.end > start && range.end < start + text.length) {
        cuts.add(range.end - start);
      }
    }
    final boundaries = cuts.toList()..sort();
    for (var index = 1; index < boundaries.length; index++) {
      final a = boundaries[index - 1], b = boundaries[index];
      final marked = ranges
          .any((range) => range.start < start + b && range.end > start + a);
      children.add(TextSpan(
          text: text.substring(a, b),
          style: marked
              ? const TextStyle(
                  decoration: TextDecoration.underline,
                  decorationStyle: TextDecorationStyle.solid)
              : null));
    }
    cursor += text.length;
    children.addAll((item.children ?? const <InlineSpan>[]).map(visit));
    return TextSpan(style: item.style, children: children);
  }

  return visit(span) as TextSpan;
}
