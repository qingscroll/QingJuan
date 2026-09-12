import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/api/reading_progress_exception.dart';
import '../../core/models/book.dart';
import '../../core/models/reading_progress_pending.dart';
import 'reader_progress_store.dart';

class ReaderProgressWriter extends ChangeNotifier {
  ReaderProgressWriter(this.api, this.bookId,
      {this.retryDelay = const Duration(seconds: 5),
      this.versioning = false,
      ReadingProgress? initialProgress,
      ReaderProgressStore? store,
      bool Function()? isCurrentContext,
      bool Function()? canSync})
      : _store = store,
        _isCurrent = isCurrentContext ?? api.captureContextGuard(),
        _canSync = canSync ?? (() => true),
        _remote = initialProgress,
        _baseRevision = initialProgress?.revision ?? 0 {
    ready = versioning ? _restore() : Future<void>.value();
  }

  final ApiClient api;
  final String bookId;
  final Duration retryDelay;
  final bool versioning;
  final ReaderProgressStore? _store;
  final bool Function() _isCurrent;
  final bool Function() _canSync;
  late final Future<void> ready;
  int _baseRevision;
  ReadingProgress? _remote;
  PendingProgressWrite? _sending;
  ReadingProgress? _queued;
  ReadingProgress? _conflict;
  ReadingProgress? restoredPosition;
  String? syncError;
  bool _storageReady = true;
  bool _needsPersistence = false;
  Future<void>? _active;
  Timer? _retry;
  bool _disposed = false;
  bool _resolving = false;
  int _localGeneration = 0;

  ReadingProgress? get conflict => _conflict;
  ReadingProgress? get localPosition => _queued ?? _sending?.position;
  ReadingProgress? get confirmedPosition => _remote;
  bool get hasPending => localPosition != null;
  bool get resolving => _resolving;
  bool get isCurrentContext => _isCurrent();
  bool get canSynchronize => _canSync();
  int get revision => _remote?.revision ?? _baseRevision;
  bool get _acceptsResponse => !_disposed && _isCurrent();

  void observeRemote(ReadingProgress progress) {
    if (!_acceptsResponse ||
        progress.revision == null ||
        progress.revision! <= (_remote?.revision ?? -1)) {
      return;
    }
    _remote = progress;
    if (!hasPending) {
      _baseRevision = progress.revision!;
    } else if (_sending == null) {
      _conflict = progress;
      unawaited(_persist());
    }
    _notify();
  }

  Future<void> _restore() async {
    try {
      final store = _store;
      final snapshot = store is ReaderProgressSnapshotStore
          ? await store.loadSnapshot()
          : null;
      final saved = snapshot == null ? await store?.load() : snapshot.pending;
      final confirmed = snapshot?.confirmed;
      if (confirmed != null &&
          (confirmed.revision ?? -1) > (_remote?.revision ?? -1)) {
        _remote = confirmed;
      }
      _storageReady = true;
      if (saved == null) {
        _baseRevision = _remote?.revision ?? _baseRevision;
        if (confirmed != null) restoredPosition = _remote;
        return;
      }
      _baseRevision = saved.baseRevision;
      _sending = saved.sending;
      // Do not overwrite a newer position captured while disk IO was in flight.
      _queued ??= saved.queued;
      restoredPosition = localPosition;
      _conflict = saved.conflict;
      if (_conflict != null &&
          (_remote?.revision ?? -1) > (_conflict!.revision ?? -1)) {
        _conflict = _remote;
      }
      if (_sending == null &&
          _queued != null &&
          (_remote?.revision ?? 0) > _baseRevision) {
        _conflict = _remote;
      }
    } catch (_) {
      _storageReady = false;
      syncError = '无法读取本机待提交进度，已暂停同步。请重试。';
    }
    _notify();
  }

  Future<void> save(ReadingProgress position) async {
    if (_disposed || !_isCurrent()) return;
    _localGeneration++;
    _queued = position;
    if (versioning && _conflict != null) _notify();
    await ready;
    if (!_isCurrent()) return;
    if (versioning && (!_storageReady || !await _persist())) return;
    await flush();
  }

  Future<void> flush() {
    _retry?.cancel();
    _retry = null;
    if (_active != null) return _active!;
    final completer = Completer<void>();
    _active = completer.future;
    unawaited(_drain(completer));
    return completer.future;
  }

  Future<bool> _persist() async {
    if (!_isCurrent()) return false;
    if (!versioning || _store == null) return true;
    try {
      await _saveStore(
          hasPending
              ? PendingReadingProgress(
                  baseRevision: _baseRevision,
                  sending: _sending,
                  queued: _queued,
                  conflict: _conflict)
              : null,
          _remote);
      _needsPersistence = false;
      return true;
    } catch (_) {
      _needsPersistence = true;
      syncError = '阅读进度尚未保存到本机，已暂停同步。请检查设备空间后重试。';
      _notify();
      return false;
    }
  }

