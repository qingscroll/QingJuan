import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/backup.dart';
import 'package:qingjuan/features/backups/backups_controller.dart';

const artifact = BackupArtifact(
    id: 'backup-one',
    createdAt: '2026-09-11T00:00:00Z',
    appVersion: '2.2.1',
    sizeBytes: 1234,
    sha256: 'digest');
const inspection = BackupInspection(
    restoreId: 'restore-one',
    confirmationToken: 'confirmation',
    createdAt: '2026-09-11T00:00:00Z',
    appVersion: '2.2.1',
    backupCounts: {'books': 3, 'reading_progress': 2},
    currentCounts: {'books': 1},
    replacementScope: ['书库与阅读记录', '翻译设置和插件'],
    warnings: ['只恢复可信备份']);

class BackupTestApi extends ApiClient {
  BackupTestApi() : super(() => 'http://127.0.0.1:19453');
  int creates = 0;
  int restores = 0;
  int inspections = 0;
  int downloads = 0;
  String? downloadedPath;
  Object? failure;
  Future<List<BackupArtifact>> Function()? listPending;
  Future<BackupInspection> Function()? inspectPending;
  Future<void> Function()? restorePending;

  @override
  Future<List<BackupArtifact>> fetchBackups() async {
    if (failure != null) throw failure!;
    return listPending?.call() ?? [artifact];
  }

  @override
  Future<BackupArtifact> createBackup() async {
    creates++;
    return artifact;
  }

  @override
  Future<BackupInspection> inspectBackup({required String filePath}) async {
    inspections++;
    if (failure != null) throw failure!;
    return inspectPending?.call() ?? inspection;
  }

  @override
  Future<void> restoreBackup(BackupInspection inspection) async {
    restores++;
    if (failure != null) throw failure!;
    await restorePending?.call();
  }

  @override
  Future<void> downloadBackupToFile(
      {required BackupArtifact artifact, required String targetPath}) async {
    downloads++;
    downloadedPath = targetPath;
    if (failure != null) throw failure!;
  }
}

void main() {
  late BackupTestApi api;
  late BackupsController controller;
  var refreshed = 0;
  setUp(() {
    api = BackupTestApi();
    refreshed = 0;
    controller = BackupsController(api, onRestored: () async {
      refreshed++;
    })
      ..setContext(revision: 1, enabled: true);
  });
  tearDown(() {
    controller.dispose();
    api.close();
  });

  test(
      'backup creation requires sensitive-data acknowledgment and adds saved artifact',
      () async {
    await controller.create();
    expect(api.creates, 0);
    controller.acknowledge(true);
    await controller.create();
    expect(api.creates, 1);
    expect(controller.artifacts, [artifact]);
    expect(controller.message, contains('保存到文件'));
  });

  test(
      'list failure has retry and never masquerades as an empty successful list',
      () async {
    api.failure = StateError('服务繁忙');
    await controller.load();
    expect(controller.error, contains('服务繁忙'));
    expect(controller.loading, isFalse);
    api.failure = null;
    await controller.load();
    expect(controller.artifacts, [artifact]);
    expect(controller.error, isNull);
  });

  test('switch discards late inspection, acknowledgment and saved records',
      () async {
    final pending = Completer<BackupInspection>();
    api.inspectPending = () => pending.future;
    await controller.load();
    controller.acknowledge(true);
    final reading = controller.inspect('/old.zip');
    controller.setContext(revision: 2, enabled: false);
    pending.complete(inspection);
    await reading;
    expect(controller.inspection, isNull);
    expect(controller.artifacts, isEmpty);
    expect(controller.acknowledged, isFalse);
    expect(controller.busy, isFalse);
  });

  test(
      'restore requires current inspection, clears confirmation and refreshes only once',
      () async {
    await controller.restore(inspection);
    expect(api.restores, 0);
    await controller.inspect('/source.zip');
    await controller.restore(inspection);
    await controller.restore(inspection);
    expect(api.restores, 1);
    expect(refreshed, 1);
    expect(controller.inspection, isNull);
    expect(controller.message, contains('已刷新'));
  });

  test(
      'failed restore is not automatically retried and needs another inspection',
      () async {
    await controller.inspect('/source.zip');
    api.failure = StateError('后端繁忙，请先暂停任务');
    await controller.restore(inspection);
    await controller.restore(inspection);
    expect(api.restores, 1);
    expect(controller.error, contains('先暂停任务'));
    expect(controller.inspection, isNull);
    expect(refreshed, 0);
  });

  test('a late successful restore cannot refresh a new backend', () async {
    final pending = Completer<void>();
    api.restorePending = () => pending.future;
    await controller.inspect('/source.zip');
    final restoring = controller.restore(inspection);
    controller.setContext(revision: 2, enabled: true);
    pending.complete();
    await restoring;
    expect(refreshed, 0);
    expect(controller.message, isNull);
  });

  test('duplicate restore requests are ignored while one is pending', () async {
    final pending = Completer<void>();
    api.restorePending = () => pending.future;
    await controller.inspect('/source.zip');
    final restoring = controller.restore(inspection);
    await controller.restore(inspection);
    expect(controller.busy, isTrue);
    expect(api.restores, 1);
    pending.complete();
    await restoring;
    expect(refreshed, 1);
  });
}
