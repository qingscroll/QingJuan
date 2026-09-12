import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/link_job.dart';
import 'package:qingjuan/features/library/link_history_controller.dart';

void main() {
  late _Api api;
  late LinkHistoryController controller;
  setUp(() {
    api = _Api();
    controller = LinkHistoryController(api)..enabled = true;
  });
  tearDown(() {
    controller.dispose();
    api.close();
  });

  test(
      'restart discovers an old active job beyond history and refresh preserves loaded pages',
      () async {
    api.records = [
      for (var i = 0; i < 120; i++)
        _job(i, status: i == 119 ? 'running' : 'completed')
    ];
    await controller.load();
    expect(controller.jobs.length, 51);
    expect(controller.jobs.last.id, 'job-119');
    expect(controller.activeCount, 1);
    await controller.load(more: true);
    expect(controller.jobs.length, 101);
    await controller.load();
    expect(controller.jobs.length, 101);
    expect(api.historyOffsets, [0, 50, 0, 50]);
    expect(controller.hasMore, isTrue);
    await controller.load(more: true);
    expect(controller.jobs.length, 120);
    expect(controller.hasMore, isFalse);
    expect(controller.jobs.map((job) => job.id).toSet().length, 120);
  });

  test('active discovery paginates independently of history rows', () async {
    api.records = [
      for (var i = 0; i < 115; i++)
        _job(i, status: i < 60 ? 'completed' : 'running')
    ];
    await controller.load();
    expect(controller.activeCount, 55);
    expect(api.activeOffsets, [0, 50]);
    expect(controller.jobs.length, 105);
  });

  testWidgets('older active completion refreshes books and stops polling',
      (tester) async {
    api.records = [
      for (var i = 0; i < 80; i++)
        _job(i, status: i == 79 ? 'running' : 'completed')
    ];
    var reloads = 0;
    controller.onBooksChanged = () async {
      reloads++;
    };
    await controller.load();
    api.records[79] = _job(79);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.activeCount, 0);
    expect(controller.jobs.last.status, 'completed');
    expect(api.details, ['job-079']);
    expect(reloads, 1);
    final calls = api.historyOffsets.length;
    await tester.pump(const Duration(seconds: 4));
    expect(api.historyOffsets.length, calls);
  });

  test('retry wins over an older list response and starts polling queued task',
      () async {
    api.records = [_job(0, status: 'failed')];
    await controller.load();
    final stale = Completer<List<LinkJob>>();
    api.nextList = () => stale.future;
    final loading = controller.load();
    await controller.retry('job-000');
    expect(controller.jobs.single.status, 'queued');
    stale.complete([_job(0, status: 'failed')]);
    await loading;
    expect(controller.jobs.single.status, 'queued');
    expect(controller.retrying, isEmpty);
  });

  test('a session reset prevents a delayed load from replacing the new account',
      () async {
    final old = Completer<List<LinkJob>>();
    api.nextList = () => old.future;
    final loading = controller.load();
    controller.reset();
    controller.enabled = true;
    api.records = [_job(2)];
    await controller.load();
    old.complete([_job(1)]);
    await loading;
    expect(controller.jobs.single.id, 'job-002');
    expect(controller.loading, isFalse);
  });

  test('lost batch responses retain per-link operation keys across retry',
      () async {
    final postedKeys = <String>[];
    final accepted = <String, LinkJob>{};
    var first = true;
    api.start = (_, key) async {
      postedKeys.add(key!);
      final job = accepted.putIfAbsent(
          key, () => _job(accepted.length, status: 'queued'));
      api.records = accepted.values.toList();
      if (first) {
        first = false;
        throw const ApiException('网络中断');
      }
      return job;
    };
    const text =
        'https://example.test/a\nhttps://example.test/b\nhttps://example.test/a';
    await expectLater(
        controller.enqueueLines(text, kind: '长小说', language: '中文'),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', contains('1 个链接未确认提交'))));
    await controller.enqueueLines(text, kind: '长小说', language: '中文');
    expect(postedKeys.length, 4);
    expect(postedKeys[0], postedKeys[2]);
    expect(postedKeys[1], postedKeys[3]);
    expect(postedKeys[0], isNot(postedKeys[1]));
    expect(accepted.length, 2);
    expect(controller.submitting, isFalse);
  });

  test(
      'switching backend aborts remaining batch URLs and ignores the old response',
      () async {
    final old = Completer<LinkJob>();
    var submissions = 0;
    api.start = (_, __) {
      submissions++;
      return old.future;
    };
    final batch = controller.enqueueLines(
        'https://example.test/a\nhttps://example.test/b',
        kind: '漫画',
        language: '日文');
    controller.reset();
    controller.enabled = true;
    old.complete(_job(1));
    await batch;
    expect(submissions, 1);
    expect(controller.jobs, isEmpty);
    expect(controller.submitting, isFalse);
  });

  test('switching account stops a bulk retry before the next job', () async {
    final old = Completer<LinkJob>();
    api.records = [_job(0, status: 'failed'), _job(1, status: 'failed')];
    await controller.load();
    api.retry = (_) => old.future;
    final bulk = controller.retryFailed();
    await controller.retryFailed();
    controller.reset();
    controller.enabled = true;
    old.completeError(const ApiException('旧会话已退出'));
    await bulk;
    expect(api.retries, ['job-000']);
    expect(controller.jobs, isEmpty);
    expect(controller.retryingFailed, isFalse);
  });

  test(
      'bulk retry skips already queued jobs and reports failures without hiding successes',
      () async {
    api.records = [
      _job(0, status: 'failed'),
      _job(1, status: 'failed'),
      _job(2, status: 'queued')
    ];
    await controller.load();
    api.retry = (id) async {
      if (id == 'job-001') throw const ApiException('服务暂不可用');
      return api.queue(id);
    };
    await expectLater(controller.retryFailed(), throwsA(isA<ApiException>()));
    expect(api.retries, ['job-000', 'job-001']);
    expect(controller.jobs.first.status, 'queued');
    expect(controller.activeCount, 2);
    expect(controller.failedCount, 1);
    expect(controller.retryingFailed, isFalse);
    expect(controller.retrying, isEmpty);
  });

  test('history network failure keeps last records and can be retried',
      () async {
    api.records = [_job(0)];
    await controller.load();
    api.nextList = () async => throw const ApiException('网络暂不可用');
    await controller.load();
    expect(controller.jobs.length, 1);
    expect(controller.error, '网络暂不可用');
    await controller.load();
    expect(controller.error, isNull);
  });

  test('invalid batches are rejected before any operation starts', () async {
    for (final text in [
      '',
      'https://example.test/a\ninvalid',
      [for (var i = 0; i < 51; i++) 'https://example.test/$i'].join('\n')
    ]) {
      await expectLater(
          controller.enqueueLines(text, kind: '长小说', language: '中文'),
          throwsA(isA<ApiException>()));
    }
    expect(api.posts, 0);
    expect(controller.submitting, isFalse);
  });
}

