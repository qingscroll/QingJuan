import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;

import '../../mobile/mobile_security_controls.dart';
import '../../mobile/mobile_settings_route.dart';
import '../../shared/responsive.dart';
import 'account_maintenance_controller.dart';
import 'account_maintenance_form.dart';
import 'auth_controller.dart';

Future<void> showAccountMaintenanceDialog(
    {required BuildContext context, required AuthController auth}) {
  final mobile = usesMobileUi(context);
  Widget builder(BuildContext context) =>
      _MaintenancePanel(auth: auth, mobile: mobile);
  return mobile
      ? Navigator.of(context)
          .push<void>(material.MaterialPageRoute(builder: builder))
      : showDialog<void>(context: context, builder: builder);
}

class _MaintenancePanel extends StatefulWidget {
  const _MaintenancePanel({required this.auth, required this.mobile});
  final AuthController auth;
  final bool mobile;
  @override
  State<_MaintenancePanel> createState() => _MaintenancePanelState();
}

class _MaintenancePanelState extends State<_MaintenancePanel> {
  late final AccountMaintenanceController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AccountMaintenanceController(widget.auth);
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = AnimatedBuilder(
        animation: _controller, builder: (context, child) => _body());
    if (widget.mobile) {
      return MobileSettingsPage(title: '密码、邮箱与登录设备', child: body);
    }
    return ContentDialog(
      title: const Text('密码、邮箱与登录设备'),
      content: SizedBox(width: 530, child: SingleChildScrollView(child: body)),
      actions: [
        Button(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'))
      ],
    );
  }

  Widget _body() {
    final account = _controller.account;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_controller.error case final error?) ...[
        mobileSecurityNotice(context,
            mobile: widget.mobile,
            title: const Text('操作未完成'),
            content: Text(error),
            severity: InfoBarSeverity.error),
        const SizedBox(height: 12),
      ],
      if (_controller.message case final message?) ...[
        mobileSecurityNotice(context,
            mobile: widget.mobile,
            title: const Text('账号维护'),
            content: Text(message)),
        const SizedBox(height: 12),
      ],
      if (!_controller.invalidated && !_controller.completed) ...[
        if (_controller.loading) const ProgressBar(),
        if (account == null && !_controller.loading)
          mobileSecurityAction(context,
              mobile: widget.mobile,
              onPressed: () => unawaited(_controller.load()),
              child: const Text('重新加载')),
        if (account != null) ...[
          const Text('登录密码', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('修改密码后，当前设备和其他设备都需要重新登录。'),
          const SizedBox(height: 8),
          mobileSecurityAction(context,
              mobile: widget.mobile,
              key: const ValueKey('account-change-password'),
              onPressed: _controller.busy
                  ? null
                  : () => _openForm(AccountMaintenanceMode.password),
              child: const Text('修改密码')),
          const SizedBox(height: 24),
          const Text('邮箱验证', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(account.email ?? '尚未登记邮箱'),
          Text(account.emailVerified
              ? '已验证，可用于找回密码。'
              : '验证邮箱后，可以在忘记密码时使用邮箱验证码重置密码。'),
          if (!account.emailServiceAvailable) const Text('管理员尚未配置邮件服务，请联系管理员。'),
          if (!account.emailVerified && account.email != null) ...[
            const SizedBox(height: 8),
            mobileSecurityAction(context,
                mobile: widget.mobile,
                key: const ValueKey('account-verify-email'),
                onPressed: _controller.busy || !account.emailServiceAvailable
                    ? null
                    : () => _openForm(AccountMaintenanceMode.verifyEmail),
                child: const Text('验证邮箱')),
          ],
          const SizedBox(height: 24),
          const Text('登录设备', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('仅显示设备类型和登录时间。退出后，该会话需重新登录。'),
          if (_controller.sessions.isEmpty)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('没有有效的登录会话。')),
          for (final session in _controller.sessions)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                        '${session.platformLabel}${session.current ? ' · 当前会话' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('登录：${_time(session.createdAt)}'),
                    Text('最近使用：${_time(session.lastSeenAt)}'),
                    const SizedBox(height: 6),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: mobileSecurityAction(context,
                            mobile: widget.mobile,
                            key: ValueKey('account-revoke-${session.id}'),
                            onPressed: _controller.busy
                                ? null
                                : () => unawaited(_controller.revoke(session)),
                            child: Text(session.current ? '退出当前会话' : '退出此会话'))),
                  ]),
            ),
          if (_controller.busy) const ProgressBar(),
          mobileSecurityAction(context,
              mobile: widget.mobile,
              onPressed: _controller.busy || _controller.loading
                  ? null
                  : () => unawaited(_controller.load()),
              child: const Text('刷新登录设备')),
        ],
      ],
    ]);
  }

  Future<void> _openForm(AccountMaintenanceMode mode) async {
    await showAccountMaintenanceForm(
        context: context, auth: widget.auth, mode: mode);
    if (mounted && widget.auth.isAuthenticated) await _controller.load();
  }

  String _time(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return '未知';
    String pad(int value) => '$value'.padLeft(2, '0');
    return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
  }
}
