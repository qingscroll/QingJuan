import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/features/detail/book_detail_page.dart';
import 'package:qingjuan/features/detail/detail_action_bar.dart';
import 'package:qingjuan/features/translation_quality/translation_quality_page.dart';
import 'package:qingjuan/shared/responsive.dart';

import '../../helpers/reliability_harness.dart';
import '../../helpers/ui_review_capture.dart';

const _bookId = 'mist-book';
const _synopsis = '沿海小城的旧书店收到一封来自三十年前的信。年轻的修书师循着书页上的批注，'
    '寻找一座已从地图上消失的灯塔。潮汐、航海日志与陌生人的来访，让一段被遗忘的旅程重新展开。'
    '这是一个关于记忆、相遇与重新出发的故事。';
const _capabilities = {
  'libraryMetadata': true,
  'storageManagement': true,
  'bookUpdates': true,
  'translationQuality': true,
};

Map<String, Object?> _detail({bool manga = false}) => {
      'book': {
        'id': _bookId,
        'title': '雾海书简',
        'bookKind': manga ? '漫画' : '长小说',
        'language': '英语',
        'sourceUrl': 'https://books.example.test/mist',
        'chapterCount': 3,
        'synopsis': _synopsis,
      },
      'author': '林间 · 远行',
      'synopsis': _synopsis,
      'totalWords': 247800,
      'downloadedChapterCount': 2,
      'translatedChapterCount': 1,
      'chapters': [
        {'index': 3, 'title': '潮汐带来的信', 'downloaded': true, 'translated': true},
        {
          'index': 9,
          'title': '旧书页里的航线',
          'downloaded': true,
          'translated': false
        },
        {
          'index': 12,
          'title': '灯塔以北',
          'downloaded': false,
          'translated': false
        },
      ],
    };

http.Response _json(Object body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
        headers: {'content-type': 'application/json'});

void main() {
  setUpAll(loadUiReviewFonts);

  _testDesktop(
      'management menu closes when opening and returning from glossary',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var glossaryLoads = 0;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/glossary')) {
        glossaryLoads++;
        return _json({'bookId': _bookId, 'revision': 0, 'entries': []});
      }
      return _json(_detail());
    }));
    addTearDown(harness.dispose);
    harness.scope.backend.capabilities = _capabilities;
    await tester.pumpWidget(harness.widget(const UiPlatformScope(
        platform: TargetPlatform.windows,
        child: BookDetailPage(bookId: _bookId))));
    await tester.pumpAndSettle();
    expect(find.text('继续阅读'), findsOneWidget);
    expect(find.text('听小说'), findsOneWidget);
    expect(find.text('术语与人名'), findsNothing);
    await tester.tap(find.text('作品管理'));
    await tester.pumpAndSettle();
    for (final label in ['编辑作品信息', '术语与人名', '译文校对', '连载追更', '存储空间']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('术语与人名'));
    await tester.pumpAndSettle();
    expect(find.byType(TranslationQualityPage), findsOneWidget);
    expect(glossaryLoads, 1);
    expect(find.byKey(const ValueKey('quality-add-term')), findsOneWidget);
    expect(find.text('作品管理'), findsNothing);
    await tester.tap(find.byIcon(FluentIcons.back));
    await tester.pumpAndSettle();
    expect(find.text('作品管理'), findsOneWidget);
    expect(find.text('编辑作品信息'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _testDesktop('chapter toolbar preserves selection for export and queued work',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final queued = Completer<http.Response>();
    final translated = <List<int>>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/chapters/translate')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        translated.add((body['chapterIndexes'] as List).cast<int>());
        return queued.future;
      }
      if (request.url.path.endsWith('/tasks')) return _json([]);
      return _json(_detail());
    }));
    addTearDown(harness.dispose);
    harness.scope.backend.capabilities = _capabilities;
    await tester.pumpWidget(harness.widget(const UiPlatformScope(
        platform: TargetPlatform.windows,
        child: BookDetailPage(bookId: _bookId))));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(DetailChapterToolbar), matching: find.text('全选章节')),
        findsOneWidget);
    await tester.tap(find.text('全选章节'));
    await tester.pump();
    expect(find.text('已选择 3 章'), findsOneWidget);
    expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((checkbox) => checkbox.checked == true),
        isTrue);
    await tester.tap(find.text('取消全选'));
    await tester.pump();
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    expect(find.text('已选择 1 章'), findsOneWidget);
    await tester.tap(find.text('下载所选'));
    await tester.pumpAndSettle();
    expect(find.text('导出所选章节'), findsOneWidget);
    expect(find.text('EPUB'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译所选'));
    await tester.pump();
    expect(translated, [
      [9]
    ]);
    expect(tester.widget<DropDownButton>(find.byType(DropDownButton)).disabled,
        isTrue);
    for (final label in ['下载所选', '翻译所选']) {
      expect(
          tester
              .widget<Button>(find.ancestor(
                  of: find.text(label), matching: find.byType(Button)))
              .onPressed,
          isNull);
    }
    expect(
        tester
            .widget<FilledButton>(find.ancestor(
                of: find.text('继续阅读'), matching: find.byType(FilledButton)))
            .onPressed,
        isNotNull);
    queued.complete(_json({
      'id': 'task-1',
      'bookId': _bookId,
      'taskType': 'translate',
      'status': 'queued',
      'totalCount': 1,
      'completedCount': 0,
      'progress': 0
    }));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 章'), findsOneWidget);
    expect(tester.widget<DropDownButton>(find.byType(DropDownButton)).disabled,
        isFalse);
    expect(tester.takeException(), isNull);
  });

  _testDesktop(
      'unavailable management capabilities and manga controls stay hidden',
      (tester) async {
    final harness = await ReliabilityHarness.create(
        MockClient((_) async => _json(_detail(manga: true))));
    addTearDown(harness.dispose);
    harness.scope.backend.capabilities = {'translationQuality': true};
    await tester.pumpWidget(harness.widget(const UiPlatformScope(
        platform: TargetPlatform.windows,
        child: BookDetailPage(bookId: _bookId))));
    await tester.pumpAndSettle();
    expect(find.text('作品管理'), findsNothing);
    expect(find.text('听小说'), findsNothing);
    expect(find.text('继续阅读'), findsOneWidget);
    expect(find.text('翻译全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    ('wide', const Size(1280, 900), 1.0),
    ('narrow-200', const Size(640, 1000), 2.0),
  ]) {
    _testDesktop('desktop detail layout ${scenario.$1}', (tester) async {
      tester.view.physicalSize = scenario.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      final harness = await ReliabilityHarness.create(
          MockClient((_) async => _json(_detail())));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities = _capabilities;
      await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: harness.widget(
              const UiPlatformScope(
                  platform: TargetPlatform.windows,
                  child: BookDetailPage(bookId: _bookId)),
              textScale: scenario.$3)));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text(_synopsis)).maxLines, isNull);
      expect(tester.takeException(), isNull);
      await captureUi(tester, boundary, 'detail-${scenario.$1}');
      await tester.ensureVisible(find.byType(DetailActionBar));
      await tester.pumpAndSettle();
      await tester.tap(find.text('作品管理'));
      await tester.pumpAndSettle();
      for (final label in ['编辑作品信息', '术语与人名', '译文校对', '连载追更', '存储空间']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await captureUi(tester, boundary, 'detail-${scenario.$1}-menu');
    });
  }
}

void _testDesktop(String description, WidgetTesterCallback callback) =>
    testWidgets(description, callback,
        variant: TargetPlatformVariant.only(TargetPlatform.windows));
