import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import '../app/app_scope.dart';
import '../core/backend/backend_connection_manager.dart';
import '../features/auth/auth_controller.dart';
import '../features/auth/account_maintenance_form.dart';
import '../features/auth/widgets/account_security_dialog.dart';
import '../features/auth/widgets/github_device_dialog.dart';
import 'mobile_action_button.dart';
import 'mobile_my_page.dart';
import 'mobile_settings_route.dart';

Future<void> showMobileAccountPage(BuildContext context) async {
  await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const MobileAccountPage()));
}

class MobileAccountPage extends StatefulWidget {
  const MobileAccountPage({super.key});
  @override
  State<MobileAccountPage> createState() => _MobileAccountPageState();
}

class _MobileAccountPageState extends State<MobileAccountPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _emailCode = TextEditingController();
  final _badge = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  bool _registering = false;
  bool _showPassword = false;
  bool _initialized = false;
  bool _loggingOut = false;
  int _countdown = 0;
  Timer? _timer;
  String? _error;
  String? _codeSentTo;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_policy());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final controller in [
      _username,
      _password,
      _name,
      _email,
      _emailCode,
      _badge,
      _confirm,
      _code
    ]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _policy({bool force = false}) async {
    try {
      await AppScope.of(context).auth.loadRegistrationPolicy(force: force);
    } catch (_) {/* The controller retains the recoverable policy error. */}
  }

  void _setRegistering(bool value) {
    _timer?.cancel();
    _emailCode.clear();
    _badge.clear();
    _code.clear();
    _password.clear();
    _confirm.clear();
    AppScope.of(context).auth.cancelTwoFactorLogin();
    setState(() {
      _registering = value;
      _error = null;
      _countdown = 0;
      _codeSentTo = null;
    });
    if (value) unawaited(_policy(force: true));
  }

  Future<void> _sendCode() async {
    final auth = AppScope.of(context).auth;
    final email = _email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _error = '请先填写有效的邮箱地址');
      return;
    }
    setState(() => _error = null);
    try {
      await auth.sendRegistrationEmailCode(email: email);
      if (!mounted || !_registering || _email.text.trim() != email) return;
      setState(() {
        _countdown = 60;
        _codeSentTo = email;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _countdown--);
        if (_countdown <= 0) timer.cancel();
      });
    } catch (_) {/* The field renders emailCodeError from the controller. */}
  }

  Future<void> _submit() async {
    final auth = AppScope.of(context).auth;
    if (auth.isBusy) return;
    String? validation;
    if (auth.loginTwoFactorChallenge != null) {
      if (_code.text.trim().isEmpty) validation = '请输入验证器代码或恢复码';
    } else {
      if (_username.text.trim().isEmpty || _password.text.isEmpty) {
        validation = '请填写用户名和密码';
      }
      if (_registering) {
        final policy = auth.registrationPolicy;
        if (_username.text.trim().length < 3 ||
            _username.text.trim().length > 32) {
          validation = '用户名长度需要为 3–32 个字符';
        } else if (_name.text.trim().isEmpty) {
          validation = '请填写显示名称';
        } else if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
            .hasMatch(_email.text.trim())) {
          validation = '请填写有效的邮箱地址';
        } else if (_password.text.length < 12 || _password.text.length > 256) {
          validation = '密码长度需要为 12–256 个字符';
        } else if (_password.text != _confirm.text) {
          validation = '两次输入的密码不一致';
        } else if (policy == null) {
          validation = '请先读取服务器的注册要求';
        } else if (policy.emailVerificationRequired &&
            !RegExp(r'^\d{6}$').hasMatch(_emailCode.text.trim())) {
          validation = '邮箱验证码需为 6 位数字';
        } else if (policy.identityBadgeRequired && _badge.text.trim().isEmpty) {
          validation = '请填写管理员提供的身份牌';
        }
      }
    }
    setState(() => _error = validation);
    if (validation != null) return;
    try {
      if (auth.loginTwoFactorChallenge != null) {
        await auth.completeTwoFactorLogin(code: _code.text.trim());
      } else if (_registering) {
        final policy = auth.registrationPolicy!;
        await auth.register(
            username: _username.text.trim(),
            displayName: _name.text.trim(),
            email: _email.text.trim(),
            password: _password.text,
            emailCode: policy.emailVerificationRequired
                ? _emailCode.text.trim()
                : null,
            identityBadge:
                policy.identityBadgeRequired ? _badge.text.trim() : null);
      } else {
        await auth.login(
            username: _username.text.trim(), password: _password.text);
      }
      if (!mounted) return;
      _password.clear();
      _confirm.clear();
      _code.clear();
      _badge.clear();
      if (auth.isAuthenticated) {
        _timer?.cancel();
        _emailCode.clear();
        FocusScope.of(context).unfocus();
      }
    } catch (_) {/* AuthController exposes the specific server error. */}
  }

  Future<void> _github() async {
    _password.clear();
    setState(() => _error = null);
    try {
      await showGitHubDeviceAuthorization(
          context: context, auth: AppScope.of(context).auth, purpose: 'login');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _logout() async {
    final auth = AppScope.of(context).auth;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('退出当前账号？'),
                content: Text(
                    '退出 ${auth.user?.label ?? '当前账号'} 后，书库与阅读进度仍保存在服务器。重新登录即可恢复。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('退出登录'))
                ]));
    if (confirmed != true || !mounted) return;
    setState(() => _loggingOut = true);
    try {
      await auth.logout();
    } catch (_) {
      /* The controller clears local credentials even on network loss. */
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[scope.auth, scope.backend]),
        builder: (context, _) {
          final auth = scope.auth;
          final connected = scope.backend.status == BackendStatus.ready;
          Widget body;
          if (!connected) {
            body = MobileSettingsNotice(
                title: '先连接阅读服务',
                message: '连接成功后，可登录账号恢复你的书库。',
                action: MobileActionButton(
                    icon: Icons.link_rounded,
                    onPressed: () => showMobileConnectionPage(context),
                    child: const Text('连接服务')));
          } else if (scope.backend.capabilities['desktopSharing'] == true) {
            body = const MobileSettingsNotice(
                title: 'PC 共享书库',
                message: '当前与 PC 共用书库、任务和阅读进度，无需额外登录。请保持 PC 青卷运行。');
          } else if (!scope.backend.multiUserEnabled) {
            body = const MobileSettingsNotice(
                title: '需要升级服务端',
                message: '当前服务端不支持个人账号。请联系管理员升级后再登录。',
                error: true);
          } else if (auth.status == UserAuthStatus.restoring) {
            body = const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('正在恢复登录状态'),
                  SizedBox(height: 16),
                  LinearProgressIndicator()
                ]);
          } else if (auth.isAuthenticated && auth.user != null) {
            body = _account(auth);
          } else {
            body = _form(auth);
          }
          return MobileSettingsPage(title: '账号管理', child: body);
        });
  }

  Widget _account(AuthController auth) {
    final user = auth.user!;
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(user.label,
              style: MiuixTheme.of(context)
                  .textStyles
                  .title4
                  .copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('@${user.username} · ${user.isAdministrator ? '管理员' : '读者'}'),
          if (user.email.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(user.email)
          ],
          const SizedBox(height: 24),
          const MobileSettingsNotice(
              title: '个人书库已就绪', message: '书籍、阅读进度与任务会保存在当前服务的个人账号中。'),
          const SizedBox(height: 20),
          ListTile(
              key: const ValueKey('auth-account-security'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.shield_outlined),
              title: const Text('账号安全'),
              subtitle: const Text('GitHub 绑定、两步验证与恢复码'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () =>
                  showAccountSecurityDialog(context: context, auth: auth)),
          const Divider(),
          const SizedBox(height: 12),
          OutlinedButton(
              key: const ValueKey('auth-logout'),
              onPressed: _loggingOut ? null : _logout,
              child: Text(_loggingOut ? '正在退出…' : '退出登录')),
        ]);
  }

  Widget _field(TextEditingController controller, String label,
          {bool password = false,
          TextInputType? keyboard,
          String? helper,
          ValueChanged<String>? onChanged,
          Iterable<String>? autofillHints}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: TextField(
            controller: controller,
            enabled: !AppScope.of(context).auth.isBusy,
            obscureText: password && !_showPassword,
            keyboardType: keyboard,
            autocorrect: !password,
            enableSuggestions: !password,
            autofillHints: autofillHints,
            textInputAction: TextInputAction.next,
            onChanged: onChanged,
            decoration: InputDecoration(
                labelText: label,
                helperText: helper,
                helperMaxLines: 3,
                suffixIcon: controller == _password
                    ? IconButton(
                        tooltip: _showPassword ? '隐藏密码' : '显示密码',
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                        icon: Icon(_showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined))
                    : null)),
      );

  Widget _form(AuthController auth) {
    final challenge = auth.loginTwoFactorChallenge != null;
    final policy = auth.registrationPolicy;
    final error = _error ?? auth.error;
    return AutofillGroup(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
          Text(
              challenge
                  ? '验证你的身份'
                  : _registering
                      ? '创建阅读账号'
                      : '欢迎回来',
              style: MiuixTheme.of(context)
                  .textStyles
                  .title4
                  .copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(challenge
              ? '输入验证器生成的代码，或使用一个恢复码。'
              : _registering
                  ? '创建账号后，书库与阅读进度只对你可见。'
                  : '登录当前服务，继续上次的阅读。'),
          const SizedBox(height: 24),
          if (challenge)
            _field(_code, '验证器代码或恢复码',
                autofillHints: const [AutofillHints.oneTimeCode])
          else ...<Widget>[
            _field(_username, '用户名',
                autofillHints: const [AutofillHints.username]),
            if (_registering) ...<Widget>[
              _field(_name, '显示名称'),
              _field(_email, '邮箱地址',
                  keyboard: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email], onChanged: (_) {
                if (_codeSentTo != null) {
                  _timer?.cancel();
                  _emailCode.clear();
                  setState(() {
                    _countdown = 0;
                    _codeSentTo = null;
                  });
                }
              }),
            ],
            _field(_password, '密码',
                password: true,
                helper: _registering ? '12–256 个字符' : null,
                autofillHints: [
                  _registering
                      ? AutofillHints.newPassword
                      : AutofillHints.password
                ]),
            if (_registering) ...<Widget>[
              _field(_confirm, '再次输入密码',
                  password: true,
                  autofillHints: const [AutofillHints.newPassword]),
              if (auth.registrationPolicyLoading)
                const Padding(
                    padding: EdgeInsets.only(bottom: 18),
                    child: LinearProgressIndicator()),
              if (auth.registrationPolicyError != null)
                MobileSettingsNotice(
                    title: '注册要求未读取',
                    message: auth.registrationPolicyError!,
                    error: true,
                    action: TextButton(
                        onPressed: () => _policy(force: true),
                        child: const Text('重新读取'))),
              if (policy?.emailVerificationRequired == true) ...<Widget>[
                _field(_emailCode, '邮箱验证码',
                    keyboard: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode]),
                OutlinedButton(
                    onPressed: auth.emailCodeSending || _countdown > 0
                        ? null
                        : _sendCode,
                    child: Text(auth.emailCodeSending
                        ? '正在发送…'
                        : _countdown > 0
                            ? '$_countdown 秒后重发'
                            : '发送验证码')),
                if (_codeSentTo != null)
                  const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('验证码已发送，请检查收件箱或垃圾邮件。')),
                if (auth.emailCodeError != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(auth.emailCodeError!,
                          style: TextStyle(
                              color: MiuixTheme.of(context).colors.error))),
                const SizedBox(height: 18),
              ],
              if (policy?.identityBadgeRequired == true)
                _field(_badge, '身份牌', password: true, helper: '由此服务的管理员提供'),
            ],
          ],
          if (error != null) ...<Widget>[
            MobileSettingsNotice(title: '请检查后重试', message: error, error: true),
            const SizedBox(height: 16)
          ],
          MobileActionButton(
              icon: challenge
                  ? Icons.verified_user_outlined
                  : _registering
                      ? Icons.person_add_alt_rounded
                      : Icons.login_rounded,
              busy: auth.isBusy,
              onPressed: auth.isBusy ||
                      (_registering &&
                          (policy == null || auth.registrationPolicyLoading))
                  ? null
                  : _submit,
              child: Text(auth.isBusy
                  ? '正在验证…'
                  : challenge
                      ? '验证并登录'
                      : _registering
                          ? '创建账号'
                          : '登录')),
          const SizedBox(height: 8),
          if (!challenge && !_registering)
            TextButton(
                key: const ValueKey('mobile-forgot-password'),
                onPressed: auth.isBusy
                    ? null
                    : () => showAccountMaintenanceForm(
                        context: context,
                        auth: auth,
                        mode: AccountMaintenanceMode.resetPassword),
                child: const Text('忘记密码')),
          if (!challenge && !_registering && policy?.githubLoginEnabled == true)
            OutlinedButton(
                onPressed: auth.isBusy ? null : _github,
                child: const Text('使用 GitHub 登录')),
          TextButton(
              onPressed: auth.isBusy
                  ? null
                  : () => _setRegistering(challenge ? false : !_registering),
              child: Text(challenge
                  ? '返回账号登录'
                  : _registering
                      ? '已有账号，前往登录'
                      : '没有账号，创建一个')),
          if (!_registering && auth.registrationPolicyError != null)
            TextButton(
                onPressed: () => _policy(force: true),
                child: const Text('重新加载其他登录方式')),
        ]));
  }
}
