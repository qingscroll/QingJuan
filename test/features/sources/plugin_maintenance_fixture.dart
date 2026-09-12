import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/plugin_maintenance.dart';
import 'package:qingjuan/core/models/site_plugin.dart';
import 'package:qingjuan/core/models/source.dart';

const pluginReport = PluginMaintenanceReport(
    pluginId: 'demo',
    version: '1.1.0',
    sha256: 'current-package-sha',
    apiVersion: 1,
    supportedApiVersion: 1,
    pythonVersion: '3.12.0',
    enabled: false,
    compatible: true,
    activeCalls: 0,
    rollbackAvailable: true,
    rollbackVersion: '1.0.0',
    rollbackSha256: 'previous-package-sha',
    checkedAt: '2026-09-11T00:00:00Z',
    checks: [
      PluginMaintenanceCheck(
          code: 'runtime',
          label: '已加载运行接口',
          status: 'passed',
          message: '清单声明的异步处理器及参数签名有效'),
      PluginMaintenanceCheck(
          code: 'scope',
          label: '自检范围',
          status: 'warning',
          message: '自检不访问第三方站点，不重新执行插件顶层代码；站点解析效果仍需通过实际导入验证')
    ]);

final maintainedPlugin = SitePlugin.fromJson({
  'id': 'demo',
  'name': '示例插件',
  'version': '1.0.0',
  'origin': 'installed',
  'enabled': false,
});

class MaintenanceApi extends ApiClient {
  MaintenanceApi() : super(() => 'http://127.0.0.1:19453');
  int checks = 0;
  int rollbacks = 0;
  int reloads = 0;
  String? expectedVersion;
  String? expectedSha256;
  Object? failure;
  Future<PluginMaintenanceReport> Function()? checkPending;
  Future<SitePlugin> Function()? rollbackPending;

  @override
  Future<PluginMaintenanceReport> checkPluginMaintenance(
      String pluginId) async {
    checks++;
    if (failure != null) throw failure!;
    return checkPending?.call() ?? pluginReport;
  }

  @override
  Future<SitePlugin> rollbackSitePlugin(String pluginId,
      {required String expectedVersion, required String expectedSha256}) async {
    rollbacks++;
    this.expectedVersion = expectedVersion;
    this.expectedSha256 = expectedSha256;
    if (failure != null) throw failure!;
    return rollbackPending?.call() ?? maintainedPlugin;
  }

  @override
  Future<List<SitePlugin>> fetchSitePlugins() async {
    reloads++;
    return [maintainedPlugin];
  }

  @override
  Future<List<BookSource>> fetchSources() async => [];
}
