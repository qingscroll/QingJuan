import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' as material;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/user_account.dart';
import '../../../mobile/mobile_settings_route.dart';
import '../../../mobile/mobile_security_controls.dart';
import '../../../shared/responsive.dart';
import '../auth_controller.dart';

Future<GitHubDevicePollResult?> showGitHubDeviceAuthorization({
  required BuildContext context,
  required AuthController auth,
  required String purpose,
  String? password,
  String? code,
}) {
  final mobile = usesMobileUi(context);
  final credentials = _GitHubStartCredentials(password, code);
  Widget builder(BuildContext routeContext) => _GitHubDeviceDialog(
        auth: auth,
        purpose: purpose,
        credentials: credentials,
        mobile: mobile,
      );
  if (mobile) {
    return Navigator.of(context).push<GitHubDevicePollResult>(
      material.MaterialPageRoute<GitHubDevicePollResult>(builder: builder),
    );
  }
  return showDialog<GitHubDevicePollResult>(
    context: context,
    barrierDismissible: false,
    builder: builder,
  );
}

class _GitHubDeviceDialog extends StatefulWidget {
  const _GitHubDeviceDialog({
    required this.auth,
    required this.purpose,
    required this.credentials,
    required this.mobile,
  });

  final AuthController auth;
  final String purpose;
  final _GitHubStartCredentials credentials;
  final bool mobile;

  @override
  State<_GitHubDeviceDialog> createState() => _GitHubDeviceDialogState();
}

class _GitHubDeviceDialogState extends State<_GitHubDeviceDialog> {
  GitHubDeviceFlow? _flow;
  String? _error;
  int _generation = 0;
  int _retryAfterSeconds = 0;
  bool _copied = false;
  Timer? _pollTimer;
  Completer<void>? _pollDelay;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  @override
  void dispose() {
    _generation += 1;
    _cancelPollDelay();
    widget.credentials.clear();
    widget.auth.cancelGitHubDeviceFlow();
    super.dispose();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    try {
      final flow = await widget.auth.startGitHubDevice(
        purpose: widget.purpose,
        password: widget.credentials.password,
        code: widget.credentials.code,
      );
      widget.credentials.clear();
      if (!mounted || generation != _generation) return;
      setState(() {
        _flow = flow;
        _retryAfterSeconds = flow.intervalSeconds;
      });
      await _poll(generation, flow);
    } catch (error) {
      widget.credentials.clear();
      if (!mounted || generation != _generation) return;
      setState(() => _error = '$error');
    }
  }

  Future<void> _poll(int generation, GitHubDeviceFlow flow) async {
    var delaySeconds = flow.intervalSeconds;
    while (mounted && generation == _generation) {
      setState(() => _retryAfterSeconds = delaySeconds);
      for (var remaining = delaySeconds; remaining > 0; remaining--) {
        await _waitForPollTick();
        if (!mounted || generation != _generation) return;
        setState(() => _retryAfterSeconds = remaining - 1);
      }
      try {
        final result = await widget.auth.pollGitHubDevice(flow);
        if (!mounted || generation != _generation) return;
        if (result.status == GitHubDevicePollStatus.pending) {
          delaySeconds = result.retryAfterSeconds ?? flow.intervalSeconds;
          continue;
        }
        Navigator.of(context).pop(result);
        return;
      } catch (error) {
        if (!mounted || generation != _generation) return;
        setState(() => _error = '$error');
        return;
      }
    }
  }

  Future<void> _waitForPollTick() {
    _cancelPollDelay();
    final delay = Completer<void>();
    _pollDelay = delay;
    _pollTimer = Timer(const Duration(seconds: 1), () {
      if (!delay.isCompleted) delay.complete();
      if (identical(_pollDelay, delay)) {
        _pollDelay = null;
        _pollTimer = null;
      }
    });
    return delay.future;
  }

