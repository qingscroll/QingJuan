import 'dart:io';
import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/reading_progress_pending.dart';
import 'package:qingjuan/features/reader/reader_progress_store.dart';
import 'package:qingjuan/features/offline/offline_cache_store.dart';
import 'package:qingjuan/features/offline/offline_library_page.dart';
import 'package:qingjuan/features/offline/offline_reader_route.dart';
import 'package:qingjuan/features/offline/offline_reading_controller.dart';
import 'package:qingjuan/features/offline/offline_save_page.dart';
import 'package:qingjuan/shared/responsive.dart';
import '../../helpers/reliability_harness.dart';
import 'offline_fixtures.dart';

void main() {
  testWidgets(
      'unavailable book progress stays visible with a working retry action',
      (tester) async {
    var requests = 0;
    final harness = await ReliabilityHarness.create(MockClient((_) async {
      requests++;
      return http.Response('{"detail":"missing"}', 404);
    }));
    final directory = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('qj-offline-retry-')))!;
    final store = OfflineCacheStore(directory: () async => directory);
    final controller = OfflineReadingController(harness.scope.api, store);
    final pending = FileReaderProgressStore(
        instanceId: offlineIdentity.instanceId,
        ownerId: offlineIdentity.ownerId,
        bookId: 'deleted-book',
        directory: () async => directory);
    addTearDown(() async {
      controller.dispose();
      harness.dispose();
      await directory.delete(recursive: true);
    });
    await tester.runAsync(() async {
      await pending.save(const PendingReadingProgress(
          baseRevision: 0,
          queued: ReadingProgress(chapterIndex: 2, scrollRatio: .2)));
      await controller.activate(
          connectionKey: offlineIdentity.connectionKey,
          instanceId: offlineIdentity.instanceId,
          ownerId: offlineIdentity.ownerId,
          displayName: offlineIdentity.displayName,
          versioning: true);
    });
    await tester.pumpWidget(harness
        .widget(OfflineLibraryPage(controller: controller), mobile: true));
    expect(find.textContaining('作品已删除或当前账号无法访问'), findsOneWidget);
    final before = requests;
    await tester.runAsync(() async {
      await tester.tap(find.text('补交待同步进度'));
      await controller.replayPending();
    });
    await tester.pumpAndSettle();
    expect(requests, greaterThan(before));
    expect(await tester.runAsync(pending.load), isNotNull);
    expect(find.textContaining('进度仍保留'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final manga in [false, true]) {
    testWidgets(
        'offline reader displays cached content with zero network and hides it after logout manga=$manga',
        (tester) async {
      var requests = 0;
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        requests++;
        return http.Response('unavailable', 503);
      }));
      final directory = await tester
          .runAsync(() => Directory.systemTemp.createTemp('qj-offline-ui-'));
      final store = OfflineCacheStore(directory: () async => directory!);
      final controller = OfflineReadingController(harness.scope.api, store);
      await tester.runAsync(() async {
        await store.remember(offlineIdentity);
        final picture =
            manga ? await File('assets/logo.png').readAsBytes() : <int>[];
        await store.saveChapter(
            offlineIdentity,
            offlineDetail(),
            offlineContent(
                images: manga
                    ? [
                        'https://backend.test/api/v1/books/offline-book/assets/image.png'
                      ]
                    : []),
            imageLoader: (_) async => picture,
            isCurrent: () => true);
        await controller.restore(
            connectionKey: offlineIdentity.connectionKey,
            allowStoredIdentity: true);
        await controller.writerFor(offlineDetail()).ready;
      });
      addTearDown(() async {
        controller.dispose();
        harness.dispose();
        await directory!.delete(recursive: true);
      });
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UiPlatformScope(
          platform: TargetPlatform.android,
          child: f.FluentTheme(
              data: buildQingJuanTheme(f.Brightness.light,
                  platform: TargetPlatform.android),
              child: harness.widget(
                  OfflineReaderRoute(
                      controller: controller,
                      book: controller.books.single,
                      initialChapterIndex: 1,
                      mode: 'original'),
                  mobile: true))));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      if (manga) {
        expect(
            tester
                .widgetList<Image>(find.byType(Image))
                .any((image) => image.image is FileImage),
            isTrue);
        expect(find.textContaining('图片未能加载'), findsNothing);
      } else {
        expect(find.textContaining('此处是本机保存的正文', findRichText: true),
            findsOneWidget,
            reason: tester.allWidgets
                .whereType<Text>()
                .map((w) => w.data ?? w.textSpan?.toPlainText())
                .join('\n'));
      }
      expect(requests, 0);
      await tester.runAsync(() => controller.deactivate(forgetIdentity: true));
      await tester.pump();
      expect(
          find.textContaining('此处是本机保存的正文', findRichText: true), findsNothing);
      expect(find.text('已退出账号或切换后端，请返回重新打开离线书库'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
    });
  }

  testWidgets(
      'offline selection and library fit narrow large text and report missing connection',
      (tester) async {
    final harness = await ReliabilityHarness.create(
        MockClient((_) async => http.Response('{}', 503)));
    final directory = await tester
        .runAsync(() => Directory.systemTemp.createTemp('qj-offline-ui-'));
    final store = OfflineCacheStore(directory: () async => directory!);
    final controller = OfflineReadingController(harness.scope.api, store);
    await tester.runAsync(() async {
      await store.remember(offlineIdentity);
      await controller.restore(
          connectionKey: offlineIdentity.connectionKey,
          allowStoredIdentity: true);
    });
    addTearDown(() async {
      controller.dispose();
      harness.dispose();
      await directory!.delete(recursive: true);
    });
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(harness.widget(
        OfflineSavePage(controller: controller, detail: offlineDetail()),
        mobile: true,
        textScale: 1.8));
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    await tester.tap(find.text('保存所选 1 章'));
    await tester.pump();
    expect(find.textContaining('请先连接原后端'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(harness.widget(
        OfflineLibraryPage(controller: controller),
        mobile: true,
        textScale: 1.8));
    expect(find.text('离线书库'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
