import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/mobile/mobile_app.dart';
import 'package:qingjuan/features/detail/book_detail_page.dart';
import 'package:qingjuan/mobile/mobile_action_button.dart';
import 'package:qingjuan/mobile/mobile_book_cover.dart';
import 'package:qingjuan/mobile/mobile_discovery_page.dart';
import 'package:qingjuan/shared/responsive.dart';

import '../helpers/reliability_harness.dart';
import '../features/reader/mobile_fixture_capture.dart';

final _captureBoundary = GlobalKey();

const _bookUrl = 'https://www.qidian.com/book/100';

Map<String, Object?> _site(String id, String name,
        {bool recommendations = true, bool pageable = true}) =>
    {
      'site': id,
      'site_name': name,
      'channels': [
        if (recommendations)
          {
            'site': id,
            'key': 'editors',
            'name': '编辑推荐',
            'kind': 'recommend',
            'pageable': pageable,
          },
        {
          'site': id,
          'key': 'hot',
          'name': '人气榜',
          'kind': 'rank',
          'pageable': pageable
        },
        {
          'site': id,
          'key': 'monthly',
          'name': '月票榜',
          'kind': 'rank',
          'group': '男生',
          'pageable': pageable,
        },
      ],
    };

http.Response _json(Object value, [int status = 200]) => http.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _catalog() => _json({
      'sites': [
        _site('qidian', '起点中文网'),
        _site('ciweimao', '刺猬猫', recommendations: false),
      ],
    });

Map<String, Object?> _result(http.Request request,
    {String? error, bool empty = false}) {
  final page = int.parse(request.url.queryParameters['page'] ?? '1');
  final channel = request.url.pathSegments.last;
  return {
    'site': request.url.pathSegments[4],
    'channel': channel,
    'page': page,
    'has_more': page == 1,
    'error': error,
    'items': empty
        ? []
        : [
            {
              'site': 'qidian',
              'title': page == 1 ? '长安的荔枝' : '第二页作品',
              'author': '马伯庸',
              'intro': '一段从岭南到长安的旅程。',
              'url': _bookUrl,
              'cover': 'https://images.example.test/cover.jpg',
              'rank': 7,
              'score': '126万热度',
            },
          ],
  };
}

