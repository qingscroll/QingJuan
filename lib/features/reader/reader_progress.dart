import 'dart:math' as math;

import '../../core/models/book.dart';

export 'reader_progress_writer.dart';

int readerPageForCharacter(List<String> pages, int offset) {
  var end = 0;
  for (var index = 0; index < pages.length; index++) {
    end += pages[index].length;
    if (offset < end) return index;
  }
  return math.max(0, pages.length - 1);
}

int readerPageCharacterOffset(List<String> pages, int pageIndex) => pages
    .take(pageIndex.clamp(0, pages.length))
    .fold(0, (offset, page) => offset + page.length);

/// Stable across processes; includes page boundaries and therefore reflow.
String readerLayoutKey(List<String> pages, {bool images = false}) {
  var hash = 0x811c9dc5;
  for (final page in pages) {
    for (final unit in page.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    hash = ((hash ^ 0xffff) * 0x01000193) & 0xffffffff;
  }
  return '${images ? 'images' : 'text'}-v1-${pages.length}-${hash.toRadixString(16)}';
}

int readerRestoredPage(ReadingProgress progress, List<String> pages,
    {required String layoutKey, required String contentMode}) {
  final lastPage = math.max(0, pages.length - 1);
  final sameContent =
      progress.contentMode == null || progress.contentMode == contentMode;
  if (sameContent &&
      progress.pageIndex != null &&
      progress.layoutKey == layoutKey) {
    return progress.pageIndex!.clamp(0, lastPage);
  }
  if (sameContent && progress.anchorType == 'image') {
    return progress.anchorIndex.clamp(0, lastPage);
  }
  if (sameContent && progress.characterOffset != null) {
    return readerPageForCharacter(pages, progress.characterOffset!);
  }
  return (progress.scrollRatio.clamp(0.0, 1.0) * lastPage).round();
}
