import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' as material;
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/models/user_account.dart';
import '../../../mobile/mobile_settings_route.dart';
import '../../../mobile/mobile_security_controls.dart';
import '../../../shared/responsive.dart';
import '../auth_controller.dart';
import 'github_device_dialog.dart';

Future<void> showAccountSecurityDialog({
  required BuildContext context,
  required AuthController auth,
}) {
  final mobile = usesMobileUi(context);
  Widget builder(BuildContext routeContext) =>
      _AccountSecurityDialog(auth: auth, mobile: mobile);
  if (mobile) {
    return Navigator.of(
      context,
    ).push<void>(material.MaterialPageRoute<void>(builder: builder));
  }
  return showDialog<void>(context: context, builder: builder);
}

class _AccountSecurityDialog extends StatefulWidget {
  const _AccountSecurityDialog({required this.auth, required this.mobile});

  final AuthController auth;
  final bool mobile;

  @override
  State<_AccountSecurityDialog> createState() => _AccountSecurityDialogState();
}

class _AccountSecurityDialogState extends State<_AccountSecurityDialog> {
  String? _operationError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadSecurity());
    });
  }

  Future<void> _loadSecurity() async {
    try {
      await widget.auth.loadAccountSecurity(force: true);
    } catch (_) {/* AuthController keeps a visible, retryable loading error. */}
  }

  @override
  Widget build(BuildContext context) {
    final body = AnimatedBuilder(
      animation: widget.auth,
      builder: (context, _) => _body(context),
    );
    if (widget.mobile) {
      return MobileSettingsPage(title: '账号安全', child: body);
    }
    return ContentDialog(
      title: const Text('账号安全'),
      content: SizedBox(width: 520, child: SingleChildScrollView(child: body)),
      actions: <Widget>[
        mobileSecurityAction(
          context,
          mobile: widget.mobile,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final auth = widget.auth;
    if (!auth.isAuthenticated) {
      return mobileSecurityNotice(
        context,
        mobile: widget.mobile,
        title: const Text('登录状态已失效'),
        content: const Text('请关闭面板并重新登录。'),
        severity: InfoBarSeverity.error,
      );
    }
    if (auth.accountSecurityLoading && auth.accountSecurity == null) {
      return const Column(
        key: ValueKey('account-security-loading'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('正在读取账号安全状态…'),
          SizedBox(height: 12),
          ProgressBar(),
        ],
      );
    }
    final loadError = auth.accountSecurityError;
    final security = auth.accountSecurity;
    if (security == null) {
      return Column(
        key: const ValueKey('account-security-error'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          mobileSecurityNotice(
            context,
            mobile: widget.mobile,
            title: const Text('无法读取账号安全状态'),
            content: Text(loadError ?? '服务器未返回安全状态'),
            severity: InfoBarSeverity.error,
          ),
          const SizedBox(height: 12),
          mobileSecurityAction(
            context,
            mobile: widget.mobile,
            onPressed: () => unawaited(_loadSecurity()),
            child: const Text('重试'),
          ),
        ],
      );
    }
    return Column(
      key: const ValueKey('account-security-ready'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_operationError case final error?) ...<Widget>[
          mobileSecurityNotice(
            context,
            mobile: widget.mobile,
            title: const Text('操作失败'),
            content: Text(error),
            severity: InfoBarSeverity.error,
          ),
          const SizedBox(height: 12),
        ],
        _SecurityTile(
          mobile: widget.mobile,
          icon: FluentIcons.code,
          title: 'GitHub 登录',
          description: security.githubBound
              ? '已绑定 @${security.githubLogin}'
              : !security.githubAvailable
                  ? '管理员尚未启用 GitHub 登录'
                  : '未绑定；绑定后可免输账号密码登录',
          status: security.githubBound ? '已绑定' : '未绑定',
          action: security.githubBound
              ? mobileSecurityAction(
                  context,
                  mobile: widget.mobile,
                  key: const ValueKey('account-security-github-unbind'),
                  onPressed: auth.accountSecurityBusy
                      ? null
                      : () => unawaited(_unbindGitHub(security)),
                  child: const Text('解除绑定'),
                )
              : !security.githubAvailable
                  ? null
                  : mobileSecurityAction(
                      context,
                      mobile: widget.mobile,
                      key: const ValueKey('account-security-github-bind'),
                      onPressed: auth.accountSecurityBusy
                          ? null
                          : () => unawaited(_bindGitHub(security)),
                      child: const Text('绑定'),
                    ),
        ),
        const SizedBox(height: 12),
        _SecurityTile(
          mobile: widget.mobile,
          icon: FluentIcons.shield,
          title: '两步验证（2FA）',
          description: security.twoFactorEnabled
              ? '登录时需输入验证器代码；剩余 ${security.recoveryCodesRemaining} 个恢复码'
              : '使用验证器应用生成的一次性代码保护账号',
          status: security.twoFactorEnabled ? '已开启' : '未开启',
          action: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (security.twoFactorEnabled) ...<Widget>[
                mobileSecurityAction(
                  context,
                  mobile: widget.mobile,
                  key: const ValueKey('account-security-recovery-regenerate'),
                  onPressed: auth.accountSecurityBusy
                      ? null
                      : () => unawaited(_regenerateRecoveryCodes()),
                  child: const Text('重生成恢复码'),
                ),
                mobileSecurityAction(
                  context,
                  mobile: widget.mobile,
                  key: const ValueKey('account-security-2fa-disable'),
                  onPressed: auth.accountSecurityBusy
                      ? null
                      : () => unawaited(_disableTwoFactor()),
                  child: const Text('关闭'),
                ),
              ] else
                mobileSecurityAction(
                  context,
                  mobile: widget.mobile,
                  primary: true,
                  key: const ValueKey('account-security-2fa-enable'),
                  onPressed: auth.accountSecurityBusy
                      ? null
                      : () => unawaited(_enableTwoFactor()),
                  child: const Text('开始设置'),
                ),
            ],
          ),
        ),
        if (auth.accountSecurityBusy) ...<Widget>[
          const SizedBox(height: 14),
          const ProgressBar(),
        ],
        const SizedBox(height: 14),
        mobileSecurityNotice(
          context,
          mobile: widget.mobile,
          title: const Text('恢复码只显示一次'),
          content: const Text('开启或重生成 2FA 后，请立即将恢复码保存到安全的位置。'),
          severity: InfoBarSeverity.warning,
        ),
      ],
    );
  }

  Future<void> _bindGitHub(AccountSecurity security) async {
    final credentials = await _showCredentialDialog(
      context,
      mobile: widget.mobile,
      title: '验证当前密码',
      explanation: '绑定 GitHub 前需要确认这是你本人。',
      requireCode: security.twoFactorEnabled,
    );
    if (credentials == null || !mounted) return;
    try {
      final authorization = showGitHubDeviceAuthorization(
        context: context,
        auth: widget.auth,
        purpose: 'bind',
        password: credentials.password,
        code: credentials.code,
      );
      credentials.clear();
      final result = await authorization;
      if (!mounted || result?.status != GitHubDevicePollStatus.bound) return;
      await widget.auth.loadAccountSecurity(force: true);
      if (mounted) setState(() => _operationError = null);
    } catch (error) {
      credentials.clear();
      if (mounted) setState(() => _operationError = '$error');
    }
  }

  Future<void> _unbindGitHub(AccountSecurity security) async {
    final credentials = await _showCredentialDialog(
      context,
      mobile: widget.mobile,
      title: '解除 GitHub 绑定',
      explanation: '解除后将不能再使用 GitHub 登录。',
      requireCode: security.twoFactorEnabled,
    );
    if (credentials == null) return;
    try {
      await widget.auth.unbindGitHub(
        password: credentials.password,
        code: credentials.code,
      );
      credentials.clear();
      if (mounted) setState(() => _operationError = null);
    } catch (error) {
      credentials.clear();
      if (mounted) setState(() => _operationError = '$error');
    }
  }

  Future<void> _enableTwoFactor() async {
    final enabled = await _showEnableTwoFactorDialog(
      context,
      auth: widget.auth,
      mobile: widget.mobile,
    );
    if (enabled == true && mounted) {
      await widget.auth.loadAccountSecurity(force: true);
    }
  }

  Future<void> _disableTwoFactor() async {
    final credentials = await _showCredentialDialog(
      context,
      mobile: widget.mobile,
      title: '关闭两步验证',
      explanation: '请输入当前密码，以及验证器代码或一个恢复码。',
      requireCode: true,
    );
    if (credentials == null) return;
    try {
      await widget.auth.disableTwoFactor(
        password: credentials.password,
        code: credentials.code,
      );
      credentials.clear();
      if (mounted) setState(() => _operationError = null);
    } catch (error) {
      credentials.clear();
      if (mounted) setState(() => _operationError = '$error');
    }
  }

  Future<void> _regenerateRecoveryCodes() async {
    final credentials = await _showCredentialDialog(
      context,
      mobile: widget.mobile,
      title: '重生成恢复码',
      explanation: '旧恢复码将立即失效。请输入密码和当前验证器代码。',
      requireCode: true,
    );
    if (credentials == null) return;
    try {
      final recoveryCodes = await widget.auth.regenerateRecoveryCodes(
        password: credentials.password,
        code: credentials.code,
      );
      credentials.clear();
      if (!mounted) return;
      await _showRecoveryCodesDialog(
        context,
        codes: recoveryCodes,
        mobile: widget.mobile,
      );
      if (mounted) setState(() => _operationError = null);
    } catch (error) {
      credentials.clear();
      if (mounted) setState(() => _operationError = '$error');
    }
  }
}