LinkJob _job(int index, {String status = 'completed'}) => LinkJob(
      id: 'job-${index.toString().padLeft(3, '0')}',
      mode: 'import',
      status: status,
      sourceUrl: 'https://example.test/$index',
      progress: status == 'completed' ? 100 : 20,
      message: '导入记录',
      logs: [],
      createdAt: DateTime.utc(2026, 9, 11)
          .subtract(Duration(minutes: index))
          .toIso8601String(),
      updatedAt: '2026-09-11T00:00:00Z',
    );

class _Api extends ApiClient {
  _Api() : super(() => 'https://qingjuan.example.test');
  List<LinkJob> records = [];
  final historyOffsets = <int>[];
  final activeOffsets = <int>[];
  final retries = <String>[];
  final details = <String>[];
  int posts = 0;
  Future<List<LinkJob>> Function()? nextList;
  Future<LinkJob> Function(String)? retry;
  Future<LinkJob> Function(JsonMap, String?)? start;
  @override
  Future<List<LinkJob>> fetchLinkJobs(
      {int offset = 0, bool activeOnly = false}) async {
    (activeOnly ? activeOffsets : historyOffsets).add(offset);
    if (!activeOnly && nextList != null) {
      final handler = nextList!;
      nextList = null;
      return handler();
    }
    final source = activeOnly ? records.where((job) => job.isActive) : records;
    return source.skip(offset).take(50).toList();
  }

  @override
  Future<LinkJob> fetchLinkJob(String jobId) async {
    details.add(jobId);
    return records.firstWhere((job) => job.id == jobId);
  }

  LinkJob queue(String id) {
    final index = records.indexWhere((job) => job.id == id);
    return records[index] = _job(int.parse(id.substring(4)), status: 'queued');
  }

  @override
  Future<LinkJob> retryLinkJob(String jobId) async {
    retries.add(jobId);
    return retry == null ? queue(jobId) : retry!(jobId);
  }

  @override
  Future<LinkJob> startLinkJob(String mode, JsonMap payload,
      {String? idempotencyKey}) async {
    posts++;
    return start == null ? _job(0) : start!(payload, idempotencyKey);
  }
}