Future<void> _mount(WidgetTester tester, ReliabilityHarness harness,
    {Size size = const Size(390, 844),
    double textScale = 1,
    bool dark = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final scope = harness.scope;
  await scope.appState.applyBackendConnection(
      mode: BackendConnectionMode.remote,
      remoteUrl: 'https://qingjuan.example.test',
      remoteToken: 'fixture');
  await scope.appState
      .setThemeMode(dark ? AppThemeMode.dark : AppThemeMode.light);
  scope.appState.selectSection(AppSection.discovery);
  scope.backend.status = BackendStatus.ready;
  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureBoundary,
      child: UiPlatformScope(
        platform: TargetPlatform.android,
        child: AppScope(
          appState: scope.appState,
          api: scope.api,
          backend: scope.backend,
          auth: scope.auth,
          library: scope.library,
          discovery: scope.discovery,
          sources: scope.sources,
          tasks: scope.tasks,
          settings: scope.settings,
          child: const MobileQingJuanApp(),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(loadMobileCaptureFonts);
  testWidgets(
      'site, kind and channel controls request distinct real lists and paginate',
      (tester) async {
    final requests = <http.Request>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/discovery/sites')) return _catalog();
      return _json(_result(request));
    }));
    addTearDown(harness.dispose);
    await _mount(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text('长安的荔枝'), findsOneWidget);
    expect(find.text('马伯庸'), findsOneWidget);
    expect(tester.widget<MobileBookCover>(find.byType(MobileBookCover)).cover,
        'https://images.example.test/cover.jpg');
    expect(find.text('第 7 名 · 126万热度'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mobile-discovery-kind-rank')));
    await tester.pumpAndSettle();
    expect(requests.last.url.path, endsWith('/qidian/channels/hot'));
    expect(find.text('第 7 名 · 126万热度'), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey('mobile-discovery-channel-picker')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('mobile-discovery-channel-monthly')));
    await tester.pumpAndSettle();
    expect(requests.last.url.path, endsWith('/qidian/channels/monthly'));
    expect(find.text('男生 · 月票榜'), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('mobile-discovery-next')));
    await tester.tap(find.byKey(const ValueKey('mobile-discovery-next')));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['page'], '2');
    expect(find.text('第二页作品'), findsOneWidget);
    expect(find.text('已到最后一页'), findsOneWidget);
    expect(
        tester
            .widget<MobileActionButton>(
                find.byKey(const ValueKey('mobile-discovery-next')))
            .onPressed,
        isNull);

    await tester.ensureVisible(
        find.byKey(const ValueKey('mobile-discovery-site-picker')));
    await tester
        .tap(find.byKey(const ValueKey('mobile-discovery-site-picker')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('mobile-discovery-site-ciweimao')));
    await tester.pumpAndSettle();
    expect(requests.last.url.path, endsWith('/ciweimao/channels/hot'));
    final count = requests.length;
    await tester
        .tap(find.byKey(const ValueKey('mobile-discovery-kind-recommend')));
    await tester.pumpAndSettle();
    expect(find.text('该站点暂无推荐栏目'), findsOneWidget);
    expect(find.text('长安的荔枝'), findsNothing);
    expect(requests.length, count);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'fixed nine-book lists explain availability without dead pagination',
      (tester) async {
    final requests = <http.Request>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/discovery/sites')) {
        return _json({
          'sites': [_site('qidian', '测试站点', pageable: false)]
        });
      }
      return _json({
        ..._result(request),
        'has_more': false,
        'items': [
          for (var index = 1; index <= 9; index++)
            {
              'site': 'qidian',
              'title': '推荐作品 $index',
              'url': 'https://example.test/book/$index'
            },
        ],
      });
    }));
    addTearDown(harness.dispose);
    await _mount(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text('共 9 部作品'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('该栏目不支持翻页，可刷新或切换栏目'), 500);
    expect(
        find.byKey(const ValueKey('mobile-discovery-previous')), findsNothing);
    expect(find.byKey(const ValueKey('mobile-discovery-next')), findsNothing);
    expect(find.textContaining('第 1 页'), findsNothing);
    expect(find.text('已到最后一页'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mobile-discovery-refresh')));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['refresh'], 'true');
    expect(requests.last.url.queryParameters['page'], '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a pageable single-page list explains why both buttons are disabled',
      (tester) async {
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/discovery/sites')) return _catalog();
      return _json({..._result(request), 'has_more': false});
    }));
    addTearDown(harness.dispose);
    await _mount(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text('已到最后一页'), findsOneWidget);
    expect(find.text('该栏目不支持翻页，可刷新或切换栏目'), findsNothing);
    for (final key in ['mobile-discovery-previous', 'mobile-discovery-next']) {
      expect(
          tester
              .widget<MobileActionButton>(find.byKey(ValueKey(key)))
              .onPressed,
          isNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed second page retains a way back and does not claim the end',
      (tester) async {
    final pages = <String>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/discovery/sites')) return _catalog();
      final page = request.url.queryParameters['page']!;
      pages.add(page);
      if (page == '2') return _json({'detail': '此页暂时无法加载'}, 400);
      return _json(_result(request));
    }));
    addTearDown(harness.dispose);
    await _mount(tester, harness);
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const ValueKey('mobile-discovery-next')));
    await tester.tap(find.byKey(const ValueKey('mobile-discovery-next')));
    await tester.pumpAndSettle();
    expect(find.text('此页暂时无法加载'), findsOneWidget);
    expect(find.text('已到最后一页'), findsNothing);
    final previous = find.byKey(const ValueKey('mobile-discovery-previous'));
    expect(tester.widget<MobileActionButton>(previous).onPressed, isNotNull);
    expect(
        tester
            .widget<MobileActionButton>(
                find.byKey(const ValueKey('mobile-discovery-next')))
            .onPressed,
        isNull);
    await tester.ensureVisible(previous);
    await tester.tap(previous);
    await tester.pumpAndSettle();
    expect(pages, ['1', '2', '1']);
    expect(find.text('长安的荔枝'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed responses with partial books do not display a last-page message',
      (tester) async {
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/discovery/sites')) return _catalog();
      return _json({..._result(request, error: '结果尚未完整'), 'has_more': false});
    }));
    addTearDown(harness.dispose);
    await _mount(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text('结果尚未完整'), findsOneWidget);
    expect(find.text('长安的荔枝'), findsOneWidget);
    expect(find.text('已到最后一页'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading, channel error, retry and empty content are explicit',
      (tester) async {
    final content = Completer<http.Response>();
    var count = 0;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/discovery/sites')) return _catalog();
      count++;
      if (count == 1) return content.future;
      return _json(_result(request, empty: true));
    }));
    addTearDown(harness.dispose);
    await _mount(tester, harness);
    await tester.pump();
    await tester.pump();
    expect(find.bySemanticsLabel('正在加载作品'), findsOneWidget);
    expect(find.text('正在加载作品'), findsNothing);
    content.complete(_json({
      'site': 'qidian',
      'channel': 'editors',
      'items': [],
      'error': '上游站点暂时不可用'
    }));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法加载作品'), findsOneWidget);
    expect(find.text('上游站点暂时不可用'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('此栏目暂无作品'), findsOneWidget);
    expect(count, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed site catalog can be retried', (tester) async {
    var failures = 1;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/discovery/sites')) {
        if (failures-- > 0) return _json({'detail': '无法获取站点'}, 400);
        return _catalog();
      }
      return _json(_result(request));
    }));
    addTearDown(harness.dispose);
    await _mount(tester, harness);
    await tester.pumpAndSettle();
    expect(find.text('站点加载失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('长安的荔枝'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('import blocks repeated submission and opens the completed book',
      (tester) async {
    final started = Completer<http.Response>();
    var imports = 0;
    Map<String, dynamic>? payload;
    const book = {'id': 'imported', 'title': '长安的荔枝', 'sourceUrl': _bookUrl};
    final completed = {
      'id': 'job',
      'mode': 'import',
      'status': 'completed',
      'book': book,
      'progress': 100
    };
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/discovery/sites')) return _catalog();
      if (request.url.path.contains('/discovery/sites/')) {
        return _json(_result(request));
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/books/link-jobs')) {
        imports++;
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return started.future;
      }
      if (request.url.path.endsWith('/books/link-jobs/job')) {
        return _json(completed);
      }
      if (request.url.path.endsWith('/books')) return _json([book]);
      if (request.url.path.endsWith('/books/imported')) {
        return _json({'book': book, 'chapters': []});
      }
      return _json({});
    }));
    harness.scope.library.imports.enabled = false;
    addTearDown(harness.dispose);
    await _mount(tester, harness);
    await tester.pumpAndSettle();
    final add = find.byKey(const ValueKey('mobile-discovery-import-$_bookUrl'));
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pump();
    expect(tester.widget<MobileActionButton>(add).onPressed, isNull);
    await tester.tap(add);
    await tester.pump();
    expect(imports, 1);
    expect((payload!['payload'] as Map)['sourceUrl'], _bookUrl);
    expect((payload!['payload'] as Map)['sourceId'], '');
    expect((payload!['payload'] as Map)['downloadMode'], 'on_demand');
    started.complete(_json(completed));
    await tester.pumpAndSettle();
    expect(find.text('已加入书库'), findsOneWidget);
    expect(find.text('打开作品'), findsOneWidget);
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.byType(BookDetailPage), findsOneWidget);
    expect(tester.widget<BookDetailPage>(find.byType(BookDetailPage)).bookId,
        'imported');
    expect(imports, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an old preview cannot import into a changed workspace',
      (tester) async {
    var imports = 0;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/discovery/sites')) return _catalog();
      if (request.url.path.endsWith('/books/preview')) {
        return _json({'title': '长安的荔枝', 'chapters': [], 'chapterCount': 0});
      }
      if (request.url.path.endsWith('/books/link-jobs')) imports++;
      return _json(_result(request));
    }));
    addTearDown(harness.dispose);
    await _mount(tester, harness);
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看内容'));
    await tester.pumpAndSettle();
    expect(find.text('作品预览'), findsOneWidget);
    harness.scope.library.resetForBackendSwitch();
    await tester.pump();
    expect(find.byKey(const ValueKey('preview-library-action')), findsNothing);
    expect(find.text('账号或服务已切换，请返回列表重新打开预览。'), findsOneWidget);
    await tester.tap(find.text('返回列表'));
    await tester.pumpAndSettle();
    expect(imports, 0);
    expect(find.text('作品预览'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late import failures cannot overwrite a changed workspace',
      (tester) async {
    final response = Completer<http.Response>();
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/discovery/sites')) return _catalog();
      if (request.method == 'POST') return response.future;
      return _json(_result(request));
    }));
    addTearDown(harness.dispose);
    await _mount(tester, harness);
    await tester.pumpAndSettle();
    final add = find.byKey(const ValueKey('mobile-discovery-import-$_bookUrl'));
    await tester.tap(add);
    await tester.pump();
    harness.scope.library.resetForBackendSwitch();
    await tester.pump();
    expect(tester.widget<MobileActionButton>(add).onPressed, isNotNull);
    response.complete(_json({'detail': '旧工作区导入失败'}, 400));
    await tester.pumpAndSettle();
    expect(find.textContaining('旧工作区'), findsNothing);
    expect(find.text('正在加入…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recommendations render in light, dark and enlarged app layouts',
      (tester) async {
    for (final configuration in [(false, 1.0), (true, 1.0), (true, 2.0)]) {
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.url.path.endsWith('/discovery/sites')) return _catalog();
        return _json(_result(request));
      }));
      await _mount(tester, harness,
          dark: configuration.$1, textScale: configuration.$2);
      await tester.pumpAndSettle();
      expect(find.byType(MobileDiscoveryPage), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('mobile-discovery-kind-rank')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-navigation-discovery')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await saveMobileFixture(tester, _captureBoundary,
          'discovery-${configuration.$1 ? 'dark' : 'light'}-${configuration.$2 == 2 ? 'large-text' : 'phone'}');
      await tester.pumpWidget(const SizedBox.shrink());
      harness.dispose();
    }
  });

  testWidgets('small phones retain scrollable controls at 200 percent text',
      (tester) async {
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.endsWith('/discovery/sites')) return _catalog();
      return _json(_result(request));
    }));
    addTearDown(harness.dispose);
    await _mount(tester, harness, size: const Size(320, 640), textScale: 2);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final add = find.byKey(const ValueKey('mobile-discovery-import-$_bookUrl'));
    await tester.scrollUntilVisible(add, 250);
    expect(tester.getSize(add).height, greaterThanOrEqualTo(48));
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('mobile-discovery-next')), 250);
    await tester.tap(find.byKey(const ValueKey('mobile-discovery-next')));
    await tester.pumpAndSettle();
    expect(harness.scope.discovery.page, 2);
    await tester.ensureVisible(
        find.byKey(const ValueKey('mobile-discovery-channel-picker')));
    await tester
        .tap(find.byKey(const ValueKey('mobile-discovery-channel-picker')));
    await tester.pumpAndSettle();
    expect(find.text('选择推荐栏目'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
