import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/models/plugin_maintenance.dart';
import 'package:qingjuan/core/models/site_plugin.dart';
import 'package:qingjuan/features/sources/plugin_maintenance_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';

import 'plugin_maintenance_fixture.dart';

void main() {
  late MaintenanceApi api;
  late SourcesController sources;
  late PluginMaintenanceController controller;
  setUp(() {
    api = MaintenanceApi();
    sources = SourcesController(api);
    controller = PluginMaintenanceController(sources, pluginId: 'demo');
  });
  tearDown(() {
    controller.dispose();
    sources.dispose();
    api.close();
  });

  test('self-check is explicit, failure is visible and retry replaces it',
      () async {
    expect(api.checks, 0);
    expect(controller.report, isNull);
    api.failure = Exception('服务器正在维护');
    await controller.check();
    expect(controller.error, contains('正在维护'));
    expect(controller.canCheck, isTrue);
    api.failure = null;
    await controller.check();
    expect(controller.error, isNull);
    expect(controller.report, same(pluginReport));
    expect(controller.canRollback, isTrue);
  });

  test(
      'rollback consumes the inspected version/hash and refreshes enabled state',
      () async {
    await controller.rollback(pluginReport);
    expect(api.rollbacks, 0);
    await controller.check();
    await controller.rollback(pluginReport);
    await controller.rollback(pluginReport);
    expect(api.rollbacks, 1);
    expect(api.expectedVersion, '1.1.0');
    expect(api.expectedSha256, 'current-package-sha');
    expect(api.reloads, 1);
    expect(sources.plugins.single.enabled, isFalse);
    expect(controller.message, contains('1.0.0'));
    expect(controller.report, isNull);
  });

  test('busy refusal requires another inspection, without automatic retry',
      () async {
    await controller.check();
    api.failure = Exception('插件正在使用，请先暂停任务');
    await controller.rollback(pluginReport);
    await controller.rollback(pluginReport);
    expect(api.rollbacks, 1);
    expect(controller.error, contains('暂停任务'));
    expect(controller.canRollback, isFalse);
    expect(api.reloads, 0);
  });

  test('backend switch clears a report and discards a late inspection',
      () async {
    final pending = Completer<PluginMaintenanceReport>();
    api.checkPending = () => pending.future;
    final checking = controller.check();
    sources.resetForBackendSwitch();
    pending.complete(pluginReport);
    await checking;
    expect(controller.available, isFalse);
    expect(controller.report, isNull);
    expect(controller.busy, isFalse);
    await controller.check();
    expect(api.checks, 1);
  });

  test('late rollback does not reload another backend or repeat the request',
      () async {
    final pending = Completer<SitePlugin>();
    api.rollbackPending = () => pending.future;
    await controller.check();
    final restoring = controller.rollback(pluginReport);
    await controller.rollback(pluginReport);
    expect(api.rollbacks, 1);
    sources.resetForBackendSwitch();
    pending.complete(maintainedPlugin);
    await restoring;
    expect(api.reloads, 0);
    expect(controller.message, isNull);
    expect(controller.canRollback, isFalse);
  });
}
