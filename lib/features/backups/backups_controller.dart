import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/models/backup.dart';

class BackupsController extends ChangeNotifier {
  BackupsController(this.api, {required this.onRestored});

  final ApiClient api;
  final Future<void> Function() onRestored;
  List<BackupArtifact> artifacts = const [];
  BackupInspection? inspection;
  String? error;
  String? message;
  String? operation;
  bool loading = false;
  bool acknowledged = false;
  bool _enabled = false;
  bool _disposed = false;
  int? _revision;
  int _generation = 0;

  bool get enabled => _enabled;
  bool get busy => operation != null;
  int get contextGeneration => _generation;

  void setContext({required int revision, required bool enabled}) {
    if (_revision == revision && _enabled == enabled) return;
    _generation++;
    _revision = revision;
    _enabled = enabled;
    artifacts = const [];
    inspection = null;
    error = message = operation = null;
    loading = acknowledged = false;
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation) =>
      !_disposed && enabled && generation == _generation;

  void acknowledge(bool value) {
    if (!enabled || busy) return;
    acknowledged = value;
    notifyListeners();
  }

  Future<void> load() async {
    if (!enabled || loading || busy || _disposed) return;
    final generation = _generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final loaded = await api.fetchBackups();
      if (_current(generation)) artifacts = List.unmodifiable(loaded);
    } catch (exception) {
      if (_current(generation)) error = '$exception';
    } finally {
      if (_current(generation)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _perform(String label, Future<void> Function(int) action) async {
    if (!enabled || busy || loading || _disposed) return;
    final generation = _generation;
    operation = label;
    error = message = null;
    notifyListeners();
    try {
      await action(generation);
    } catch (exception) {
      if (_current(generation)) error = '$exception';
    } finally {
      if (_current(generation)) {
        operation = null;
        notifyListeners();
      }
    }
  }

  Future<void> create() async {
    if (!acknowledged) return;
    await _perform('正在创建完整备份', (generation) async {
      final artifact = await api.createBackup();
      if (!_current(generation)) return;
      artifacts = List.unmodifiable([
        artifact,
        ...artifacts.where((existing) => existing.id != artifact.id),
      ]);
      message = '备份已创建。请点击“保存到文件”，存放在受保护的独立位置。';
    });
  }

  Future<void> inspect(String path) async {
    if (!enabled || busy || loading) return;
    inspection = null;
    await _perform('正在检查备份文件', (generation) async {
      final result = await api.inspectBackup(filePath: path);
      if (_current(generation)) inspection = result;
    });
  }

  Future<void> restore(BackupInspection confirmed) async {
    if (!identical(inspection, confirmed)) return;
    await _perform('正在恢复数据并重新加载服务', (generation) async {
      // A restore is never retried automatically, even after a lost response.
      inspection = null;
      await api.restoreBackup(confirmed);
      if (!_current(generation)) return;
      message = '备份已恢复，正在刷新书库、任务和设置。';
      try {
        await onRestored();
      } catch (_) {
        if (_current(generation)) {
          error = '数据已恢复，但客户端刷新未完成。请返回书架并刷新。';
        }
        return;
      }
      if (_current(generation)) message = '备份已恢复，书库、任务和设置已刷新。';
    });
  }

  Future<void> download(BackupArtifact artifact, String targetPath) =>
      _perform('正在保存备份文件', (generation) async {
        await api.downloadBackupToFile(
            artifact: artifact, targetPath: targetPath);
        if (_current(generation)) message = '备份文件已保存并通过完整性校验。';
      });

  void reportPickerError() {
    if (_disposed || !enabled) return;
    error = '无法打开系统文件选择器，请稍后重试。';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
