import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/features/discovery/discovery_page.dart';
import 'package:qingjuan/features/preview/book_preview_page.dart';
import 'package:qingjuan/features/search/search_page.dart';
import 'package:qingjuan/mobile/mobile_discovery_page.dart';
import 'package:qingjuan/mobile/mobile_search_page.dart';
import 'package:qingjuan/mobile/mobile_theme.dart';
import 'package:qingjuan/shared/responsive.dart';

import '../../helpers/reliability_harness.dart';
import '../discovery/discovery_page_test.dart' as discovery_fixture;

void main() {
  for (final mobile in [false, true]) {
    for (final discovery in [false, true]) {
      testWidgets(
          'view content before joining mobile=$mobile discovery=$discovery',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize =
            mobile ? const f.Size(390, 900) : const f.Size(1200, 1000);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final requests = <http.Request>[];
        final harness =
            await ReliabilityHarness.create(MockClient((request) async {
          requests.add(request);
          return _respond(request);
        }));
        addTearDown(harness.dispose);
        harness.scope.library.imports.enabled = false;
        harness.scope.backend.capabilities['previewReading'] = true;
        final page = discovery
            ? mobile
                ? const MobileDiscoveryPage()
                : const DiscoveryPage()
            : mobile
                ? const MobileSearchPage()
                : const SearchPage();
        await tester.pumpWidget(_host(harness, page, mobile: mobile));
        await tester.pumpAndSettle();
        if (discovery) {
          await harness.scope.discovery.selectKind('rank');
          await harness.scope.discovery.nextPage();
          await tester.pumpAndSettle();
        } else {
          await tester.enterText(
              find.byKey(f.ValueKey(
                  mobile ? 'mobile-store-query' : 'search-query-input')),
              '月亮');
          await tester.tap(find.byKey(f.ValueKey(
              mobile ? 'mobile-store-search-submit' : 'search-submit-button')));
          await tester.pumpAndSettle();
        }
        final title = discovery
            ? mobile
                ? '月票榜作品 2'
                : '21. 月票榜作品 2'
            : '搜索到的月亮';
        await tester.ensureVisible(find.text(title));
        // The card itself is the default viewing target, not an import action.
        await tester.tap(find.text(title));
        await tester.tap(find.text(title), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.byType(BookPreviewPage), findsOneWidget);
        expect(
            requests.where(
                (request) => request.url.path.endsWith('/books/preview')),
            hasLength(1));
        final previewRequest = requests.lastWhere(
            (request) => request.url.path.endsWith('/books/preview'));
        final payload = jsonDecode(previewRequest.body) as Map<String, dynamic>;
        expect(payload['sourceUrl'], _url);
        expect(payload['sourceId'], discovery ? '' : 'source-test');
        expect(harness.scope.library.books, isEmpty);
        expect(_imports(requests), isEmpty);
        await tester
            .ensureVisible(find.byKey(const f.ValueKey('preview-chapter-1')));
        await tester.tap(find.byKey(const f.ValueKey('preview-chapter-1')));
        await tester.pumpAndSettle();
        expect(find.byKey(const f.ValueKey('preview-chapter-content')),
            findsOneWidget);
        expect(find.text('这是加入书架前可查看的正文。'), findsWidgets);
        final chapterRequest = requests.lastWhere(
            (request) => request.url.path.endsWith('/books/preview/chapter'));
        final chapterPayload =
            jsonDecode(chapterRequest.body) as Map<String, dynamic>;
        expect(chapterPayload['chapterIndex'], 1);
        expect(chapterPayload['book']['sourceUrl'], _url);
        expect(_imports(requests), isEmpty);
        expect(harness.scope.library.books, isEmpty);
        await tester.tap(find.byKey(const f.ValueKey('preview-back')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const f.ValueKey('preview-back')));
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget);
        if (discovery) {
          expect(harness.scope.discovery.kind, 'rank');
          expect(harness.scope.discovery.page, 2);
          expect(harness.scope.discovery.selectedChannel!.key, 'monthly');
        } else {
          expect(find.text('月亮'), findsOneWidget);
          expect(harness.scope.sources.results.single.title, '搜索到的月亮');
        }
        // The explicit viewing button has the same path, and joining is opt-in.
        final view = find.byKey(f.ValueKey(discovery
            ? mobile
                ? 'mobile-discovery-preview-$_url'
                : 'discovery-preview-42'
            : mobile
                ? 'mobile-search-preview-$_url'
                : 'search-preview-$_url'));
        await tester.ensureVisible(view);
        await tester.tap(view);
        await tester.pumpAndSettle();
        expect(_imports(requests), isEmpty);
        await tester
            .tap(find.byKey(const f.ValueKey('preview-library-action')));
        await tester.pumpAndSettle();
        expect(_imports(requests), hasLength(1));
        expect(harness.scope.library.books.single.id, 'joined');
        expect(find.text('打开作品'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const f.SizedBox.shrink());
        harness.scope.library.resetForBackendSwitch();
        await tester.pumpAndSettle();
      });
    }
  }
}

