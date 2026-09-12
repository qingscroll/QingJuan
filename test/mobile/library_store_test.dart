import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/source.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/mobile/mobile_library_page.dart';
import 'package:qingjuan/mobile/mobile_app.dart';
import 'package:qingjuan/mobile/mobile_import_sheet.dart';
import 'package:qingjuan/mobile/mobile_search_page.dart';
import 'package:qingjuan/mobile/mobile_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/reader/mobile_fixture_capture.dart';

void main() {
  setUpAll(loadMobileCaptureFonts);
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
      'mobile shelf has account metadata filters and a reachable edit entry',
      (tester) async {
    _setViewport(tester, const Size(390, 844));
    final fixture = await _Fixture.create((_) async => _json({
          'bookId': 'metadata',
          'title': '可编辑作品',
          'author': '作者',
          'synopsis': '',
          'revision': 0
        }));
    addTearDown(fixture.dispose);
    fixture.backend.capabilities = {'libraryMetadata': true};
    fixture.library.books = [
      Book.fromJson({
        'id': 'metadata',
        'title': '可编辑作品',
        'pinned': true,
        'groupName': '收藏'
      })
    ];
    fixture.library.state = LoadState.ready;
    await tester
        .pumpWidget(fixture.app(const MobileLibraryPage(), textScale: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-library-organize')));
    await tester.pumpAndSettle();
    expect(find.text('全部分组'), findsOneWidget);
    expect(find.text('全部阅读状态'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester
        .longPress(find.byKey(const ValueKey('mobile-library-book-metadata')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑信息'));
    await tester.pumpAndSettle();
    expect(find.text('编辑作品信息'), findsOneWidget);
    expect(find.byKey(const ValueKey('metadata-title')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final dedicatedEntry in <bool>[false, true]) {
    testWidgets(
        'mobile album number import works with dedicated entry $dedicatedEntry',
        (tester) async {
      _setViewport(tester, const Size(390, 844));
      final submitted = <Map<String, dynamic>>[];
      final fixture = await _Fixture.create((request) async {
        if (request.method == 'POST') {
          submitted.add(jsonDecode(request.body) as Map<String, dynamic>);
        }
        return _json(_job('failed'));
      });
      addTearDown(fixture.dispose);
      await tester
          .pumpWidget(fixture.app(MobileImportPage(comic18: dedicatedEntry)));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('mobile-import-url'));
      await tester.enterText(input, ' 00123456 ');
      await tester.pumpAndSettle();
      expect(find.text('漫画'), findsOneWidget);
      final submit = find.byKey(const ValueKey('mobile-import-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(submitted, hasLength(1));
      final payload = submitted.single['payload'] as Map<String, dynamic>;
      expect(submitted.single['mode'], 'import');
      expect(payload['albumId'], '123456');
      expect(payload['sourceUrl'], 'https://18comic.vip/album/123456/');
      expect(payload['bookKind'], '漫画');
      expect(payload['downloadMode'], 'all');
      await tester.tap(find.text('查看'));
      await tester.pumpAndSettle();
      expect(find.text('重新导入'), findsOneWidget);
      await tester.tap(find.text('重新导入'));
      await tester.pumpAndSettle();
      expect(submitted, hasLength(2));
      expect(submitted.last['payload'], payload);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'mobile import chooser opens number entry and rejects invalid IDs',
      (tester) async {
    _setViewport(tester, const Size(390, 844));
    final requests = <http.Request>[];
    final fixture = await _Fixture.create((request) async {
      requests.add(request);
      return _json(<Object>[]);
    });
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(Builder(
        builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => showMobileImportSheet(context),
                  child: const Text('导入测试')),
            ))));
    await tester.tap(find.text('导入测试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('禁漫本子号'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<MobileImportPage>(find.byType(MobileImportPage)).comic18,
        isTrue);
    await tester.enterText(
        find.byKey(const ValueKey('mobile-import-url')), '-1');
    final submit = find.byKey(const ValueKey('mobile-import-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('请输入有效的禁漫本子号（正整数）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'store uses every real provider and keeps built-in imports on demand',
      (tester) async {
    _setViewport(tester, const Size(390, 844));
    final requests = <http.Request>[];
    final fixture = await _Fixture.create((request) async {
      requests.add(request);
      if (request.url.path == '/api/v1/sources/search') {
        return _json(<Object>[_result('书源结果')]);
      }
      if (request.url.path == '/api/v1/plugins/search') {
        return _json(<Object>[
          {..._result('插件结果'), 'sourceId': ''}
        ]);
      }
      if (request.url.path == '/api/v1/builtin-sites/search') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json(<Object>[_result('${body['sourceId']}结果')]);
      }
      if (request.url.path == '/api/v1/books/link-jobs') {
        return _json(_job('queued'));
      }
      if (request.url.path == '/api/v1/books/link-jobs/test-job') {
        return _json(_job('failed'));
      }
      return _json(<String, Object>{}, 404);
    });
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(const MobileSearchPage()));
    await tester.pumpAndSettle();
    expect(find.text('搜索'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('mobile-store-search-submit')));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);

    await tester.enterText(find.byType(TextField), '测试作品');
    await tester.tap(find.byKey(const ValueKey('mobile-store-search-submit')));
    await tester.pumpAndSettle();
    expect(requests.single.url.path, '/api/v1/sources/search');
    expect(find.text('书源结果'), findsOneWidget);
    final sourceBody = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(sourceBody['sourceIds'], <String>['source-1']);

    for (final engine in BookSearchEngine.values
        .skip(1)
        .where((engine) => engine != BookSearchEngine.installedPlugins)) {
      final selector =
          find.byKey(ValueKey('mobile-store-category-${engine.name}'));
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      expect(fixture.sources.results, isEmpty);
      await tester
          .tap(find.byKey(const ValueKey('mobile-store-search-submit')));
      await tester.pumpAndSettle();
      final body = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(requests.last.url.path, '/api/v1/builtin-sites/search');
      expect(body['sourceId'], 'source-builtin-${engine.name}');
      expect(find.text('source-builtin-${engine.name}结果'), findsOneWidget);
    }

    await tester.tap(find.text('加入书库'));
    await tester.pumpAndSettle();
    final importRequest = requests.singleWhere(
        (request) => request.url.path == '/api/v1/books/link-jobs');
    final body = jsonDecode(importRequest.body) as Map<String, dynamic>;
    final payload = body['payload'] as Map<String, dynamic>;
    expect(body['mode'], 'import');
    expect(payload['sourceId'], 'source-builtin-biqvge');
    expect(payload['downloadMode'], 'on_demand');
    expect(
        requests.where((request) => request.url.path == '/api/v1/books/import'),
        isEmpty);
    expect(find.textContaining('导入失败'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    expect(tester.takeException(), isNull);
    final pluginSelector =
        find.byKey(const ValueKey('mobile-store-category-installedPlugins'));
    await tester.ensureVisible(pluginSelector);
    await tester.tap(pluginSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-store-search-submit')));
    await tester.pumpAndSettle();
    expect(requests.last.url.path, '/api/v1/plugins/search');
    expect(find.text('插件结果'), findsOneWidget);
    expect(fixture.sources.results.single.toImportPayload()['sourceId'], '');
  });

  for (final dark in <bool>[false, true]) {
    testWidgets(
        'import ${dark ? 'dark' : 'light'} progress exposes recovery supported by the backend',
        (tester) async {
      _setViewport(tester, const Size(390, 844));
      SharedPreferences.setMockInitialValues(<String, Object>{
        'qingjuan.backend.remote.url': 'https://qingjuan.example.test',
        'qingjuan.backendMode': 'remote',
      });
      var phase = 'running';
      var starts = 0;
      final fixture = await _Fixture.create((request) async {
        if (request.method == 'POST') starts++;
        return _json(<String, Object?>{
          ..._job(phase),
          'progress': 42,
          'message': phase == 'failed' ? '作品目录解析未完成' : '正在读取作品目录 · 已解析 42 章',
          'error': phase == 'failed' ? '书源暂时无法响应，请稍后重新导入。' : null,
        });
      });
      addTearDown(fixture.dispose);
      fixture.backend.status = BackendStatus.ready;
      fixture.library.state = LoadState.empty;
      await fixture.appState
          .setThemeMode(dark ? AppThemeMode.dark : AppThemeMode.light);
      await fixture.library.startLinkJob('import', <String, dynamic>{
        'title': '山间的一封信',
        'sourceUrl': 'https://books.example.test/book/1',
        'bookKind': '长小说'
      });
      final key = GlobalKey();
      await tester.pumpWidget(
          RepaintBoundary(key: key, child: fixture.fullMobileApp()));
      await tester.pumpAndSettle();
      expect(find.text('正在读取作品目录 · 已解析 42 章'), findsOneWidget);
      await saveMobileFixture(
          tester, key, 'import-running-${dark ? 'dark' : 'light'}');
      phase = 'failed';
      await fixture.library.refreshLinkJob();
      await tester.pumpAndSettle();
      expect(find.text('导入未完成'), findsOneWidget);
      await tester.tap(find.text('查看'));
      await tester.pumpAndSettle();
      expect(find.text('书源暂时无法响应，请稍后重新导入。'), findsWidgets);
      expect(find.text('重新导入'), findsOneWidget);
      expect(find.text('取消任务'), findsNothing);
      await saveMobileFixture(
          tester, key, 'import-recovery-${dark ? 'dark' : 'light'}');
      phase = 'running';
      await tester.tap(find.text('重新导入'));
      await tester.pumpAndSettle();
      expect(starts, 2);
      expect(fixture.library.hasActiveLinkJob, isTrue);
      fixture.library.resetForBackendSwitch();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty search results differ from the initial store state',
      (tester) async {
    _setViewport(tester, const Size(390, 844));
    final fixture = await _Fixture.create((_) async => _json(<Object>[]));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(const MobileSearchPage()));
    await tester.pumpAndSettle();
    expect(find.text('找一本想读的作品'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '没有这本书');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('没有找到相关作品'), findsOneWidget);
    expect(find.text('找一本想读的作品'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text store stays usable on a compact screen',
      (tester) async {
    _setViewport(tester, const Size(320, 740));
    final fixture =
        await _Fixture.create((_) async => _json(<Object>[_result('测试作品')]));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
        fixture.app(const MobileSearchPage(), dark: true, textScale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), '作品');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('测试作品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('import submits once and remains traceable after leaving search',
      (tester) async {
    _setViewport(tester, const Size(390, 844));
    var starts = 0;
    final fixture = await _Fixture.create((request) async {
      if (request.url.path.endsWith('/search')) {
        return _json(<Object>[_result('异步导入作品')]);
      }
      if (request.method == 'POST' && request.url.path.endsWith('/link-jobs')) {
        starts++;
        return _json(_job('queued'));
      }
      return _json(<String, Object>{
        ..._job('running'),
        'progress': 35,
        'message': '已解析 35 个章节'
      });
    });
    fixture.library.state = LoadState.empty;
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(const MobileSearchPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '异步');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入书库'));
    // The server job intentionally stays running, including its busy indicator.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(starts, 1);
    expect(find.text('已解析 35 个章节'), findsOneWidget);
    expect(find.text('正在加入…'), findsOneWidget);
    await tester.pumpWidget(fixture.app(const MobileLibraryPage()));
    await tester.pumpAndSettle();
    expect(find.text('已解析 35 个章节'), findsOneWidget);
    expect(fixture.library.hasActiveLinkJob, isTrue);
    expect(starts, 1);
    expect(tester.takeException(), isNull);
    fixture.library.resetForBackendSwitch();
  });

  testWidgets(
      'link import validates URL before any request with large text and keyboard',
      (tester) async {
    _setViewport(tester, const Size(320, 740));
    final requests = <http.Request>[];
    final fixture = await _Fixture.create((request) async {
      requests.add(request);
      return _json(<Object>[]);
    });
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
        fixture.app(const MobileImportPage(), dark: true, textScale: 2));
    await tester.pumpAndSettle();
    final submit = find.byKey(const ValueKey('mobile-import-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text('请输入完整的 HTTP 或 HTTPS 作品地址，或禁漫本子号（正整数）'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('mobile-import-url')));
    await tester.enterText(find.byKey(const ValueKey('mobile-import-url')),
        'https://books.example.test/book/1');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'batch deletion names the objects and only deletes selected books after confirmation',
      (tester) async {
    _setViewport(tester, const Size(390, 844));
    final deleted = <String>[];
    final fixture = await _Fixture.create((request) async {
      if (request.method == 'DELETE') deleted.add(request.url.path);
      return _json(<String, Object>{});
    });
    fixture.library
      ..state = LoadState.ready
      ..books = <Book>[
        Book.fromJson(<String, dynamic>{'id': 'keep', 'title': '保留的故事'}),
        Book.fromJson(<String, dynamic>{'id': 'remove', 'title': '将删除的故事'}),
      ];
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(const MobileLibraryPage()));
    await tester.pumpAndSettle();
    await tester
        .longPress(find.byKey(const ValueKey('mobile-library-book-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除所选'));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    expect(find.text('《将删除的故事》'), findsOneWidget);
    expect(find.textContaining('无法撤销'), findsOneWidget);
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(deleted, <String>['/api/v1/books/remove']);
    expect(fixture.library.books.single.id, 'keep');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'shelf categories intersect search and empty states reset both filters',
      (tester) async {
    _setViewport(tester, const Size(390, 844));
    final fixture = await _Fixture.create((_) async => _json(<Object>[]));
    fixture.library
      ..books = <Book>[
        Book.fromJson(<String, dynamic>{
          'id': 'long-novel',
          'title': '山海长歌',
          'bookKind': '长小说',
        }),
        Book.fromJson(<String, dynamic>{
          'id': 'light-novel',
          'title': '月光邮局',
          'bookKind': '轻小说',
        }),
        Book.fromJson(<String, dynamic>{
          'id': 'manga',
          'title': '山海画卷',
          'bookKind': '漫画',
        }),
      ]
      ..state = LoadState.ready;
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(const MobileLibraryPage()));
    await tester.pumpAndSettle();

    Future<void> selectCategory(String name) async {
      final chip = find.byKey(ValueKey('mobile-library-filter-$name'));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }

    expect(find.text('全部 3'), findsOneWidget);
    expect(find.text('小说 2'), findsOneWidget);
    expect(find.text('漫画 1'), findsOneWidget);
    expect(find.text('山海长歌'), findsOneWidget);
    expect(find.text('月光邮局'), findsOneWidget);
    expect(find.text('山海画卷'), findsOneWidget);

    await selectCategory('novels');
    expect(find.text('山海长歌'), findsOneWidget);
    expect(find.text('月光邮局'), findsOneWidget);
    expect(find.text('山海画卷'), findsNothing);

    await tester
        .tap(find.byKey(const ValueKey('mobile-library-search-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '山海');
    await tester.pumpAndSettle();
    expect(find.text('山海长歌'), findsOneWidget);
    expect(find.text('月光邮局'), findsNothing);
    expect(find.text('山海画卷'), findsNothing);

    await selectCategory('manga');
    expect(fixture.library.query, '山海');
    expect(find.text('山海画卷'), findsOneWidget);
    expect(find.text('山海长歌'), findsNothing);

    await selectCategory('all');
    expect(find.text('山海长歌'), findsOneWidget);
    expect(find.text('山海画卷'), findsOneWidget);
    expect(find.text('月光邮局'), findsNothing);

    await selectCategory('novels');
    await tester.enterText(find.byType(TextField), '没有匹配的作品');
    await tester.pumpAndSettle();
    expect(find.text('没有找到这本书'), findsOneWidget);
    await tester.ensureVisible(find.text('查看全部藏书'));
    await tester.tap(find.text('查看全部藏书'));
    await tester.pumpAndSettle();
    expect(fixture.library.query, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(find.text('山海长歌'), findsOneWidget);
    expect(find.text('月光邮局'), findsOneWidget);
    expect(find.text('山海画卷'), findsOneWidget);

    await selectCategory('manga');
    await fixture.library.delete('manga');
    await tester.pumpAndSettle();
    expect(find.text('这里还没有漫画'), findsOneWidget);
    expect(find.text('漫画 0'), findsOneWidget);
    await tester.ensureVisible(find.text('查看全部藏书'));
    await tester.tap(find.text('查看全部藏书'));
    await tester.pumpAndSettle();
    expect(find.text('全部 2'), findsOneWidget);
    expect(find.text('山海长歌'), findsOneWidget);
    expect(find.text('月光邮局'), findsOneWidget);
    expect(find.text('山海画卷'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final dark in <bool>[false, true]) {
    testWidgets(
        'compact ${dark ? 'dark' : 'light'} shelf keeps search context and readable titles',
        (tester) async {
      _setViewport(tester, const Size(320, 740));
      final fixture = await _Fixture.create((_) async => _json(<Object>[]));
      fixture.library
        ..books = <Book>[
          Book.fromJson(<String, dynamic>{
            'id': 'one',
            'title': '山海之间的一段很长很长的故事',
            'bookKind': '长小说',
            'chapterCount': 80
          }),
          Book.fromJson(<String, dynamic>{
            'id': 'two',
            'title': '城市来信',
            'bookKind': '长小说',
            'chapterCount': 50
          }),
        ]
        ..state = LoadState.ready;
      addTearDown(fixture.dispose);
      await tester
          .pumpWidget(fixture.app(const MobileLibraryPage(), dark: dark));
      await tester.pumpAndSettle();
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.text('长小说'), findsNothing);
      expect(find.textContaining('章'), findsNothing);
      final title = tester.widget<Text>(find.text('山海之间的一段很长很长的故事'));
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);

      await tester
          .tap(find.byKey(const ValueKey('mobile-library-search-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '城市');
      await tester.pumpAndSettle();
      expect(find.text('城市来信'), findsOneWidget);
      expect(find.text('山海之间的一段很长很长的故事'), findsNothing);
      await tester.tap(find.byWidgetPredicate((widget) =>
          widget is MiuixPressable && widget.semanticLabel == '清除搜索'));
      await tester.pumpAndSettle();
      expect(fixture.library.query, isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(find.text('山海之间的一段很长很长的故事'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '城市');
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('mobile-library-search-toggle')));
      await tester.pumpAndSettle();
      expect(fixture.library.query, '城市');
      expect(find.text('山海之间的一段很长很长的故事'), findsNothing);
      await tester
          .tap(find.byKey(const ValueKey('mobile-library-search-toggle')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '城市');
      expect(tester.takeException(), isNull);
    });
  }
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Map<String, Object> _result(String title) => <String, Object>{
      'title': title,
      'author': '测试作者',
      'synopsis': '这是用来验证移动端列表保持清晰可读的作品简介。内容超过两行时会自然截断，不会挤压封面与加入书架按钮。',
      'sourceUrl': 'https://books.example.test/book/1',
      'sourceId': 'source-1',
      'sourceName': '测试书源',
      'bookKind': '长小说',
      'sourceLanguage': '中文',
    };

Map<String, Object> _job(String status) => <String, Object>{
      'id': 'test-job',
      'mode': 'import',
      'status': status,
      'progress': 0,
      'message': '测试导入结束',
      'error': '测试导入结束',
      'logs': <Object>[],
      'createdAt': '2026-09-05T12:00:00Z',
      'updatedAt': '2026-09-05T12:00:00Z',
    };

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

class _Fixture {
  _Fixture(this.api, this.appState) {
    backend = BackendConnectionManager(api, isConfigured: () => true);
    auth = AuthController.localAdministrator(api);
    library = LibraryController(api);
    sources = SourcesController(api)
      ..state = LoadState.ready
      ..sources = const <BookSource>[
        BookSource(
            id: 'source-1',
            name: '测试书源',
            baseUrl: 'https://books.example.test',
            description: '',
            enabled: true,
            supported: true,
            status: 'online',
            statusMessage: '',
            tags: <String>[]),
      ];
    tasks = TasksController(api);
    settings = SettingsController(api);
  }

  static Future<_Fixture> create(
          Future<http.Response> Function(http.Request) handler) async =>
      _Fixture(
        ApiClient(() => 'https://qingjuan.example.test',
            client: MockClient(handler)),
        AppState(await SharedPreferences.getInstance(),
            initialRemoteBackendToken: 'test-token'),
      );

  final ApiClient api;
  final AppState appState;
  late final BackendConnectionManager backend;
  late final AuthController auth;
  late final LibraryController library;
  late final SourcesController sources;
  late final TasksController tasks;
  late final SettingsController settings;

  Widget fullMobileApp() => AppScope(
        appState: appState,
        api: api,
        backend: backend,
        auth: auth,
        library: library,
        sources: sources,
        tasks: tasks,
        settings: settings,
        child: const MobileQingJuanApp(),
      );

  Widget app(Widget child, {bool dark = false, double textScale = 1}) =>
      AppScope(
        appState: appState,
        api: api,
        backend: backend,
        auth: auth,
        library: library,
        sources: sources,
        tasks: tasks,
        settings: settings,
        child: MiuixThemeController(
          colorSchemeMode:
              dark ? MiuixColorSchemeMode.dark : MiuixColorSchemeMode.light,
          lightColors: qjMobileLightColors(),
          darkColors: qjMobileDarkColors(),
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const <Locale>[Locale('zh', 'CN')],
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              GlobalWidgetsLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(body: SafeArea(child: child)),
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
    appState.dispose();
    api.close();
  }
}
