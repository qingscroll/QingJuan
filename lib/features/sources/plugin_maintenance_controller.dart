import 'package:flutter/foundation.dart';

import '../../core/models/plugin_maintenance.dart';
import '../../core/state/load_state.dart';
import 'sources_controller.dart';

class PluginMaintenanceController extends ChangeNotifier {
  PluginMaintenanceController(this.sources, {required this.pluginId})
      : _currentBackend = sources.captureBackend() {
    sources.addListener(_sourcesChanged);
  }

  final SourcesController sources;
  final String pluginId;
  final bool Function() _currentBackend;
  PluginMaintenanceReport? report;
  String? error;
  String? message;
  bool checking = false;
  bool rollingBack = false;
  bool available = true;
  bool _disposed = false;

  bool get busy => checking || rollingBack;
  bool get canCheck => available && !busy && !sources.changingPackages;
  bool get canRollback =>
      canCheck && report?.rollbackAvailable == true && report?.activeCalls == 0;

  bool accepts(PluginMaintenanceReport candidate) =>
      available && _currentBackend() && identical(report, candidate);

  void _sourcesChanged() {
    if (_disposed) return;
    if (!_currentBackend()) {
      available = false;
      checking = false;
      rollingBack = false;
      report = null;
      error = null;
      message = null;
    }
    notifyListeners();
  }

  Future<void> check() async {
    if (!canCheck) return;
    checking = true;
    error = null;
    message = null;
    report = null;
    notifyListeners();
    try {
      final result = await sources.api.checkPluginMaintenance(pluginId);
      if (!_usable) return;
      report = result;
    } catch (exception) {
      if (!_usable) return;
      error = '$exception';
    } finally {
      if (_usable) {
        checking = false;
        notifyListeners();
      }
    }
  }

  Future<void> rollback(PluginMaintenanceReport confirmed) async {
    if (!canRollback || !accepts(confirmed)) return;
    rollingBack = true;
    error = null;
    message = null;
    // A confirmation authorizes exactly one attempt against this package hash.
    report = null;
    notifyListeners();
    try {
      final plugin = await sources.api.rollbackSitePlugin(pluginId,
          expectedVersion: confirmed.version, expectedSha256: confirmed.sha256);
      if (!_usable) return;
      message = '已回退到 ${plugin.version}，启停设置保持不变。';
      await sources.load();
      if (!_usable) return;
      if (sources.state == LoadState.error) {
        error = '版本已回退，但插件列表刷新失败，请关闭面板后重新加载。';
      }
    } catch (exception) {
      if (!_usable) return;
      error = '$exception';
    } finally {
      if (_usable) {
        rollingBack = false;
        notifyListeners();
      }
    }
  }

  bool get _usable => !_disposed && available && _currentBackend();

  @override
  void dispose() {
    _disposed = true;
    sources.removeListener(_sourcesChanged);
    super.dispose();
  }
}
