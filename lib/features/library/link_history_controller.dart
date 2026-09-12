import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/link_job.dart';

class LinkHistoryController extends ChangeNotifier {
  LinkHistoryController(this.api);
  final ApiClient api;
  Future<void> Function()? onBooksChanged;
  bool enabled = false;
  List<LinkJob> jobs = const [];
  String? error;
  bool loading = false;
  bool submitting = false;
  bool retryingFailed = false;
  bool hasMore = false;
  final Set<String> _retrying = {};
  Set<String> get retrying => Set.unmodifiable(_retrying);
  final Map<String, String> _operationKeys = {};
  Timer? _poller;
  int _generation = 0;
  int _requestId = 0;
  int _nextOffset = 0;
  bool _disposed = false;

  int get contextGeneration => _generation;
  int get activeCount => jobs.where((job) => job.isActive).length;
  int get failedCount => jobs.where((job) => job.isFailed).length;

  void reset() {
    _generation++;
    _requestId++;
    _nextOffset = 0;
    enabled = false;
    jobs = const [];
    error = null;
    loading = submitting = retryingFailed = hasMore = false;
    _retrying.clear();
    _operationKeys.clear();
    _poller?.cancel();
    _poller = null;
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  bool _currentLoad(int generation, int requestId) =>
      _current(generation) && requestId == _requestId;

  void _invalidateLoad() {
    _requestId++;
    loading = false;
  }

  Future<void> load({bool more = false}) async {
    if (!enabled || loading || _disposed || (more && !hasMore)) return;
    final generation = _generation;
    final requestId = ++_requestId;
    final previous = jobs;
    loading = true;
    notifyListeners();
    try {
      // Refresh the whole visible window. Server offsets cannot use the number
      // of display rows, since they also include deduplicated older active jobs.
      final merged = <String, LinkJob>{
        if (more)
          for (final job in previous) job.id: job,
      };
      var offset = more ? _nextOffset : 0;
      final target = more ? offset + 50 : (_nextOffset > 50 ? _nextOffset : 50);
      var nextHasMore = false;
      do {
        final page = await api.fetchLinkJobs(offset: offset);
        if (!_currentLoad(generation, requestId)) return;
        for (final job in page) {
          merged[job.id] = job;
        }
        offset += page.length;
        nextHasMore = page.length == 50;
      } while (nextHasMore && offset < target);

      // After restart an old running job can be outside the first history page.
      final active = <String, LinkJob>{};
      var activeOffset = 0;
      while (true) {
        final page =
            await api.fetchLinkJobs(offset: activeOffset, activeOnly: true);
        if (!_currentLoad(generation, requestId)) return;
        for (final job in page) {
          active[job.id] = job;
        }
        if (page.length < 50) break;
        activeOffset += page.length;
      }
      merged.addAll(active);
      final formerlyActive = {
        for (final job in [...previous, ...merged.values])
          if (job.isActive && !active.containsKey(job.id)) job.id,
      };
      for (final id in formerlyActive) {
        final latest = await api.fetchLinkJob(id);
        if (!_currentLoad(generation, requestId)) return;
        merged[id] = latest;
      }
      jobs = List.unmodifiable(merged.values.toList()..sort(_newestFirst));
      _nextOffset = offset;
      hasMore = nextHasMore;
      error = null;
      _updatePolling();
      final previousActiveIds =
          previous.where((job) => job.isActive).map((job) => job.id).toSet();
      if (jobs.any((job) =>
          job.mode == 'import' &&
          job.isCompleted &&
          previousActiveIds.contains(job.id))) {
        await onBooksChanged?.call();
      }
    } catch (exception) {
      if (_currentLoad(generation, requestId)) error = '$exception';
    } finally {
      if (_currentLoad(generation, requestId)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  static int _newestFirst(LinkJob left, LinkJob right) {
    final date = right.createdAt.compareTo(left.createdAt);
    return date == 0 ? right.id.compareTo(left.id) : date;
  }

  void _updatePolling() {
    if (activeCount > 0 && _poller == null) {
      _poller =
          Timer.periodic(const Duration(seconds: 2), (_) => unawaited(load()));
    } else if (activeCount == 0) {
      _poller?.cancel();
      _poller = null;
    }
  }

  void _accept(LinkJob job) {
    _invalidateLoad();
    jobs = List.unmodifiable(<String, LinkJob>{
      for (final existing in jobs) existing.id: existing,
      job.id: job,
    }.values.toList()
      ..sort(_newestFirst));
    _updatePolling();
  }

  Future<void> retry(String jobId) => _retry(jobId, refresh: true);

  Future<void> _retry(String jobId, {required bool refresh}) async {
    if (!enabled || _disposed || !_retrying.add(jobId)) return;
    final generation = _generation;
    _invalidateLoad();
    notifyListeners();
    try {
      final job = await api.retryLinkJob(jobId);
      if (!_current(generation)) return;
      _accept(job);
      if (refresh) await load();
    } catch (_) {
      if (_current(generation)) rethrow;
    } finally {
      if (_current(generation)) {
        _retrying.remove(jobId);
        notifyListeners();
      }
    }
  }

  Future<void> retryFailed() async {
    if (!enabled || retryingFailed || _disposed) return;
    final generation = _generation;
    final failedIds =
        jobs.where((job) => job.isFailed).map((job) => job.id).toList();
    retryingFailed = true;
    notifyListeners();
    var failed = 0;
    try {
      for (final id in failedIds) {
        if (!_current(generation)) return;
        try {
          await _retry(id, refresh: false);
        } catch (_) {
          failed++;
        }
      }
      if (!_current(generation)) return;
      await load();
      if (!_current(generation)) return;
      if (failed > 0) throw ApiException('$failed 个任务未确认重试，请重试；已排队的任务不会重复创建');
    } finally {
      if (_current(generation)) {
        retryingFailed = false;
        notifyListeners();
      }
    }
  }

  Future<void> enqueueLines(String text,
      {required String kind, required String language}) async {
    if (!enabled || submitting || _disposed) return;
    final urls = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet();
    if (urls.isEmpty || urls.length > 50) {
      throw const ApiException('请输入 1 到 50 个作品链接，每行一个');
    }
    for (final url in urls) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw const ApiException('链接格式不正确，请检查每一行的完整网址');
      }
    }
    final generation = _generation;
    submitting = true;
    error = null;
    notifyListeners();
    var failed = 0;
    String? firstError;
    try {
      for (final url in urls) {
        if (!_current(generation)) return;
        final key = _operationKeys.putIfAbsent(
            '$kind|$language|$url', ApiClient.createOperationKey);
        try {
          final job = await api.startLinkJob(
              'import',
              {
                'sourceUrl': url,
                'bookKind': kind,
                'language': language,
                'downloadMode': 'on_demand',
              },
              idempotencyKey: key);
          if (!_current(generation)) return;
          _accept(job);
          notifyListeners();
        } catch (exception) {
          failed++;
          firstError ??= '$exception';
        }
      }
      if (!_current(generation)) return;
      await load();
      if (!_current(generation)) return;
      if (failed > 0) {
        throw ApiException('$failed 个链接未确认提交，请重试；已提交的任务不会重复创建。$firstError');
      }
      for (final url in urls) {
        _operationKeys.remove('$kind|$language|$url');
      }
    } finally {
      if (_current(generation)) {
        submitting = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poller?.cancel();
    super.dispose();
  }
}
