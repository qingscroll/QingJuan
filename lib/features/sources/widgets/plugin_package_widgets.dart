import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../../../core/models/site_plugin.dart';
import '../sources_controller.dart';

class PluginPackageImportButton extends StatefulWidget {
  const PluginPackageImportButton({required this.controller, super.key});
  final SourcesController controller;

  @override
  State<PluginPackageImportButton> createState() =>
      _PluginPackageImportButtonState();
}

class _PluginPackageImportButtonState extends State<PluginPackageImportButton> {
  bool _busy = false;

  Future<void> _choosePackage() async {
    if (_busy) return;
    final current = widget.controller.captureBackend();
    setState(() => _busy = true);
    try {
      final file = await openFile(acceptedTypeGroups: const [
        XTypeGroup(label: '青卷插件包', extensions: ['zip', 'qjplugin']),
      ]);
      if (file == null || !current()) return;
      if (await file.length() > 2 * 1024 * 1024) {
        throw Exception('插件包不能超过 2 MiB');
      }
      final bytes = await file.readAsBytes();
      if (!current()) return;
      final inspection =
          await widget.controller.inspectPluginPackage(bytes, file.name);
      if (!mounted || !current()) return;
      await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _PackageInstallDialog(
                inspection: inspection,
                install: () async {
                  if (!current()) throw Exception('后端已切换，请重新选择插件包');
                  await widget.controller.importPluginPackage(bytes, file.name,
                      replace: inspection.installedVersion != null);
                },
              ));
    } catch (error) {
      if (!mounted || !current()) return;
      displayInfoBar(context,
          builder: (_, __) => InfoBar(
                title: const Text('插件导入失败'),
                content: Text('$error'),
                severity: InfoBarSeverity.error,
              ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FilledButton(
        key: const ValueKey('import-plugin-package'),
        onPressed:
            _busy || widget.controller.changingPackages ? null : _choosePackage,
        child: Text(_busy ? '正在校验插件包…' : '导入插件'),
      );
}

class _PackageInstallDialog extends StatefulWidget {
  const _PackageInstallDialog(
      {required this.inspection, required this.install});
  final SitePluginPackageInspection inspection;
  final Future<void> Function() install;

  @override
  State<_PackageInstallDialog> createState() => _PackageInstallDialogState();
}

class _PackageInstallDialogState extends State<_PackageInstallDialog> {
  bool _trusted = false;
  bool _saving = false;
  String? _error;

  Future<void> _install() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.install();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.inspection;
    final plugin = info.plugin;
    return PopScope(
      canPop: !_saving,
      child: ContentDialog(
        title: Text(info.installedVersion == null ? '安装站点插件' : '更新站点插件'),
        content: SingleChildScrollView(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
              Text('${plugin.name} (${plugin.id})'),
              const SizedBox(height: 8),
              Text('作者声明：${plugin.author}'),
              Text(info.installedVersion == null
                  ? '版本：${plugin.version}'
                  : '版本：${info.installedVersion} → ${plugin.version}'),
              Text('站点：${plugin.domains.join('、')}'),
              const SizedBox(height: 8),
              Text(plugin.description),
              const SizedBox(height: 16),
              const InfoBar(
                title: Text('仅安装你信任的插件'),
                content: Text(
                    '插件会以青卷后端权限运行 Python 代码，可访问后端数据和网络。作者信息未经认证。更新会保留启停状态。'),
                severity: InfoBarSeverity.warning,
              ),
              const SizedBox(height: 12),
              Checkbox(
                  checked: _trusted,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _trusted = value ?? false),
                  content: const Text('我信任此插件来源并同意运行其代码')),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: InfoBar(
                      title: const Text('安装失败'),
                      content: Text(_error!),
                      severity: InfoBarSeverity.error,
                    )),
            ])),
        actions: [
          Button(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
              onPressed: !_trusted || _saving ? null : _install,
              child: Text(_saving ? '正在安装…' : '确认安装')),
        ],
      ),
    );
  }
}

class PluginPackageUninstallButton extends StatelessWidget {
  const PluginPackageUninstallButton(
      {required this.plugin, required this.controller, super.key});
  final SitePlugin plugin;
  final SourcesController controller;

  Future<void> _uninstall(BuildContext context) async {
    final current = controller.captureBackend();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => ContentDialog(
              title: Text('卸载${plugin.name}？'),
              content: const Text('卸载后无法继续通过此插件解析或下载。已导入书籍和缓存章节会保留。'),
              actions: [
                Button(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('卸载')),
              ],
            ));
    if (confirmed != true || !current()) return;
    try {
      await controller.uninstallPlugin(plugin);
    } catch (error) {
      if (!context.mounted || !current()) return;
      displayInfoBar(context,
          builder: (_, __) => InfoBar(
                title: const Text('卸载失败'),
                content: Text('$error'),
                severity: InfoBarSeverity.error,
              ));
    }
  }

  @override
  Widget build(BuildContext context) => Button(
        key: ValueKey('uninstall-plugin-${plugin.id}'),
        onPressed:
            controller.changingPackages ? null : () => _uninstall(context),
        child: const Text('卸载插件'),
      );
}