  Future<void> _saveStore(
      PendingReadingProgress? pending, ReadingProgress? confirmed) async {
    final store = _store;
    if (store is ReaderProgressSnapshotStore) {
      await store.saveSnapshot(pending, confirmed);
    } else {
      await store?.save(pending);
    }
  }

  Future<void> _drain(Completer<void> completer) async {
    try {
      await ready;
      if (!_isCurrent()) return;
      if (!_storageReady) await _restore();
      if (!_storageReady) return;
      while (hasPending && _isCurrent() && _canSync()) {
        if (versioning) {
          if (_conflict != null) {
            await _persist();
            return;
          }
          _sending ??= PendingProgressWrite(
              operationId: _operationId(),
              expectedRevision: _baseRevision,
              position: _queued!);
          if (identical(_queued, _sending!.position)) _queued = null;
          if (!await _persist()) return;
          if (!_isCurrent()) return;
          final sending = _sending!;
          try {
            final result = await api.saveVersionedProgress(
                bookId, sending.position,
                expectedRevision: sending.expectedRevision,
                operationId: sending.operationId);
            // A replaced writer must leave the durable operation untouched.
            // Its successor can replay the same ID without losing newer text positions.
            if (!_acceptsResponse) return;
            if (result.revision == null ||
                result.revision! <= sending.expectedRevision) {
              throw const FormatException('服务器未确认进度版本');
            }
            _baseRevision = max(_baseRevision, result.revision!);
            if ((_remote?.revision ?? -1) > result.revision!) {
              _queued ??= sending.position;
              _conflict = _remote;
            } else {
              _remote = result;
            }
            _sending = null;
            syncError = null;
            if (!await _persist()) return;
            _notify();
          } on ReadingProgressConflict catch (error) {
            if (!_acceptsResponse) return;
            if (error.current.revision == null) {
              syncError = '服务器没有返回可核对的进度版本，待提交位置仍已保留。请重试。';
              await _persist();
              _notify();
              return;
            }
            if ((_remote?.revision ?? -1) <= (error.current.revision ?? -1)) {
              _remote = error.current;
            }
            _conflict = _remote ?? error.current;
            syncError = null;
            await _persist();
            _notify();
            return;
          } catch (_) {
            if (!_acceptsResponse) return;
            syncError = '阅读进度尚未同步，待提交位置已保留在本机。联网后将重试。';
            await _persist();
            _scheduleRetry();
            _notify();
            return;
          }
        } else {
          final current = _queued!;
          _queued = null;
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
            _queued ??= current;
            _scheduleRetry();
            return;
          }
        }
      }
      if (versioning && hasPending) await _persist();
      if (versioning && !hasPending && _needsPersistence && await _persist()) {
        syncError = null;
        _notify();
      }
      if (!versioning && !_isCurrent()) _queued = null;
    } finally {
      _active = null;
      completer.complete();
    }
  }

  Future<bool> keepLocal() async {
    await flush();
    if (_conflict == null ||
        localPosition == null ||
        _disposed ||
        !_isCurrent() ||
        !_canSync() ||
        _resolving) {
      return false;
    }
    _resolving = true;
    _notify();
    try {
      _queued = localPosition;
      _sending = null;
      _baseRevision = _conflict!.revision!;
      _conflict = null;
      if (!await _persist()) return false;
      await flush();
      return _conflict == null && !hasPending;
    } finally {
      _resolving = false;
      _notify();
    }
  }

  Future<ReadingProgress?> useServer() async {
    await flush();
    if (_conflict == null ||
        _disposed ||
        !_isCurrent() ||
        !_canSync() ||
        _resolving) {
      return null;
    }
    _resolving = true;
    _notify();
    try {
      final generation = _localGeneration;
      final latest = await api.fetchReadingProgress(bookId);
      if (!_acceptsResponse) return null;
      if (latest.revision == null || latest.revision != _conflict!.revision) {
        if ((latest.revision ?? -1) >= (_conflict!.revision ?? -1)) {
          _conflict = latest;
        }
        _remote = _conflict;
        await _persist();
        return null;
      }
      if (generation != _localGeneration) return null;
      // Publish the explicit discard before forgetting the local pending position.
      await _saveStore(null, latest);
      if (generation != _localGeneration) {
        await _persist();
        return null;
      }
      _queued = null;
      _sending = null;
      _conflict = null;
      _remote = latest;
      _baseRevision = latest.revision!;
      syncError = null;
      return latest;
    } catch (_) {
      syncError = '无法确认服务端阅读位置，本机待提交进度仍已保留。请重试。';
      return null;
    } finally {
      _resolving = false;
      _notify();
    }
  }

  void _scheduleRetry() {
    if (!_disposed && _isCurrent()) {
      _retry = Timer(retryDelay, () => unawaited(flush()));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _operationId() {
    final random = Random.secure();
    return List.generate(
            24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    super.dispose();
  }
}
