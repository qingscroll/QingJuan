import 'package:fluent_ui/fluent_ui.dart';

import '../../../core/models/plugin_maintenance.dart';
import '../plugin_maintenance_controller.dart';

class PluginRollbackConfirmation extends StatelessWidget {
  const PluginRollbackConfirmation(
      {required this.controller, required this.report, super.key});
  final PluginMaintenanceController controller;
  final PluginMaintenanceReport report;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final current = controller.accepts(report) && controller.canRollback;
        return ContentDialog(
          title: const Text('确认回退插件版本'),
          content: SingleChildScrollView(
            child: current
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('版本：${report.version} → ${report.rollbackVersion}'),
                      const SizedBox(height: 12),
                      const Text('回退会重新加载之前安装的 Python 代码，并保留插件启停设置和已导入书籍。'),
                      const SizedBox(height: 8),
                      const Text('当前版本会成为可回退版本。请确认你仍信任此插件；回退本身不能验证站点是否恢复可用。'),
                    ],
                  )
                : const Text('后端或自检结果已变化，请取消后重新自检。'),
          ),
          actions: [
            Button(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消')),
            FilledButton(
                key: const ValueKey('confirm-plugin-rollback'),
                onPressed:
                    current ? () => Navigator.of(context).pop(true) : null,
                child: const Text('确认回退')),
          ],
        );
      });
}
