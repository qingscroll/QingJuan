import 'package:flutter/widgets.dart';

import '../../core/models/book.dart';
import 'reader_pagination.dart';
import 'reader_progress.dart';

/// Chapter-local logical pages for a continuous text viewport. The cache owns
/// only the current layout; scrolling never runs the chapter paginator again.
class ReaderContinuousLayout {
  ReaderContinuousLayout(
      {required this.viewport,
      required this.style,
      required this.paragraphSpacing,
      required this.textScaler,
      required this.textDirection,
      this.locale});

  final Size viewport;
  final TextStyle style;
  final double paragraphSpacing;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final Locale? locale;
  final Map<ChapterContent, List<String>> _pages = Map.identity();
  final Map<ChapterContent, String> _keys = Map.identity();

  bool matches(ReaderContinuousLayout other) =>
      viewport == other.viewport &&
      style == other.style &&
      paragraphSpacing == other.paragraphSpacing &&
      textScaler == other.textScaler &&
      textDirection == other.textDirection &&
      locale == other.locale;

  List<String> pages(ChapterContent content, List<String> paragraphs) =>
      _pages.putIfAbsent(
          content,
          () => paginateReaderTextForLayout(paragraphs.join('\n\n'),
              maxWidth: viewport.width,
              pageHeight: viewport.height,
              style: style,
              paragraphSpacing: paragraphSpacing,
              textScaler: textScaler,
              textDirection: textDirection,
              locale: locale));

  String key(ChapterContent content, List<String> paragraphs) =>
      _keys.putIfAbsent(
          content,
          () => 'continuous-${readerLayoutKey([
                    '${viewport.width}:${viewport.height}:$paragraphSpacing:'
                        '${style.fontFamily}:${style.fontFamilyFallback?.join(',')}:'
                        '${style.fontSize}:${style.fontWeight?.value}:${style.fontStyle?.index}:'
                        '${style.letterSpacing}:${style.wordSpacing}:${style.height}:'
                        '${style.leadingDistribution?.index}:${style.textBaseline?.index}:'
                        '${style.fontFeatures?.map((f) => '${f.feature}=${f.value}').join(',')}:'
                        '${style.fontVariations?.map((f) => '${f.axis}=${f.value}').join(',')}:'
                        '${textScaler.scale(style.fontSize ?? 14)}:${textDirection.index}:'
                        '${locale?.toLanguageTag()}',
                    ...pages(content, paragraphs),
                  ])}');

  void evict(ChapterContent content) {
    _pages.remove(content);
    _keys.remove(content);
  }
}