class _SecurityTile extends StatelessWidget {
  const _SecurityTile({
    required this.mobile,
    required this.icon,
    required this.title,
    required this.description,
    required this.status,
    required this.action,
  });

  final bool mobile;
  final IconData icon;
  final String title;
  final String description;
  final String status;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    if (mobile) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              title,
              style: material.Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              status,
              style: TextStyle(
                color: material.Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(description),
            if (action != null) ...<Widget>[
              const SizedBox(height: 14),
              action!,
            ],
            const SizedBox(height: 12),
            const material.Divider(height: 1),
          ],
        ),
      );
    }
    final theme = FluentTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.resources.subtleFillColorSecondary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.resources.cardStrokeColorDefault),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final header = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: theme.typography.bodyStrong),
                    const SizedBox(height: 3),
                    Text(description, style: theme.typography.caption),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(status, style: theme.typography.caption),
            ],
          );
          if (action == null) return header;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              header,
              const SizedBox(height: 12),
              Align(alignment: AlignmentDirectional.centerEnd, child: action!),
            ],
          );
        },
      ),
    );
  }
}

class _Credentials {
  _Credentials(this.password, this.code);

  String password;
  String code;

  void clear() {
    password = '';
    code = '';
  }
}

Future<_Credentials?> _showCredentialDialog(
  BuildContext context, {
  required bool mobile,
  required String title,
  required String explanation,
  required bool requireCode,
}) {
  Widget builder(BuildContext routeContext) => _CredentialDialog(
        title: title,
        explanation: explanation,
        requireCode: requireCode,
        mobile: mobile,
      );
  if (mobile) {
    return Navigator.of(context).push<_Credentials>(
      material.MaterialPageRoute<_Credentials>(builder: builder),
    );
  }
  return showDialog<_Credentials>(context: context, builder: builder);
}

