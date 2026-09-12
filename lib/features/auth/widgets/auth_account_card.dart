import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

import '../../../core/backend/backend_connection_manager.dart';
import '../../../shared/responsive.dart';
import '../../settings/widgets/settings_section_card.dart';
import '../auth_controller.dart';
import '../account_maintenance_form.dart';
import 'account_security_dialog.dart';
import 'github_device_dialog.dart';

enum _AuthFormMode { login, register }

class AuthAccountCard extends StatefulWidget {
  const AuthAccountCard({
    required this.auth,
    required this.backend,
    required this.isLocalMode,
    required this.backendUrl,
    required this.backendRevision,
    super.key,
  });

  final AuthController auth;
  final BackendConnectionManager backend;
  final bool isLocalMode;
  final String backendUrl;
  final int backendRevision;

  @override
  State<AuthAccountCard> createState() => _AuthAccountCardState();
}

class _AuthAccountCardState extends State<AuthAccountCard> {
  final _usernameController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _emailCodeController = TextEditingController();
  final _identityBadgeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _twoFactorCodeController = TextEditingController();
  _AuthFormMode _mode = _AuthFormMode.login;
  String? _formError;
  Timer? _emailCodeTimer;
  int _emailCodeCountdown = 0;
  bool _emailCodeSent = false;
  String? _policyRequestedForBackend;
  bool _hasEnteredRegistration = false;