const _url = 'https://www.qidian.com/book/42/';
const _book = {
  'id': 'joined',
  'title': '正文预览作品',
  'sourceUrl': _url,
  'chapterCount': 1,
  'bookKind': '长小说',
  'language': '中文',
};

Iterable<http.Request> _imports(List<http.Request> requests) =>
    requests.where((request) =>
        request.method == 'POST' &&
        (request.url.path.endsWith('/books/import') ||
            request.url.path.endsWith('/books/link-jobs')));

http.Response _respond(http.Request request) {
  final path = request.url.path;
  if (path.contains('/discovery/')) return discovery_fixture.response(request);
  if (path.endsWith('/sources/search')) {
    return _json([
      {
        'title': '搜索到的月亮',
        'author': '作者',
        'sourceUrl': _url,
        'sourceId': 'source-test',
        'sourceName': '测试书源',
        'bookKind': '长小说',
        'sourceLanguage': '中文',
        'synopsis': '搜索简介',
      }
    ]);
  }
  if (path.endsWith('/books/preview')) {
    return _json({
      'title': '正文预览作品',
      'author': '作者',
      'synopsis': '作品简介',
      'bookKind': '长小说',
      'chapterCount': 1,
      'sourceStatus': 'ongoing',
      'chapters': [
        {
          'title': '第一章',
          'url': '$_url/chapter/1',
          'pageCount': 0,
          'accessRestricted': false
        }
      ],
    });
  }
  if (path.endsWith('/books/preview/chapter')) {
    return _json({
      'chapter': {
        'index': 1,
        'title': '第一章',
        'downloaded': false,
        'translated': false,
        'wordCount': 18,
        'imageCount': 0
      },
      'content': '这是加入书架前可查看的正文。',
      'paragraphs': ['这是加入书架前可查看的正文。'],
      'mode': 'original',
      'translatedAvailable': false,
      'imageSources': [],
      'pageTranslations': [],
    });
  }
  if (path.endsWith('/books/link-jobs') ||
      path.endsWith('/books/link-jobs/import-preview')) {
    return _json({
      'id': 'import-preview',
      'mode': 'import',
      'status': 'completed',
      'progress': 100,
      'book': _book,
      'logs': [],
      'message': '导入完成'
    });
  }
  if (path.endsWith('/books')) return _json([_book]);
  return _json({});
}

http.Response _json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

f.Widget _host(ReliabilityHarness harness, f.Widget page,
    {required bool mobile}) {
  final scope = harness.scope;
  final platform = mobile ? f.TargetPlatform.android : f.TargetPlatform.windows;
  f.Widget platformScope(f.BuildContext context, f.Widget? child) =>
      UiPlatformScope(platform: platform, child: child!);
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
    child: mobile
        ? MiuixThemeController(
            colorSchemeMode: MiuixColorSchemeMode.light,
            lightColors: qjMobileLightColors(),
            darkColors: qjMobileDarkColors(),
            textStyles: qjMobileTextStyles(),
            child: m.MaterialApp(
                builder: platformScope, home: m.Scaffold(body: page)))
        : f.FluentApp(
            builder: platformScope,
            theme: buildQingJuanTheme(f.Brightness.light, platform: platform),
            home: page),
  );
}
