import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/book.dart';
import '../../core/state/load_state.dart';
import '../library/library_controller.dart';

class BookPreviewController extends ChangeNotifier {
  BookPreviewController(this.library,
      {required JsonMap payload,
      Book? existingBook,
      bool Function()? isCurrentContext,
      bool Function()? supportsReading})
      : payload = Map.unmodifiable(payload),
        _generation = library.contextGeneration,
        _apiCurrent = library.api.captureContextGuard(),
        _contextCurrent = isCurrentContext ?? (() => true),
        _supportsReading = supportsReading ?? (() => true),
        _knownBook = existingBook {
    library.addListener(_libraryChanged);
    _findExistingBook();
  }

  final LibraryController library;
  ApiClient get api => library.api;
  final JsonMap payload;
  final int _generation;
  final bool Function() _apiCurrent;
  final bool Function() _contextCurrent;
  final bool Function() _supportsReading;
  Book? _knownBook;
  bool _disposed = false;
  bool invalidated = false;
  int _previewOperation = 0;
  int _chapterOperation = 0;
  BookPreview? preview;
  ChapterContent? chapter;
  int? chapterIndex;
  bool loading = false;
  bool chapterLoading = false;
  bool importing = false;
  String? error;
  String? chapterError;
  String? importError;
  bool added = false;

  bool get isCurrent =>
      !_disposed &&
      !invalidated &&
      _generation == library.contextGeneration &&
      _apiCurrent() &&
      _contextCurrent();

  Book? get existingBook => isCurrent ? _knownBook : null;
  bool get canRead => isCurrent && _supportsReading();

  void checkContext() {
    if (_disposed || invalidated || isCurrent) return;
    invalidated = true;
    _previewOperation++;
    _chapterOperation++;
    preview = null;
    chapter = null;
    _knownBook = null;
    error = chapterError = importError = null;
    loading = chapterLoading = importing = false;
    notifyListeners();
  }

  void _libraryChanged() {
    checkContext();
    if (!isCurrent) return;
    _findExistingBook();
    notifyListeners();
  }

  void _findExistingBook() {
    final source = _canonicalSource(payload['sourceUrl'] as String? ?? '');
    if (source.isEmpty) {
      _knownBook = null;
      return;
    }
    for (final book in library.books) {
      if (_canonicalSource(book.sourceUrl) == source) {
        _knownBook = book;
        return;
      }
    }
    if (_knownBook != null &&
        (_canonicalSource(_knownBook!.sourceUrl) != source ||
            library.state == LoadState.ready ||
            library.state == LoadState.empty)) {
      _knownBook = null;
    }
  }

  Future<void> load() async {
    if (!isCurrent || loading) return;
    final operation = ++_previewOperation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final value = await api.previewBook(payload);
      if (!isCurrent || operation != _previewOperation) return;
      preview = value;
    } catch (exception) {
      if (isCurrent && operation == _previewOperation) {
        error = '无法加载作品预览：$exception';
      }
    } finally {
      if (isCurrent && operation == _previewOperation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadChapter(int index) async {
    if (!canRead || chapterLoading) return;
    final directory = preview?.chapters ?? const [];
    if (!directory.any((entry) => entry.index == index)) {
      return;
    }
    final operation = ++_chapterOperation;
    chapterIndex = index;
    chapter = null;
    chapterLoading = true;
    chapterError = null;
    notifyListeners();
    try {
      final expected = directory.firstWhere((entry) => entry.index == index);
      final value = await api.previewChapter(payload, index,
          expectedChapterUrl: expected.url);
      if (!isCurrent || operation != _chapterOperation) return;
      if (value.chapter.index != index) {
        throw const ApiException('书源目录已变化，请返回预览页重新加载目录');
      }
      chapter = value;
    } catch (exception) {
      if (isCurrent && operation == _chapterOperation) {
        chapterError = '此章暂时无法试读：$exception';
      }
    } finally {
      if (isCurrent && operation == _chapterOperation) {
        chapterLoading = false;
        notifyListeners();
      }
    }
  }

  Future<Book?> addToLibrary() async {
    if (!isCurrent || importing) return null;
    _findExistingBook();
    if (_knownBook != null) return _knownBook;
    importing = true;
    importError = null;
    notifyListeners();
    try {
      final book = await library.importFromSearch(payload);
      if (!isCurrent) return null;
      _knownBook = book;
      added = true;
      return book;
    } catch (exception) {
      if (isCurrent) importError = '加入书架失败：$exception';
      return null;
    } finally {
      if (isCurrent) {
        importing = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    library.removeListener(_libraryChanged);
    chapter = null;
    super.dispose();
  }
}

String _canonicalSource(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return value.trim();
  return uri.replace(fragment: '').toString().replaceFirst(RegExp(r'/+$'), '');
}
