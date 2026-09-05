import 'dart:async';
import 'dart:math' as math;

import '../../core/api/api_client.dart';
import '../../core/models/book.dart';

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

/// Serializes writes so an older request cannot overtake the newest position.
/// Failed writes remain pending and are retried while the reader is active.
class ReaderProgressWriter {
  ReaderProgressWriter(this.api, this.bookId,
      {this.retryDelay = const Duration(seconds: 5)})
      : _isCurrent = api.captureContextGuard();

  final ApiClient api;
  final String bookId;
  final Duration retryDelay;
  final bool Function() _isCurrent;
  ReadingProgress? _pending;
  Future<void>? _active;
  Timer? _retry;
  bool _disposed = false;

  Future<void> save(ReadingProgress position) {
    if (_disposed || !_isCurrent()) return Future.value();
    _pending = position;
    return flush();
  }

  Future<void> flush() {
    _retry?.cancel();
    _retry = null;
    if (_active != null) return _active!;
    if (_pending == null) return Future.value();
    final completer = Completer<void>();
    _active = completer.future;
    unawaited(_drain(completer));
    return completer.future;
  }

  Future<void> _drain(Completer<void> completer) async {
    try {
      while (_pending != null && _isCurrent()) {
        final current = _pending!;
        _pending = null;
        try {
          await api.saveProgress(
              bookId, current.chapterIndex, current.scrollRatio,
              anchorType: current.anchorType,
              anchorIndex: current.anchorIndex,
              anchorOffsetRatio: current.anchorOffsetRatio,
              pageIndex: current.pageIndex,
              pageCount: current.pageCount,
              layoutKey: current.layoutKey,
              contentMode: current.contentMode,
              characterOffset: current.characterOffset);
        } catch (_) {
          _pending ??= current;
          if (!_disposed && _isCurrent()) {
            _retry = Timer(retryDelay, () => unawaited(flush()));
          }
          return;
        }
      }
      if (!_isCurrent()) _pending = null;
    } finally {
      // Release ownership in the same continuation that finishes draining.
      // A later whenComplete callback leaves a gap where save() can join an
      // already-finished drain and strand the newly queued position.
      _active = null;
      completer.complete();
    }
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
  }
}
