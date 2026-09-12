import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;

import '../../mobile/mobile_security_controls.dart';
import '../../mobile/mobile_settings_route.dart';
import '../../shared/responsive.dart';
import 'account_maintenance_controller.dart';
import 'auth_controller.dart';

enum AccountMaintenanceMode { password, verifyEmail, resetPassword }

Future<void> showAccountMaintenanceForm(
    {required BuildContext context,
    required AuthController auth,
    required AccountMaintenanceMode mode}) {
  final mobile = usesMobileUi(context);
  Widget builder(BuildContext context) =>
      _MaintenanceForm(auth: auth, mobile: mobile, mode: mode);
  return mobile
      ? Navigator.of(context)
          .push<void>(material.MaterialPageRoute(builder: builder))
      : showDialog<void>(
          context: context, builder: builder, barrierDismissible: false);
}

class _MaintenanceForm extends StatefulWidget {
  const _MaintenanceForm(
      {required this.auth, required this.mobile, required this.mode});
  final AuthController auth;
  final bool mobile;
  final AccountMaintenanceMode mode;
  @override
  State<_MaintenanceForm> createState() => _MaintenanceFormState();
}

class _MaintenanceFormState extends State<_MaintenanceForm> {
  late final AccountMaintenanceController _controller;
  final _password = TextEditingController();
  final _replacement = TextEditingController();
  final _confirmation = TextEditingController();
  final _email = TextEditingController();
  final _emailCode = TextEditingController();
  final _secondFactor = TextEditingController();
  bool _emailSent = false;
  String? _validationError;

  String get _title => switch (widget.mode) {
        AccountMaintenanceMode.password => '修改密码',
        AccountMaintenanceMode.verifyEmail => '验证邮箱',
        AccountMaintenanceMode.resetPassword => '找回密码',
      };
  bool get _reset => widget.mode == AccountMaintenanceMode.resetPassword;
  bool get _verify => widget.mode == AccountMaintenanceMode.verifyEmail;
  bool get _needsSecondFactor =>
      widget.auth.accountSecurity?.twoFactorEnabled ?? false;

  @override
  void initState() {
    super.initState();
    _controller = AccountMaintenanceController(widget.auth)
      ..addListener(_changed);
  }

  void _changed() {
    if (_controller.invalidated) _clearSecrets();
    if (mounted) setState(() {});
  }

