import '../../core/models/book.dart';
import 'annotation_highlights.dart';

/// Dart string indices and the reader's persisted character offsets use UTF-16.
ReadingProgress selectedTextPosition(
        {required int chapterIndex,
        required String mode,
        required int characterOffset,
        bool precise = true}) =>
    ReadingProgress(
        chapterIndex: chapterIndex,
        scrollRatio: 0,
        contentMode: mode,
        anchorType: 'top',
        characterOffset: characterOffset,
        layoutKey:
            precise ? preciseAnnotationLayout : unresolvedAnnotationLayout);

String annotationQuote(String text) =>
    text.replaceAll('\ue000', '').replaceAll('\ufffc', '').trim();

String boundedAnnotationQuote(String text) =>
    String.fromCharCodes(annotationQuote(text).runes.take(4000));

/// SelectionArea exposes text, not a range. Repeated text stays at the page
/// anchor instead of guessing which occurrence the user selected.
int uniqueSelectedOffset(String pageText, String quote) {
  final comparable = pageText.replaceAll('\ue000', '\ufffc');
  final first = comparable.indexOf(quote);
  return first >= 0 && comparable.indexOf(quote, first + 1) < 0 ? first : 0;
}

/// SelectionArea reports visible text without a reliable range. Map a unique
/// visible selection back through the existing one-unit paragraph placeholders.
int? preciseSelectedOffset(String pageText, String selection) {
  final quote = annotationQuote(selection);
  if (quote.isEmpty) return null;
  final units = <int>[];
  final sourceOffsets = <int>[];
  for (var index = 0; index < pageText.length; index++) {
    final unit = pageText.codeUnitAt(index);
    if (unit == 0xe000 || unit == 0xfffc) continue;
    units.add(unit);
    sourceOffsets.add(index);
  }
  final comparable = String.fromCharCodes(units);
  final first = comparable.indexOf(quote);
  if (first < 0 || comparable.indexOf(quote, first + 1) >= 0) return null;
  return sourceOffsets[first];
}
