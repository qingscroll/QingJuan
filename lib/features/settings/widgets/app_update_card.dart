import 'package:fluent_ui/fluent_ui.dart';

import '../../../core/updates/app_update_controller.dart';
import 'settings_section_card.dart';

class AppUpdateCard extends StatelessWidget {
  const AppUpdateCard({required this.controller, super.key});
  final AppUpdateController controller;

  Future<void> _install(BuildContext context) async {
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => ContentDialog(
              title: const Text('退出并安装更新？'),
              content:
                  const Text('青卷将关闭并启动安装程序，本机下载和翻译任务会中断。请先保存正在编辑的内容；书库与设置会保留。'),
              actions: <Widget>[
                Button(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('稍后安装')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('退出并安装')),
              ],
            ));
    if (accepted == true) await controller.install();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final update = controller;
        final latest = update.release;
        return SettingsSectionCard(
            icon: FluentIcons.sync,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('软件更新',
                    style: FluentTheme.of(context).typography.subtitle),
                const SizedBox(height: 8),
                Text('当前版本：${update.currentVersion ?? '读取中'} · 每次启动自动检查'),
                const SizedBox(height: 8),
                Text(switch (update.status) {
                  UpdateStatus.idle => '从 GitHub Releases 获取正式版本',
                  UpdateStatus.checking => '正在检查新版本…',
                  UpdateStatus.current => '当前已是最新版本',
                  UpdateStatus.available => '发现新版本 ${latest!.version}',
                  UpdateStatus.downloading =>
                    '正在下载安装包 ${(update.progress * 100).toStringAsFixed(0)}%',
                  UpdateStatus.ready => '安装包已下载并通过校验，可以安装',
                  UpdateStatus.installing => '正在启动安装程序…',
                }),
                if (update.checkedAt case final time?) ...<Widget>[
                  const SizedBox(height: 6),
                  Text('上次检查：${time.toLocal().toString().split('.').first}',
                      style: FluentTheme.of(context).typography.caption),
                ],
                if (latest != null &&
                    latest.notes.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  const Text('更新说明'),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: SingleChildScrollView(
                          child: SelectableText(latest.notes))),
                ],
                if (latest != null && !update.canDownload) ...<Widget>[
                  const SizedBox(height: 12),
                  const Text('此版本安装包尚未就绪，可查看发布页面或稍后重新检查。'),
                ],
                if (!update.windows && latest != null) ...<Widget>[
                  const SizedBox(height: 8),
                  const Text('下载 APK 后按系统提示安装。'),
                ],
                if (update.status == UpdateStatus.downloading) ...<Widget>[
                  const SizedBox(height: 12),
                  ProgressBar(value: update.progress * 100),
                ],
                if (update.error case final error?) ...<Widget>[
                  const SizedBox(height: 12),
                  InfoBar(
                      title: const Text('更新未完成'),
                      content: Text(error),
                      severity: InfoBarSeverity.warning),
                ],
                const SizedBox(height: 16),
                Wrap(spacing: 10, runSpacing: 10, children: <Widget>[
                  Button(
                      key: const ValueKey('check-app-update'),
                      onPressed:
                          update.busy || update.status == UpdateStatus.ready
                              ? null
                              : update.check,
                      child: Text(update.status == UpdateStatus.checking
                          ? '正在检查'
                          : '检查更新')),
                  if (update.status == UpdateStatus.available &&
                      update.canDownload)
                    FilledButton(
                        onPressed: update.download,
                        child: Text(update.windows ? '下载更新' : '下载新版 APK')),
                  if (update.status == UpdateStatus.downloading)
                    Button(
                        onPressed: update.cancelDownload,
                        child: const Text('取消下载')),
                  if (update.status == UpdateStatus.ready)
                    FilledButton(
                        onPressed: () => _install(context),
                        child: const Text('退出并安装')),
                  HyperlinkButton(
                      onPressed: update.openRelease, child: const Text('发布页面')),
                ]),
              ],
            ));
      });
}

class AppUpdateBanner extends StatefulWidget {
  const AppUpdateBanner(
      {required this.controller, required this.onOpenSettings, super.key});
  final AppUpdateController controller;
  final VoidCallback onOpenSettings;
  @override
  State<AppUpdateBanner> createState() => _AppUpdateBannerState();
}

class _AppUpdateBannerState extends State<AppUpdateBanner> {
  bool _dismissed = false;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final release = widget.controller.release;
        if (_dismissed || release == null) return const SizedBox.shrink();
        return SafeArea(
            bottom: false,
            child: InfoBar(
                title: Text('青卷 ${release.version} 已发布'),
                content: const Text('可在设置中查看并更新。'),
                action: Button(
                    onPressed: widget.onOpenSettings,
                    child: const Text('查看更新')),
                onClose: () => setState(() => _dismissed = true)));
      });
}