  @override
  void didUpdateWidget(AuthAccountCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.auth == widget.auth &&
        oldWidget.backendUrl == widget.backendUrl &&
        oldWidget.isLocalMode == widget.isLocalMode &&
        oldWidget.backendRevision == widget.backendRevision) {
      return;
    }
    _emailCodeTimer?.cancel();
    _usernameController.clear();
    _displayNameController.clear();
    _emailController.clear();
    _emailCodeController.clear();
    _identityBadgeController.clear();
    _passwordController.clear();
    _confirmPasswordController.clear();
    _twoFactorCodeController.clear();
    _mode = _AuthFormMode.login;
    _formError = null;
    _emailCodeCountdown = 0;
    _emailCodeSent = false;
    _policyRequestedForBackend = null;
    _hasEnteredRegistration = false;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    _emailController.dispose();
    _emailCodeController.dispose();
    _identityBadgeController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _twoFactorCodeController.clear();
    _twoFactorCodeController.dispose();
    _emailCodeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[widget.auth, widget.backend]),
      builder: (context, _) => SettingsSectionCard(
        icon: FluentIcons.contact,
        child: widget.isLocalMode
            ? _localAdministrator(context)
            : _remoteAccount(context),
      ),
    );
  }

  Widget _localAdministrator(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '本机管理员',
            style: FluentTheme.of(context).typography.subtitle,
          ),
          const SizedBox(height: 6),
          const Text('Windows 本机后端仅供当前设备使用，无需注册或登录。'),
          const SizedBox(height: 12),
          const InfoBar(
            title: Text('已使用本机管理身份'),
            content: Text('书架、任务与阅读进度保存在这台电脑的本机后端。'),
            severity: InfoBarSeverity.success,
          ),
        ],
      );

  Widget _remoteAccount(BuildContext context) {
    if (widget.backend.status != BackendStatus.ready) {
      return const InfoBar(
        title: Text('连接 Linux 后端后登录'),
        content: Text('请先在“后端连接”中保存可用的服务器地址和连接 Token。'),
        severity: InfoBarSeverity.info,
      );
    }
    if (!widget.backend.multiUserEnabled) {
      return const InfoBar(
        title: Text('服务器版本不支持多用户'),
        content: Text('请升级 Linux 后端后再登录；客户端不会进入共享书架。'),
        severity: InfoBarSeverity.error,
      );
    }
    _ensureLoginOptionsLoaded();
    if (widget.auth.status == UserAuthStatus.restoring) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('正在恢复登录状态'),
          SizedBox(height: 12),
          ProgressBar(),
        ],
      );
    }
    if (widget.auth.loginTwoFactorChallenge != null) {
      return _twoFactorLoginForm(context);
    }
    final user = widget.auth.user;
    if (widget.auth.isAuthenticated && user != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              CircleAvatar(
                radius: 24,
                child: Text(
                  user.label.isEmpty ? '青' : user.label.characters.first,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      user.label,
                      style: FluentTheme.of(context).typography.subtitle,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '@${user.username} · ${user.isAdministrator ? '管理员' : '用户'}',
                      style: FluentTheme.of(context).typography.caption,
                    ),
                    if (user.email.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        user.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FluentTheme.of(context).typography.caption,
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      _serverLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FluentTheme.of(context).typography.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                key: const ValueKey('auth-account-security'),
                onPressed: widget.auth.isBusy
                    ? null
                    : () => showAccountSecurityDialog(
                          context: context,
                          auth: widget.auth,
                        ),
                child: const Text('账号安全'),
              ),
              Button(
                key: const ValueKey('auth-logout'),
                onPressed: widget.auth.isBusy ? null : widget.auth.logout,
                child: const Text('退出登录'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const InfoBar(
            title: Text('个人书架已启用'),
            content: Text('书架、阅读进度和任务只对当前登录用户可见。'),
            severity: InfoBarSeverity.success,
          ),
        ],
      );
    }
    return _authenticationForm(context);
  }

  Widget _authenticationForm(BuildContext context) {
    final registering = _mode == _AuthFormMode.register;
    final message = _formError ?? widget.auth.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          registering ? '注册 Linux 后端账号' : '登录 Linux 后端',
          style: FluentTheme.of(context).typography.subtitle,
        ),
        const SizedBox(height: 4),
        Text(
          registering
              ? '连接到 $_serverLabel，创建你的独立书架账号。'
              : '连接到 $_serverLabel，每个账号使用独立书架。',
          style: FluentTheme.of(context).typography.caption,
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          children: <Widget>[
            if (!registering)
              const FilledButton(
                key: ValueKey('auth-login-tab'),
                onPressed: null,
                child: Text('登录'),
              )
            else
              Button(
                key: const ValueKey('auth-login-tab'),
                onPressed: _showLogin,
                child: const Text('登录'),
              ),
            if (registering)
              const FilledButton(
                key: ValueKey('auth-register-tab'),
                onPressed: null,
                child: Text('注册'),
              )
            else
              Button(
                key: const ValueKey('auth-register-tab'),
                onPressed: _showRegistration,
                child: const Text('注册'),
              ),
          ],
        ),
        const SizedBox(height: 14),
        InfoLabel(
          label: '用户名',
          child: TextBox(
            key: const ValueKey('auth-username'),
            controller: _usernameController,
            magnifierConfiguration: textInputMagnifierConfiguration(context),
            autocorrect: false,
            enableSuggestions: false,
            placeholder: '输入用户名',
          ),
        ),
        if (registering) ...<Widget>[
          const SizedBox(height: 12),
          InfoLabel(
            label: '显示名称',
            child: TextBox(
              key: const ValueKey('auth-display-name'),
              controller: _displayNameController,
              magnifierConfiguration: textInputMagnifierConfiguration(context),
              placeholder: '其他设备上显示的名称',
            ),
          ),
          const SizedBox(height: 12),
          InfoLabel(
            label: '邮箱',
            child: TextBox(
              key: const ValueKey('auth-email'),
              controller: _emailController,
              magnifierConfiguration: textInputMagnifierConfiguration(context),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              enableSuggestions: false,
              placeholder: '用于注册验证和账号识别',
              onChanged: (_) => _emailAddressChanged(),
            ),
          ),
          const SizedBox(height: 12),
          _registrationPolicyArea(context),
        ],
        const SizedBox(height: 12),
        InfoLabel(
          label: '密码',
          child: TextBox(
            key: const ValueKey('auth-password'),
            controller: _passwordController,
            magnifierConfiguration: textInputMagnifierConfiguration(context),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            placeholder: registering ? '设置登录密码' : '输入登录密码',
            onSubmitted: (_) => _submit(),
          ),
        ),
        if (registering) ...<Widget>[
          const SizedBox(height: 12),
          InfoLabel(
            label: '确认密码',
            child: TextBox(
              key: const ValueKey('auth-confirm-password'),
              controller: _confirmPasswordController,
              magnifierConfiguration: textInputMagnifierConfiguration(context),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              placeholder: '再次输入密码',
              onSubmitted: (_) => _submit(),
            ),
          ),
        ],
        if (message != null && message.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          InfoBar(
            title: Text(registering ? '注册失败' : '登录失败'),
            content: Text(message),
            severity: InfoBarSeverity.error,
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('auth-submit'),
          onPressed: widget.auth.isBusy ||
                  (registering &&
                      (widget.auth.registrationPolicy == null ||
                          widget.auth.registrationPolicyLoading ||
                          widget.auth.emailCodeSending))
              ? null
              : _submit,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.auth.isBusy) ...<Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: ProgressRing(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
              ],
              Text(widget.auth.isBusy
                  ? (registering ? '正在注册' : '正在登录')
                  : (registering ? '创建账号并登录' : '登录')),
            ],
          ),
        ),
        if (!registering) ...<Widget>[
          const SizedBox(height: 10),
          Button(
            key: const ValueKey('auth-forgot-password'),
            onPressed: widget.auth.isBusy
                ? null
                : () => showAccountMaintenanceForm(
                    context: context,
                    auth: widget.auth,
                    mode: AccountMaintenanceMode.resetPassword),
            child: const Text('忘记密码'),
          ),
        ],
        if (!registering &&
            widget.auth.registrationPolicy?.githubLoginEnabled ==
                true) ...<Widget>[
          const SizedBox(height: 10),
          Button(
            key: const ValueKey('auth-github-login'),
            onPressed:
                widget.auth.isBusy ? null : () => unawaited(_loginWithGitHub()),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(FluentIcons.code, size: 16),
                SizedBox(width: 8),
                Text('使用 GitHub 登录'),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _twoFactorLoginForm(BuildContext context) {
    final message = _formError ?? widget.auth.error;
    return Column(
      key: const ValueKey('auth-two-factor-step'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '两步验证',
          style: FluentTheme.of(context).typography.subtitle,
        ),
        const SizedBox(height: 5),
        const Text('密码或 GitHub 已验证。请输入验证器生成的 6 位代码，也可以使用一个恢复码。'),
        const SizedBox(height: 14),
        InfoLabel(
          label: '验证器代码或恢复码',
          child: TextBox(
            key: const ValueKey('auth-two-factor-code'),
            controller: _twoFactorCodeController,
            autocorrect: false,
            enableSuggestions: false,
            autofocus: true,
            placeholder: '输入验证码或恢复码',
            onSubmitted: (_) => _submitTwoFactor(),
          ),
        ),
        if (message != null && message.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          InfoBar(
            title: const Text('验证失败'),
            content: Text(message),
            severity: InfoBarSeverity.error,
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton(
              key: const ValueKey('auth-two-factor-submit'),
              onPressed: widget.auth.isBusy
                  ? null
                  : () => unawaited(_submitTwoFactor()),
              child: Text(widget.auth.isBusy ? '正在验证' : '继续登录'),
            ),
            Button(
              key: const ValueKey('auth-two-factor-cancel'),
              onPressed: widget.auth.isBusy
                  ? null
                  : () {
                      _twoFactorCodeController.clear();
                      setState(() => _formError = null);
                      widget.auth.cancelTwoFactorLogin();
                    },
              child: const Text('返回登录'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _registrationPolicyArea(BuildContext context) {
    final auth = widget.auth;
    if (auth.registrationPolicyLoading) {
      return const Column(
        key: ValueKey('auth-registration-policy-loading'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InfoBar(
            title: Text('正在读取注册要求'),
            content: Text('确认服务器是否需要邮箱验证码或身份牌。'),
            severity: InfoBarSeverity.info,
          ),
          SizedBox(height: 10),
          ProgressBar(),
        ],
      );
    }
    if (auth.registrationPolicyError case final error?) {
      return Column(
        key: const ValueKey('auth-registration-policy-error'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InfoBar(
            title: const Text('无法读取注册要求'),
            content: Text(error),
            severity: InfoBarSeverity.error,
          ),
          const SizedBox(height: 10),
          Button(
            key: const ValueKey('auth-registration-policy-retry'),
            onPressed: () => unawaited(_loadRegistrationPolicy(force: true)),
            child: const Text('重新加载'),
          ),
        ],
      );
    }
    final policy = auth.registrationPolicy;
    if (policy == null) {
      return const InfoBar(
        key: ValueKey('auth-registration-policy-unavailable'),
        title: Text('尚未读取注册要求'),
        content: Text('请重新进入注册页或重试。'),
        severity: InfoBarSeverity.warning,
      );
    }

    final requirements = <String>[
      if (policy.emailVerificationRequired) '邮箱验证码',
      if (policy.identityBadgeRequired) '身份牌',
    ];
    return Column(
      key: const ValueKey('auth-registration-policy-ready'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InfoBar(
          title: const Text('注册要求已确认'),
          content: Text(
            requirements.isEmpty
                ? '填写邮箱后即可创建账号。'
                : '本服务器还要求：${requirements.join('、')}。',
          ),
          severity: InfoBarSeverity.success,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Button(
            key: const ValueKey('auth-registration-policy-refresh'),
            onPressed: widget.auth.emailCodeSending
                ? null
                : () => unawaited(_loadRegistrationPolicy(force: true)),
            child: const Text('刷新注册要求'),
          ),
        ),
        if (policy.emailVerificationRequired) ...<Widget>[
          const SizedBox(height: 12),
          _emailCodeField(context),
        ],
        if (policy.identityBadgeRequired) ...<Widget>[
          const SizedBox(height: 12),
          InfoLabel(
            label: '身份牌',
            child: TextBox(
              key: const ValueKey('auth-identity-badge'),
              controller: _identityBadgeController,
              magnifierConfiguration: textInputMagnifierConfiguration(context),
              autocorrect: false,
              enableSuggestions: false,
              obscureText: true,
              placeholder: '输入管理员提供的身份牌',
            ),
          ),
        ],
      ],
    );
  }

  Widget _emailCodeField(BuildContext context) {
    final sending = widget.auth.emailCodeSending;
    final canSend = !sending && _emailCodeCountdown == 0;
    final button = Button(
      key: const ValueKey('auth-send-email-code'),
      onPressed: canSend ? () => unawaited(_sendEmailCode()) : null,
      child: Text(
        sending
            ? '正在发送'
            : _emailCodeCountdown > 0
                ? '$_emailCodeCountdown 秒后重发'
                : '发送验证码',
      ),
    );
    final input = InfoLabel(
      label: '邮箱验证码',
      child: TextBox(
        key: const ValueKey('auth-email-code'),
        controller: _emailCodeController,
        magnifierConfiguration: textInputMagnifierConfiguration(context),
        keyboardType: TextInputType.number,
        autocorrect: false,
        enableSuggestions: false,
        placeholder: '输入收到的验证码',
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        LayoutBuilder(
          builder: (context, constraints) {
            final stack = usesMobileUi(context) || constraints.maxWidth < 460;
            if (stack) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  input,
                  const SizedBox(height: 8),
                  button,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(child: input),
                const SizedBox(width: 10),
                button,
              ],
            );
          },
        ),
        if (widget.auth.emailCodeError case final error?) ...<Widget>[
          const SizedBox(height: 8),
          InfoBar(
            title: const Text('验证码发送失败'),
            content: Text(error),
            severity: InfoBarSeverity.error,
          ),
        ] else if (_emailCodeSent) ...<Widget>[
          const SizedBox(height: 8),
          const InfoBar(
            key: ValueKey('auth-email-code-sent'),
            title: Text('验证码已发送'),
            content: Text('请检查收件箱；若未收到，也请查看垃圾邮件。'),
            severity: InfoBarSeverity.success,
          ),
        ],
      ],
    );
  }

  void _showLogin() {
    _emailCodeTimer?.cancel();
    _emailCodeController.clear();
    _identityBadgeController.clear();
    _twoFactorCodeController.clear();
    widget.auth.cancelTwoFactorLogin();
    setState(() {
      _mode = _AuthFormMode.login;
      _formError = null;
      _emailCodeCountdown = 0;
      _emailCodeSent = false;
    });
  }

  void _showRegistration() {
    final shouldRefresh =
        _hasEnteredRegistration && widget.auth.registrationPolicyError == null;
    _hasEnteredRegistration = true;
    setState(() {
      _mode = _AuthFormMode.register;
      _formError = null;
    });
    if (widget.auth.registrationPolicyError == null) {
      unawaited(_loadRegistrationPolicy(force: shouldRefresh));
    }
  }

  void _ensureLoginOptionsLoaded() {
    if (_policyRequestedForBackend == widget.backendUrl) return;
    _policyRequestedForBackend = widget.backendUrl;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.isLocalMode || !widget.backend.multiUserEnabled) {
        return;
      }
      unawaited(_loadRegistrationPolicy());
    });
  }

  Future<void> _loadRegistrationPolicy({bool force = false}) async {
    try {
      await widget.auth.loadRegistrationPolicy(force: force);
      if (!mounted) return;
      final policy = widget.auth.registrationPolicy;
      if (policy == null) return;
      if (!policy.emailVerificationRequired) {
        _emailCodeTimer?.cancel();
        _emailCodeController.clear();
      }
      if (!policy.identityBadgeRequired) {
        _identityBadgeController.clear();
      }
      setState(() {
        if (!policy.emailVerificationRequired) {
          _emailCodeCountdown = 0;
          _emailCodeSent = false;
        }
      });
    } catch (_) {
      // AuthController 会暴露加载失败状态及重试入口。
    }
  }

  Future<void> _loginWithGitHub() async {
    setState(() => _formError = null);
    _passwordController.clear();
    try {
      await showGitHubDeviceAuthorization(
        context: context,
        auth: widget.auth,
        purpose: 'login',
      );
    } catch (error) {
      if (mounted) setState(() => _formError = '$error');
    }
  }

  Future<void> _submitTwoFactor() async {
    final code = _twoFactorCodeController.text.trim();
    if (code.isEmpty) {
      setState(() => _formError = '请输入验证器代码或恢复码');
      return;
    }
    setState(() => _formError = null);
    try {
      await widget.auth.completeTwoFactorLogin(code: code);
      _twoFactorCodeController.clear();
    } catch (_) {
      // AuthController 会保留挑战，使用户无需重新输入密码即可重试。
    }
  }

  void _emailAddressChanged() {
    if (!_emailCodeSent && _emailCodeCountdown == 0) return;
    _emailCodeTimer?.cancel();
    _emailCodeController.clear();
    setState(() {
      _emailCodeSent = false;
      _emailCodeCountdown = 0;
    });
  }

  Future<void> _sendEmailCode() async {
    final email = _emailController.text.trim();
    if (!_validEmail(email)) {
      setState(() => _formError = '请输入有效的邮箱地址');
      return;
    }
    setState(() => _formError = null);
    try {
      await widget.auth.sendRegistrationEmailCode(email: email);
      if (!mounted ||
          _mode != _AuthFormMode.register ||
          widget.auth.registrationPolicy?.emailVerificationRequired != true ||
          _emailController.text.trim() != email) {
        return;
      }
      _startEmailCodeCountdown();
    } catch (_) {
      // AuthController 会在验证码区域显示服务端错误。
    }
  }

  void _startEmailCodeCountdown() {
    _emailCodeTimer?.cancel();
    setState(() {
      _emailCodeSent = true;
      _emailCodeCountdown = 60;
    });
    _emailCodeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _emailCodeCountdown <= 1) {
        timer.cancel();
        if (mounted) setState(() => _emailCodeCountdown = 0);
        return;
      }
      setState(() => _emailCodeCountdown -= 1);
    });
  }

  String get _serverLabel {
    final uri = Uri.tryParse(widget.backendUrl);
    return uri?.host.isNotEmpty == true ? uri!.host : widget.backendUrl;
  }

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final registering = _mode == _AuthFormMode.register;
    final displayName = _displayNameController.text.trim();
    final email = _emailController.text.trim();
    if (username.isEmpty || password.isEmpty) {
      setState(() => _formError = '请填写用户名和密码');
      return;
    }
    if (registering && displayName.isEmpty) {
      setState(() => _formError = '请填写显示名称');
      return;
    }
    if (registering && !_validEmail(email)) {
      setState(() => _formError = '请输入有效的邮箱地址');
      return;
    }
    if (registering && (username.length < 3 || username.length > 32)) {
      setState(() => _formError = '用户名长度需要为 3–32 个字符');
      return;
    }
    if (registering && (password.length < 12 || password.length > 256)) {
      setState(() => _formError = '密码长度需要为 12–256 个字符');
      return;
    }
    if (registering && password != _confirmPasswordController.text) {
      setState(() => _formError = '两次输入的密码不一致');
      return;
    }
    final policy = widget.auth.registrationPolicy;
    if (registering && policy == null) {
      setState(() => _formError = '请先等待注册要求加载完成');
      return;
    }
    final emailCode = _emailCodeController.text.trim();
    if (registering && policy!.emailVerificationRequired && emailCode.isEmpty) {
      setState(() => _formError = '请填写邮箱验证码');
      return;
    }
    if (registering &&
        policy!.emailVerificationRequired &&
        !RegExp(r'^\d{6}$').hasMatch(emailCode)) {
      setState(() => _formError = '邮箱验证码需为 6 位数字');
      return;
    }
    final identityBadge = _identityBadgeController.text.trim();
    if (registering && policy!.identityBadgeRequired && identityBadge.isEmpty) {
      setState(() => _formError = '请填写身份牌');
      return;
    }
    setState(() => _formError = null);
    try {
      if (registering) {
        await widget.auth.register(
          username: username,
          displayName: displayName,
          email: email,
          password: password,
          emailCode: policy!.emailVerificationRequired ? emailCode : null,
          identityBadge: policy.identityBadgeRequired ? identityBadge : null,
        );
      } else {
        await widget.auth.login(username: username, password: password);
      }
      if (!mounted) return;
      _passwordController.clear();
      _confirmPasswordController.clear();
      if (registering) {
        _emailCodeTimer?.cancel();
        _emailCodeController.clear();
        _identityBadgeController.clear();
        if (mounted) {
          setState(() {
            _emailCodeCountdown = 0;
            _emailCodeSent = false;
          });
        }
      }
    } catch (_) {
      // AuthController 已将服务端错误转换成可观察状态。
    }
  }

  bool _validEmail(String value) =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value);
}
