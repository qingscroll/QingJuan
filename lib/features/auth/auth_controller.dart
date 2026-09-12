import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/backend/user_session_store.dart';
import '../../core/models/user_account.dart';

enum UserAuthStatus {
  inactive,
  restoring,
  localAdministrator,
  anonymous,
  authenticating,
  authenticated,
}

class AuthController extends ChangeNotifier {
  AuthController(
    this.api,
    this.sessionStore, {
    required String Function() backendUrl,
  }) : _backendUrl = backendUrl;

  factory AuthController.localAdministrator(
    ApiClient api, {
    String Function()? backendUrl,
  }) {
    final controller = AuthController(
      api,
      const _NoopUserSessionStore(),
      backendUrl: backendUrl ?? (() => ''),
    );
    controller
      ..status = UserAuthStatus.localAdministrator
      .._multiUser = false;
    return controller;
  }

  final ApiClient api;
  final UserSessionStore sessionStore;
  final String Function() _backendUrl;

  UserAuthStatus status = UserAuthStatus.inactive;
  UserAccount? user;
  String? error;
  String _userToken = '';
  bool _multiUser = false;
  int _generation = 0;
  int _registrationPolicyOperation = 0;
  int _emailCodeOperation = 0;
  int _githubOperation = 0;
  int _githubLoginGeneration = 0;
  int _accountSecurityOperation = 0;
  bool _disposed = false;
  bool _canRestoreOfflineSession = false;

  RegistrationPolicy? registrationPolicy;
  bool registrationPolicyLoading = false;
  String? registrationPolicyError;
  bool emailCodeSending = false;
  String? emailCodeError;
  TwoFactorLoginChallenge? loginTwoFactorChallenge;
  GitHubDeviceFlow? githubDeviceFlow;
  bool githubDeviceBusy = false;
  String? githubDeviceError;
  AccountSecurity? accountSecurity;
  bool accountSecurityLoading = false;
  bool accountSecurityBusy = false;
  String? accountSecurityError;

  String get userToken => _userToken;
  bool get canRestoreOfflineSession => _canRestoreOfflineSession;
  int get contextRevision => _generation;
  bool get multiUserEnabled => _multiUser;
  bool get isAuthenticated => status == UserAuthStatus.authenticated;
  bool get isLocalAdministrator => status == UserAuthStatus.localAdministrator;
  bool get isBusy =>
      status == UserAuthStatus.restoring ||
      status == UserAuthStatus.authenticating;
  bool get canAccessWorkspace => isLocalAdministrator || isAuthenticated;
  bool get canManageServiceConfiguration =>
      isLocalAdministrator ||
      (isAuthenticated && (user?.isAdministrator ?? false));
  String? get workspaceIdentity {
    if (isLocalAdministrator) return 'local:${_normalizedBackendUrl()}';
    final currentUser = user;
    if (!isAuthenticated || currentUser == null) return null;
    return '${_normalizedBackendUrl()}:${currentUser.id}';
  }

  Future<void> initializeForCurrentBackend({
    required bool multiUser,
  }) async {
    final generation = ++_generation;
    _multiUser = multiUser;
    user = null;
    error = null;
    _userToken = '';
    _canRestoreOfflineSession = false;
    _resetRegistrationState();
    _resetSensitiveAuthState();

    if (!multiUser) {
      status = UserAuthStatus.localAdministrator;
      await _deleteStoredToken();
      _notify();
      return;
    }

    status = UserAuthStatus.restoring;
    _notify();
    final token = await sessionStore.readToken(_normalizedBackendUrl());
    if (generation != _generation || _disposed) return;
    if (token == null || token.trim().isEmpty) {
      status = UserAuthStatus.anonymous;
      _notify();
      return;
    }

    _userToken = token.trim();
    _canRestoreOfflineSession = true;
    try {
      final restoredUser = await api.fetchUserSession();
      if (generation != _generation || _disposed) return;
      user = restoredUser;
      status = UserAuthStatus.authenticated;
    } catch (exception) {
      if (generation != _generation || _disposed) return;
      _userToken = '';
      user = null;
      status = UserAuthStatus.anonymous;
      error = '$exception';
      if (exception is ApiException &&
          (exception.statusCode == 401 || exception.statusCode == 403)) {
        _canRestoreOfflineSession = false;
        await _deleteStoredToken();
      }
    }
    _notify();
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    if (!_multiUser || isBusy) return;
    final generation = ++_generation;
    status = UserAuthStatus.authenticating;
    error = null;
    loginTwoFactorChallenge = null;
    _notify();
    try {
      final result = await api.loginUser(
        username: username.trim(),
        password: password,
      );
      if (generation != _generation || _disposed) return;
      switch (result) {
        case AuthenticatedLogin(:final session):
          await _applySession(session, generation: generation);
        case TwoFactorLoginChallenge():
          loginTwoFactorChallenge = result;
          status = UserAuthStatus.anonymous;
          _notify();
      }
    } catch (exception) {
      if (generation != _generation || _disposed) return;
      status = UserAuthStatus.anonymous;
      error = '$exception';
      _notify();
      rethrow;
    }
  }

