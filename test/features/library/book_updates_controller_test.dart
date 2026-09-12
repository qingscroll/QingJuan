import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/core/models/book_update.dart';
import 'package:qingjuan/features/library/book_updates_controller.dart';

void main() {
  late _Api api;
  late BookUpdatesController controller;
  setUp(() {
    api = _Api();
    controller = BookUpdatesController(api)..enabled = true;
  });
  tearDown(() {
    controller.dispose();
    api.close();
  });

  test('check result wins over older summary and refreshes books once',
      () async {
    final stale = Completer<List<BookUpdate>>();
    api.list = () => stale.future;
    final loading = controller.load();
    var refreshes = 0;
    controller.onBooksChanged = () async {
      refreshes++;
    };
    await controller.check('book');
    stale.complete([_state(count: 0)]);
    await loading;
    expect(controller.records['book']!.newChapterCount, 2);
    expect(controller.loading, isFalse);
    expect(refreshes, 1);
  });

  test('older per-book refresh cannot overwrite an acknowledgement', () async {
    final stale = Completer<BookUpdate>();
    api.get = () => stale.future;
    final refreshing = controller.refresh('book');
    await controller.acknowledge('book', 8);
    stale.complete(_state(count: 2));
    expect(await refreshing, isNull);
    expect(controller.records['book']!.newChapterCount, 0);
    expect(api.acknowledged, 8);
  });

  test('duplicate mutation is blocked and failed check retains state for retry',
      () async {
    await controller.load();
    final pending = Completer<BookUpdate>();
    api.check = () => pending.future;
    final checking = controller.check('book');
    expect(await controller.check('book'), isNull);
    expect(controller.isPending('book'), isTrue);
    final failure = expectLater(checking, throwsA(isA<ApiException>()));
    pending.completeError(const ApiException('正在处理章节', statusCode: 409));
    await failure;
    expect(controller.isPending('book'), isFalse);
    expect(controller.records['book']!.newChapterCount, 0);
    api.check = null;
    expect((await controller.check('book'))!.newChapterCount, 2);
  });

  test(
      'account reset discards late reads and mutations and resets pending state',
      () async {
    final pending = Completer<BookUpdate>();
    api.check = () => pending.future;
    final checking = controller.check('book');
    controller.reset();
    pending.complete(_state(count: 2));
    expect(await checking, isNull);
    expect(controller.records, isEmpty);
    expect(controller.isPending('book'), isFalse);
    controller.enabled = true;
    final stale = Completer<List<BookUpdate>>();
    api.list = () => stale.future;
    final loading = controller.load();
    controller.enabled = false;
    stale.complete([_state(count: 9)]);
    await loading;
    expect(controller.records, isEmpty);
    expect(controller.loading, isFalse);
  });

  test('settings forward revision and summary failures retain known updates',
      () async {
    api.get = () async => const BookUpdate(bookId: 'book', automatic: true);
    await controller.refresh('book');
    await controller.configure('book',
        expectedRevision: 4, intervalHours: 12, autoDownload: true);
    expect(api.settings, [4, null, 12, true]);
    api.list = () => Future.error(const ApiException('网络失败'));
    await controller.load();
    expect(controller.records['book']!.newChapterCount, 2);
    expect(controller.error, contains('网络失败'));
    expect(() => controller.records.clear(), throwsUnsupportedError);
  });

  test('legacy enabled never becomes a serial label or an outgoing setting',
      () async {
    for (final enabled in [false, true]) {
      api.get = () async => BookUpdate.fromJson({
            'bookId': 'book',
            'enabled': enabled,
          });
      final record = await controller.refresh('book');
      expect(record!.automatic, isFalse);
      expect(record.sourceStatus, 'unknown');
      expect(record.sourceStatusLabel, '连载状态待确认');
      await controller.configure('book',
          expectedRevision: 0, intervalHours: 6, autoDownload: false);
      expect(api.settings, [0, null, 6, false]);
    }
  });

  test('only explicit source statuses are shown as ongoing or complete', () {
    for (final status in ['ongoing', 'completed', 'unknown', 'unexpected']) {
      final record = BookUpdate.fromJson({
        'bookId': 'book',
        'sourceStatus': status,
        'automatic': true,
        'enabled': true,
        'supported': false,
        'unsupportedReason': '来源未提供目录接口',
        'sourceStatusCheckedAt': '2026-09-12T08:00:00Z',
      });
      expect(record.sourceStatus,
          status == 'ongoing' || status == 'completed' ? status : 'unknown');
      expect(record.supported, isFalse);
      expect(record.unsupportedReason, '来源未提供目录接口');
      expect(record.sourceStatusCheckedAt, isNotNull);
    }
  });

  testWidgets('summary polling stops when capability is disabled',
      (tester) async {
    controller.enabled = false;
    controller.enabled = true;
    await tester.pump(const Duration(seconds: 30));
    expect(api.listCalls, 1);
    controller.enabled = false;
    await tester.pump(const Duration(seconds: 60));
    expect(api.listCalls, 1);
    controller.enabled = true;
    controller.reset();
    await tester.pump(const Duration(seconds: 60));
    expect(api.listCalls, 1);
  });
}

BookUpdate _state({int count = 0}) =>
    BookUpdate(bookId: 'book', newChapterCount: count, latestChapterIndex: 8);

class _Api extends ApiClient {
  _Api() : super(() => 'https://example.test');
  Future<List<BookUpdate>> Function()? list;
  Future<BookUpdate> Function()? get;
  Future<BookUpdate> Function()? check;
  List<Object?>? settings;
  int listCalls = 0;
  int? acknowledged;
  @override
  Future<List<BookUpdate>> fetchBookUpdates() async {
    listCalls++;
    return list != null ? list!() : [_state()];
  }

  @override
  Future<BookUpdate> fetchBookUpdate(String id) async =>
      get != null ? get!() : _state();
  @override
  Future<BookUpdate> checkBookUpdates(String id) async =>
      check != null ? check!() : _state(count: 2);
  @override
  Future<BookUpdate> acknowledgeBookUpdates(String id,
      {required int throughChapterIndex}) async {
    acknowledged = throughChapterIndex;
    return _state();
  }

  @override
  Future<BookUpdate> configureBookUpdates(String id,
      {required int expectedRevision,
      bool? enabled,
      required int intervalHours,
      required bool autoDownload}) async {
    settings = [expectedRevision, enabled, intervalHours, autoDownload];
    return _state(count: 2);
  }
}
