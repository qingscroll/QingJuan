import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/site_plugin.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';

const pluginJson = <String, dynamic>{
  'id': 'sample',
  'name': '独立插件',
  'version': '1.2.0',
  'origin': 'installed',
  'author': '作者',
  'enabled': true,
  'apiVersion': 1,
};

void main() {
  test('package upload uses multipart and local request authentication',
      () async {
    final requests = <http.Request>[];
    final api = ApiClient(() => 'http://127.0.0.1:19453',
        client: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode(pluginJson), 201,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final plugin = await api.importSitePluginPackage(
        [80, 75, 3, 4], 'sample.qjplugin',
        replace: true);
    expect(plugin.isInstalled, isTrue);
    expect(requests.single.url.path, '/api/v1/plugins/import');
    expect(requests.single.headers['X-QingJuan-Local-Request'], '1');
    expect(requests.single.headers['content-type'],
        startsWith('multipart/form-data;'));
    expect(requests.single.body, contains('filename="sample.qjplugin"'));
    expect(requests.single.body, contains('name="replace"\r\n\r\ntrue'));
    expect(requests.single.followRedirects, isFalse);
  });

  test('successful install and uninstall update visible plugins', () async {
    final api =
        ApiClient(() => 'http://127.0.0.1', client: MockClient((request) async {
      if (request.method == 'DELETE') return http.Response('', 204);
      return http.Response(jsonEncode(pluginJson), 201,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final controller = SourcesController(api);
    await controller.importPluginPackage([80, 75], 'sample.zip');
    expect(controller.plugins.single.id, 'sample');
    expect(controller.changingPackages, isFalse);
    await controller.uninstallPlugin(controller.plugins.single);
    expect(controller.plugins, isEmpty);
    controller.dispose();
  });

  test('late installation response cannot populate a switched backend',
      () async {
    final response = Completer<http.Response>();
    final api = ApiClient(() => 'http://127.0.0.1',
        client: MockClient((_) => response.future));
    final controller = SourcesController(api);
    final installing = controller.importPluginPackage([80, 75], 'sample.zip');
    controller.resetForBackendSwitch();
    response.complete(http.Response(jsonEncode(pluginJson), 201,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await installing;
    expect(controller.plugins, isEmpty);
    expect(controller.changingPackages, isFalse);
    controller.dispose();
  });

  test(
      'installed plugin search produces a URL import without a Legado source ID',
      () async {
    final api =
        ApiClient(() => 'http://127.0.0.1', client: MockClient((request) async {
      expect(request.url.path, '/api/v1/plugins/search');
      return http.Response(
          jsonEncode([
            {
              'title': '作品',
              'sourceUrl': 'https://example.test/book/1',
              'sourceName': '独立插件',
              'sourceId': '',
              'bookKind': '长小说'
            }
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final controller = SourcesController(api);
    await controller.search('作品', engine: BookSearchEngine.installedPlugins);
    expect(controller.results.single.toImportPayload()['sourceId'], '');
    expect(controller.results.single.sourceName, '独立插件');
    controller.dispose();
  });

  test('metadata copy preserves installation and load failure information', () {
    final plugin = SitePlugin.fromJson({...pluginJson, 'loadError': '加载失败'})
        .copyWith(enabled: false);
    expect(plugin.isInstalled, isTrue);
    expect(plugin.author, '作者');
    expect(plugin.loadError, '加载失败');
    expect(plugin.enabled, isFalse);
  });
}