  Future<void> completeTwoFactorLogin({required String code}) async {
    final challenge = loginTwoFactorChallenge;
    if (!_multiUser || challenge == null || isBusy) return;
    final generation = ++_generation;
    status = UserAuthStatus.authenticating;
    error = null;
    _notify();
    try {
      final session = await api.completeTwoFactorLogin(
        challengeToken: challenge.challengeToken,
        code: code.trim(),
      );
      if (generation != _generation || _disposed) return;
      loginTwoFactorChallenge = null;
      await _applySession(session, generation: generation);
    } catch (exception) {
      if (generation != _generation || _disposed) return;
      status = UserAuthStatus.anonymous;
      error = '$exception';
      _notify();
      rethrow;
    }
  }

  void cancelTwoFactorLogin() {
    if (loginTwoFactorChallenge == null) return;
    ++_generation;
    loginTwoFactorChallenge = null;
    error = null;
    status = UserAuthStatus.anonymous;
    _notify();
  }

  Future<void> register({
    required String username,
    required String displayName,
    required String email,
    required String password,
    String? emailCode,
    String? identityBadge,
  }) async {
    if (!_multiUser || isBusy) return;
    final generation = ++_generation;
    status = UserAuthStatus.authenticating;
    error = null;
    loginTwoFactorChallenge = null;
    _notify();
    try {
      final session = await api.registerUser(
        username: username.trim(),
        displayName: displayName.trim(),
        email: email.trim(),
        password: password,
        emailCode: emailCode?.trim(),
        identityBadge: identityBadge?.trim(),
      );
      if (generation != _generation || _disposed) return;
      await _applySession(session, generation: generation);
    } catch (exception) {
      if (generation != _generation || _disposed) return;
      status = UserAuthStatus.anonymous;
      error = '$exception';
      _notify();
      rethrow;
    }
  }

  Future<void> loadRegistrationPolicy({bool force = false}) async {
    if (!_multiUser || registrationPolicyLoading) return;
    if (!force && registrationPolicy != null) return;
    final operation = ++_registrationPolicyOperation;
    registrationPolicyLoading = true;
    registrationPolicyError = null;
    if (!emailCodeSending) emailCodeError = null;
    _notify();
    try {
      final policy = await api.fetchRegistrationPolicy();
      if (!_registrationOperationIsCurrent(operation)) return;
      registrationPolicy = policy;
      registrationPolicyLoading = false;
      _notify();
    } catch (exception) {
      if (!_registrationOperationIsCurrent(operation)) return;
      registrationPolicy = null;
      registrationPolicyLoading = false;
      registrationPolicyError = '$exception';
      _notify();
      rethrow;
    }
  }

  Future<void> sendRegistrationEmailCode({required String email}) async {
    if (!_multiUser || emailCodeSending) return;
    final operation = ++_emailCodeOperation;
    emailCodeSending = true;
    emailCodeError = null;
    _notify();
    try {
      await api.sendRegistrationEmailCode(email: email.trim());
      if (!_emailCodeOperationIsCurrent(operation)) return;
      emailCodeSending = false;
      _notify();
    } catch (exception) {
      if (!_emailCodeOperationIsCurrent(operation)) return;
      emailCodeSending = false;
      emailCodeError = '$exception';
      _notify();
      rethrow;
    }
  }

  Future<GitHubDeviceFlow> startGitHubDevice({
    required String purpose,
    String? password,
    String? code,
  }) async {
    if (!_multiUser || (purpose == 'bind' && !isAuthenticated)) {
      throw StateError('当前状态不能开始 GitHub 授权');
    }
    if (purpose != 'login' && purpose != 'bind') {
      throw ArgumentError.value(purpose, 'purpose');
    }
    final operation = ++_githubOperation;
    githubDeviceBusy = true;
    githubDeviceError = null;
    githubDeviceFlow = null;
    if (purpose == 'login') {
      _githubLoginGeneration = ++_generation;
      loginTwoFactorChallenge = null;
      error = null;
      status = UserAuthStatus.authenticating;
    }
    _notify();
    try {
      final flow = await api.startGitHubDevice(
        purpose: purpose,
        password: password,
        code: code,
      );
      if (_disposed || operation != _githubOperation) {
        throw StateError('GitHub 授权已取消');
      }
      githubDeviceFlow = flow;
      githubDeviceBusy = false;
      _notify();
      return flow;
    } catch (exception) {
      if (!_disposed && operation == _githubOperation) {
        githubDeviceBusy = false;
        githubDeviceError = '$exception';
        if (purpose == 'login') {
          status = UserAuthStatus.anonymous;
          error = '$exception';
        }
        _notify();
      }
      rethrow;
    }
  }

