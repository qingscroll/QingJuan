import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/book.dart';
import '../../core/models/offline_cache.dart';
import '../reader/reader_progress_store.dart';
import '../reader/reader_progress_writer.dart';
import 'offline_cache_store.dart';

class OfflineReadingController extends ChangeNotifier {
  OfflineReadingController(this.api, this.store);
  final ApiClient api;
  final OfflineCacheStore store;
  OfflineIdentity? _identity;
  OfflineIdentity? get identity => _identity;
  List<OfflineBook> _books = [];
  List<OfflineBook> get books => List.unmodifiable(_books);
  final Map<String, ReaderProgressWriter> _writers = {};
  final Map<String, String> _replayErrors = {};
  Map<String, String> get replayErrors => Map.unmodifiable(_replayErrors);
  Map<String, ReaderProgressWriter> get pendingWriters =>
      Map.unmodifiable(Map.fromEntries(_writers.entries
          .where((e) => e.value.hasPending || e.value.syncError != null)));
  int bytesUsed = 0;
  int get limitBytes => store.limitBytes;
  String? error;
  bool loading = false;
  bool downloading = false;
  int completed = 0;
  int total = 0;
  bool _online = false;
  bool get online => _online && _networkGuard();
  bool Function() _networkGuard = () => false;
  int _generation = 0;
  int _downloadGeneration = 0;
  int _refreshGeneration = 0;
  String? _downloadBookId;
  bool _disposed = false;
  Future<void>? _replay;
  final Set<String> _localImages = {};

  Future<void> activate(
      {required String connectionKey,
      required String instanceId,
      required String ownerId,
      required String displayName,
      required bool versioning}) async {
    if (connectionKey.isEmpty || instanceId.isEmpty || ownerId.isEmpty) return;
    final old = _identity;
    if (old?.connectionKey != connectionKey ||
        old?.instanceId != instanceId ||
        old?.ownerId != ownerId) {
      _reset();
    }
    _identity = OfflineIdentity(
        connectionKey: connectionKey,
        instanceId: instanceId,
        ownerId: ownerId,
        displayName: displayName,
        versioning: versioning);
    _online = true;
    _networkGuard = api.captureContextGuard();
    final generation = _generation;
    try {
      await store.remember(_identity!);
    } catch (_) {
      if (_current(generation)) error = '无法保存离线身份，重启后的离线入口暂不可用';
    }
    if (!_current(generation)) return;
    await refresh();
    if (_current(generation)) await replayPending();
  }

  Future<void> restore(
      {required String connectionKey,
      required bool allowStoredIdentity}) async {
    _reset();
    final generation = _generation;
    if (!allowStoredIdentity || connectionKey.isEmpty) {
      _notify();
      return;
    }
    try {
      final saved = await store.recall(connectionKey);
      if (!_current(generation)) return;
      _identity = saved;
      await refresh();
    } catch (_) {
      if (_current(generation)) error = '无法读取本机离线书库';
    }
    _notify();
  }

  Future<void> deactivate({bool forgetIdentity = false}) async {
    final old = _identity;
    _reset();
    _notify();
    if (forgetIdentity && old != null) {
      await store.forget(old.connectionKey);
    }
  }

  void suspendOnline() {
    _online = false;
    _notify();
  }

