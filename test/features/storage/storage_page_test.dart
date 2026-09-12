import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/features/storage/storage_controller.dart';
import 'package:qingjuan/features/storage/storage_page.dart';

import '../../helpers/reliability_harness.dart';

Map<String, dynamic> report({bool cleaned = false}) => {
      'bookId': 'book-one',
      'totalBytes': cleaned ? 100 : 120,
      'protectedBytes': 100,
      'reclaimableBytes': cleaned ? 0 : 20,
      'fileCount': cleaned ? 1 : 2,
      'categories': [
        {
          'id': 'original',
          'label': '原文',
          'bytes': 100,
          'fileCount': 1,
          'cleanable': false,
          'description': '下载和阅读缓存中的小说原文，保留'
        },
        {
          'id': 'exports',
          'label': '导出临时文件',
          'bytes': cleaned ? 0 : 20,
          'fileCount': cleaned ? 0 : 1,
          'cleanable': true,
          'description': '清理后导出下载链接失效，可从原书重新导出'
        }
      ],
      'warnings': ['章节缓存就是原文或原图，不能清理。'],
    };
final preview = {
  'bookId': 'book-one',
  'cleanupId': 'cleanup-one',
  'confirmationToken': 'signed-token',
  'totalBytes': 20,
  'fileCount': 1,
  'artifacts': [
    {
      'id': 'a' * 32,
      'format': 'epub',
      'sizeBytes': 20,
      'createdAt': '2026-09-11T00:00:00Z'
    }
  ],
  'warnings': ['仅删除此书的导出临时文件。'],
};

void main() {
  late ReliabilityHarness harness;
  int cleanups = 0, previews = 0;
  Completer<http.Response>? pending;
  setUp(() async {
    cleanups = previews = 0;
    pending = null;
    harness = await ReliabilityHarness.create(MockClient((request) async {
      Object body = report();
      if (request.url.path.endsWith('cleanup-preview')) {
        previews++;
        expect(jsonDecode(request.body), {
          'categories': ['exports']
        });
        body = preview;
      } else if (request.url.path.endsWith('/cleanup')) {
        cleanups++;
        expect(jsonDecode(request.body),
            {'cleanupId': 'cleanup-one', 'confirmationToken': 'signed-token'});
        if (pending != null) return pending!.future;
        body = {
          'bookId': 'book-one',
          'deletedBytes': 20,
          'deletedFiles': 1,
          'warnings': [],
          'storage': report(cleaned: true)
        };
      }
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  });
  tearDown(() => harness.dispose());

  Future<void> inspect(WidgetTester tester) async {
    await tester.tap(find.byKey(const f.ValueKey('storage-preview')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const f.ValueKey('storage-cleanup')), 150,
        scrollable: find
            .descendant(
                of: find.byKey(const f.ValueKey('storage-scroll')),
                matching: find.byType(f.Scrollable))
            .first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const f.ValueKey('storage-cleanup')));
    await tester.pumpAndSettle();
  }

  for (final mobile in [false, true]) {
    testWidgets(
        'export cleanup requires signed preview and explicit confirmation $mobile',
        (tester) async {
      await tester.pumpWidget(harness.widget(
          BookStoragePage(bookId: 'book-one', mobile: mobile),
          mobile: mobile));
      await tester.pumpAndSettle();
      expect(cleanups, 0);
      expect(previews, 0);
      await inspect(tester);
      expect(cleanups, 0);
      expect(find.textContaining('原文、译文、图片、笔记和阅读进度均保留'), findsOneWidget);
      await tester.tap(find.byKey(const f.ValueKey('storage-confirm')));
      await tester.pumpAndSettle();
      expect(cleanups, 1);
      expect(find.textContaining('已清理 1 个导出文件'), findsOneWidget);
      expect(find.byKey(const f.ValueKey('storage-cleanup')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'storage layout scrolls at 360 pixels and 200 percent text $mobile',
        (tester) async {
      tester.view.physicalSize = const f.Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(harness.widget(
          BookStoragePage(bookId: 'book-one', mobile: mobile),
          mobile: mobile,
          textScale: 2));
      await tester.pumpAndSettle();
      await inspect(tester);
      expect(tester.takeException(), isNull);
      expect(mobile ? find.byType(m.AlertDialog) : find.byType(f.ContentDialog),
          findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('backend change redacts confirmation and prevents cleanup',
      (tester) async {
    await tester
        .pumpWidget(harness.widget(const BookStoragePage(bookId: 'book-one')));
    await tester.pumpAndSettle();
    await inspect(tester);
    harness.scope.library.resetForBackendSwitch();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<f.FilledButton>(
                find.byKey(const f.ValueKey('storage-confirm')))
            .onPressed,
        isNull);
    expect(find.textContaining('将删除 1 个'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.textContaining('书籍文件'), findsNothing);
    expect(cleanups, 0);
  });

  test('late cleanup response cannot replace the switched account state',
      () async {
    final controller =
        BookStorageController(harness.scope.library, bookId: 'book-one');
    addTearDown(controller.dispose);
    await controller.load();
    await controller.inspect();
    final confirmed = controller.preview!;
    pending = Completer<http.Response>();
    final cleaning = controller.cleanup(confirmed);
    await Future<void>.delayed(Duration.zero);
    harness.scope.library.resetForBackendSwitch();
    pending!.complete(http.Response(
        jsonEncode({
          'bookId': 'book-one',
          'deletedBytes': 20,
          'deletedFiles': 1,
          'warnings': [],
          'storage': report(cleaned: true)
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await cleaning;
    expect(controller.report, isNull);
    expect(controller.preview, isNull);
    expect(controller.message, isNull);
    expect(controller.invalidated, isTrue);
  });
}