  Future<GitHubDevicePollResult> pollGitHubDevice(
    GitHubDeviceFlow flow,
  ) async {
    final operation = _githubOperation;
    if (_disposed || githubDeviceFlow?.flowId != flow.flowId) {
      throw StateError('GitHub 授权已取消');
    }
    final result = await api.pollGitHubDevice(flow);
    if (_disposed || operation != _githubOperation) {
      throw StateError('GitHub 授权已取消');
    }
    switch (result.status) {
      case GitHubDevicePollStatus.pending:
        break;
      case GitHubDevicePollStatus.bound:
        githubDeviceFlow = null;
        accountSecurity = null;
        githubDeviceBusy = false;
        _notify();
      case GitHubDevicePollStatus.authenticated:
        final session = result.session;
        if (session == null) {
          throw const FormatException('GitHub 登录响应缺少会话');
        }
        githubDeviceFlow = null;
        githubDeviceBusy = false;
        await _applySession(session, generation: _githubLoginGeneration);
      case GitHubDevicePollStatus.twoFactorRequired:
        final challenge = result.challenge;
        if (challenge == null) {
          throw const FormatException('GitHub 登录响应缺少两步验证挑战');
        }
        githubDeviceFlow = null;
        githubDeviceBusy = false;
        loginTwoFactorChallenge = challenge;
        status = UserAuthStatus.anonymous;
        _notify();
    }
    return result;
  }

  void cancelGitHubDeviceFlow() {
    final flow = githubDeviceFlow;
    if (flow == null && !githubDeviceBusy) return;
    ++_githubOperation;
    githubDeviceFlow = null;
    githubDeviceBusy = false;
    githubDeviceError = null;
    if (flow?.purpose == 'login' || status == UserAuthStatus.authenticating) {
      ++_generation;
      status = UserAuthStatus.anonymous;
      error = null;
    }
    _notify();
  }

  Future<void> loadAccountSecurity({bool force = false}) async {
    if (!isAuthenticated || accountSecurityLoading) return;
    if (!force && accountSecurity != null) return;
    final operation = ++_accountSecurityOperation;
    accountSecurityLoading = true;
    accountSecurityError = null;
    _notify();
    try {
      final value = await api.fetchAccountSecurity();
      if (!_accountSecurityOperationIsCurrent(operation)) return;
      accountSecurity = value;
      accountSecurityLoading = false;
      _notify();
    } catch (exception) {
      if (!_accountSecurityOperationIsCurrent(operation)) return;
      accountSecurityLoading = false;
      accountSecurityError = '$exception';
      _notify();
      rethrow;
    }
  }

  Future<void> unbindGitHub({
    required String password,
    String? code,
  }) async {
    await _runAccountSecurityMutation(() async {
      await api.unbindGitHub(password: password, code: code);
    });
  }

  Future<TwoFactorSetup> setupTwoFactor({required String password}) async {
    if (!_multiUser || !isAuthenticated) {
      throw StateError('当前状态不能修改账号安全设置');
    }
    return api.setupTwoFactor(password: password);
  }

  Future<RecoveryCodes> enableTwoFactor({
    required String setupId,
    required String code,
  }) async {
    late RecoveryCodes recoveryCodes;
    await _runAccountSecurityMutation(() async {
      recoveryCodes = await api.enableTwoFactor(setupId: setupId, code: code);
    });
    return recoveryCodes;
  }

  Future<void> disableTwoFactor({
    required String password,
    required String code,
  }) =>
      _runAccountSecurityMutation(
        () => api.disableTwoFactor(password: password, code: code),
      );

  Future<RecoveryCodes> regenerateRecoveryCodes({
    required String password,
    required String code,
  }) async {
    late RecoveryCodes recoveryCodes;
    await _runAccountSecurityMutation(() async {
      recoveryCodes = await api.regenerateTwoFactorRecoveryCodes(
        password: password,
        code: code,
      );
    });
    return recoveryCodes;
  }

