import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/site_plugin.dart';
import '../../../shared/mobile_sheet.dart';
import '../../../shared/responsive.dart';
import '../sources_controller.dart';

class PluginBrowserLoginDialog extends StatefulWidget {
  const PluginBrowserLoginDialog(
      {required this.plugin, required this.controller, super.key});

  final SitePlugin plugin;
  final SourcesController controller;

  @override
  State<PluginBrowserLoginDialog> createState() =>
      _PluginBrowserLoginDialogState();
}

class _PluginBrowserLoginDialogState extends State<PluginBrowserLoginDialog> {
  SitePluginBrowserLogin? _flow;
  Timer? _timer;
  int _generation = 0;
  bool _success = false;
  bool _opening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _cancel(SitePluginBrowserLogin? flow) async {
    if (flow == null) return;
    try {
      await widget.controller.cancelBrowserLogin(widget.plugin.id, flow.flowId);
    } catch (_) {
      // The backend also expires abandoned flows after five minutes.
    }
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    unawaited(_cancel(_flow));
    super.dispose();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    _timer?.cancel();
    final previous = _flow;
    setState(() {
      _flow = null;
      _error = null;
      _success = false;
    });
    await _cancel(previous);
    if (!mounted || generation != _generation) return;
    try {
      final flow = await widget.controller.startBrowserLogin(widget.plugin.id);
      if (!mounted || generation != _generation) {
        await _cancel(flow);
        return;
      }
      setState(() => _flow = flow);
      _schedulePoll(generation);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '无法创建登录，请确认后端连接和插件状态后重试。');
      }
    }
  }

  void _schedulePoll(int generation) {
    _timer =
        Timer(const Duration(seconds: 2), () => unawaited(_poll(generation)));
  }

  Future<void> _poll(int generation) async {
    if (!mounted || generation != _generation) return;
    final flow = _flow;
    if (flow == null) return;
    if (DateTime.now().isAfter(flow.expiresAt)) {
      setState(() => _error = '登录已过期，请重新登录。');
      return;
    }
    try {
      final result = await widget.controller
          .pollBrowserLogin(widget.plugin.id, flow.flowId);
      if (!mounted || generation != _generation) return;
      if (result.loggedIn) {
        setState(() {
          _success = true;
          _error = null;
        });
      } else if (result.status != 'pending') {
        setState(() => _error = '登录已取消或过期，请重新登录。');
      } else {
        _schedulePoll(generation);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '读取登录状态失败，后端或账号可能已切换，请重试。');
      }
    }
  }

  Future<void> _open() async {
    final flow = _flow;
    if (flow == null || _opening) return;
    setState(() => _opening = true);
    try {
      // Verify the owning backend/account before opening its scoped login page.
      final status = await widget.controller
          .pollBrowserLogin(widget.plugin.id, flow.flowId);
      if (!mounted || !identical(flow, _flow)) return;
      if (status.status != 'pending') throw StateError('登录已结束');
      if (!await launchUrl(flow.verificationUri,
          mode: LaunchMode.externalApplication)) {
        throw StateError('无法打开浏览器');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开登录页面，请确认系统浏览器和后端连接后重试。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(mainAxisSize: MainAxisSize.min, children: [
      if (_flow == null && _error == null) const ProgressRing(),
      if (_success) const Icon(FluentIcons.completed_solid, size: 40),
      const SizedBox(height: 12),
      Text(_error ??
          (_success
              ? '少年梦账号已登录，可以下载账号可访问的章节。'
              : '在浏览器中输入少年梦账号密码并完成人机验证。登录成功后，这里会自动更新。')),
      const SizedBox(height: 12),
      const Text('登录状态仅保留在当前后端运行期间，退出后清除。'),
      if (_flow != null && !_success && _error == null) ...[
        const SizedBox(height: 18),
        FilledButton(
            key: const ValueKey('plugin-browser-login-open'),
            onPressed: _opening ? null : _open,
            child: const Text('打开登录页面')),
      ],
    ]);
    final actions = <Widget>[
      if (_error != null)
        Button(
            key: const ValueKey('plugin-browser-login-retry'),
            onPressed: _start,
            child: const Text('重新登录')),
      Button(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_success ? '完成' : '取消')),
    ];
    if (usesMobileUi(context)) {
      return MobileSheet(
          title: '${widget.plugin.name}账号登录',
          actions: actions,
          onClose: () => Navigator.of(context).pop(),
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(20), child: body));
    }
    return ContentDialog(
        title: Text('${widget.plugin.name}账号登录'),
        content: SizedBox(width: 420, child: body),
        actions: actions);
  }
}
