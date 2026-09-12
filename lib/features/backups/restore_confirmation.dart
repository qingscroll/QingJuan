import 'package:fluent_ui/fluent_ui.dart';

import '../../core/models/backup.dart';
import 'backup_acknowledgment.dart';
import 'backups_controller.dart';

class RestoreConfirmation extends StatefulWidget {
  const RestoreConfirmation(
      {required this.report, required this.controller, super.key});
  final BackupInspection report;
  final BackupsController controller;

  @override
  State<RestoreConfirmation> createState() => _RestoreConfirmationState();
}

class _RestoreConfirmationState extends State<RestoreConfirmation> {
  bool _accepted = false;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final valid = widget.controller.enabled &&
              identical(widget.controller.inspection, widget.report);
          return ContentDialog(
            constraints: const BoxConstraints(maxWidth: 640),
            title: const Text('确认替换本机数据'),
            content: !valid
                ? const Text('后端已切换或预检已失效，请关闭后重新选择备份。')
                : SizedBox(
                    width: 580,
                    height: MediaQuery.sizeOf(context).height * .45,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('恢复将用备份中的数据替换当前内容。建议先创建并保存当前备份。'),
                          const SizedBox(height: 12),
                          for (final entry in const {
                            'books': '书籍',
                            'reading_progress': '阅读记录',
                            'tasks': '任务',
                            'link_jobs': '链接历史',
                            'site_plugin_packages': '插件包',
                            'users': '账号',
                          }.entries)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text(
                                  '${entry.value}：当前 ${widget.report.currentCounts[entry.key] ?? 0} → 备份 ${widget.report.backupCounts[entry.key] ?? 0}'),
                            ),
                          const SizedBox(height: 12),
                          const Text('替换范围',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          for (final scope in widget.report.replacementScope)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text('• $scope'),
                            ),
                          const SizedBox(height: 12),
                          for (final warning in widget.report.warnings)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(warning),
                            ),
                          const SizedBox(height: 12),
                          BackupAcknowledgment(
                            checkboxKey:
                                const ValueKey('backup-restore-acknowledgment'),
                            checked: _accepted,
                            onChanged: (value) =>
                                setState(() => _accepted = value ?? false),
                            label: '我信任此备份及其中的插件，并确认替换以上数据。',
                          ),
                        ],
                      ),
                    ),
                  ),
            actions: [
              Button(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消')),
              FilledButton(
                key: const ValueKey('backup-confirm-restore'),
                onPressed: _accepted && valid
                    ? () => Navigator.of(context).pop(true)
                    : null,
                child: const Text('确认恢复'),
              ),
            ],
          );
        },
      );
}
