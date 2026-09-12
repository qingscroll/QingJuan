import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/book.dart';
import '../../core/models/book_metadata.dart';
import '../../core/models/link_job.dart';
import '../../core/state/load_state.dart';
import 'link_history_controller.dart';
import 'book_updates_controller.dart';

enum LibrarySort {
  recent('最近阅读'),
  title('按书名'),
  author('按作者'),
  server('书库顺序');

  const LibrarySort(this.label);
  final String label;
}

class LibraryController extends ChangeNotifier {
  LibraryController(this.api)
      : imports = LinkHistoryController(api),
        serials = BookUpdatesController(api) {
    imports.onBooksChanged = () => load(silent: true);
    imports.addListener(notifyListeners);
    serials.onBooksChanged = () => load(silent: true);
    serials.addListener(notifyListeners);
  }

  final LinkHistoryController imports;
  final BookUpdatesController serials;

  final ApiClient api;
  LoadState state = LoadState.idle;
  List<Book> books = const [];
  String query = '';
  String? error;
  LinkJob? linkJob;
  JsonMap? linkJobPayload;
  String? linkJobConnectionError;
  Timer? _linkJobPoller;
  bool _linkJobLoadInProgress = false;
  bool _linkJobStartInProgress = false;
  String? _linkJobOperationKey;
  String? _linkJobMode;
  bool _disposed = false;
  int _contextGeneration = 0;
  int _loadRequest = 0;
  String? groupFilter;
  String? tagFilter;
  String? readingStateFilter;
  bool pinnedOnly = false;
  bool onlyNewUpdates = false;
  LibrarySort sort = LibrarySort.recent;
  double? importProgress;

  int get contextGeneration => _contextGeneration;
  List<String> get groups =>
      (books.map((b) => b.groupName).whereType<String>().toSet().toList()
        ..sort());
  List<String> get tags =>
      (books.expand((b) => b.tags).toSet().toList()..sort());
  bool get hasOrganizationFilters =>
      groupFilter != null ||
      tagFilter != null ||
      readingStateFilter != null ||
      pinnedOnly ||
      onlyNewUpdates;

  void setOnlyNewUpdates(bool value) {
    onlyNewUpdates = value;
    notifyListeners();
  }

  void setOrganization(
      {String? group,
      String? tag,
      String? readingState,
      bool pinned = false,
      bool newUpdates = false}) {
    groupFilter = group;
    tagFilter = tag;
    readingStateFilter = readingState;
    pinnedOnly = pinned;
    onlyNewUpdates = newUpdates;
    notifyListeners();
  }

  void setSort(LibrarySort value) {
    sort = value;
    notifyListeners();
  }

  bool get hasActiveLinkJob => linkJob?.isActive ?? false;

  void resetForBackendSwitch() {
    imports.reset();
    serials.reset();
    _contextGeneration += 1;
    _loadRequest += 1;
    _linkJobPoller?.cancel();
    _linkJobPoller = null;
    _linkJobLoadInProgress = false;
    _linkJobStartInProgress = false;
    _linkJobOperationKey = null;
    _linkJobMode = null;
    importProgress = null;
    books = const [];
    query = '';
    groupFilter = tagFilter = readingStateFilter = null;
    pinnedOnly = false;
    onlyNewUpdates = false;
    sort = LibrarySort.recent;
    error = null;
    linkJob = null;
    linkJobPayload = null;
    linkJobConnectionError = null;
    state = LoadState.idle;
    notifyListeners();
  }