  void _reset() {
    _generation++;
    _downloadGeneration++;
    _refreshGeneration++;
    _downloadBookId = null;
    for (final writer in _writers.values) {
      writer.dispose();
    }
    _writers.clear();
    _replayErrors.clear();
    _localImages.clear();
    _replay = null;
    _identity = null;
    _books = [];
    bytesUsed = 0;
    _online = false;
    downloading = false;
    loading = false;
    error = null;
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    final identity = _identity;
    if (identity == null) return;
    final generation = _generation;
    final refreshGeneration = ++_refreshGeneration;
    bool current() =>
        _current(generation) && refreshGeneration == _refreshGeneration;
    loading = true;
    _notify();
    try {
      final books = await store.list(identity);
      final bytes = await store.bytesUsed(identity);
      if (!current()) return;
      _books = books;
      bytesUsed = bytes;
    } catch (_) {
      if (current()) error = '无法读取离线书库，请检查设备存储后重试';
    } finally {
      if (current()) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> download(
      BookDetail detail, Set<int> indices, String mode) async {
    final identity = _identity;
    if (identity == null || downloading) return;
    if (!online) {
      error = '请先连接原后端并登录，再保存离线章节';
      _notify();
      return;
    }
    if (!identity.versioning) {
      error = '请升级后端以启用安全的离线进度同步';
      _notify();
      return;
    }
    if (!const ['original', 'translated'].contains(mode) ||
        indices.isEmpty ||
        indices.any((index) => !detail.chapters.any((c) => c.index == index))) {
      error = '请选择有效的章节与正文模式';
      _notify();
      return;
    }
    final generation = _generation;
    final operation = ++_downloadGeneration;
    _downloadBookId = detail.book.id;
    bool current() =>
        _current(generation) && operation == _downloadGeneration && online;
    downloading = true;
    completed = 0;
    total = indices.length;
    error = null;
    _notify();
    try {
      for (final index in indices.toList()..sort()) {
        final content =
            await api.fetchChapter(detail.book.id, index, mode: mode);
        if (!current()) return;
        if (content.mode != mode ||
            (mode == 'translated' && !content.translatedAvailable)) {
          throw const OfflineCacheException('所选章节译文尚未就绪，请完成翻译后重新保存');
        }
        await store.saveChapter(identity, detail, content,
            imageLoader: (url) => api.fetchOfflineImage(url),
            isCurrent: current);
        if (!current()) return;
        completed++;
        _notify();
      }
    } catch (exception) {
      if (_current(generation) && operation == _downloadGeneration) {
        error = exception is OfflineCacheException
            ? exception.message
            : '离线保存未完成，已保存章节仍可阅读。请检查连接和设备空间后重试。';
      }
    } finally {
      if (_current(generation) && operation == _downloadGeneration) {
        downloading = false;
        _downloadBookId = null;
        await refresh();
      }
    }
  }

  Future<void> cancelDownload() async {
    _cancelDownload();
    await refresh();
  }

  void _cancelDownload() {
    _downloadGeneration++;
    _downloadBookId = null;
    downloading = false;
    _notify();
  }

  Future<void> remove(String bookId, {Set<int>? indices, String? mode}) async {
    final identity = _identity;
    if (identity == null) return;
    if (_downloadBookId == bookId) _cancelDownload();
    final generation = _generation;
    try {
      await store.remove(identity, bookId, indices: indices, mode: mode);
    } catch (_) {
      if (_current(generation)) error = '清理失败，请检查设备存储后重试';
    }
    if (_current(generation)) await refresh();
  }

  Future<void> clear() async {
    final identity = _identity;
    if (identity == null) return;
    _cancelDownload();
    final generation = _generation;
    try {
      await store.clear(identity);
      if (_current(generation)) error = null;
    } catch (_) {
      if (_current(generation)) error = '清理失败，请检查设备存储后重试';
    }
    if (_current(generation)) await refresh();
  }

  Future<ChapterContent> loadChapter(String bookId, int chapterIndex,
      {String mode = 'translated', bool prefetch = false}) async {
    final identity = _identity;
    if (identity == null) throw const OfflineCacheException('离线身份已失效，请返回书库');
    final generation = _generation;
    final ChapterContent content;
    try {
      content = await store.loadChapter(identity, bookId, chapterIndex, mode);
    } on OfflineCacheException {
      rethrow;
    } catch (_) {
      throw const OfflineCacheException('本机章节无法读取，请联网后清理并重新保存');
    }
    if (!_current(generation)) {
      throw const OfflineCacheException('已切换账号或后端，请重新打开离线书库');
    }
    _localImages.addAll(content.imageSources);
    return content;
  }

  String localImagePath(String source) {
    if (!_localImages.contains(source)) {
      throw const OfflineCacheException('离线图片未获授权');
    }
    return Uri.parse(source).toFilePath();
  }

  ReaderProgressWriter writerFor(BookDetail detail) {
    final identity = _identity;
    if (identity == null) throw const OfflineCacheException('当前没有离线身份');
    return _writer(detail.book.id, detail.progress, identity);
  }

  ReaderProgressWriter _writer(
      String bookId, ReadingProgress initial, OfflineIdentity identity) {
    final writer = _writers.putIfAbsent(bookId, () {
      final generation = _generation;
      final writer = ReaderProgressWriter(api, bookId,
          versioning: true,
          initialProgress: initial,
          store: FileReaderProgressStore(
              instanceId: identity.instanceId,
              ownerId: identity.ownerId,
              bookId: bookId,
              directory: store.directory),
          isCurrentContext: () => _current(generation),
          canSync: () => online);
      writer.addListener(_notify);
      return writer;
    });
    writer.observeRemote(initial);
    return writer;
  }

  Future<void> replayPending() {
    if (_replay != null) return _replay!;
    final future = _replayPending();
    _replay = future;
    return future.whenComplete(() {
      if (identical(_replay, future)) _replay = null;
    });
  }

  Future<void> _replayPending() async {
    final identity = _identity;
    if (identity == null || !online || !identity.versioning) return;
    final generation = _generation;
    late final List<String> bookIds;
    try {
      bookIds = await FileReaderProgressStore.pendingBooks(
          instanceId: identity.instanceId,
          ownerId: identity.ownerId,
          directory: store.directory);
    } catch (_) {
      if (_current(generation)) error = '无法读取本机待同步记录，进度已保留；请检查设备存储后重试';
      _notify();
      return;
    }
    for (final bookId in {...bookIds, ..._writers.keys}) {
      try {
        if (!_current(generation) || !online) return;
        _replayErrors.remove(bookId);
        if (!_writers.containsKey(bookId)) {
          final progress = await api.fetchReadingProgress(bookId);
          if (!_current(generation) || !online) return;
          _writer(bookId, progress, identity);
        }
        await _writers[bookId]!.flush();
      } catch (exception) {
        if (!_current(generation)) return;
        _replayErrors[bookId] = exception is ApiException &&
                (exception.statusCode == 403 || exception.statusCode == 404)
            ? '作品已删除或当前账号无法访问，进度仍保留。恢复作品或访问权限后，可再次补交。'
            : '这本书的进度暂时无法同步，记录仍保留。请检查连接后再次补交。';
      }
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _reset();
    super.dispose();
  }
}
