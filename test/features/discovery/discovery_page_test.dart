import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/features/discovery/discovery_page.dart';

import '../../helpers/reliability_harness.dart';
import '../reader/mobile_fixture_capture.dart';

void main() {
  setUpAll(loadMobileCaptureFonts);
  testWidgets(
      'desktop switches recommendation and rank with working pagination',
      (tester) async {
    final requests = <Uri>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      requests.add(request.url);
      return response(request);
    }));
    addTearDown(harness.dispose);
    tester.view.reset();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    final capture = GlobalKey();
    await tester.pumpWidget(
        harness.widget(RepaintBoundary(key: capture, child: _desktopPage())));
    await tester.pumpAndSettle();
    await saveMobileFixture(tester, capture, 'discovery-desktop-recommend');
    expect(find.text('编辑精选作品'), findsOneWidget);
    expect(find.text('共 1 部作品'), findsOneWidget);
    expect(find.text('该栏目不支持翻页，可刷新或切换栏目'), findsOneWidget);
    expect(find.byKey(const ValueKey('discovery-previous')), findsNothing);
    expect(find.byKey(const ValueKey('discovery-next')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('discovery-kind-rank')));
    await tester.pumpAndSettle();
    expect(find.text('1. 月票榜作品 1'), findsOneWidget);
    await saveMobileFixture(tester, capture, 'discovery-desktop-rank');
    expect(find.text('编辑精选作品'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('discovery-next')));
    await tester.pumpAndSettle();
    expect(find.text('21. 月票榜作品 2'), findsOneWidget);
    expect(requests.last.queryParameters['page'], '2');
    expect(find.text('已到最后一页'), findsOneWidget);
    expect(
        tester
            .widget<Button>(find.byKey(const ValueKey('discovery-next')))
            .onPressed,
        isNull);
    await tester.tap(find.byKey(const ValueKey('discovery-previous')));
    await tester.pumpAndSettle();
    expect(find.text('1. 月票榜作品 1'), findsOneWidget);
    await harness.scope.discovery.selectSite('rank_only');
    await harness.scope.discovery.selectKind('recommend');
    await tester.pumpAndSettle();
    expect(find.text('该站点暂无推荐栏目'), findsOneWidget);
    expect(find.text('1. 月票榜作品 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop can return from a failed second page', (tester) async {
    final requests = <Uri>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      requests.add(request.url);
      if (request.url.path.endsWith('/monthly') &&
          request.url.queryParameters['page'] == '2') {
        return _response(jsonEncode({'detail': '第二页暂时无法加载'}), 400);
      }
      return response(request);
    }));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget(_desktopPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('discovery-kind-rank')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('discovery-next')));
    await tester.pumpAndSettle();
    expect(find.text('第二页暂时无法加载'), findsOneWidget);
    expect(find.text('第 2 页'), findsOneWidget);
    expect(find.text('已到最后一页'), findsNothing);
    expect(
        tester
            .widget<Button>(find.byKey(const ValueKey('discovery-next')))
            .onPressed,
        isNull);
    await tester.tap(find.byKey(const ValueKey('discovery-previous')));
    await tester.pumpAndSettle();
    expect(find.text('1. 月票榜作品 1'), findsOneWidget);
    expect(requests.last.queryParameters['page'], '1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop shows source errors and retries with forced refresh',
      (tester) async {
    var failed = true;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.url.path.contains('/channels/') && failed) {
        return _response(
            jsonEncode({
              'site': 'qidian',
              'channel': 'home',
              'error': '站点暂时不可用，请稍后重试。'
            }),
            200);
      }
      if (request.url.path.contains('/channels/')) {
        expect(request.url.queryParameters['refresh'], 'true');
      }
      return response(request);
    }));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget(_desktopPage()));
    await tester.pumpAndSettle();
    expect(find.text('站点暂时不可用，请稍后重试。'), findsOneWidget);
    failed = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('编辑精选作品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop disables repeated imports and reports failures',
      (tester) async {
    var imports = 0;
    final pending = Completer<http.Response>();
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      if (request.method == 'POST' &&
          request.url.path.endsWith('/books/link-jobs')) {
        imports += 1;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['payload']['sourceUrl'], 'https://www.qidian.com/book/42/');
        expect(body['payload']['sourceId'], '');
        return pending.future;
      }
      return response(request);
    }));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget(_desktopPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入书架'));
    await tester.pump();
    expect(find.text('正在加入书架…'), findsOneWidget);
    await tester.tap(find.text('正在加入书架…'));
    expect(imports, 1);
    pending.complete(_response(jsonEncode({'detail': '该站点暂时无法导入'}), 400));
    await tester.pumpAndSettle();
    expect(find.textContaining('该站点暂时无法导入'), findsOneWidget);
    expect(find.text('加入书架'), findsOneWidget);
  });

  testWidgets('desktop narrow layout supports 200 percent text',
      (tester) async {
    final harness = await ReliabilityHarness.create(
        MockClient((request) async => response(request)));
    addTearDown(harness.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(720, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness.widget(_desktopPage(), textScale: 2));
    await tester.pumpAndSettle();
    expect(find.text('编辑精选作品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

http.Response response(http.Request request) {
  if (request.url.path.endsWith('/discovery/sites')) {
    return _response(
        jsonEncode({
          'sites': [
            {
              'site': 'qidian',
              'site_name': '起点中文网',
              'content': 'novel',
              'channels': [
                {
                  'site': 'qidian',
                  'key': 'home',
                  'name': '编辑推荐',
                  'kind': 'recommend',
                  'pageable': false
                },
                {
                  'site': 'qidian',
                  'key': 'monthly',
                  'name': '月票榜',
                  'kind': 'rank',
                  'group': '男频',
                  'pageable': true
                },
              ]
            },
            {
              'site': 'rank_only',
              'site_name': '仅有排行站点',
              'channels': [
                {
                  'site': 'rank_only',
                  'key': 'monthly',
                  'name': '月票榜',
                  'kind': 'rank'
                },
              ]
            },
          ]
        }),
        200);
  }
  final rank = request.url.path.endsWith('/monthly');
  final page = int.tryParse(request.url.queryParameters['page'] ?? '') ?? 1;
  return _response(
      jsonEncode({
        'site': 'qidian',
        'channel': rank ? 'monthly' : 'home',
        'page': page,
        'has_more': rank && page == 1,
        'items': [
          {
            'site': 'qidian',
            'kind': rank ? 'rank' : 'recommend',
            'rank': rank ? (page - 1) * 20 + 1 : null,
            'book_id': '42',
            'title': rank ? '月票榜作品 $page' : '编辑精选作品',
            'author': '示例作者',
            'intro': '故事从一卷古书开始，记录山川、风物与远行途中相遇的人。',
            'score': '热度 8.6 万',
            'url': 'https://www.qidian.com/book/42/',
          }
        ],
      }),
      200);
}

http.Response _response(String body, int status) => http.Response(body, status,
    headers: {'content-type': 'application/json; charset=utf-8'});

Widget _desktopPage() {
  final theme =
      buildQingJuanTheme(Brightness.light, platform: TargetPlatform.windows);
  return UiPlatformScope(
      platform: TargetPlatform.windows,
      child: FluentTheme(
          data: theme,
          child: DefaultTextStyle(
              style: theme.typography.body!,
              child: ColoredBox(
                  color: theme.scaffoldBackgroundColor,
                  child: const DiscoveryPage()))));
}
