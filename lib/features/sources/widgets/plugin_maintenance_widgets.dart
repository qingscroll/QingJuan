import 'package:fluent_ui/fluent_ui.dart';

import '../../../core/models/plugin_maintenance.dart';
import '../../../core/models/site_plugin.dart';
import '../plugin_maintenance_controller.dart';
import '../sources_controller.dart';
import 'plugin_rollback_confirmation.dart';

class PluginMaintenanceButton extends StatelessWidget {
  const PluginMaintenanceButton(
      {required this.plugin, required this.controller, super.key});

  final SitePlugin plugin;
  final SourcesController controller;

  Future<void> _open(BuildContext context) async {
    final maintenance =
        PluginMaintenanceController(controller, pluginId: plugin.id);
    try {
      await showDialog<void>(
          context: context,
          builder: (_) => PluginMaintenanceDialog(
              controller: maintenance, pluginName: plugin.name));
    } finally {
      maintenance.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Button(
        key: ValueKey('maintain-plugin-${plugin.id}'),
        onPressed: controller.changingPackages || !plugin.isInstalled
            ? null
            : () => _open(context),
        child: const Text('插件维护'),
      );
}

class PluginMaintenanceDialog extends StatelessWidget {
  const PluginMaintenanceDialog(
      {required this.controller, required this.pluginName, super.key});
  final PluginMaintenanceController controller;
  final String pluginName;

  Future<void> _rollback(BuildContext context) async {
    final report = controller.report;
    if (report == null || !controller.canRollback) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) =>
            PluginRollbackConfirmation(controller: controller, report: report));
    if (confirmed == true && controller.accepts(report)) {
      await controller.rollback(report);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) => PopScope(
            canPop: !controller.busy,
            child: ContentDialog(
              constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
              title: Text('$pluginName · 插件维护'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!controller.available)
                      const InfoBar(
                          title: Text('后端已切换'),
                          content: Text('请关闭此面板，在当前后端重新打开插件维护。'),
                          severity: InfoBarSeverity.warning)
                    else ...[
                      const Text('自检检查安装包完整性和当前运行接口，不访问站点，也不代表站点解析可用。'),
                      const SizedBox(height: 12),
                      if (controller.busy) ...[
                        const ProgressBar(),
                        const SizedBox(height: 8),
                        Text(controller.rollingBack ? '正在回退并刷新插件…' : '正在检查插件…'),
                      ],
                      if (controller.report case final report?)
                        _MaintenanceReport(report: report)
                      else if (!controller.busy && controller.message == null)
                        const Text('点击“运行自检”查看兼容性和可回退版本。'),
                      if (controller.message case final message?)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: InfoBar(
                                title: const Text('回退完成'),
                                content: Text(message),
                                severity: InfoBarSeverity.success)),
                      if (controller.error case final error?)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: InfoBar(
                                title: const Text('插件维护提示'),
                                content: Text(error),
                                severity: InfoBarSeverity.error)),
                    ],
                  ],
                ),
              ),
              actions: [
                Button(
                    onPressed: controller.busy
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('关闭')),
                if (controller.available)
                  Button(
                      key: const ValueKey('rollback-plugin'),
                      onPressed: controller.canRollback
                          ? () => _rollback(context)
                          : null,
                      child: const Text('回退上一版本')),
                if (controller.available)
                  FilledButton(
                      key: const ValueKey('check-plugin'),
                      onPressed: controller.canCheck ? controller.check : null,
                      child: const Text('运行自检')),
              ],
            ),
          ));
}

class _MaintenanceReport extends StatelessWidget {
  const _MaintenanceReport({required this.report});
  final PluginMaintenanceReport report;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoBar(
              title: Text(report.compatible ? '接口兼容性检查通过' : '插件需要修复'),
              severity: report.compatible
                  ? InfoBarSeverity.success
                  : InfoBarSeverity.warning),
          const SizedBox(height: 8),
          Text('当前版本：${report.version} · ${report.enabled ? '已启用' : '已停用'}'),
          Text(
              '插件协议：${report.apiVersion} / 后端支持：${report.supportedApiVersion}'),
          Text('后端 Python：${report.pythonVersion}'),
          Text(report.rollbackAvailable
              ? '可回退版本：${report.rollbackVersion}'
              : '没有可回退的上一版本'),
          Text('检查时间：${report.checkedAt}'),
          if (report.activeCalls > 0)
            const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('插件正在处理请求，请等待完成后重新自检。')),
          const SizedBox(height: 8),
          const Text('有任务使用此插件时，更新、回退和卸载会被拒绝；请先暂停任务并等待当前请求完成。'),
          for (final check in report.checks)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: InfoBar(
                  title: Text(check.label),
                  content: Text(check.message),
                  severity: switch (check.status) {
                    'passed' => InfoBarSeverity.success,
                    'failed' => InfoBarSeverity.error,
                    _ => InfoBarSeverity.warning,
                  },
                )),
        ],
      );
}
