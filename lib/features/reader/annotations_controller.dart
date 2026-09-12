import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/models/reading_annotation.dart';
import '../library/library_controller.dart';

/// A page owns this controller. Changing workspace invalidates it permanently.
class AnnotationsController extends ChangeNotifier {
  AnnotationsController(this.api, this.library, this.bookId)
      : _generation = library.contextGeneration {
    library.addListener(_workspaceChanged);
  }
  final ApiClient api;
  final LibraryController library;
  final String bookId;
  final int _generation;
  bool _disposed = false;
  bool invalidated = false;
  bool loading = false;
  bool saving = false;
  bool searching = false;
  bool hasMore = false;
  String? error;
  String? searchError;
  String kind = 'bookmark';
  List<ReadingAnnotation> items = const [];
  List<CachedTextHit> hits = const [];
  String? nextCursor;
  int scannedChapters = 0, uncachedChapters = 0, skippedChapters = 0;
  bool searchTruncated = false;
  bool hasSearched = false;
  int _request = 0, _searchRequest = 0, _offset = 0;
  String _query = '', _mode = 'original';
  int? _chapterIndex;
  bool get _current =>
      !_disposed && !invalidated && library.contextGeneration == _generation;

  void _workspaceChanged() {
    if (!_current && !_disposed && !invalidated) {
      invalidated = true;
      _request++;
      _searchRequest++;
      items = const [];
      hits = const [];
      error = searchError = nextCursor = null;
      loading = saving = searching = hasMore = false;
      notifyListeners();
    }
  }

  Future<void> load({String? filter, bool more = false}) async {
    if (!_current || saving || (more && (loading || !hasMore))) return;
    if (filter != null) kind = filter;
    final request = ++_request;
    final offset = more ? _offset : 0;
    loading = true;
    error = null;
    if (!more) {
      items = const [];
      _offset = 0;
      hasMore = false;
    }
    notifyListeners();
    try {
      final result =
          await api.fetchAnnotations(bookId, kind: kind, offset: offset);
      if (!_current || request != _request) return;
      final byId = {
        if (more)
          for (final item in items) item.id: item,
        for (final item in result) item.id: item
      };
      items = List.unmodifiable(byId.values);
      _offset = offset + result.length;
      hasMore = result.length == 50;
    } catch (exception) {
      if (_current && request == _request) error = '$exception';
    } finally {
      if (_current && request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> _mutate(Future<void> Function() action) async {
    if (!_current || saving) return false;
    saving = true;
    loading = false;
    error = null;
    _request++;
    notifyListeners();
    var succeeded = false;
    try {
      await action();
      succeeded = _current;
    } catch (exception) {
      if (_current) error = '$exception';
    } finally {
      if (_current) {
        saving = false;
        notifyListeners();
      }
    }
    if (succeeded) await load();
    return succeeded && _current;
  }

  Future<bool> create(
          {required String clientKey,
          required String kind,
          required String label,
          required String quote,
          required String note,
          required AnnotationPosition position}) =>
      _mutate(() async {
        await api.createAnnotation(bookId,
            clientKey: clientKey,
            kind: kind,
            label: label,
            quote: quote,
            note: note,
            position: position);
      });

  Future<bool> update(ReadingAnnotation item,
          {required String label, required String note}) =>
      _mutate(() async {
        await api.updateAnnotation(bookId, item.id,
            expectedRevision: item.revision,
            changes: {'label': label, 'note': note});
      });

  Future<bool> delete(ReadingAnnotation item) => _mutate(() =>
      api.deleteAnnotation(bookId, item.id, expectedRevision: item.revision));

  Future<void> search(
      {String? query,
      String mode = 'original',
      int? chapterIndex,
      bool more = false}) async {
    if (!_current || (more && (searching || nextCursor == null))) return;
    if (!more) {
      _query = (query ?? '').trim();
      _mode = mode;
      _chapterIndex = chapterIndex;
      hits = const [];
      nextCursor = null;
      scannedChapters = uncachedChapters = skippedChapters = 0;
      searchTruncated = false;
      hasSearched = true;
    }
    final request = ++_searchRequest;
    searchError = null;
    if (_query.isEmpty || _query.length > 120) {
      searchError = '请输入 1 到 120 个字符的关键词';
      searching = false;
      notifyListeners();
      return;
    }
    searching = true;
    notifyListeners();
    try {
      final result = await api.searchCachedText(bookId,
          query: _query,
          mode: _mode,
          chapterIndex: _chapterIndex,
          cursor: more ? nextCursor : null);
      if (!_current || request != _searchRequest) return;
      hits = List.unmodifiable([...hits, ...result.results]);
      nextCursor = result.nextCursor;
      scannedChapters += result.scannedChapters;
      uncachedChapters += result.uncachedChapters;
      skippedChapters += result.skippedChapters;
      searchTruncated = searchTruncated || result.truncated;
    } catch (exception) {
      if (_current && request == _searchRequest) searchError = '$exception';
    } finally {
      if (_current && request == _searchRequest) {
        searching = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    library.removeListener(_workspaceChanged);
    super.dispose();
  }
}