class _CredentialDialog extends StatefulWidget {
  const _CredentialDialog({
    required this.title,
    required this.explanation,
    required this.requireCode,
    required this.mobile,
  });

  final String title;
  final String explanation;
  final bool requireCode;
  final bool mobile;

  @override
  State<_CredentialDialog> createState() => _CredentialDialogState();
}

class _CredentialDialogState extends State<_CredentialDialog> {
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _passwordController.clear();
    _codeController.clear();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _passwordController.text;
    final code = _codeController.text.trim();
    if (password.isEmpty) {
      setState(() => _error = '请输入当前密码');
      return;
    }
    if (widget.requireCode && code.isEmpty) {
      setState(() => _error = '请输入验证器代码或恢复码');
      return;
    }
    Navigator.of(context).pop(_Credentials(password, code));
    _passwordController.clear();
    _codeController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(widget.explanation),
        const SizedBox(height: 14),
        InfoLabel(
          label: '当前密码',
          child: mobileSecurityInput(
            context,
            mobile: widget.mobile,
            key: const ValueKey('security-current-password'),
            controller: _passwordController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
          ),
        ),
        if (widget.requireCode) ...<Widget>[
          const SizedBox(height: 12),
          InfoLabel(
            label: '验证器代码或恢复码',
            child: mobileSecurityInput(
              context,
              mobile: widget.mobile,
              key: const ValueKey('security-current-code'),
              controller: _codeController,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _submit(),
            ),
          ),
        ],
        if (_error case final error?) ...<Widget>[
          const SizedBox(height: 10),
          mobileSecurityNotice(
            context,
            mobile: widget.mobile,
            title: const Text('请检查输入'),
            content: Text(error),
            severity: InfoBarSeverity.error,
          ),
        ],
      ],
    );
    final actions = <Widget>[
      mobileSecurityAction(
        context,
        mobile: widget.mobile,
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      mobileSecurityAction(
        context,
        mobile: widget.mobile,
        primary: true,
        key: const ValueKey('security-credentials-submit'),
        onPressed: _submit,
        child: const Text('继续'),
      ),
    ];
    if (widget.mobile) {
      return MobileSettingsPage(
        title: widget.title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            content,
            const SizedBox(height: 24),
            material.FilledButton(
              key: const ValueKey('security-credentials-submit'),
              onPressed: _submit,
              child: const Text('继续'),
            ),
          ],
        ),
      );
    }
    return ContentDialog(
      title: Text(widget.title),
      content: SizedBox(width: 420, child: content),
      actions: actions,
    );
  }
}

