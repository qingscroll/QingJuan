import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/core/models/discovery.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/discovery/discovery_controller.dart';

void main() {
  late DiscoveryApi api;
  late DiscoveryController controller;
  setUp(() {
    api = DiscoveryApi();
    controller = DiscoveryController(api);
  });
  tearDown(() {
    controller.dispose();
    api.close();
  });

  test('loads the first site recommendation and exposes immutable lists',
      () async {
    await controller.loadSites();
    expect(controller.sitesState, LoadState.ready);
    expect(controller.kind, 'recommend');
    expect(controller.selectedSite?.site, 'first');
    expect(controller.selectedChannel?.key, 'home');
    expect(controller.result?.items.single.title, 'first/home/1');
    expect(api.limits, [100]);
    expect(() => controller.sites.clear(), throwsUnsupportedError);
    expect(() => controller.channels.clear(), throwsUnsupportedError);
  });

  test('rank-only sites leave recommendations empty and switch explicitly',
      () async {
    await controller.loadSites();
    await controller.selectSite('rank_only');
    expect(controller.kind, 'recommend');
    expect(controller.channels, isEmpty);
    expect(controller.selectedChannel, isNull);
    expect(controller.result, isNull);
    expect(controller.contentState, LoadState.empty);
    expect(api.requests, hasLength(1));
    await controller.selectKind('rank');
    expect(controller.selectedChannel?.key, 'monthly');
    expect(controller.result?.items.single.title, 'rank_only/monthly/1');
  });

  test('changing a channel resets page and discards late content', () async {
    await controller.loadSites();
    final pending = Completer<DiscoveryResult>();
    api.pending = pending;
    final loading = controller.nextPage();
    expect(controller.page, 2);
    await controller.selectKind('rank');
    expect(controller.page, 1);
    pending.complete(resultFor('first', 'home', 2));
    await loading;
    expect(controller.result?.channel, 'monthly');
    expect(controller.result?.page, 1);
    expect(controller.contentState, LoadState.ready);
  });

  test('refresh bypasses cache while pagination respects end and pageable',
      () async {
    await controller.loadSites();
    await controller.nextPage();
    expect(controller.page, 2);
    expect(api.limits, [100, 100]);
    expect(controller.hasMore, isFalse);
    await controller.nextPage();
    expect(api.requests, hasLength(2));
    await controller.previousPage();
    await controller.refresh();
    expect(api.requests.last, 'first/home/1/true');
    await controller.selectChannel('featured');
    expect(controller.isPageable, isFalse);
    expect(controller.hasMore, isFalse);
    expect(controller.canNextPage, isFalse);
    expect(controller.canPreviousPage, isFalse);
    await controller.nextPage();
    expect(controller.page, 1);
  });

  test('pagination stays available after a later page fails', () async {
    await controller.loadSites();
    expect(controller.isPageable, isTrue);
    expect(controller.canNextPage, isTrue);
    expect(controller.canPreviousPage, isFalse);
    api.contentError = const ApiException('第二页暂时无法加载');
    await controller.nextPage();
    expect(controller.page, 2);
    expect(controller.result, isNull);
    expect(controller.contentState, LoadState.error);
    expect(controller.canPreviousPage, isTrue);
    expect(controller.canNextPage, isFalse);
    api.contentError = null;
    await controller.previousPage();
    expect(controller.page, 1);
    expect(controller.result?.items.single.title, 'first/home/1');
    expect(controller.canNextPage, isTrue);
    expect(controller.canPreviousPage, isFalse);
  });

  test('loading and partial errors cannot advance another page', () async {
    await controller.loadSites();
    final pending = Completer<DiscoveryResult>();
    api.pending = pending;
    final loading = controller.nextPage();
    expect(controller.canNextPage, isFalse);
    expect(controller.canPreviousPage, isFalse);
    await controller.nextPage();
    await controller.previousPage();
    expect(api.requests, hasLength(2));
    pending.complete(resultFor('first', 'home', 2));
    await loading;
    expect(controller.canPreviousPage, isTrue);
    expect(controller.canNextPage, isFalse);
    api.resultError = '返回数据不完整';
    await controller.previousPage();
    expect(controller.hasMore, isTrue);
    expect(controller.canNextPage, isFalse);
  });

  test('channel errors are retryable and backend partial errors stay visible',
      () async {
    api.contentError = const ApiException('站点暂时不可用');
    await controller.loadSites();
    expect(controller.contentState, LoadState.error);
    expect(controller.error, '站点暂时不可用');
    api.contentError = null;
    await controller.refresh();
    expect(controller.contentState, LoadState.ready);
    expect(controller.error, isNull);
    api.resultError = '上游响应不完整';
    await controller.refresh();
    expect(controller.contentState, LoadState.error);
    expect(controller.error, '上游响应不完整');
    expect(controller.result, isNotNull);
  });

  test('site errors are independent of content and can be retried', () async {
    api.sitesError = const ApiException('无法获取站点');
    await controller.loadSites();
    expect(controller.sitesState, LoadState.error);
    expect(controller.sitesError, '无法获取站点');
    expect(controller.error, isNull);
    api.sitesError = null;
    await controller.refresh();
    expect(controller.sitesState, LoadState.ready);
    expect(controller.sitesError, isNull);
  });

  test('reset discards pending site requests and allows immediate reload',
      () async {
    final pending = Completer<List<DiscoverySite>>();
    api.sitesPending = pending;
    final loading = controller.loadSites();
    controller.resetForBackendChange();
    expect(controller.sitesState, LoadState.idle);
    await controller.loadSites();
    pending.complete([const DiscoverySite(site: 'stale', siteName: '旧站点')]);
    await loading;
    expect(controller.selectedSite?.site, 'first');
    expect(controller.sites.map((site) => site.site), isNot(contains('stale')));
  });

  test('reset discards late failures without restoring old state', () async {
    await controller.loadSites();
    final pending = Completer<DiscoveryResult>();
    api.pending = pending;
    final loading = controller.refresh();
    controller.resetForBackendChange();
    pending.completeError(const ApiException('旧后端错误'));
    await loading;
    expect(controller.sites, isEmpty);
    expect(controller.result, isNull);
    expect(controller.contentState, LoadState.idle);
    expect(controller.error, isNull);
  });

  test('dispose invalidates pending requests and subsequent operations',
      () async {
    final disposable = DiscoveryController(api);
    final pending = Completer<List<DiscoverySite>>();
    api.sitesPending = pending;
    final loading = disposable.loadSites();
    disposable.dispose();
    pending.complete(sites);
    await loading;
    await disposable.loadSites();
    disposable.resetForBackendChange();
    expect(api.requests, isEmpty);
  });

  test('duplicate site and refresh requests are ignored while loading',
      () async {
    final pendingSites = Completer<List<DiscoverySite>>();
    api.sitesPending = pendingSites;
    final loading = controller.loadSites();
    await controller.loadSites();
    expect(api.siteRequests, 1);
    pendingSites.complete(sites);
    await loading;
    final pending = Completer<DiscoveryResult>();
    api.pending = pending;
    final refreshing = controller.refresh();
    await controller.refresh();
    expect(api.requests, hasLength(2));
    pending.complete(resultFor('first', 'home', 1));
    await refreshing;
  });
}