  Future<void> logout() async {
    if (!_multiUser) return;
    final generation = ++_generation;
    final request =
        _userToken.isNotEmpty ? api.logoutUser() : Future<void>.value();
    _canRestoreOfflineSession = false;
    _userToken = '';
    user = null;
    status = UserAuthStatus.anonymous;
    _resetSensitiveAuthState();
    _notify();
    try {
      await request;
    } finally {
      if (generation == _generation && !_disposed) {
        _userToken = '';
        user = null;
        error = null;
        _resetSensitiveAuthState();
        status = UserAuthStatus.anonymous;
        await _deleteStoredToken();
        _notify();
      }
    }
  }

  Future<void> clearForBackendSwitch() async {
    ++_generation;
    _canRestoreOfflineSession = false;
    _multiUser = false;
    _userToken = '';
    user = null;
    error = null;
    _resetRegistrationState();
    _resetSensitiveAuthState();
    status = UserAuthStatus.inactive;
    _notify();
    await _deleteStoredToken();
  }

  void invalidateSession() {
    if (!_multiUser || _userToken.isEmpty) return;
    ++_generation;
    _canRestoreOfflineSession = false;
    _userToken = '';
    user = null;
    error = '登录状态已失效，请重新登录';
    _resetSensitiveAuthState();
    status = UserAuthStatus.anonymous;
    unawaited(_deleteStoredToken());
    _notify();
  }

  Future<void> _applySession(
    UserSession session, {
    required int generation,
  }) async {
    await sessionStore.writeToken(
      backendUrl: _normalizedBackendUrl(),
      token: session.token,
    );
    if (_disposed || generation != _generation) {
      await _deleteStoredToken();
      return;
    }
    _userToken = session.token;
    _canRestoreOfflineSession = true;
    user = session.user;
    error = null;
    loginTwoFactorChallenge = null;
    githubDeviceFlow = null;
    githubDeviceBusy = false;
    status = UserAuthStatus.authenticated;
    _notify();
  }

  Future<void> _deleteStoredToken() async {
    try {
      await sessionStore.deleteToken();
    } catch (_) {
      // 安全存储清理失败不应阻止内存会话立即失效。
    }
  }

  String _normalizedBackendUrl() =>
      _backendUrl().trim().replaceAll(RegExp(r'/+$'), '');

  bool _registrationOperationIsCurrent(int operation) =>
      !_disposed && operation == _registrationPolicyOperation;

  bool _emailCodeOperationIsCurrent(int operation) =>
      !_disposed && operation == _emailCodeOperation;

  bool _accountSecurityOperationIsCurrent(int operation) =>
      !_disposed && operation == _accountSecurityOperation && isAuthenticated;

  Future<void> _runAccountSecurityMutation(
    Future<void> Function() action,
  ) async {
    if (!isAuthenticated || accountSecurityBusy) {
      throw StateError('当前状态不能修改账号安全设置');
    }
    final operation = ++_accountSecurityOperation;
    accountSecurityBusy = true;
    accountSecurityError = null;
    _notify();
    try {
      await action();
    } catch (exception) {
      if (!_disposed && operation == _accountSecurityOperation) {
        accountSecurityBusy = false;
        accountSecurityError = '$exception';
        _notify();
      }
      rethrow;
    }
    if (!_accountSecurityOperationIsCurrent(operation)) return;
    accountSecurityBusy = false;
    accountSecurity = null;
    _notify();
    unawaited(_refreshAccountSecurityAfterMutation());
  }

  Future<void> _refreshAccountSecurityAfterMutation() async {
    try {
      await loadAccountSecurity(force: true);
    } catch (_) {
      // 修改已成功，刷新失败只保留为可重试的加载错误，不能吞掉一次性恢复码。
    }
  }

  void _resetRegistrationState() {
    _registrationPolicyOperation += 1;
    _emailCodeOperation += 1;
    registrationPolicy = null;
    registrationPolicyLoading = false;
    registrationPolicyError = null;
    emailCodeSending = false;
    emailCodeError = null;
  }

  void _resetSensitiveAuthState() {
    _githubOperation += 1;
    _accountSecurityOperation += 1;
    loginTwoFactorChallenge = null;
    githubDeviceFlow = null;
    githubDeviceBusy = false;
    githubDeviceError = null;
    accountSecurity = null;
    accountSecurityLoading = false;
    accountSecurityBusy = false;
    accountSecurityError = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _canRestoreOfflineSession = false;
    _resetSensitiveAuthState();
    _userToken = '';
    user = null;
    _disposed = true;
    super.dispose();
  }
}

class _NoopUserSessionStore implements UserSessionStore {
  const _NoopUserSessionStore();

  @override
  Future<void> deleteToken() async {}

  @override
  Future<String?> readToken(String backendUrl) async => null;

  @override
  Future<void> writeToken({
    required String backendUrl,
    required String token,
  }) async {}
}