Future<bool?> _showEnableTwoFactorDialog(
  BuildContext context, {
  required AuthController auth,
  required bool mobile,
}) {
  Widget builder(BuildContext routeContext) =>
      _EnableTwoFactorDialog(auth: auth, mobile: mobile);
  if (mobile) {
    return Navigator.of(
      context,
    ).push<bool>(material.MaterialPageRoute<bool>(builder: builder));
  }
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: builder,
  );
}

enum _TwoFactorSetupStep { password, verify, recovery }

class _EnableTwoFactorDialog extends StatefulWidget {
  const _EnableTwoFactorDialog({required this.auth, required this.mobile});

  final AuthController auth;
  final bool mobile;

  @override
  State<_EnableTwoFactorDialog> createState() => _EnableTwoFactorDialogState();
}

class _EnableTwoFactorDialogState extends State<_EnableTwoFactorDialog> {
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  _TwoFactorSetupStep _step = _TwoFactorSetupStep.password;
  TwoFactorSetup? _setup;
  RecoveryCodes? _recoveryCodes;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _passwordController.clear();
    _codeController.clear();
    _passwordController.dispose();
    _codeController.dispose();
    _setup = null;
    _recoveryCodes = null;
    super.dispose();
  }

  Future<void> _continue() async {
    if (_busy) return;
    switch (_step) {
      case _TwoFactorSetupStep.password:
        final password = _passwordController.text;
        if (password.isEmpty) {
          setState(() => _error = '请输入当前密码');
          return;
        }
        setState(() {
          _busy = true;
          _error = null;
        });
        try {
          final setup = await widget.auth.setupTwoFactor(password: password);
          _passwordController.clear();
          if (!mounted) return;
          setState(() {
            _setup = setup;
            _step = _TwoFactorSetupStep.verify;
            _busy = false;
          });
        } catch (error) {
          _passwordController.clear();
          if (mounted) {
            setState(() {
              _busy = false;
              _error = '$error';
            });
          }
        }
      case _TwoFactorSetupStep.verify:
        final code = _codeController.text.trim();
        if (!RegExp(r'^\d{6}$').hasMatch(code)) {
          setState(() => _error = '请输入验证器生成的 6 位数字');
          return;
        }
        setState(() {
          _busy = true;
          _error = null;
        });
        try {
          final recoveryCodes = await widget.auth.enableTwoFactor(
            setupId: _setup!.setupId,
            code: code,
          );
          _codeController.clear();
          if (!mounted) return;
          setState(() {
            _setup = null;
            _recoveryCodes = recoveryCodes;
            _step = _TwoFactorSetupStep.recovery;
            _busy = false;
          });
        } catch (error) {
          _codeController.clear();
          if (mounted) {
            setState(() {
              _busy = false;
              _error = '$error';
            });
          }
        }
      case _TwoFactorSetupStep.recovery:
        Navigator.of(context).pop(true);
    }
  }

  Future<void> _copy(String value) =>
      Clipboard.setData(ClipboardData(text: value));

  @override
  Widget build(BuildContext context) {
    final body = SingleChildScrollView(
      padding: widget.mobile ? const EdgeInsets.all(18) : EdgeInsets.zero,
      child: _body(context),
    );
    final close = _step == _TwoFactorSetupStep.recovery
        ? () => Navigator.of(context).pop(true)
        : () => Navigator.of(context).pop(false);
    final canClose = !_busy;
    late final Widget shell;
    if (widget.mobile) {
      shell = MobileSettingsPage(
        title: '开启两步验证',
        canClose: canClose,
        onClose: close,
        child: _body(context),
      );
    } else {
      shell = ContentDialog(
        title: const Text('开启两步验证'),
        content: SizedBox(width: 470, height: 530, child: body),
        actions: <Widget>[
          mobileSecurityAction(
            context,
            mobile: widget.mobile,
            onPressed: canClose ? close : null,
            child: Text(_step == _TwoFactorSetupStep.recovery ? '完成' : '取消'),
          ),
        ],
      );
    }
    return PopScope<void>(canPop: canClose, child: shell);
  }

  String get _stepLabel => switch (_step) {
        _TwoFactorSetupStep.password => '第 1 步：验证当前密码',
        _TwoFactorSetupStep.verify => '第 2 步：连接验证器',
        _TwoFactorSetupStep.recovery => '第 3 步：保存恢复码',
      };

  Widget _body(BuildContext context) {
    final widgets = <Widget>[
      Text(_stepLabel, style: FluentTheme.of(context).typography.bodyStrong),
      const SizedBox(height: 12),
      ...switch (_step) {
        _TwoFactorSetupStep.password => <Widget>[
            const Text('先输入当前密码。下一步会显示只能用于本次设置的二维码和密钥。'),
            const SizedBox(height: 14),
            InfoLabel(
              label: '当前密码',
              child: mobileSecurityInput(
                context,
                mobile: widget.mobile,
                key: const ValueKey('2fa-setup-password'),
                controller: _passwordController,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => _continue(),
              ),
            ),
          ],
        _TwoFactorSetupStep.verify => _verificationWidgets(context),
        _TwoFactorSetupStep.recovery => _recoveryWidgets(context),
      },
      if (_error case final error?) ...<Widget>[
        const SizedBox(height: 12),
        mobileSecurityNotice(
          context,
          mobile: widget.mobile,
          title: const Text('设置失败'),
          content: Text(error),
          severity: InfoBarSeverity.error,
        ),
      ],
      const SizedBox(height: 16),
      if (_busy)
        const ProgressBar()
      else
        mobileSecurityAction(
          context,
          mobile: widget.mobile,
          primary: true,
          key: const ValueKey('2fa-setup-continue'),
          onPressed: _continue,
          child: Text(switch (_step) {
            _TwoFactorSetupStep.password => '验证密码',
            _TwoFactorSetupStep.verify => '验证并开启',
            _TwoFactorSetupStep.recovery => '我已安全保存',
          }),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widgets,
    );
  }

  List<Widget> _verificationWidgets(BuildContext context) {
    final setup = _setup!;
    return <Widget>[
      const Text('用验证器应用扫描二维码，然后输入生成的 6 位代码。'),
      const SizedBox(height: 12),
      Center(
        child: Container(
          padding: const EdgeInsets.all(10),
          color: const Color(0xFFFFFFFF),
          child: QrImageView(
            key: const ValueKey('2fa-setup-qr'),
            data: setup.otpauthUri,
            size: 184,
            backgroundColor: const Color(0xFFFFFFFF),
          ),
        ),
      ),
      const SizedBox(height: 12),
      InfoLabel(
        label: '手动输入密钥',
        child: Row(
          children: <Widget>[
            Expanded(
              child: SelectableText(
                setup.secret,
                key: const ValueKey('2fa-setup-secret'),
              ),
            ),
            IconButton(
              icon: const Icon(FluentIcons.copy),
              onPressed: () => _copy(setup.secret),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      mobileSecurityAction(
        context,
        mobile: widget.mobile,
        key: const ValueKey('2fa-setup-copy-uri'),
        onPressed: () => _copy(setup.otpauthUri),
        child: const Text('复制验证器 URI'),
      ),
      const SizedBox(height: 12),
      InfoLabel(
        label: '6 位验证码',
        child: mobileSecurityInput(
          context,
          mobile: widget.mobile,
          key: const ValueKey('2fa-setup-code'),
          controller: _codeController,
          keyboardType: TextInputType.number,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 6,
          onSubmitted: (_) => _continue(),
        ),
      ),
    ];
  }

  List<Widget> _recoveryWidgets(BuildContext context) {
    final codes = _recoveryCodes!.values;
    final text = codes.join('\n');
    return <Widget>[
      mobileSecurityNotice(
        context,
        mobile: widget.mobile,
        key: const ValueKey('2fa-recovery-warning'),
        title: const Text('恢复码只显示这一次'),
        content: const Text('每个恢复码只能使用一次。请立即复制并离线保存。'),
        severity: InfoBarSeverity.warning,
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: FluentTheme.of(context).resources.subtleFillColorSecondary,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          text,
          key: const ValueKey('2fa-recovery-codes'),
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      ),
      const SizedBox(height: 10),
      mobileSecurityAction(
        context,
        mobile: widget.mobile,
        key: const ValueKey('2fa-recovery-copy-all'),
        onPressed: () => _copy(text),
        child: const Text('复制全部恢复码'),
      ),
    ];
  }
}

Future<void> _showRecoveryCodesDialog(
  BuildContext context, {
  required RecoveryCodes codes,
  required bool mobile,
}) {
  final text = codes.values.join('\n');
  final content = Builder(
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        mobileSecurityNotice(
          context,
          mobile: mobile,
          title: const Text('旧恢复码已失效'),
          content: const Text('新恢复码只显示这一次，请立即保存。'),
          severity: InfoBarSeverity.warning,
        ),
        const SizedBox(height: 12),
        SelectableText(
          text,
          key: const ValueKey('2fa-regenerated-recovery-codes'),
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        const SizedBox(height: 10),
        mobileSecurityAction(
          context,
          mobile: mobile,
          onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          child: const Text('复制全部恢复码'),
        ),
      ],
    ),
  );
  Widget builder(BuildContext routeContext) {
    if (mobile) {
      return MobileSettingsPage(
        title: '新的恢复码',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            content,
            const SizedBox(height: 20),
            material.FilledButton(
              onPressed: () => Navigator.of(routeContext).pop(),
              child: const Text('我已保存'),
            ),
          ],
        ),
      );
    }
    return ContentDialog(
      title: const Text('新的恢复码'),
      content: SizedBox(width: 420, child: content),
      actions: <Widget>[
        mobileSecurityAction(
          context,
          mobile: mobile,
          primary: true,
          onPressed: () => Navigator.of(routeContext).pop(),
          child: const Text('我已保存'),
        ),
      ],
    );
  }

  if (mobile) {
    return Navigator.of(
      context,
    ).push<void>(material.MaterialPageRoute<void>(builder: builder));
  }
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: builder,
  );
}
