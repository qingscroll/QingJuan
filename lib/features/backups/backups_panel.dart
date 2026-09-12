import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../../core/models/backup.dart';
import 'backup_acknowledgment.dart';
import 'backups_controller.dart';
import 'restore_confirmation.dart';

class BackupsPanel extends StatelessWidget {
  const BackupsPanel({
    required this.controller,
    this.selectFile,
    this.saveLocation,
    super.key,
  });

  final BackupsController controller;
  final Future<String?> Function()? selectFile;
  final Future<String?> Function(BackupArtifact)? saveLocation;

  bool get _disabled =>
      !controller.enabled || controller.busy || controller.loading;

  Future<void> _inspect() async {
    final generation = controller.contextGeneration;
    try {
      final path = selectFile != null
          ? await selectFile!()
          : (await openFile(acceptedTypeGroups: const [
              XTypeGroup(label: '青卷完整备份', extensions: ['zip']),
            ]))
              ?.path;
      if (path != null && generation == controller.contextGeneration) {
        await controller.inspect(path);
      }
    } catch (_) {
      if (generation == controller.contextGeneration) {
        controller.reportPickerError();
      }
    }
  }

  Future<void> _save(BackupArtifact artifact) async {
    final generation = controller.contextGeneration;
    try {
      final path = saveLocation != null
          ? await saveLocation!(artifact)
          : (await getSaveLocation(
              suggestedName: 'qingjuan-backup-${artifact.id}.zip',
              acceptedTypeGroups: const [
                XTypeGroup(label: '青卷完整备份', extensions: ['zip']),
              ],
            ))
              ?.path;
      if (path != null && generation == controller.contextGeneration) {
        await controller.download(artifact, path);
      }
    } catch (_) {
      if (generation == controller.contextGeneration) {
        controller.reportPickerError();
      }
    }
  }

  Future<void> _confirm(BuildContext context, BackupInspection report) async {
    final generation = controller.contextGeneration;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) =>
          RestoreConfirmation(report: report, controller: controller),
    );
    if (confirmed == true && generation == controller.contextGeneration) {
      await controller.restore(report);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('备份书库文件、阅读记录、任务、翻译设置及插件。创建或恢复期间，本机业务会短暂停止。'),
            const SizedBox(height: 12),
            if (!controller.enabled)
              const InfoBar(
                title: Text('请连接支持备份的 Windows 本机后端'),
                content: Text('服务器备份请在 Linux 管理界面操作。后端切换后，原预检结果已清除。'),
                severity: InfoBarSeverity.warning,
              ),
            if (controller.error case final error?) ...[
              InfoBar(
                title: const Text('操作未完成'),
                content: Text(error),
                severity: InfoBarSeverity.error,
              ),
              const SizedBox(height: 12),
            ],
            if (controller.message case final message?) ...[
              InfoBar(title: Text(message), severity: InfoBarSeverity.success),
              const SizedBox(height: 12),
            ],
            if (controller.loading || controller.busy) ...[
              const ProgressBar(),
              const SizedBox(height: 8),
              Text(controller.operation ?? '正在读取备份记录'),
              const SizedBox(height: 12),
            ],
            BackupAcknowledgment(
              checkboxKey: const ValueKey('backup-sensitive-acknowledgment'),
              checked: controller.acknowledged,
              onChanged: _disabled
                  ? null
                  : (value) => controller.acknowledge(value ?? false),
              label: '我了解备份含模型密钥、账号信息和可执行插件，并会安全保管备份文件。',
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 8, children: [
              FilledButton(
                key: const ValueKey('backup-create'),
                onPressed: _disabled || !controller.acknowledged
                    ? null
                    : () => unawaited(controller.create()),
                child: const Text('创建完整备份'),
              ),
              Button(
                key: const ValueKey('backup-select-file'),
                onPressed: _disabled ? null : () => unawaited(_inspect()),
                child: const Text('选择备份并预检'),
              ),
              Button(
                onPressed:
                    _disabled ? null : () => unawaited(controller.load()),
                child: const Text('刷新记录'),
              ),
            ]),
            if (controller.inspection case final report?) ...[
              const SizedBox(height: 20),
              Text(
                  '预检通过 · ${backupDate(report.createdAt)} · v${report.appVersion}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                  '当前书籍 ${report.currentCounts['books'] ?? 0} 本，备份中 ${report.backupCounts['books'] ?? 0} 本。恢复会替换当前数据。'),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Button(
                  key: const ValueKey('backup-review-restore'),
                  onPressed: _disabled
                      ? null
                      : () => unawaited(_confirm(context, report)),
                  child: const Text('查看恢复范围'),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Text('本机备份记录', style: FluentTheme.of(context).typography.subtitle),
            const SizedBox(height: 8),
            if (!controller.loading &&
                controller.error == null &&
                controller.artifacts.isEmpty &&
                controller.enabled)
              const Text('还没有备份。创建后可保存到磁盘，也可选择已有备份进行恢复。'),
            for (final artifact in controller.artifacts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                        '${backupDate(artifact.createdAt)} · v${artifact.appVersion}\n${_size(artifact.sizeBytes)}'),
                    Button(
                      key: ValueKey('backup-save-${artifact.id}'),
                      onPressed:
                          _disabled ? null : () => unawaited(_save(artifact)),
                      child: const Text('保存到文件'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
}

String backupDate(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return value;
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
}

String _size(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
