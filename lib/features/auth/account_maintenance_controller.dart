import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models/account_maintenance.dart';
import 'auth_controller.dart';

class AccountMaintenanceController extends ChangeNotifier {
  AccountMaintenanceController(this.auth)
      : _contextRevision = auth.contextRevision,
        _identity = auth.workspaceIdentity,
        _multiUser = auth.multiUserEnabled {
    auth.addListener(_authChanged);
  }

  final AuthController auth;
  final int _contextRevision;
  final String? _identity;
  final bool _multiUser;
  bool _disposed = false;
  bool _endingSession = false;
  int _operation = 0;
  Timer? _timer;
  AccountMaintenance? account;
  List<AccountSession> sessions = const [];
  bool loading = false;
  bool busy = false;
  bool invalidated = false;
  bool completed = false;
  String? error;
  String? message;
  int resendSeconds = 0;

  Future<void> load() async {
    if (loading || invalidated || !auth.isAuthenticated) return;
    final operation = ++_operation;
    loading = true;
    error = null;
    _notify();
    try {
      final values = await Future.wait<Object>([
        auth.api.fetchAccountMaintenance(),
        auth.api.fetchAccountSessions(),
      ]);
      if (!_current(operation)) return;
      account = values[0] as AccountMaintenance;
      sessions = List.unmodifiable(values[1] as List<AccountSession>);
    } catch (exception) {
      if (_current(operation)) error = '$exception';
    } finally {
      if (_current(operation)) {
        loading = false;
        _notify();
      }
    }
  }

  Future<bool> changePassword(
      {required String currentPassword,
      required String newPassword,
      String? code}) async {
    final changed = await _run(() async {
      await auth.api.changeAccountPassword(
          currentPassword: currentPassword,
          newPassword: newPassword,
          code: code);
      if (_disposed || invalidated) return;
      completed = true;
      message = '密码已修改，所有旧会话已退出，请重新登录。';
    });
    if (changed && !_disposed) {
      _endingSession = true;
      auth.invalidateSession();
    }
    return changed;
  }

  Future<bool> sendVerification({required String password, String? code}) =>
      _dispatch(() => auth.api
          .requestAccountEmailVerification(password: password, code: code));

  Future<bool> sendReset({required String email}) =>
      _dispatch(() => auth.api.requestPasswordReset(email: email));

  Future<bool> verifyEmail({required String emailCode}) => _run(() async {
        await auth.api.confirmAccountEmailVerification(emailCode: emailCode);
        if (_disposed || invalidated) return;
        completed = true;
        message = '邮箱已验证，现在可以通过该邮箱找回密码。';
      });

  Future<bool> resetPassword(
          {required String email,
          required String emailCode,
          required String newPassword,
          String? code}) =>
      _run(() async {
        await auth.api.confirmPasswordReset(
            email: email,
            emailCode: emailCode,
            newPassword: newPassword,
            code: code);
        if (_disposed || invalidated) return;
        completed = true;
        message = '密码已重置，所有旧会话已退出，请使用新密码登录。';
      });

  Future<bool> revoke(AccountSession session) async {
    final success = await _run(() async {
      await auth.api.revokeAccountSession(session.id);
      if (_disposed || invalidated) return;
      sessions =
          List.unmodifiable(sessions.where((item) => item.id != session.id));
      message = session.current ? '当前会话已退出，请重新登录。' : '已退出所选设备的登录会话。';
    });
    if (success && session.current && !_disposed) {
      _endingSession = true;
      completed = true;
      auth.invalidateSession();
      _notify();
    }
    return success;
  }

  Future<bool> _dispatch(Future<AccountEmailDispatch> Function() action) {
    if (resendSeconds > 0) return Future.value(false);
    return _run(() async {
      final dispatch = await action();
      if (_disposed || invalidated) return;
      message = dispatch.message;
      resendSeconds = dispatch.resendAfterSeconds.clamp(1, 3600);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_disposed || invalidated || resendSeconds <= 1) {
          resendSeconds = 0;
          timer.cancel();
        } else {
          resendSeconds--;
        }
        _notify();
      });
    });
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (busy || invalidated || completed || loading) return false;
    final operation = ++_operation;
    busy = true;
    error = null;
    _notify();
    try {
      await action();
      if (!_current(operation)) return false;
      return true;
    } catch (exception) {
      if (_current(operation)) error = '$exception';
      return false;
    } finally {
      if (_current(operation)) {
        busy = false;
        _notify();
      }
    }
  }

  void _authChanged() {
    if (_disposed || _endingSession) return;
    if (auth.contextRevision == _contextRevision &&
        auth.workspaceIdentity == _identity &&
        auth.multiUserEnabled == _multiUser) {
      return;
    }
    invalidated = true;
    ++_operation;
    busy = false;
    loading = false;
    account = null;
    sessions = const [];
    message = null;
    error = '账号或服务器已切换，请关闭后重新打开。';
    _timer?.cancel();
    resendSeconds = 0;
    _notify();
  }

  bool _current(int operation) =>
      !_disposed && !invalidated && operation == _operation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_operation;
    _timer?.cancel();
    auth.removeListener(_authChanged);
    super.dispose();
  }
}
