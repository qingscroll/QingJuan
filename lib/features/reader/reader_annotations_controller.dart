import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

import '../../core/models/reading_annotation.dart';
import '../library/library_controller.dart';
import 'annotation_highlights.dart';

/// Reader-owned, chapter-scoped data. No timers, no extra chapter downloads.
class ReaderAnnotationsController extends ChangeNotifier {
  ReaderAnnotationsController(this.library, this.bookId)
      : _generation = library.contextGeneration {
    library.addListener(_contextChanged);
  }
  final LibraryController library;
  final String bookId;
  final int _generation;
  final Map<String, List<TextRange>> _ranges = {};
  final Set<String> _requested = {};
  final Map<String, String> _fingerprints = {};
  final Map<String, int> _requests = {};
  int _revision = 0;
  bool _disposed = false;
  bool get _current => !_disposed && library.contextGeneration == _generation;
  List<TextRange> ranges(int chapterIndex, String mode) =>
      _ranges['$mode:$chapterIndex'] ?? const [];

  void _contextChanged() {
    if (!_current && !_disposed) clear();
  }

  void clear() {
    _revision++;
    _requested.clear();
    _ranges.clear();
    _fingerprints.clear();
    _requests.clear();
    if (!_disposed) notifyListeners();
  }

  Future<void> load(int chapterIndex, String mode, String text) async {
    final key = '$mode:$chapterIndex';
    if (!_current) return;
    final fingerprint = sha256.convert(utf8.encode(text)).toString();
    if (_fingerprints[key] != fingerprint) {
      _fingerprints[key] = fingerprint;
      _requested.remove(key);
      if (_ranges.remove(key) != null) notifyListeners();
    }
    if (!_requested.add(key)) return;
    final revision = _revision;
    final request = (_requests[key] ?? 0) + 1;
    _requests[key] = request;
    bool current() =>
        _current && revision == _revision && request == _requests[key];
    final notes = <String, ReadingAnnotation>{};
    var offset = 0;
    try {
      while (current()) {
        final page = await library.api.fetchAnnotations(bookId,
            chapterIndex: chapterIndex,
            mode: mode,
            kind: 'note',
            offset: offset);
        if (!current()) return;
        var added = 0;
        for (final note in page) {
          if (!notes.containsKey(note.id)) added++;
          notes[note.id] = note;
        }
        offset += page.length;
        if (page.length < 50 || added == 0) break;
      }
      if (!current()) return;
      _ranges[key] = annotationHighlightRanges(text, notes.values,
          bookId: bookId, chapterIndex: chapterIndex, mode: mode);
      notifyListeners();
    } catch (_) {
      // Missing/offline annotations must not block reading or retain stale lines.
      if (current()) {
        _ranges.remove(key);
        _requested.remove(key);
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    library.removeListener(_contextChanged);
    super.dispose();
  }
}
