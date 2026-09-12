import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/models/task.dart';
import '../../core/state/load_state.dart';

class TasksController extends ChangeNotifier {
  TasksController(this.api);

  final ApiClient api;
  LoadState state = LoadState.idle;
  List<BookTask> tasks = const [];
  final Map<String, List<TaskPageResult>> taskPageResults =
      <String, List<TaskPageResult>>{};
  String? error;
  Timer? _poller;
  bool _loadInProgress = false;
  int _loadRequestId = 0;
  bool _disposed = false;
  int _contextGeneration = 0;
  final Set<String> _controlling = <String>{};
  bool isControlling(String taskId) => _controlling.contains(taskId);
  int get contextGeneration => _contextGeneration;

  int get activeCount => tasks.where((task) => task.isActive).length;

  void resetForBackendSwitch() {
    _contextGeneration += 1;
    _poller?.cancel();
    _poller = null;
    tasks = const [];
    taskPageResults.clear();
    _controlling.clear();
    error = null;
    state = LoadState.idle;
    _loadInProgress = false;
    _loadRequestId += 1;
    notifyListeners();
  }

  Future<void> load({bool silent = false}) async {
    if (_loadInProgress || _disposed) return;
    final generation = _contextGeneration;
    final requestId = ++_loadRequestId;
    _loadInProgress = true;
    var shouldNotify = false;
    if (!silent) {
      state = LoadState.loading;
      error = null;
      notifyListeners();
    }
    try {
      final nextTasks = await api.fetchTasks();
      if (_disposed ||
          generation != _contextGeneration ||
          requestId != _loadRequestId) {
        return;
      }
      final pageResultsChanged = await _loadIncrementalPageResults(
        nextTasks,
        generation: generation,
        requestId: requestId,
      );
      if (_disposed ||
          generation != _contextGeneration ||
          requestId != _loadRequestId) {
        return;
      }
      final nextState = nextTasks.isEmpty ? LoadState.empty : LoadState.ready;
      shouldNotify = pageResultsChanged ||
          !_sameTasks(tasks, nextTasks) ||
          state != nextState ||
          error != null;
      if (shouldNotify) {
        tasks = nextTasks;
        state = nextState;
        error = null;
      }
      _updatePolling();
    } catch (exception) {
      if (_disposed ||
          generation != _contextGeneration ||
          requestId != _loadRequestId) {
        return;
      }
      final nextError = '$exception';
      shouldNotify = state != LoadState.error || error != nextError;
      if (shouldNotify) {
        error = nextError;
        state = LoadState.error;
      }
    } finally {
      if (requestId == _loadRequestId) _loadInProgress = false;
      if (!_disposed && generation == _contextGeneration && shouldNotify) {
        notifyListeners();
      }
    }
  }

  Future<void> enqueue(
      String bookId, String action, List<int> chapterIndexes) async {
    final generation = _contextGeneration;
    await api.enqueueTask(bookId, action, chapterIndexes);
    if (!_disposed && generation == _contextGeneration) {
      await load(silent: true);
    }
  }

  Future<void> retry(String taskId) async {
    await _changeTask(taskId, () => api.retryTask(taskId));
  }

  Future<void> control(String taskId, String action) async {
    await _changeTask(taskId, () => api.controlTask(taskId, action));
  }

  Future<void> _changeTask(
      String taskId, Future<BookTask> Function() change) async {
    if (_disposed || !_controlling.add(taskId)) return;
    final generation = _contextGeneration;
    _invalidateLoad();
    notifyListeners();
    try {
      final updated = await change();
      if (_disposed || generation != _contextGeneration) return;
      // Polls started either before or during a mutation must not overwrite its
      // authoritative response, including while page results are being loaded.
      _invalidateLoad();
      tasks = [for (final task in tasks) task.id == taskId ? updated : task];
      error = null;
      state = tasks.isEmpty ? LoadState.empty : LoadState.ready;
      _updatePolling();
    } catch (_) {
      if (!_disposed && generation == _contextGeneration) rethrow;
    } finally {
      if (!_disposed && generation == _contextGeneration) {
        _controlling.remove(taskId);
        notifyListeners();
      }
    }
  }

  void _invalidateLoad() {
    _loadRequestId++;
    _loadInProgress = false;
    if (state == LoadState.loading) {
      state = tasks.isEmpty ? LoadState.empty : LoadState.ready;
    }
  }

  List<TaskPageResult> pageResultsForTask(String taskId) =>
      taskPageResults[taskId] ?? const <TaskPageResult>[];

  Future<bool> _loadIncrementalPageResults(
    List<BookTask> nextTasks, {
    required int generation,
    required int requestId,
  }) async {
    final previousActiveIds = tasks
        .where((task) => task.type == 'translate' && _isActive(task))
        .map((task) => task.id)
        .toSet();
    final watchedIds = nextTasks
        .where(
          (task) =>
              task.type == 'translate' &&
              (_isActive(task) || previousActiveIds.contains(task.id)),
        )
        .map((task) => task.id)
        .toSet();
    var changed = false;
    for (final taskId in watchedIds) {
      if (_disposed ||
          generation != _contextGeneration ||
          requestId != _loadRequestId) {
        return false;
      }
      final current = taskPageResults[taskId] ?? const <TaskPageResult>[];
      final after = current.isEmpty ? 0 : current.last.sequence;
      try {
        final additions = await api.fetchTaskPageResults(taskId, after: after);
        if (additions.isEmpty ||
            _disposed ||
            generation != _contextGeneration ||
            requestId != _loadRequestId) {
          continue;
        }
        final seen = current.map((entry) => entry.sequence).toSet();
        final merged = <TaskPageResult>[
          ...current,
          ...additions.where((entry) => seen.add(entry.sequence)),
        ];
        taskPageResults[taskId] =
            merged.length <= 200 ? merged : merged.sublist(merged.length - 200);
        changed = true;
      } catch (_) {
        // 逐页结果是增量增强信息；单次获取失败不应遮蔽任务主进度。
      }
    }
    if (_disposed ||
        generation != _contextGeneration ||
        requestId != _loadRequestId) {
      return false;
    }
    final liveTaskIds = nextTasks.map((task) => task.id).toSet();
    final beforeCleanup = taskPageResults.length;
    taskPageResults.removeWhere((taskId, _) => !liveTaskIds.contains(taskId));
    return changed || taskPageResults.length != beforeCleanup;
  }

  bool _isActive(BookTask task) => task.isActive;

  void _updatePolling() {
    if (activeCount > 0 && _poller == null) {
      _poller = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(load(silent: true)),
      );
    } else if (activeCount == 0) {
      _poller?.cancel();
      _poller = null;
    }
  }

  bool _sameTasks(List<BookTask> current, List<BookTask> next) {
    if (identical(current, next)) return true;
    if (current.length != next.length) return false;
    for (var index = 0; index < current.length; index++) {
      final left = current[index];
      final right = next[index];
      if (left.id != right.id ||
          left.bookId != right.bookId ||
          left.type != right.type ||
          left.attempts != right.attempts ||
          left.status != right.status ||
          left.completedCount != right.completedCount ||
          left.totalCount != right.totalCount ||
          left.progress != right.progress ||
          left.message != right.message ||
          left.error != right.error ||
          left.updatedAt != right.updatedAt) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _poller?.cancel();
    super.dispose();
  }
}