const sites = [
  DiscoverySite(site: 'first', siteName: '第一站', channels: [
    DiscoveryChannel(site: 'first', key: 'home', name: '首页', kind: 'recommend'),
    DiscoveryChannel(
        site: 'first',
        key: 'featured',
        name: '精选',
        kind: 'recommend',
        pageable: false),
    DiscoveryChannel(site: 'first', key: 'monthly', name: '月榜', kind: 'rank'),
  ]),
  DiscoverySite(site: 'rank_only', siteName: '只有排行', channels: [
    DiscoveryChannel(
        site: 'rank_only', key: 'monthly', name: '月榜', kind: 'rank'),
  ]),
];

DiscoveryResult resultFor(String site, String channel, int page,
        {String? error}) =>
    DiscoveryResult(
        site: site,
        channel: channel,
        page: page,
        hasMore: page < 2,
        error: error,
        items: [DiscoveryBook(site: site, title: '$site/$channel/$page')]);

class DiscoveryApi extends ApiClient {
  DiscoveryApi() : super(() => 'http://127.0.0.1:19453');

  final requests = <String>[];
  final limits = <int>[];
  int siteRequests = 0;
  Exception? sitesError;
  Exception? contentError;
  String? resultError;
  Completer<List<DiscoverySite>>? sitesPending;
  Completer<DiscoveryResult>? pending;

  @override
  Future<List<DiscoverySite>> fetchDiscoverySites() async {
    siteRequests += 1;
    final delayed = sitesPending;
    sitesPending = null;
    if (delayed != null) return delayed.future;
    final failure = sitesError;
    if (failure != null) throw failure;
    return sites;
  }

  @override
  Future<DiscoveryResult> fetchDiscoveryChannel(String site, String channel,
      {int page = 1, int limit = 20, bool refresh = false}) async {
    requests.add('$site/$channel/$page/$refresh');
    limits.add(limit);
    final delayed = pending;
    pending = null;
    if (delayed != null) return delayed.future;
    final failure = contentError;
    if (failure != null) throw failure;
    return resultFor(site, channel, page, error: resultError);
  }
}