  void _clearSecrets() {
    for (final controller in [
      _password,
      _replacement,
      _confirmation,
      _emailCode,
      _secondFactor,
      _email
    ]) {
      controller.clear();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    for (final controller in [
      _password,
      _replacement,
      _confirmation,
      _emailCode,
      _secondFactor,
      _email
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = _body();
    if (widget.mobile) {
      return PopScope(
          canPop: !_controller.busy,
          child: MobileSettingsPage(
              title: _title, canClose: !_controller.busy, child: body));
    }
    return PopScope(
        canPop: !_controller.busy,
        child: ContentDialog(
            title: Text(_title),
            content:
                SizedBox(width: 470, child: SingleChildScrollView(child: body)),
            actions: [
              Button(
                  onPressed: _controller.busy
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Text(_controller.completed ? '返回' : '关闭')),
            ]));
  }

  Widget _body() {
    final error = _validationError ?? _controller.error;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (error != null) ...[
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
      if (!_controller.completed && !_controller.invalidated) ...[
        Text(_verify
            ? '验证码会发送到 ${widget.auth.user?.email ?? '账号登记邮箱'}。'
            : _reset
                ? '请输入账号已经验证的邮箱。若未验证邮箱或丢失两步验证恢复码，请联系管理员。'
                : '修改密码后，所有设备的旧会话都会退出。'),
        const SizedBox(height: 12),
        if (_reset)
          _field('邮箱', 'account-reset-email', _email,
              keyboardType: TextInputType.emailAddress, enabled: !_emailSent),
        if (!_reset && (!_verify || !_emailSent))
          _field('当前密码', 'account-current-password', _password, secret: true),
        if (!_verify || !_emailSent)
          _field(_needsSecondFactor ? '验证器代码或恢复码（必填）' : '验证器代码或恢复码（已启用两步验证时填写）',
              'account-second-factor', _secondFactor,
              secret: true, maxLength: 32),
        if (_reset || _verify) ...[
          mobileSecurityAction(context,
              mobile: widget.mobile,
              key: const ValueKey('account-send-email-code'),
              onPressed: _controller.busy || _controller.resendSeconds > 0
                  ? null
                  : _send,
              child: Text(_controller.resendSeconds > 0
                  ? '${_controller.resendSeconds} 秒后可重发'
                  : '发送邮箱验证码')),
          const SizedBox(height: 12),
          _field('邮箱验证码', 'account-email-code', _emailCode,
              keyboardType: TextInputType.number, maxLength: 8),
        ],
        if (!_verify) ...[
          _field('新密码（至少 12 个字符）', 'account-new-password', _replacement,
              secret: true),
          _field('确认新密码', 'account-confirm-password', _confirmation,
              secret: true),
        ],
        if (_controller.busy) ...[
          const ProgressBar(),
          const SizedBox(height: 12)
        ],
        mobileSecurityAction(context,
            mobile: widget.mobile,
            primary: true,
            key: const ValueKey('account-maintenance-submit'),
            onPressed: _controller.busy || ((_reset || _verify) && !_emailSent)
                ? null
                : _submit,
            child: Text(_controller.busy ? '正在处理…' : _title)),
      ],
      if (_controller.completed && widget.mobile)
        mobileSecurityAction(context,
            mobile: true,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('返回登录或账号设置')),
    ]);
  }

  Widget _field(String label, String key, TextEditingController controller,
          {bool secret = false,
          bool enabled = true,
          int maxLength = 256,
          TextInputType? keyboardType}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(label),
          const SizedBox(height: 6),
          mobileSecurityInput(context,
              mobile: widget.mobile,
              key: ValueKey(key),
              controller: controller,
              enabled: enabled && !_controller.busy,
              obscureText: secret,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: keyboardType,
              maxLength: maxLength),
        ]),
      );

  String? _code() =>
      _secondFactor.text.trim().isEmpty ? null : _secondFactor.text.trim();

  Future<void> _send() async {
    setState(() => _validationError = null);
    if (_reset && !_email.text.trim().contains('@')) {
      setState(() => _validationError = '请输入有效的邮箱地址');
      return;
    }
    if (_verify &&
        (_password.text.isEmpty || (_needsSecondFactor && _code() == null))) {
      // A resend requires fresh credentials because TOTP/recovery codes cannot be reused.
      if (_emailSent) setState(() => _emailSent = false);
      setState(() => _validationError = '请输入当前密码和已启用的两步验证码，再发送验证码');
      return;
    }
    final success = _reset
        ? await _controller.sendReset(email: _email.text.trim())
        : await _controller.sendVerification(
            password: _password.text, code: _code());
    if (!mounted) return;
    _password.clear();
    if (_verify) _secondFactor.clear();
    if (mounted && success) setState(() => _emailSent = true);
  }

  Future<void> _submit() async {
    setState(() => _validationError = null);
    if (!_verify &&
        (_replacement.text.length < 12 ||
            _replacement.text != _confirmation.text)) {
      setState(() => _validationError = '新密码需至少 12 个字符，且两次输入必须一致');
      return;
    }
    if (!_verify && !_reset && _password.text.isEmpty) {
      setState(() => _validationError = '请输入当前密码');
      return;
    }
    if ((_verify || _reset) &&
        !RegExp(r'^\d{8}$').hasMatch(_emailCode.text.trim())) {
      setState(() => _validationError = '请输入 8 位邮箱验证码');
      return;
    }
    final success = switch (widget.mode) {
      AccountMaintenanceMode.password => await _controller.changePassword(
          currentPassword: _password.text,
          newPassword: _replacement.text,
          code: _code()),
      AccountMaintenanceMode.verifyEmail =>
        await _controller.verifyEmail(emailCode: _emailCode.text.trim()),
      AccountMaintenanceMode.resetPassword => await _controller.resetPassword(
          email: _email.text.trim(),
          emailCode: _emailCode.text.trim(),
          newPassword: _replacement.text,
          code: _code()),
    };
    if (!mounted) return;
    _secondFactor.clear();
    if (success) _clearSecrets();
  }
}