  List<Book> get filteredBooks {
    final needle = query.trim().toLowerCase();
    final updateStates = serials.records;
    final result = books.where((book) {
      if (groupFilter != null && (book.groupName ?? '') != groupFilter) {
        return false;
      }
      if (tagFilter != null && !book.tags.contains(tagFilter)) return false;
      if (readingStateFilter != null &&
          book.readingState != readingStateFilter) {
        return false;
      }
      if (pinnedOnly && !book.pinned) return false;
      if (onlyNewUpdates &&
          (updateStates[book.id]?.newChapterCount ?? 0) == 0) {
        return false;
      }
      return needle.isEmpty ||
          [book.title, book.author, book.synopsis, ...book.tags]
              .any((value) => value.toLowerCase().contains(needle));
    }).toList();
    final order = {for (var i = 0; i < books.length; i++) books[i].id: i};
    result.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final comparison = switch (sort) {
        LibrarySort.recent =>
          (b.lastReadAt ?? '').compareTo(a.lastReadAt ?? ''),
        LibrarySort.title => a.title.compareTo(b.title),
        LibrarySort.author => a.author.compareTo(b.author),
        LibrarySort.server => 0,
      };
      return comparison != 0
          ? comparison
          : order[a.id]!.compareTo(order[b.id]!);
    });
    return List.unmodifiable(result);
  }

  Future<void> load({bool silent = false}) async {
    if (imports.enabled) unawaited(imports.load());
    if (serials.enabled) unawaited(serials.load());
    final generation = _contextGeneration;
    final request = ++_loadRequest;
    if (!silent) {
      state = LoadState.loading;
      error = null;
      notifyListeners();
    }
    try {
      final loadedBooks = await api.fetchBooks();
      if (_disposed ||
          generation != _contextGeneration ||
          request != _loadRequest) {
        return;
      }
      books = List.unmodifiable(loadedBooks);
      error = null;
      state = books.isEmpty ? LoadState.empty : LoadState.ready;
    } catch (exception) {
      if (_disposed ||
          generation != _contextGeneration ||
          request != _loadRequest) {
        return;
      }
      error = '$exception';
      state = LoadState.error;
    }
    if (!_disposed &&
        generation == _contextGeneration &&
        request == _loadRequest) {
      notifyListeners();
    }
  }

  void _invalidateLoad() {
    _loadRequest++;
    if (state == LoadState.loading) {
      state = books.isEmpty ? LoadState.empty : LoadState.ready;
    }
  }

  Future<BookMetadata?> updateMetadata(String bookId, JsonMap patch) async {
    final generation = _contextGeneration;
    _invalidateLoad();
    try {
      final metadata = await api.updateBookMetadata(bookId,
          expectedRevision: patch['expectedRevision'] as int,
          changes: Map<String, dynamic>.from(patch)
            ..remove('expectedRevision'));
      if (_disposed || generation != _contextGeneration) return null;
      _invalidateLoad();
      books = List.unmodifiable(books
          .map((book) => book.id == bookId ? metadata.applyTo(book) : book));
      notifyListeners();
      return metadata;
    } finally {
      if (!_disposed && generation == _contextGeneration) {
        _invalidateLoad();
        notifyListeners();
      }
    }
  }

  void setQuery(String value) {
    if (query == value) return;
    query = value;
    notifyListeners();
  }

  Future<BookPreview> preview(JsonMap payload) => api.previewBook(payload);

  Future<void> startLinkJob(String mode, JsonMap payload) async {
    if (hasActiveLinkJob || _linkJobStartInProgress) {
      throw const ApiException('已有链接任务正在处理，请等待当前任务完成后重试');
    }
    final generation = _contextGeneration;
    _linkJobStartInProgress = true;
    linkJobConnectionError = null;
    if (linkJob != null ||
        _linkJobMode != mode ||
        !mapEquals(linkJobPayload, payload)) {
      _linkJobOperationKey = null;
    }
    _linkJobOperationKey ??= ApiClient.createOperationKey();
    _linkJobMode = mode;
    linkJobPayload = Map<String, dynamic>.from(payload);
    // The previous terminal job must not make an unconfirmed new operation
    // appear consumed: a lost response must retain this new operation's key.
    linkJob = null;
    try {
      final startedJob = await api.startLinkJob(mode, payload,
          idempotencyKey: _linkJobOperationKey);
      if (_disposed || generation != _contextGeneration) return;
      linkJob = startedJob;
      notifyListeners();
      _updateLinkJobPolling();
      await refreshLinkJob();
    } finally {
      if (generation == _contextGeneration) _linkJobStartInProgress = false;
    }
  }

  Future<void> refreshLinkJob() async {
    final current = linkJob;
    if (current == null || _linkJobLoadInProgress || _disposed) return;
    _linkJobLoadInProgress = true;
    final generation = _contextGeneration;
    try {
      final next = await api.fetchLinkJob(current.id);
      if (_disposed ||
          generation != _contextGeneration ||
          linkJob?.id != current.id) {
        return;
      }
      linkJob = next;
      linkJobConnectionError = null;
      _updateLinkJobPolling();
      if (next.isCompleted && next.mode == 'import' && next.book != null) {
        await load(silent: true);
      } else {
        notifyListeners();
      }
    } catch (exception) {
      if (_disposed || generation != _contextGeneration) return;
      linkJobConnectionError = '$exception';
      notifyListeners();
    } finally {
      if (generation == _contextGeneration) {
        _linkJobLoadInProgress = false;
      }
    }
  }

  void clearLinkJob() {
    if (hasActiveLinkJob || _linkJobStartInProgress) return;
    _linkJobPoller?.cancel();
    _linkJobPoller = null;
    linkJob = null;
    linkJobPayload = null;
    linkJobConnectionError = null;
    _linkJobOperationKey = null;
    _linkJobMode = null;
    notifyListeners();
  }

  void _updateLinkJobPolling() {
    if (hasActiveLinkJob && _linkJobPoller == null) {
      _linkJobPoller = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(refreshLinkJob()),
      );
    } else if (!hasActiveLinkJob) {
      _linkJobPoller?.cancel();
      _linkJobPoller = null;
    }
  }

  Future<Book> import(JsonMap payload) async {
    final generation = _contextGeneration;
    final book = await api.importBook(payload);
    if (_disposed || generation != _contextGeneration) return book;
    await load(silent: true);
    return book;
  }

  Future<Book> importFromSearch(
    JsonMap payload, {
    Duration pollInterval = const Duration(milliseconds: 600),
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (hasActiveLinkJob) {
      throw const ApiException('已有链接任务正在处理，请等待当前任务完成后重试');
    }
    await startLinkJob('import', payload);
    final jobId = linkJob?.id;
    if (jobId == null || jobId.isEmpty) {
      throw const ApiException('后端未返回导入任务编号');
    }
    final deadline = DateTime.now().add(timeout);
    while (!_disposed && DateTime.now().isBefore(deadline)) {
      final current = linkJob;
      if (current == null || current.id != jobId) {
        throw const ApiException('导入任务状态已失效，请重新加入书架');
      }
      if (current.isCompleted) {
        final book = current.book;
        if (book == null) {
          throw const ApiException('导入任务已完成，但未返回书籍信息');
        }
        return book;
      }
      if (current.isFailed) {
        throw ApiException(
          current.error?.trim().isNotEmpty == true
              ? current.error!.trim()
              : (current.message.trim().isEmpty
                  ? '导入失败，请稍后重试'
                  : current.message.trim()),
        );
      }
      await Future<void>.delayed(pollInterval);
      await refreshLinkJob();
    }
    if (_disposed) throw const ApiException('导入已取消');
    throw const ApiException('导入等待超时，任务仍可在书架页继续查看');
  }

  Future<Book> importLocal({
    required String filePath,
    required String kind,
    required String language,
    required bool translate,
    String? title,
    String textEncoding = 'auto',
  }) async {
    final generation = _contextGeneration;
    importProgress = 0;
    notifyListeners();
    try {
      final book = await api.importLocalBook(
        filePath: filePath,
        kind: kind,
        language: language,
        translate: translate,
        title: title,
        textEncoding: textEncoding,
        onProgress: (sentBytes, totalBytes) {
          if (_disposed ||
              generation != _contextGeneration ||
              totalBytes <= 0) {
            return;
          }
          importProgress = sentBytes / totalBytes;
          notifyListeners();
        },
      );
      if (!_disposed && generation == _contextGeneration) {
        await load(silent: true);
      }
      return book;
    } finally {
      if (!_disposed && generation == _contextGeneration) {
        importProgress = null;
        notifyListeners();
      }
    }
  }

  Future<void> delete(String bookId) async {
    final generation = _contextGeneration;
    await api.deleteBook(bookId);
    if (_disposed || generation != _contextGeneration) return;
    _invalidateLoad();
    books = books.where((book) => book.id != bookId).toList();
    state = books.isEmpty ? LoadState.empty : LoadState.ready;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    imports.dispose();
    serials.dispose();
    _linkJobPoller?.cancel();
    super.dispose();
  }
}
