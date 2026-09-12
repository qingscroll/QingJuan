import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/rendering.dart' show debugDisableShadows;
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/library/book_metadata_editor.dart';
import 'package:qingjuan/features/library/book_updates_page.dart';
import 'package:qingjuan/features/library/widgets/book_card.dart';
import 'package:qingjuan/features/library/widgets/desktop_library_view.dart';
import 'package:qingjuan/shared/responsive.dart';

import '../../helpers/reliability_harness.dart';
import '../../helpers/ui_review_capture.dart';

void main() {
  setUpAll(loadUiReviewFonts);

  testWidgets('more menu is keyboard reachable and commands never open reading',
      (tester) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    var opened = 0;
    var edited = 0;
    var updates = 0;
    await tester.pumpWidget(_desktop(
        harness,
        f.Center(
          child: f.SizedBox(
            width: 340,
            height: 232,
            child: BookCard(
              book: _book,
              onOpen: () => opened++,
              desktopActions: DesktopBookCardActions(
                  onEditMetadata: () => edited++,
                  onManageUpdates: () => updates++,
                  newChapterCount: 3),
            ),
          ),
        )));
    await tester.pumpAndSettle();
    expect(find.text('编辑信息'), findsNothing);
    expect(find.text('连载追更'), findsNothing);
    expect(find.text('新增 3 章'), findsOneWidget);
    expect(_tooltip('管理《${_book.title}》'), findsOneWidget);
    // Focus the native button, then use its normal keyboard activation.
    f.Focus.of(tester.element(find.text('更多'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('编辑信息'), findsOneWidget);
    expect(find.text('连载追更'), findsOneWidget);
    expect(opened, 0);
    await tester.tap(find.text('编辑信息'));
    await tester.pumpAndSettle();
    expect(edited, 1);
    expect(opened, 0);
    expect(find.text('编辑信息'), findsNothing);
    await tester.tap(find.byKey(const f.ValueKey('book-more-book')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连载追更'));
    await tester.pumpAndSettle();
    expect(updates, 1);
    expect(opened, 0);
    await tester.tap(find.byKey(const f.ValueKey('read-book-book')));
    await tester.tap(find.byKey(const f.ValueKey('book-content-book')));
    expect(opened, 2);
    expect(tester.takeException(), isNull);
    await _finish(tester, harness);
  });

  testWidgets('library menu opens updates for its own book without reading',
      (tester) async {
    final requests = <http.Request>[];
    final harness = await _harness(requests: requests);
    addTearDown(harness.dispose);
    _setWindow(tester, const f.Size(1150, 850));
    _configure(harness);
    var opened = 0;
    await tester.pumpWidget(_desktop(
        harness,
        DesktopLibraryView(
            controller: harness.scope.library,
            onOpen: (_) => opened++,
            onImport: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const f.ValueKey('book-more-book')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连载追更'));
    await tester.pumpAndSettle();
    expect(find.byType(BookUpdatesPage), findsOneWidget);
    expect(requests.single.url.path, '/api/v1/books/book/updates');
    expect(opened, 0);
    await tester.tap(find.byIcon(f.FluentIcons.back));
    await tester.pumpAndSettle();
    expect(find.byType(BookUpdatesPage), findsNothing);
    expect(find.byType(DesktopLibraryView), findsOneWidget);
    await tester.tap(find.byKey(const f.ValueKey('book-more-book')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑信息'));
    await tester.pumpAndSettle();
    expect(find.byType(BookMetadataEditor), findsOneWidget);
    expect(requests.last.url.path, '/api/v1/books/book/metadata');
    await tester.tap(find.byIcon(f.FluentIcons.back));
    await tester.pumpAndSettle();
    expect(find.byType(BookMetadataEditor), findsNothing);
    expect(find.byKey(const f.ValueKey('book-more-book')), findsOneWidget);
    expect(find.text('编辑信息'), findsNothing);
    expect(opened, 0);
    expect(tester.takeException(), isNull);
    await _finish(tester, harness);
  });

  for (final switchContext in [true, false]) {
    testWidgets('open menu rejects stale context=$switchContext or capability',
        (tester) async {
      final requests = <http.Request>[];
      final harness = await _harness(requests: requests);
      addTearDown(harness.dispose);
      _setWindow(tester, const f.Size(1150, 850));
      _configure(harness);
      await tester.pumpWidget(_desktop(
          harness,
          DesktopLibraryView(
              controller: harness.scope.library,
              onOpen: (_) => fail('Stale card opened reading'),
              onImport: () {})));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const f.ValueKey('book-more-book')));
      await tester.pumpAndSettle();
      if (switchContext) {
        harness.scope.library.resetForBackendSwitch();
        // Even an identical book ID in the next workspace cannot use this menu.
        _configure(harness);
      } else {
        harness.scope.backend.capabilities['libraryMetadata'] = false;
        harness.scope.library.serials.enabled = false;
      }
      await tester.tap(find.text('编辑信息'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.text('保存修改'), findsNothing);
      expect(tester.takeException(), isNull);
      await _finish(tester, harness);
    });
  }

  for (final entry in [
    (metadata: false, updates: false, source: true),
    (metadata: true, updates: false, source: true),
    (metadata: false, updates: true, source: true),
    (metadata: true, updates: true, source: false),
  ]) {
    testWidgets('management entries obey capabilities and source $entry',
        (tester) async {
      final harness = await _harness();
      addTearDown(harness.dispose);
      _setWindow(tester, const f.Size(1150, 850));
      _configure(harness,
          metadata: entry.metadata,
          updates: entry.updates,
          book: entry.source
              ? _book
              : Book.fromJson({'id': 'book', 'title': '本地文本'}));
      await tester.pumpWidget(_desktop(
          harness,
          DesktopLibraryView(
              controller: harness.scope.library,
              onOpen: (_) {},
              onImport: () {})));
      await tester.pumpAndSettle();
      final hasUpdates = entry.updates && entry.source;
      if (!entry.metadata && !hasUpdates) {
        expect(find.byType(f.DropDownButton), findsNothing);
      } else {
        await tester.tap(find.byKey(const f.ValueKey('book-more-book')));
        await tester.pumpAndSettle();
        expect(
            find.text('编辑信息'), entry.metadata ? findsOneWidget : findsNothing);
        expect(find.text('连载追更'), hasUpdates ? findsOneWidget : findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await _finish(tester, harness);
    });
  }

  testWidgets('mobile BookCard retains compact reading target without commands',
      (tester) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    var opened = 0;
    await tester.pumpWidget(_desktop(
        harness,
        UiPlatformScope(
          platform: f.TargetPlatform.android,
          child: f.Center(
            child: f.SizedBox(
              width: 150,
              height: 300,
              child: BookCard(
                book: _book,
                onOpen: () => opened++,
                desktopActions: DesktopBookCardActions(
                    onEditMetadata: () => fail('Desktop commands on mobile')),
              ),
            ),
          ),
        )));
    await tester.pumpAndSettle();
    expect(find.byType(f.DropDownButton), findsNothing);
    expect(find.text('打开阅读'), findsNothing);
    await tester.tap(find.text(_book.title));
    expect(opened, 1);
    expect(tester.takeException(), isNull);
    await _finish(tester, harness);
  });

  testWidgets('narrow card keeps both commands at 250 percent text',
      (tester) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    _setWindow(tester, const f.Size(420, 620));
    final boundary = f.GlobalKey();
    await tester.pumpWidget(f.RepaintBoundary(
      key: boundary,
      child: _desktop(
          harness,
          f.Center(
            child: f.SizedBox(
              width: 300,
              height: 400,
              child: BookCard(
                book: _book,
                onOpen: () {},
                desktopActions: DesktopBookCardActions(
                    onEditMetadata: () {},
                    onManageUpdates: () {},
                    newChapterCount: 1234),
              ),
            ),
          ),
          textScale: 2.5),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('阅读'), findsOneWidget);
    expect(_tooltip('打开阅读'), findsOneWidget);
    expect(_tooltip('管理《${_book.title}》'), findsOneWidget);
    await captureUi(tester, boundary, 'library-card-narrow-250');
    await tester.tap(find.byKey(const f.ValueKey('book-more-book')));
    await tester.pumpAndSettle();
    expect(find.text('编辑信息'), findsOneWidget);
    expect(find.text('连载追更'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _finish(tester, harness);
  });

  for (final scenario in [
    (width: 1200.0, scale: 1.0, name: 'library-desktop'),
    (width: 640.0, scale: 2.0, name: 'library-narrow-large-text'),
  ]) {
    testWidgets('library cards align and stay usable ${scenario.name}',
        (tester) async {
      final harness = await _harness();
      addTearDown(harness.dispose);
      _setWindow(tester, f.Size(scenario.width, 1100));
      _configure(harness);
      harness.scope.library.books = [
        _book,
        Book.fromJson({
          'id': 'other',
          'title': '晚风中的图书馆',
          'author': '牧野',
          'readingState': 'unread',
          'chapterCount': 32,
        }),
        Book.fromJson({
          'id': 'third',
          'title': '城市与群星',
          'author': '亚瑟·克拉克',
          'groupName': '科幻书单',
          'tags': ['经典'],
          'readingState': 'finished',
          'chapterCount': 42,
          'lastReadChapterIndex': 42,
          'translated': true,
        }),
      ];
      await harness.scope.library.serials.load();
      final boundary = f.GlobalKey();
      await tester.pumpWidget(f.RepaintBoundary(
        key: boundary,
        child: _desktop(
            harness,
            DesktopLibraryView(
                controller: harness.scope.library,
                onOpen: (_) {},
                onImport: () {}),
            textScale: scenario.scale),
      ));
      await tester.pumpAndSettle();
      expect(find.text('未分组'), findsNothing);
      expect(find.text('在读'), findsWidgets);
      expect(find.text('新增 3 章'), findsOneWidget);
      expect(find.text('科幻书单 · #探索 · #经典'), findsOneWidget);
      final card =
          tester.getRect(find.byKey(const f.ValueKey('desktop-book-book')));
      final more =
          tester.getRect(find.byKey(const f.ValueKey('book-more-book')));
      final reading =
          tester.getRect(find.byKey(const f.ValueKey('read-book-book')));
      expect(card.contains(more.center), isTrue);
      expect(card.contains(reading.center), isTrue);
      expect(reading.center.dy, more.center.dy);
      expect(tester.takeException(), isNull);
      await captureUi(tester, boundary, scenario.name);
      final previousShadows = debugDisableShadows;
      if (captureUiReview) debugDisableShadows = false;
      try {
        // Paint the new menu with real shadows before its layer is cached.
        await tester.tap(find.byKey(const f.ValueKey('book-more-book')));
        await tester.pumpAndSettle();
        expect(find.text('编辑信息'), findsOneWidget);
        expect(find.text('连载追更'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureUi(tester, boundary, '${scenario.name}-menu');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      } finally {
        debugDisableShadows = previousShadows;
      }
      await _finish(tester, harness);
    });
  }
}

final _book = Book.fromJson({
  'id': 'book',
  'title': '远方的星海：穿越群星的漫长旅程',
  'author': '林间',
  'sourceUrl': 'https://example.test/book',
  'bookKind': '长小说',
  'language': '中文',
  'chapterCount': 128,
  'lastReadChapterIndex': 36,
  'groupName': '科幻书单',
  'tags': ['探索', '经典'],
  'pinned': true,
  'readingState': 'reading',
});

const _update = {
  'bookId': 'book',
  'newChapterCount': 3,
  'latestChapterIndex': 128
};

Future<ReliabilityHarness> _harness({List<http.Request>? requests}) =>
    ReliabilityHarness.create(MockClient((request) async {
      requests?.add(request);
      return http.Response(
          jsonEncode(
              request.url.path == '/api/v1/book-updates' ? [_update] : _update),
          200,
          headers: {'content-type': 'application/json'});
    }));

void _configure(ReliabilityHarness harness,
    {bool metadata = true, bool updates = true, Book? book}) {
  harness.scope.backend.capabilities['libraryMetadata'] = metadata;
  harness.scope.backend.capabilities['bookUpdates'] = updates;
  harness.scope.library.imports.enabled = false;
  harness.scope.library.serials.enabled = updates;
  harness.scope.library.books = [book ?? _book];
  harness.scope.library.state = LoadState.ready;
}

void _setWindow(WidgetTester tester, f.Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Finder _tooltip(String message) => find.byWidgetPredicate(
    (widget) => widget is f.Tooltip && widget.message == message);

Future<void> _finish(WidgetTester tester, ReliabilityHarness harness) async {
  // In the app the workspace owns this polling lifetime, outside the card tree.
  harness.scope.library.serials.enabled = false;
  await tester.pumpWidget(const f.SizedBox.shrink());
  await tester.pumpAndSettle();
}

f.Widget _desktop(ReliabilityHarness harness, f.Widget page,
    {double textScale = 1}) {
  final scope = harness.scope;
  final theme = buildQingJuanTheme(f.Brightness.light,
      platform: f.TargetPlatform.windows);
  return AppScope(
    appState: scope.appState,
    api: scope.api,
    backend: scope.backend,
    auth: scope.auth,
    library: scope.library,
    discovery: scope.discovery,
    sources: scope.sources,
    tasks: scope.tasks,
    settings: scope.settings,
    child: f.FluentApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      builder: (context, child) => UiPlatformScope(
        platform: f.TargetPlatform.windows,
        child: f.MediaQuery(
          data: f.MediaQuery.of(context)
              .copyWith(textScaler: f.TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
      home: f.ColoredBox(color: theme.scaffoldBackgroundColor, child: page),
    ),
  );
}
