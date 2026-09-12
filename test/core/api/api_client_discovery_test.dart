import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';

void main() {
  test('discovery sites use the authenticated backend and sites envelope',
      () async {
    final api = ApiClient(() => 'https://qingjuan.example',
        token: () => 'connection',
        userToken: () => 'session',
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/discovery/sites');
          expect(request.method, 'GET');
          expect(request.headers['Authorization'], 'Bearer connection');
          expect(request.headers['X-QingJuan-User-Token'], 'session');
          return http.Response(
              jsonEncode({
                'sites': [
                  {
                    'site': 'qidian',
                    'site_name': '起点',
                    'channels': [
                      {
                        'site': 'qidian',
                        'key': 'monthly',
                        'name': '月票榜',
                        'kind': 'rank'
                      }
                    ]
                  }
                ]
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    addTearDown(api.close);
    final sites = await api.fetchDiscoverySites();
    expect(sites.single.siteName, '起点');
    expect(sites.single.channels.single.key, 'monthly');
    expect(() => sites.clear(), throwsUnsupportedError);
  });

  test('channel path segments and pagination remain separate URI components',
      () async {
    final api = ApiClient(() => 'https://qingjuan.example',
        client: MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.pathSegments, [
        'api',
        'v1',
        'discovery',
        'sites',
        'site/中文',
        'channels',
        'channel?月榜'
      ]);
      expect(request.url.queryParameters,
          {'page': '2', 'limit': '30', 'refresh': 'true'});
      return http.Response(
          jsonEncode({
            'site': 'site/中文',
            'channel': 'channel?月榜',
            'page': 2,
            'limit': 30,
            'has_more': false,
            'items': [
              {
                'site': 'site/中文',
                'title': '作品',
                'url': 'https://books.example/one'
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    addTearDown(api.close);
    final result = await api.fetchDiscoveryChannel('site/中文', 'channel?月榜',
        page: 2, limit: 30, refresh: true);
    expect(result.page, 2);
    expect(result.items.single.title, '作品');
  });

  test('channel requests fail once and preserve normalized gateway errors',
      () async {
    var requests = 0;
    final api = ApiClient(() => 'https://qingjuan.example',
        client: MockClient((request) async {
      requests += 1;
      return http.Response('<html>private upstream details</html>', 502);
    }));
    addTearDown(api.close);
    await expectLater(
        api.fetchDiscoveryChannel('qidian', 'monthly'),
        throwsA(isA<ApiException>().having((error) => error.message, 'message',
            allOf(contains('HTTP 502'), isNot(contains('private'))))));
    expect(requests, 1);
  });

  test('transport failures do not repeat long-running discovery requests',
      () async {
    var requests = 0;
    final api = ApiClient(() => 'https://qingjuan.example',
        client: MockClient((request) async {
      requests += 1;
      throw http.ClientException('network unavailable');
    }));
    addTearDown(api.close);
    await expectLater(api.fetchDiscoveryChannel('qidian', 'monthly'),
        throwsA(isA<ApiException>()));
    expect(requests, 1);
  });
}
