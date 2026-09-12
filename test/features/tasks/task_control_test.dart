import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/core/models/task.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';

void main() {
  late _Api api;
  late TasksController controller;
  setUp(() {
    api = _Api();
    controller = TasksController(api)..tasks = [_task('running')];
  });
  tearDown(() {
    controller.dispose();
    api.close();
  });

  test('control response wins over a poll started before it', () async {
    final poll = Completer<List<BookTask>>();
    api.list = () => poll.future;
    final loading = controller.load(silent: true);
    await controller.control('task-1', 'pause');
    expect(controller.tasks.single.status, 'pause_requested');
    poll.complete([_task('running')]);
    await loading;
    expect(controller.tasks.single.status, 'pause_requested');
  });

  test(
      'a poll waiting for page results cannot overwrite a control or clear results',
      () async {
    final pages = Completer<List<TaskPageResult>>();
    api.list = () async => [_task('running', type: 'translate')];
    api.pages = () => pages.future;
    final loading = controller.load(silent: true);
    await Future<void>.delayed(Duration.zero);
    await controller.control('task-1', 'pause');
    pages.complete([_page]);
    await loading;
    expect(controller.tasks.single.status, 'pause_requested');
    expect(controller.taskPageResults, isEmpty);
  });

  test('retry and control share the same per-task in-flight guard', () async {
    final response = Completer<BookTask>();
    api.change = (_, __) => response.future;
    final pause = controller.control('task-1', 'pause');
    await controller.retry('task-1');
    await controller.control('task-1', 'cancel');
    expect(api.controls, 1);
    expect(api.retries, 0);
    expect(controller.isControlling('task-1'), isTrue);
    response.complete(_task('pause_requested'));
    await pause;
    expect(controller.isControlling('task-1'), isFalse);
  });

  test('different tasks remain independently controllable', () async {
    final response = Completer<BookTask>();
    controller.tasks = [_task('running'), _task('paused', id: 'task-2')];
    api.change = (id, _) => id == 'task-1'
        ? response.future
        : Future.value(_task('queued', id: id));
    final pause = controller.control('task-1', 'pause');
    await controller.control('task-2', 'resume');
    expect(controller.isControlling('task-1'), isTrue);
    expect(controller.tasks.last.status, 'queued');
    response.complete(_task('pause_requested'));
    await pause;
  });

  test(
      'switching backend discards late success and errors without clearing new busy state',
      () async {
    final old = Completer<BookTask>();
    final next = Completer<BookTask>();
    api.change = (_, __) => old.future;
    final first = controller.control('task-1', 'pause');
    controller.resetForBackendSwitch();
    controller.tasks = [_task('running')];
    api.change = (_, __) => next.future;
    final second = controller.control('task-1', 'pause');
    old.completeError(const ApiException('旧账号失败'));
    await first;
    expect(controller.isControlling('task-1'), isTrue);
    next.complete(_task('paused'));
    await second;
    expect(controller.tasks.single.status, 'paused');
  });

  test('failed action retains existing data and can be retried', () async {
    api.change = (_, __) async => throw const ApiException('无法暂停');
    await expectLater(
        controller.control('task-1', 'pause'), throwsA(isA<ApiException>()));
    expect(controller.tasks.single.status, 'running');
    expect(controller.isControlling('task-1'), isFalse);
    api.change = (_, __) async => _task('paused');
    await controller.control('task-1', 'pause');
    expect(controller.tasks.single.status, 'paused');
  });

  test(
      'a failed control cannot leave an invalidated manual refresh loading forever',
      () async {
    final old = Completer<List<BookTask>>();
    api.list = () => old.future;
    final loading = controller.load();
    expect(controller.state, LoadState.loading);
    api.change = (_, __) async => throw const ApiException('服务暂不可用');
    await expectLater(
        controller.control('task-1', 'pause'), throwsA(isA<ApiException>()));
    old.complete([_task('running')]);
    await loading;
    expect(controller.state, LoadState.ready);
    expect(controller.tasks.single.status, 'running');
  });

  testWidgets(
      'stop requests continue polling until the backend reaches a safe boundary',
      (tester) async {
    api.change = (_, action) async =>
        _task(action == 'cancel' ? 'cancel_requested' : 'pause_requested');
    api.list = () async => [_task('paused')];
    await controller.control('task-1', 'pause');
    expect(controller.activeCount, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.tasks.single.status, 'paused');
    expect(api.loads, 1);
    await tester.pump(const Duration(seconds: 4));
    expect(api.loads, 1);
    api.list = () async => [_task('cancelled')];
    await controller.control('task-1', 'cancel');
    await tester.pump(const Duration(seconds: 2));
    expect(controller.tasks.single.status, 'cancelled');
    await tester.pump(const Duration(seconds: 4));
    expect(api.loads, 2);
  });

  test(
      'retry applies its authoritative response even when a list poll is delayed',
      () async {
    controller.tasks = [_task('failed')];
    final response = Completer<List<BookTask>>();
    api.list = () => response.future;
    final loading = controller.load();
    await controller.retry('task-1');
    expect(controller.tasks.single.status, 'queued');
    response.complete([_task('failed')]);
    await loading;
    expect(controller.tasks.single.status, 'queued');
  });
}

BookTask _task(String status,
        {String id = 'task-1', String type = 'download'}) =>
    BookTask(
      id: id,
      bookId: 'book-1',
      type: type,
      status: status,
      totalCount: 10,
      completedCount: 4,
      progress: 40,
      message: '任务进度',
      attempts: 1,
      updatedAt: '2026-09-11T12:00:00Z',
    );

const _page = TaskPageResult(
    sequence: 1,
    taskId: 'task-1',
    chapterIndex: 1,
    chapterTitle: '第一章',
    pageNumber: 1,
    totalPages: 1,
    texts: []);

class _Api extends ApiClient {
  _Api() : super(() => 'https://qingjuan.example.test');
  int controls = 0;
  int retries = 0;
  int loads = 0;
  Future<List<BookTask>> Function() list = () async => [_task('running')];
  Future<List<TaskPageResult>> Function() pages = () async => [];
  Future<BookTask> Function(String, String) change =
      (_, __) async => _task('pause_requested');
  @override
  Future<List<BookTask>> fetchTasks() {
    loads++;
    return list();
  }

  @override
  Future<BookTask> controlTask(String id, String action) {
    controls++;
    return change(id, action);
  }

  @override
  Future<BookTask> retryTask(String id) async {
    retries++;
    return _task('queued', id: id);
  }

  @override
  Future<List<TaskPageResult>> fetchTaskPageResults(String taskId,
          {int after = 0}) =>
      pages();
}