  void _cancelPollDelay() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final delay = _pollDelay;
    _pollDelay = null;
    if (delay != null && !delay.isCompleted) delay.complete();
  }

  Future<void> _copyCode() async {
    final code = _flow?.userCode;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  Future<void> _openTrustedVerificationPage() async {
    try {
      await launchUrl(
        GitHubDeviceFlow.trustedVerificationUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // 某些精简系统没有可用浏览器；用户仍可复制固定的可信地址。
    }
  }

  void _close() {
    _generation += 1;
    _cancelPollDelay();
    widget.auth.cancelGitHubDeviceFlow();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final content = _body(context);
    if (widget.mobile) {
      return MobileSettingsPage(
        title: widget.purpose == 'bind' ? '绑定 GitHub' : '使用 GitHub 登录',
        onClose: _close,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            content,
            const SizedBox(height: 20),
            material.OutlinedButton(
              key: const ValueKey('github-device-cancel'),
              onPressed: _close,
              child: const Text('取消授权'),
            ),
          ],
        ),
      );
    }
    return ContentDialog(
      title: Text(widget.purpose == 'bind' ? '绑定 GitHub' : '使用 GitHub 登录'),
      content: SizedBox(width: 460, child: content),
      actions: <Widget>[
        mobileSecurityAction(
          context,
          mobile: widget.mobile,
          key: const ValueKey('github-device-cancel'),
          onPressed: _close,
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    if (_error case final error?) {
      return Column(
        key: const ValueKey('github-device-error'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          mobileSecurityNotice(
            context,
            mobile: widget.mobile,
            title: const Text('GitHub 授权失败'),
            content: Text(error),
            severity: InfoBarSeverity.error,
          ),
          const SizedBox(height: 12),
          mobileSecurityAction(
            context,
            mobile: widget.mobile,
            primary: true,
            onPressed: widget.purpose == 'bind'
                ? _close
                : () {
                    setState(() {
                      _error = null;
                      _flow = null;
                    });
                    unawaited(_start());
                  },
            child: Text(widget.purpose == 'bind' ? '关闭后重新验证' : '重试'),
          ),
        ],
      );
    }
    final flow = _flow;
    if (flow == null) {
      return const Column(
        key: ValueKey('github-device-loading'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('正在向 GitHub 申请一次性设备代码…'),
          SizedBox(height: 14),
          ProgressBar(),
        ],
      );
    }
    return Column(
      key: const ValueKey('github-device-ready'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text('请在浏览器中打开 GitHub，并输入下面的代码：'),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: FluentTheme.of(context).resources.subtleFillColorSecondary,
            borderRadius: BorderRadius.circular(10),
          ),
          child: SelectableText(
            flow.userCode,
            key: const ValueKey('github-device-user-code'),
            textAlign: TextAlign.center,
            style: FluentTheme.of(context).typography.title?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            mobileSecurityAction(
              context,
              mobile: widget.mobile,
              key: const ValueKey('github-device-copy-code'),
              onPressed: _copyCode,
              child: Text(_copied ? '已复制代码' : '复制代码'),
            ),
            mobileSecurityAction(
              context,
              mobile: widget.mobile,
              primary: true,
              key: const ValueKey('github-device-open-browser'),
              onPressed: _openTrustedVerificationPage,
              child: const Text('打开 GitHub'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SelectableText(
          GitHubDeviceFlow.trustedVerificationUri.toString(),
          key: const ValueKey('github-device-trusted-url'),
        ),
        const SizedBox(height: 14),
        const ProgressBar(),
        const SizedBox(height: 8),
        Text(
          _retryAfterSeconds > 0
              ? '等待 GitHub 确认，$_retryAfterSeconds 秒后检查…'
              : '正在检查授权结果…',
          style: FluentTheme.of(context).typography.caption,
        ),
        const SizedBox(height: 10),
        mobileSecurityNotice(
          context,
          mobile: widget.mobile,
          title: const Text('安全提示'),
          content: const Text(
            '只在 github.com/login/device 输入本窗口本次显示的代码；不要替他人输入代码。青卷不会持久化设备代码，GitHub 访问令牌也不会下发到客户端。',
          ),
          severity: InfoBarSeverity.info,
        ),
      ],
    );
  }
}

class _GitHubStartCredentials {
  _GitHubStartCredentials(this.password, this.code);

  String? password;
  String? code;

  void clear() {
    password = null;
    code = null;
  }
}
