import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/reader/reader_page.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _captureReader = bool.fromEnvironment('QINGJUAN_CAPTURE_MOBILE_UI');
final _readerPreviewKey = GlobalKey();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!_captureReader) return;
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json'))
            as List<dynamic>;
    for (final entry in manifest.cast<Map<String, dynamic>>()) {
      final loader = FontLoader(entry['family'] as String);
      for (final font
          in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
    }
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    for (final family in <String>[
      'Roboto',
      'Segoe UI Variable Text',
      'Segoe UI Variable Display',
      'Ahem',
    ]) {
      await (FontLoader(
        family,
      )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes))))
          .load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
        '${platform.name} continuous saves chapter pages and restores text after resize',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(820, 720);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final paragraphs = List.generate(
          50,
          (i) => i.isEven
              ? '短段落 $i。'
              : '长段落 $i：${List.filled(30, '这是一段包含不同长度文字的正文，用于确认重新排版不会跳到错误位置。').join()}');
      final writes = <Map<String, dynamic>>[];
      Future<_Harness> open(
              {ReadingProgress? progress,
              ReaderFlowMode flow = ReaderFlowMode.continuous}) =>
          _Harness.create(
            MockClient((request) async {
              if (request.method == 'PUT') {
                writes.add(jsonDecode(request.body) as Map<String, dynamic>);
                return http.Response('{}', 200);
              }
              return http.Response(
                  jsonEncode({
                    ..._chapterPayload,
                    'paragraphs': paragraphs,
                    'content': paragraphs.join('\n')
                  }),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }),
            targetPlatform: platform,
            flowMode: flow,
            detail: BookDetail(
                book: _detail.book,
                author: _detail.author,
                synopsis: _detail.synopsis,
                totalWords: 40000,
                downloadedCount: 1,
                translatedCount: 0,
                progress: progress ?? _detail.progress,
                chapters: _detail.chapters),
          );
      Future<void> settle() async {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
      }

      ScrollController controller() => tester
          .widget<ListView>(find.byKey(ValueKey(
              platform == TargetPlatform.windows
                  ? 'desktop-reader-1-translated'
                  : 'reader-continuous-translated')))
          .controller!;
      final first = await open();
      addTearDown(first.dispose);
      await tester.pumpWidget(first.widget);
      await settle();
      controller().jumpTo(22000);
      await settle();
      final saved = writes.last;
      expect(saved['pageIndex'], greaterThan(0));
      expect(saved['pageCount'], greaterThan(saved['pageIndex'] as int));
      expect(saved['layoutKey'], isNotEmpty);
      expect(saved['characterOffset'], greaterThan(0));
      expect(find.byKey(const ValueKey('reader-continuous-page-label')),
          findsOneWidget);
      expect(
          Book.fromJson({
            'lastReadChapterIndex': saved['chapterIndex'],
            'lastReadPageIndex': saved['pageIndex']
          }).readingPositionLabel,
          '第 1 章 · 第 ${(saved['pageIndex'] as int) + 1} 页');
      ReadingProgress progressFrom(Map<String, dynamic> saved) =>
          ReadingProgress(
              chapterIndex: 1,
              scrollRatio: (saved['scrollRatio'] as num).toDouble(),
              anchorType: saved['anchorType'] as String,
              anchorIndex: saved['anchorIndex'] as int,
              anchorOffsetRatio: (saved['anchorOffsetRatio'] as num).toDouble(),
              pageIndex: saved['pageIndex'] as int,
              pageCount: saved['pageCount'] as int,
              layoutKey: saved['layoutKey'] as String,
              contentMode: 'translated',
              characterOffset: saved['characterOffset'] as int);
      await tester.pumpWidget(const SizedBox.shrink());
      final reopened = await open(progress: progressFrom(saved));
      addTearDown(reopened.dispose);
      await tester.pumpWidget(reopened.widget);
      await settle();
      expect(writes.last['pageIndex'], saved['pageIndex']);
      expect(writes.last['characterOffset'], saved['characterOffset']);
      tester.view.physicalSize = const Size(480, 720);
      await settle();
      final resized = writes.last;
      expect(resized['layoutKey'], isNot(saved['layoutKey']));
      expect(resized['pageCount'], greaterThan(saved['pageCount'] as int));
      expect(resized['anchorIndex'], saved['anchorIndex']);
      expect(
          (resized['characterOffset'] as int) -
              (saved['characterOffset'] as int),
          inInclusiveRange(-40, 0));
      if (platform == TargetPlatform.windows) {
        await tester.tap(find.byIcon(FluentIcons.font_increase));
      } else {
        await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reader-font-increase')));
      }
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(writes.last['characterOffset'], greaterThan(0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle();
      final enlarged = writes.last;
      expect(enlarged['layoutKey'], isNot(resized['layoutKey']));
      expect(enlarged['anchorIndex'], resized['anchorIndex']);
      expect(
          (enlarged['characterOffset'] as int) -
              (resized['characterOffset'] as int),
          inInclusiveRange(-40, 0));
      if (platform == TargetPlatform.android) {
        final target = enlarged['characterOffset'] as int;
        await tester.pumpWidget(const SizedBox.shrink());
        final paged = await open(
            progress: progressFrom(enlarged), flow: ReaderFlowMode.paged);
        addTearDown(paged.dispose);
        await tester.pumpWidget(paged.widget);
        await settle();
        final restored = writes.last;
        expect(restored['characterOffset'], lessThanOrEqualTo(target));
        tester
            .widget<PageView>(find.byType(PageView))
            .controller!
            .jumpToPage((restored['pageIndex'] as int) + 1);
        await settle();
        final nextPage = writes.last;
        expect(nextPage['characterOffset'], greaterThan(target));
        await tester.pumpWidget(const SizedBox.shrink());
        final continuous = await open(progress: progressFrom(nextPage));
        addTearDown(continuous.dispose);
        await tester.pumpWidget(continuous.widget);
        await settle();
        expect(
            (writes.last['characterOffset'] as int) -
                (nextPage['characterOffset'] as int),
            inInclusiveRange(-40, 0));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('loads chapter after AppScope becomes available', (tester) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        expect(request.url.path, '/api/v1/books/book-1/chapters/1');
        return http.Response(
          jsonEncode(_chapterPayload),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.textContaining('这是章节正文。'), findsOneWidget);
    expect(find.text('暂时无法加载'), findsNothing);
    final body = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan?.toPlainText(includePlaceholders: false) ==
                '这是章节正文。',
      ),
    );
    expect(body.textAlign, TextAlign.justify);
    expect(body.style?.height, 1.65);
  });

  testWidgets('Windows renders the v1.3.4 desktop reader chrome', (
    tester,
  ) async {
    final harness = await _Harness.create(
      MockClient(
        (_) async => http.Response(
          jsonEncode(_chapterPayload),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        ),
      ),
      targetPlatform: TargetPlatform.windows,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(find.byKey(const ValueKey('desktop-reader-page')), findsOneWidget);
    expect(find.text('上一章'), findsOneWidget);
    expect(find.text('下一章'), findsOneWidget);
    expect(find.textContaining('这是章节正文。'), findsOneWidget);
    final body = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.textSpan?.toPlainText(includePlaceholders: false) ==
                '这是章节正文。',
      ),
    );
    expect(body.textAlign, TextAlign.justify);
    expect(find.byKey(const ValueKey('reader-bottom-controls')), findsNothing);
  });

  testWidgets('builds only visible paragraphs for a long chapter', (
    tester,
  ) async {
    final paragraphs = List<String>.generate(
      500,
      (index) => '正文段落 ${index + 1}',
    );
    final payload = <String, Object?>{
      ..._chapterPayload,
      'content': paragraphs.join('\n'),
      'paragraphs': paragraphs,
    };
    final harness = await _Harness.create(
      MockClient(
        (_) async => http.Response(
          jsonEncode(payload),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        ),
      ),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(find.byType(SelectableText).evaluate().length, lessThan(50));
    expect(find.textContaining('正文段落 500'), findsNothing);
  });

  testWidgets('volume keys turn pages in paged reading mode', (tester) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{}', 200);
        return http.Response(
          jsonEncode(_longChapterPayloadFor(1)),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
      volumeKeyReadingEnabled: true,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    final pageView = tester.widget<PageView>(find.byType(PageView));
    final controller = pageView.controller!;
    expect(controller.page, 0);

    await _sendReaderVolumeKey('down');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    expect(controller.page, closeTo(1, 0.01));
  });

  testWidgets('rapid volume presses queue every paged navigation', (
    tester,
  ) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{}', 200);
        return http.Response(
          jsonEncode(_longChapterPayloadFor(1)),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
      volumeKeyReadingEnabled: true,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    final pageView = tester.widget<PageView>(find.byType(PageView));
    final controller = pageView.controller!;

    await _sendReaderVolumeKey('down');
    await _sendReaderVolumeKey('down');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump(const Duration(milliseconds: 180));

    expect(controller.page, closeTo(2, 0.01));
  });

  testWidgets(
    'rapid volume presses wait for pagination after crossing a chapter',
    (tester) async {
      final harness = await _Harness.create(
        MockClient((request) async {
          if (request.method == 'PUT') return http.Response('{}', 200);
          final chapterIndex = int.parse(request.url.pathSegments.last);
          final payload = chapterIndex == 2
              ? _longChapterPayloadFor(chapterIndex)
              : _chapterPayloadFor(chapterIndex);
          return http.Response(
            jsonEncode(payload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
        detail: _threeChapterDetail,
        volumeKeyReadingEnabled: true,
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(harness.widget);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      await _sendReaderVolumeKey('down');
      await _sendReaderVolumeKey('down');
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      await tester.pump(const Duration(milliseconds: 180));

      expect(find.text('第 2 / 3 章'), findsOneWidget);
      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.controller!.page, closeTo(1, 0.01));
    },
  );

  testWidgets('opening the directory discards queued volume navigation', (
    tester,
  ) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{}', 200);
        return http.Response(
          jsonEncode(_longChapterPayloadFor(1)),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
      volumeKeyReadingEnabled: true,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    final pageView = tester.widget<PageView>(find.byType(PageView));
    final controller = pageView.controller!;
    await _sendReaderVolumeKey('down');
    await _sendReaderVolumeKey('down');
    await tester.tap(
      find.byKey(const ValueKey('reader-directory-button')).hitTestable(),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.byKey(const ValueKey('reader-chapter-dialog')), findsOneWidget);
    expect(controller.page, closeTo(1, 0.01));
  });

  testWidgets('volume keys move up and down in continuous reading mode', (
    tester,
  ) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{}', 200);
        return http.Response(
          jsonEncode(_longChapterPayloadFor(1)),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
      flowMode: ReaderFlowMode.continuous,
      volumeKeyReadingEnabled: true,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('reader-continuous-translated')),
    );
    final controller = list.controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));

    await _sendReaderVolumeKey('down');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    final afterDown = controller.offset;
    expect(afterDown, greaterThan(0));

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await _sendReaderVolumeKey('up');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    expect(controller.offset, lessThan(afterDown));
  });

  testWidgets('rapid volume presses queue continuous page scrolling', (
    tester,
  ) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{}', 200);
        return http.Response(
          jsonEncode(_longChapterPayloadFor(1)),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
      flowMode: ReaderFlowMode.continuous,
      volumeKeyReadingEnabled: true,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('reader-continuous-translated')),
    );
    final controller = list.controller!;
    final viewport = controller.position.viewportDimension;

    await _sendReaderVolumeKey('down');
    await _sendReaderVolumeKey('down');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pump(const Duration(milliseconds: 180));

    expect(controller.offset, greaterThan(viewport * 1.5));
  });

  testWidgets(
    'one volume press continues into a chapter still being prefetched',
    (tester) async {
      final releaseSecondChapter = Completer<void>();
      final harness = await _Harness.create(
        MockClient((request) async {
          if (request.method == 'PUT') return http.Response('{}', 200);
          final chapterIndex = int.parse(request.url.pathSegments.last);
          if (chapterIndex == 2) await releaseSecondChapter.future;
          final payload = chapterIndex == 2
              ? _longChapterPayloadFor(chapterIndex)
              : _chapterPayloadFor(chapterIndex);
          return http.Response(
            jsonEncode(payload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
        detail: _threeChapterDetail,
        flowMode: ReaderFlowMode.continuous,
        volumeKeyReadingEnabled: true,
      );
      addTearDown(harness.dispose);
      addTearDown(() {
        if (!releaseSecondChapter.isCompleted) releaseSecondChapter.complete();
      });

      await tester.pumpWidget(harness.widget);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('reader-continuous-translated')),
      );
      final controller = list.controller!;

      await _sendReaderVolumeKey('down');
      releaseSecondChapter.complete();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));

      expect(find.textContaining('第二章正文段落'), findsWidgets);
      expect(controller.offset, greaterThan(0));
    },
  );

  testWidgets('volume up at a chapter start opens the previous chapter end', (
    tester,
  ) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{}', 200);
        final chapterIndex = int.parse(request.url.pathSegments.last);
        return http.Response(
          jsonEncode(_longChapterPayloadFor(chapterIndex)),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
      detail: _threeChapterDetail,
      initialChapterIndex: 2,
      flowMode: ReaderFlowMode.continuous,
      volumeKeyReadingEnabled: true,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await _sendReaderVolumeKey('up');
    await tester.pump();
    await tester.pump();

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('reader-continuous-translated')),
    );
    expect(find.text('第 1 / 3 章'), findsOneWidget);
    expect(list.controller!.offset, greaterThan(0));
  });

  testWidgets(
    'prefetches the next chapter and switches without a loading page',
    (tester) async {
      final requestedChapters = <int>[];
      final prefetchRequests = <int>[];
      final releaseFirstChapter = Completer<void>();
      final harness = await _Harness.create(
        MockClient((request) async {
          if (request.method == 'PUT') {
            return http.Response('{}', 200);
          }
          final chapterIndex = int.parse(request.url.pathSegments.last);
          requestedChapters.add(chapterIndex);
          if (request.url.queryParameters['prefetch'] == 'true') {
            prefetchRequests.add(chapterIndex);
          }
          if (chapterIndex == 1) await releaseFirstChapter.future;
          return http.Response(
            jsonEncode(_chapterPayloadFor(chapterIndex)),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
        detail: _threeChapterDetail,
      );
      addTearDown(harness.dispose);
      addTearDown(() {
        if (!releaseFirstChapter.isCompleted) releaseFirstChapter.complete();
      });

      await tester.pumpWidget(harness.widget);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      expect(requestedChapters, containsAll(<int>[1, 2]));
      expect(prefetchRequests, contains(2));
      expect(prefetchRequests, isNot(contains(1)));

      releaseFirstChapter.complete();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      expect(find.textContaining('第一章正文。'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reader-next-button')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 150));

      expect(find.text('正在打开章节'), findsNothing);
      expect(find.textContaining('第二章正文。'), findsOneWidget);
      expect(requestedChapters.where((index) => index == 2), hasLength(1));
      expect(requestedChapters, contains(3));
    },
  );

  testWidgets('opens reader settings and quickly jumps from the directory', (
    tester,
  ) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{}', 200);
        return http.Response(
          jsonEncode(
            _chapterPayloadFor(int.parse(request.url.pathSegments.last)),
          ),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
      detail: _threeChapterDetail,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('reader-settings-panel')), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);
    expect(find.text('行间距'), findsOneWidget);
    expect(find.text('阅读主题'), findsOneWidget);
    expect(find.text('音量键滑动 / 翻页'), findsNothing);
    expect(find.text('阅读方式'), findsNothing);
    expect(find.text('翻页动效'), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(RepaintBoundary), findsWidgets);
    final bottomControls = find.byKey(const ValueKey('reader-bottom-controls'));
    expect(tester.widget<AnimatedSlide>(bottomControls).offset, Offset.zero);
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .descendant(
                  of: bottomControls,
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isFalse,
    );
    final eyeCare = find.byKey(const ValueKey('reader-palette-eyeCare'));
    await tester.ensureVisible(eyeCare);
    await tester.tap(eyeCare);
    final fontIncrease = find.byKey(const ValueKey('reader-font-increase'));
    await tester.ensureVisible(fontIncrease);
    await tester.tap(fontIncrease);
    final relaxedSpacing = find.byKey(const ValueKey('reader-spacing-relaxed'));
    await tester.ensureVisible(relaxedSpacing);
    await tester.tap(relaxedSpacing);
    await tester.pump();
    expect(harness.appState.readerPaletteMode, ReaderPaletteMode.eyeCare);
    expect(harness.appState.readerFontSize, 20);
    expect(harness.appState.readerLineSpacing, ReaderLineSpacing.relaxed);

    await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-settings-panel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('reader-more-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-options-panel')), findsOneWidget);
    expect(find.text('音量键滑动 / 翻页'), findsOneWidget);
    final fadeAnimation = find.byKey(const ValueKey('reader-animation-fade'));
    await tester.ensureVisible(fadeAnimation);
    await tester.tap(fadeAnimation);
    await tester.pump();
    expect(harness.appState.readerPageAnimation, ReaderPageAnimation.fade);
    expect(harness.appState.readerFlowMode, ReaderFlowMode.paged);

    final continuousMode = find.byKey(const ValueKey('reader-mode-continuous'));
    await tester.ensureVisible(continuousMode);
    await tester.tap(continuousMode);
    await tester.pump();
    expect(harness.appState.readerFlowMode, ReaderFlowMode.continuous);
    await tester.tap(find.byKey(const ValueKey('reader-options-close')));
    await tester.pumpAndSettle();
    final continuousReader = find.byKey(
      const ValueKey('reader-continuous-translated'),
    );
    expect(continuousReader, findsOneWidget);
    final continuousList = tester.widget<ListView>(continuousReader);
    final continuousBody = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.textSpan?.toPlainText(includePlaceholders: false) ==
                '第一章正文。',
      ),
    );
    expect(continuousBody.textAlign, TextAlign.justify);
    final contentPadding = continuousList.padding! as EdgeInsets;
    expect(contentPadding.bottom, lessThan(80));
    expect(contentPadding.horizontal, closeTo(160, 0.01));
    expect(
      continuousList.scrollCacheExtent,
      const ScrollCacheExtent.pixels(420),
    );
    expect(tester.getSize(continuousReader).height, 600);

    expect(
      find.byKey(const ValueKey('reader-directory-button')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reader-directory-button')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-chapter-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-chapter-3')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.textContaining('第三章正文。'), findsOneWidget);
    expect(find.text('第 3 / 3 章'), findsOneWidget);
  });

  testWidgets('a short tap on selectable text hides and restores controls', (
    tester,
  ) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{}', 200);
        return http.Response(
          jsonEncode(_chapterPayload),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    final topControls = find.byKey(const ValueKey('reader-top-controls'));
    final bottomControls = find.byKey(const ValueKey('reader-bottom-controls'));
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<AnimatedSlide>(topControls).offset.dy, lessThan(0));
    expect(
      tester.widget<AnimatedSlide>(bottomControls).offset.dy,
      greaterThan(0),
    );

    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<AnimatedSlide>(topControls).offset, Offset.zero);
    expect(tester.widget<AnimatedSlide>(bottomControls).offset, Offset.zero);
  });

  testWidgets(
    'continuous reader keeps short and wrapped paragraph starts globally aligned',
    (tester) async {
      const shortBody = '短段。';
      const longBody =
          '这是一个足够长的正文段落，用于覆盖不同 Android 厂商字体宽度与换行结果，并验证段落外层不会按固有宽度收缩后分别居中。';
      final payload = <String, Object?>{
        ..._chapterPayload,
        'content': '$shortBody\n$longBody',
        'paragraphs': const <String>[shortBody, longBody],
      };
      final harness = await _Harness.create(
        MockClient((request) async {
          if (request.method == 'PUT') return http.Response('{}', 200);
          return http.Response(
            jsonEncode(payload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
        flowMode: ReaderFlowMode.continuous,
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(harness.widget);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      Finder paragraphFinder(String body) => find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText &&
                widget.textSpan?.toPlainText(includePlaceholders: false) ==
                    body,
          );
      expect(
        tester.getSize(paragraphFinder(shortBody)).width,
        closeTo(tester.getSize(paragraphFinder(longBody)).width, 0.01),
      );
      expect(
        tester.getTopLeft(paragraphFinder(shortBody)).dx,
        closeTo(tester.getTopLeft(paragraphFinder(longBody)).dx, 0.01),
      );
    },
  );

  testWidgets(
    'Android reader hides only the top system overlay and restores it',
    (tester) async {
      final platformCalls = <MethodCall>[];
      final readerPlatformCalls = <MethodCall>[];
      const readerChannel = MethodChannel('qingjuan/reader');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(readerChannel, (call) async {
        readerPlatformCalls.add(call);
        return null;
      });
      addTearDown(() {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        messenger.setMockMethodCallHandler(readerChannel, null);
      });
      final harness = await _Harness.create(
        MockClient((request) async {
          if (request.method == 'PUT') return http.Response('{}', 200);
          return http.Response(
            jsonEncode(_chapterPayload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(harness.widget);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      platformCalls.clear();
      readerPlatformCalls.clear();

      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 300));

      final modeCalls = platformCalls.where(
        (call) => call.method == 'SystemChrome.setEnabledSystemUIMode',
      );
      expect(modeCalls, isNotEmpty);
      expect(
        modeCalls.map((call) => '${call.arguments}').join('\n'),
        contains('SystemUiMode.edgeToEdge'),
      );
      expect(
        platformCalls.any(
          (call) => call.method == 'SystemChrome.setEnabledSystemUIOverlays',
        ),
        isFalse,
      );
      expect(
        readerPlatformCalls.any((call) {
          if (call.method != 'setReaderSystemUi') return false;
          final arguments = call.arguments as Map<Object?, Object?>?;
          return arguments?['enabled'] == true &&
              arguments?['backgroundColor'] is int &&
              arguments?['backgroundColor'] != 0xFF000000;
        }),
        isTrue,
      );
      final readerSurface = find.byKey(const ValueKey('reader-mobile-surface'));
      expect(tester.getTopLeft(readerSurface), Offset.zero);
      expect(tester.getSize(readerSurface), const Size(800, 600));
      final surfaceDecoration = tester
          .widget<AnimatedContainer>(readerSurface)
          .decoration as BoxDecoration;
      expect(surfaceDecoration.color, isNot(const Color(0xFF000000)));

      platformCalls.clear();
      readerPlatformCalls.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        platformCalls.any(
          (call) =>
              call.method == 'SystemChrome.setEnabledSystemUIMode' &&
              '${call.arguments}'.contains('SystemUiMode.edgeToEdge'),
        ),
        isTrue,
      );
      expect(
        readerPlatformCalls.any((call) {
          if (call.method != 'setReaderSystemUi') return false;
          final arguments = call.arguments as Map<Object?, Object?>?;
          return arguments?['enabled'] == true &&
              arguments?['backgroundColor'] is int;
        }),
        isTrue,
      );

      platformCalls.clear();
      readerPlatformCalls.clear();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(
        platformCalls.any(
          (call) =>
              call.method == 'SystemChrome.setEnabledSystemUIMode' &&
              '${call.arguments}'.contains('SystemUiMode.edgeToEdge'),
        ),
        isTrue,
      );
      expect(
        readerPlatformCalls.any((call) {
          if (call.method != 'setReaderSystemUi') return false;
          final arguments = call.arguments as Map<Object?, Object?>?;
          return arguments?['enabled'] == false &&
              arguments?['backgroundColor'] is int;
        }),
        isTrue,
      );
    },
  );

  testWidgets(
    'reader controls remain usable at 320 wide and 200 percent text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 740);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final harness = await _Harness.create(
        MockClient((request) async {
          if (request.method == 'PUT') return http.Response('{}', 200);
          return http.Response(
            jsonEncode(_chapterPayload),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(harness.dispose);
      final app = harness.widget as FluentApp;
      await tester.pumpWidget(
        FluentApp(
          theme: app.theme,
          home: app.home,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
      await tester.pumpAndSettle();
      expect(find.text('字体大小'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final flow in ReaderFlowMode.values) {
    testWidgets(
      'reader restores saved position across content versions in ${flow.name}',
      (tester) async {
        final detail = BookDetail(
          book: _detail.book,
          author: _detail.author,
          synopsis: _detail.synopsis,
          totalWords: 4000,
          downloadedCount: 1,
          translatedCount: 1,
          progress: const ReadingProgress(chapterIndex: 1, scrollRatio: .6),
          chapters: _detail.chapters,
        );
        final harness = await _Harness.create(
          MockClient((request) async {
            if (request.method == 'PUT') return http.Response('{}', 200);
            return http.Response(
              jsonEncode(_longChapterPayloadFor(1)),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
          detail: detail,
          flowMode: flow,
        );
        addTearDown(harness.dispose);
        await tester.pumpWidget(harness.widget);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        if (flow == ReaderFlowMode.paged) {
          expect(
            tester
                .widget<PageView>(find.byType(PageView).first)
                .controller!
                .page!,
            greaterThan(0),
          );
        } else {
          expect(
            tester
                .widget<ListView>(
                  find.byKey(const ValueKey('reader-continuous-translated')),
                )
                .controller!
                .offset,
            greaterThan(0),
          );
        }
        await tester.tap(find.byKey(const ValueKey('reader-content-mode')));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        if (flow == ReaderFlowMode.paged) {
          expect(
            tester
                .widget<PageView>(find.byType(PageView).first)
                .controller!
                .page!,
            greaterThan(0),
          );
        } else {
          expect(
            tester
                .widget<ListView>(
                  find.byKey(const ValueKey('reader-continuous-original')),
                )
                .controller!
                .offset,
            greaterThan(0),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('manga reader keeps failed-image recovery local and zoomable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final detail = BookDetail.fromJson({
      'book': {
        'id': 'book-1',
        'title': '漫画阅读测试',
        'bookKind': '漫画',
        'language': '中文',
        'chapterCount': 1,
      },
      'chapters': [
        {'index': 1, 'title': '第一话', 'downloaded': true, 'imageCount': 1},
      ],
    });
    final payload = {
      ..._chapterPayload,
      'content': '',
      'paragraphs': <String>[],
      'imageSources': ['https://example.invalid/manga-page.png'],
    };
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{}', 200);
        return http.Response(
          jsonEncode(payload),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
      detail: detail,
    );
    addTearDown(harness.dispose);
    await harness.appState.setReaderPaletteMode(ReaderPaletteMode.white);
    await tester.pumpWidget(
      RepaintBoundary(key: _readerPreviewKey, child: harness.widget),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('重试图片'), findsOneWidget);
    await _saveReaderPreview(tester, 'manga-image-error-light');
    await tester.tap(find.byKey(const ValueKey('reader-night-button')));
    await tester.pumpAndSettle();
    await _saveReaderPreview(tester, 'manga-image-error-dark');
    await tester.tap(find.text('重试图片'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
    expect(find.text('第 1 张图片未能加载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader settings fit a narrow phone viewport', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'PUT') return http.Response('{}', 200);
        return http.Response(
          jsonEncode(_captureReader ? _readerPreviewPayload : _chapterPayload),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );
    addTearDown(harness.dispose);
    await harness.appState.setReaderPaletteMode(ReaderPaletteMode.white);

    await tester.pumpWidget(
      RepaintBoundary(key: _readerPreviewKey, child: harness.widget),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    if (_captureReader) {
      await tester.pump(const Duration(seconds: 5));
      await _saveReaderPreview(tester, 'reader-light');
      await tester.tapAt(const Offset(195, 420));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('reader-settings-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-palette-night')), findsOneWidget);
    await _saveReaderPreview(tester, 'reader-settings-light');
    await tester.tap(find.byKey(const ValueKey('reader-palette-night')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(harness.appState.readerPaletteMode, ReaderPaletteMode.night);
    expect(find.byType(BackdropFilter), findsNothing);
    await _saveReaderPreview(tester, 'reader-settings-dark');
    if (_captureReader) {
      await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 5));
      await _saveReaderPreview(tester, 'reader-dark');
    }
    expect(tester.takeException(), isNull);
  });
}

Future<void> _saveReaderPreview(WidgetTester tester, String name) async {
  if (!_captureReader) return;
  await tester.pumpAndSettle();
  final boundary = _readerPreviewKey.currentContext!.findRenderObject()!
      as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/mobile-ui-preview');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

final _readerPreviewPayload = <String, Object?>{
  ..._chapterPayload,
  'paragraphs': <String>[
    '清晨的光落在窗边，照亮了昨夜未曾合上的书。街道还没有完全醒来，远处偶尔传来一两声自行车铃，像一段故事轻轻翻过的页脚。',
    '她倒了一杯温水，坐回那把熟悉的椅子。书中的旅人正要离开小镇，带着一只旧皮箱和一张没有写完的明信片。',
    '有时候，阅读并不需要抵达什么地方。只要在文字之间停留片刻，便能从日常的匆忙里，找回一点属于自己的安静。',
    '窗外的树叶动了起来。她把书签往后移了一页，继续读下去。',
  ],
};

Future<void> _sendReaderVolumeKey(String direction) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'qingjuan/reader',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('volumeKey', direction),
    ),
    null,
  );
}

const _detail = BookDetail(
  book: Book(
    id: 'book-1',
    title: '测试作品',
    sourceUrl: 'https://example.com/book-1',
    kind: '长小说',
    language: '中文',
    status: '已导入',
    chapterCount: 1,
    translated: false,
    synopsis: '',
    lastReadChapterIndex: 1,
  ),
  author: '测试作者',
  synopsis: '',
  totalWords: 8,
  downloadedCount: 1,
  translatedCount: 0,
  progress: ReadingProgress(chapterIndex: 1, scrollRatio: 0),
  chapters: <Chapter>[
    Chapter(
      index: 1,
      title: '第一章',
      downloaded: true,
      translated: false,
      wordCount: 8,
      imageCount: 0,
    ),
  ],
);

const _chapterPayload = <String, Object?>{
  'chapter': <String, Object?>{
    'index': 1,
    'title': '第一章',
    'downloaded': true,
    'translated': false,
    'wordCount': 8,
    'imageCount': 0,
  },
  'content': '这是章节正文。',
  'paragraphs': <String>['这是章节正文。'],
  'mode': 'translated',
  'translatedAvailable': false,
  'imageSources': <String>[],
  'pageTranslations': <String>[],
};

const _threeChapterDetail = BookDetail(
  book: Book(
    id: 'book-1',
    title: '测试作品',
    sourceUrl: 'https://example.com/book-1',
    kind: '长小说',
    language: '中文',
    status: '已导入',
    chapterCount: 3,
    translated: false,
    synopsis: '',
    lastReadChapterIndex: 1,
  ),
  author: '测试作者',
  synopsis: '',
  totalWords: 24,
  downloadedCount: 3,
  translatedCount: 0,
  progress: ReadingProgress(chapterIndex: 1, scrollRatio: 0),
  chapters: <Chapter>[
    Chapter(
      index: 1,
      title: '第一章',
      downloaded: true,
      translated: false,
      wordCount: 8,
      imageCount: 0,
    ),
    Chapter(
      index: 2,
      title: '第二章',
      downloaded: true,
      translated: false,
      wordCount: 8,
      imageCount: 0,
    ),
    Chapter(
      index: 3,
      title: '第三章',
      downloaded: true,
      translated: false,
      wordCount: 8,
      imageCount: 0,
    ),
  ],
);

Map<String, Object?> _chapterPayloadFor(int chapterIndex) => <String, Object?>{
      'chapter': <String, Object?>{
        'index': chapterIndex,
        'title': '第${<String>['一', '二', '三'][chapterIndex - 1]}章',
        'downloaded': true,
        'translated': false,
        'wordCount': 8,
        'imageCount': 0,
      },
      'content': '第${<String>['一', '二', '三'][chapterIndex - 1]}章正文。',
      'paragraphs': <String>[
        '第${<String>['一', '二', '三'][chapterIndex - 1]}章正文。',
      ],
      'mode': 'translated',
      'translatedAvailable': false,
      'imageSources': <String>[],
      'pageTranslations': <String>[],
    };

Map<String, Object?> _longChapterPayloadFor(int chapterIndex) {
  final chapterName = <String>['一', '二', '三'][chapterIndex - 1];
  final paragraphs = List<String>.generate(
    80,
    (index) => '第$chapterName章正文段落 ${index + 1}，用于验证连续滚动和分页。',
  );
  return <String, Object?>{
    ..._chapterPayloadFor(chapterIndex),
    'content': paragraphs.join('\n'),
    'paragraphs': paragraphs,
  };
}

class _Harness {
  _Harness({
    required this.widget,
    required this.appState,
    required this.api,
    required this.library,
    required this.sources,
    required this.tasks,
    required this.settings,
  });

  static Future<_Harness> create(
    http.Client client, {
    BookDetail detail = _detail,
    TargetPlatform targetPlatform = TargetPlatform.android,
    int initialChapterIndex = 1,
    ReaderFlowMode flowMode = ReaderFlowMode.paged,
    bool volumeKeyReadingEnabled = false,
  }) async {
    final appState = AppState(await SharedPreferences.getInstance());
    await appState.setReaderFlowMode(flowMode);
    await appState.setVolumeKeyReadingEnabled(volumeKeyReadingEnabled);
    final api = ApiClient(() => appState.backendUrl, client: client);
    final backend = BackendConnectionManager(api, isConfigured: () => false);
    final library = LibraryController(api);
    final sources = SourcesController(api);
    final tasks = TasksController(api);
    final settings = SettingsController(api);
    final readerTheme = buildQingJuanTheme(
      Brightness.light,
      platform: targetPlatform,
    );
    final widget = FluentApp(
      debugShowCheckedModeBanner: false,
      theme: _captureReader
          ? readerTheme.copyWith(
              typography: readerTheme.typography.apply(fontFamily: 'Roboto'),
            )
          : readerTheme,
      builder: !_captureReader
          ? null
          : (context, child) => DefaultTextStyle(
                style: const TextStyle(fontFamily: 'Roboto'),
                child: child!,
              ),
      home: UiPlatformScope(
        platform: targetPlatform,
        child: AppScope(
          appState: appState,
          api: api,
          backend: backend,
          auth: AuthController.localAdministrator(api),
          library: library,
          sources: sources,
          tasks: tasks,
          settings: settings,
          child: ReaderPage(
            detail: detail,
            initialChapterIndex: initialChapterIndex,
          ),
        ),
      ),
    );
    return _Harness(
      widget: widget,
      appState: appState,
      api: api,
      library: library,
      sources: sources,
      tasks: tasks,
      settings: settings,
    );
  }

  final Widget widget;
  final AppState appState;
  final ApiClient api;
  final LibraryController library;
  final SourcesController sources;
  final TasksController tasks;
  final SettingsController settings;

  void dispose() {
    library.dispose();
    sources.dispose();
    tasks.dispose();
    settings.dispose();
    api.close();
    appState.dispose();
  }
}
