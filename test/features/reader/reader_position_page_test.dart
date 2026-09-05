import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('closing and reopening restores the same chapter and exact page',
      (tester) async {
    final server = _ProgressServer();
    final harness = await _ReaderHarness.create(server, ReaderFlowMode.paged);
    addTearDown(harness.dispose);
    await _open(tester, harness, server);
    final pages = tester.widget<PageView>(find.byType(PageView)).controller!;
    pages.jumpToPage(3);
    await tester.pump();
    // Leave before the debounce expires: disposal must capture the current page.
    await _close(tester);

    final saved = server.writes.last;
    expect(saved['chapterIndex'], 2);
    expect(saved['pageIndex'], 3);
    expect(saved['pageCount'], greaterThan(3));
    expect(saved['layoutKey'], isNotEmpty);
    expect(saved['contentMode'], 'translated');
    expect(saved['characterOffset'], greaterThan(0));

    await _open(tester, harness, server);
    final restored = tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(restored.page, closeTo(3, .01));
    await tester.pump(const Duration(milliseconds: 500));
    expect(server.writes.last['chapterIndex'], 2);
    expect(server.writes.last['layoutKey'], saved['layoutKey']);
    expect(server.writes.last['pageIndex'], 3);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets(
      'same-chapter scroll saves anchors and restores the visible paragraph',
      (tester) async {
    final server = _ProgressServer();
    final harness =
        await _ReaderHarness.create(server, ReaderFlowMode.continuous);
    addTearDown(harness.dispose);
    await _open(tester, harness, server);
    await tester.pump(const Duration(milliseconds: 500));
    server.writes.clear();
    final list = find.byKey(const ValueKey('reader-continuous-translated'));
    final controller = tester.widget<ListView>(list).controller!;

    controller.jumpTo(680);
    await tester.pump(const Duration(milliseconds: 180));
    controller.jumpTo(1080);
    await tester.pump(const Duration(milliseconds: 180));
    expect(server.writes, isEmpty,
        reason: 'continuous scrolling must debounce writes');
    await tester.pump(const Duration(milliseconds: 500));
    expect(server.writes, hasLength(1));
    final first = server.writes.single;
    expect(first['chapterIndex'], 2);
    expect(first['anchorType'], 'paragraph');
    expect(first['anchorIndex'], greaterThan(0));
    expect(first['anchorOffsetRatio'], inInclusiveRange(0.0, 1.0));

    controller.jumpTo(1593);
    await tester.pump();
    final writesBeforeBackground = server.writes.length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(server.writes.length, greaterThan(writesBeforeBackground));
    final background = Map<String, dynamic>.from(server.writes.last);
    expect(background['chapterIndex'], 2);
    expect(background['anchorIndex'], greaterThan(first['anchorIndex'] as int));
    final paragraph = server.paragraphs(2)[background['anchorIndex'] as int];
    final paragraphFinder = find.textContaining(paragraph);
    expect(paragraphFinder, findsOneWidget);
    final beforeY = tester.getTopLeft(paragraphFinder).dy;
    final beforeOffset = controller.offset;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _close(tester);

    await _open(tester, harness, server);
    final restoredController = tester.widget<ListView>(list).controller!;
    expect(find.textContaining(paragraph), findsOneWidget);
    expect(tester.getTopLeft(find.textContaining(paragraph)).dy,
        closeTo(beforeY, 1));
    expect(restoredController.offset, closeTo(beforeOffset, 1));
    await tester.pump(const Duration(milliseconds: 500));
    expect(server.writes.last['anchorIndex'], background['anchorIndex']);
    expect(server.writes.last['anchorOffsetRatio'],
        closeTo(background['anchorOffsetRatio'] as double, .01));
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets(
      'failed initial chapter load never overwrites the previous position',
      (tester) async {
    final server = _ProgressServer()
      ..failChapters = true
      ..progress = const ReadingProgress(
        chapterIndex: 2,
        scrollRatio: .6,
        pageIndex: 4,
        pageCount: 8,
        layoutKey: 'previous-layout',
        contentMode: 'translated',
      );
    final harness = await _ReaderHarness.create(server, ReaderFlowMode.paged);
    addTearDown(harness.dispose);
    await _open(tester, harness, server);
    expect(find.text('暂时无法加载'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 600));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _close(tester);
    expect(server.writes, isEmpty);
    expect(server.progress.chapterIndex, 2);
    expect(server.progress.pageIndex, 4);
    expect(server.progress.scrollRatio, .6);
    expect(tester.takeException(), isNull);
  });

  testWidgets('font changes and live resize preserve the current text position',
      (tester) async {
    final server = _ProgressServer();
    final harness = await _ReaderHarness.create(server, ReaderFlowMode.paged);
    addTearDown(harness.dispose);
    await _open(tester, harness, server);
    tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(6);
    await tester.pump(const Duration(milliseconds: 500));
    final oldPage = server.writes.last['pageIndex'] as int;
    final oldCharacter = server.writes.last['characterOffset'] as int;
    await _close(tester);

    await harness.state.setReaderFontSize(28);
    await _open(tester, harness, server);
    await tester.pump(const Duration(milliseconds: 500));
    expect(server.writes.last['pageIndex'], greaterThan(oldPage));
    await _expectCurrentPageContains(tester, server, oldCharacter);

    final beforeResize = server.writes.last['characterOffset'] as int;
    await tester.binding.setSurfaceSize(const Size(320, 640));
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 500));
    await _expectCurrentPageContains(tester, server, beforeResize);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets(
      'distant paragraph anchor survives large differences in item height',
      (tester) async {
    final server = _ProgressServer()
      ..paragraphOverride = List.generate(80,
          (index) => '段落${index + 1}：${'不同高度的正文。' * [1, 36, 3, 60][index % 4]}')
      ..progress = const ReadingProgress(
        chapterIndex: 2,
        scrollRatio: .6,
        anchorType: 'paragraph',
        anchorIndex: 50,
        anchorOffsetRatio: .37,
        contentMode: 'translated',
      );
    final harness =
        await _ReaderHarness.create(server, ReaderFlowMode.continuous);
    addTearDown(harness.dispose);
    await _open(tester, harness, server);
    for (var frame = 0; frame < 45; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining(server.paragraphs(2)[50]), findsOneWidget);
    expect(server.writes, isNotEmpty);
    expect(server.writes.last['anchorIndex'], 50);
    expect(server.writes.last['anchorOffsetRatio'], closeTo(.37, .01));
    expect(tester.takeException(), isNull);
    await _close(tester);
  });
}

Future<void> _expectCurrentPageContains(
    WidgetTester tester, _ProgressServer server, int character) async {
  final saved = server.writes.last;
  final index = saved['pageIndex'] as int;
  expect(index, inInclusiveRange(0, (saved['pageCount'] as int) - 1));
  expect(saved['characterOffset'], lessThanOrEqualTo(character));
  tester
      .widget<PageView>(find.byType(PageView))
      .controller!
      .jumpToPage(index + 1);
  await tester.pump(const Duration(milliseconds: 500));
  expect(server.writes.last['characterOffset'], greaterThan(character),
      reason: 'the restored page must contain the old character anchor');
}

Future<void> _open(
    WidgetTester tester, _ReaderHarness harness, _ProgressServer server) async {
  await tester.binding.setSurfaceSize(const Size(420, 820));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(harness.widget(server.detail));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  // Restoring a distant lazy paragraph may require several measured frames.
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

class _ProgressServer {
  ReadingProgress progress =
      const ReadingProgress(chapterIndex: 2, scrollRatio: 0);
  final writes = <Map<String, dynamic>>[];
  bool failChapters = false;
  List<String>? paragraphOverride;

  List<String> paragraphs(int chapter) =>
      paragraphOverride ??
      List.generate(72,
          (index) => '第$chapter章段落${index + 1}：${'青卷阅读定位。' * (2 + index % 4)}');

  Future<http.Response> respond(http.Request request) async {
    if (request.method == 'PUT' && request.url.path.endsWith('/progress')) {
      final value = jsonDecode(request.body) as Map<String, dynamic>;
      writes.add(value);
      progress = ReadingProgress.fromJson({
        for (final entry in value.entries)
          'last${entry.key[0].toUpperCase()}${entry.key.substring(1)}':
              entry.value,
      });
      return http.Response('{}', 200);
    }
    if (failChapters) {
      return http.Response('{"detail":"章节暂不可用，请重试"}', 503);
    }
    final chapter = int.parse(request.url.pathSegments.last);
    return http.Response(
      jsonEncode({
        'chapter': {
          'index': chapter,
          'title': '第$chapter章',
          'downloaded': true
        },
        'content': paragraphs(chapter).join('\n'),
        'paragraphs': paragraphs(chapter),
        'mode': 'translated',
        'imageSources': <String>[],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  BookDetail get detail => BookDetail.fromJson({
        'book': {'id': 'position-book', 'title': '位置测试', 'chapterCount': 2},
        'chapters': [
          for (var chapter = 1; chapter <= 2; chapter++)
            {'index': chapter, 'title': '第$chapter章', 'downloaded': true},
        ],
      }).withProgress(progress);
}

extension on BookDetail {
  BookDetail withProgress(ReadingProgress saved) => BookDetail(
        book: book,
        author: author,
        synopsis: synopsis,
        totalWords: totalWords,
        downloadedCount: downloadedCount,
        translatedCount: translatedCount,
        progress: saved,
        chapters: chapters,
      );
}

class _ReaderHarness {
  _ReaderHarness(this.state, this.api)
      : backend = BackendConnectionManager(api, isConfigured: () => false),
        auth = AuthController.localAdministrator(api),
        library = LibraryController(api),
        sources = SourcesController(api),
        tasks = TasksController(api),
        settings = SettingsController(api);

  static Future<_ReaderHarness> create(
      _ProgressServer server, ReaderFlowMode mode) async {
    final state = AppState(await SharedPreferences.getInstance());
    await state.setReaderFlowMode(mode);
    return _ReaderHarness(state,
        ApiClient(() => state.backendUrl, client: MockClient(server.respond)));
  }

  final AppState state;
  final ApiClient api;
  final BackendConnectionManager backend;
  final AuthController auth;
  final LibraryController library;
  final SourcesController sources;
  final TasksController tasks;
  final SettingsController settings;

  Widget widget(BookDetail detail) => FluentApp(
        theme: buildQingJuanTheme(Brightness.light,
            platform: TargetPlatform.android),
        home: UiPlatformScope(
          platform: TargetPlatform.android,
          child: AppScope(
            appState: state,
            api: api,
            backend: backend,
            auth: auth,
            library: library,
            sources: sources,
            tasks: tasks,
            settings: settings,
            child: ReaderPage(
                detail: detail,
                initialChapterIndex: detail.progress.chapterIndex),
          ),
        ),
      );

  void dispose() {
    library.dispose();
    sources.dispose();
    tasks.dispose();
    settings.dispose();
    auth.dispose();
    backend.dispose();
    api.close();
    state.dispose();
  }
}
