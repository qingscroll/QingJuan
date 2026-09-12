import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

import '../../app/app_state.dart';
import '../../core/backend/backend_connection_manager.dart';
import '../auth/auth_controller.dart';
import 'offline_reading_controller.dart';

/// Binds device caches to the last verified server/account and credential set.
class OfflineWorkspaceBinding with WidgetsBindingObserver {
  OfflineWorkspaceBinding(
      {required this.app,
      required this.backend,
      required this.auth,
      required this.offline}) {
    _configuration = _configurationKey();
    app.addListener(_changed);
    backend.addListener(_changed);
    auth.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _changed();
  }

  final AppState app;
  final BackendConnectionManager backend;
  final AuthController auth;
  final OfflineReadingController offline;
  late String _configuration;
  String? _observation;
  String? _activeKey;
  int _minimumReadyEpoch = 0;
  int _minimumAuthRevision = 0;
  int _operation = 0;
  bool _disposed = false;

  String _configurationKey() => jsonEncode([
        app.connectionMode.name,
        app.backendUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        app.backendConnectionRevision,
        app.backendToken,
      ]);

  String _credentialKey(String sessionToken) => sha256
      .convert(utf8.encode(jsonEncode([
        app.connectionMode.name,
        app.backendUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        app.backendToken,
        sessionToken,
      ])))
      .toString();

  void _changed() {
    if (_disposed) return;
    final config = _configurationKey();
    if (config != _configuration) {
      _configuration = config;
      _minimumReadyEpoch = backend.readyEpoch + 1;
      _minimumAuthRevision = auth.contextRevision + 1;
      _activeKey = null;
      unawaited(offline.deactivate());
    }
    final observation = jsonEncode([
      config,
      backend.status.name,
      backend.readyEpoch,
      backend.instanceId,
      backend.capabilities['readingProgressVersioning'],
      auth.status.name,
      auth.contextRevision,
      auth.workspaceIdentity,
      auth.canRestoreOfflineSession
    ]);
    if (observation == _observation) return;
    _observation = observation;
    final operation = ++_operation;
    if (backend.status == BackendStatus.ready &&
        backend.readyEpoch >= _minimumReadyEpoch &&
        auth.contextRevision >= _minimumAuthRevision &&
        auth.canAccessWorkspace) {
      final key = _credentialKey(auth.userToken);
      final ownerId = auth.user?.id ?? 'user-admin';
      final versioning =
          backend.capabilities['readingProgressVersioning'] == true;
      if (_activeKey == key &&
          offline.online &&
          offline.identity?.instanceId == backend.instanceId &&
          offline.identity?.ownerId == ownerId &&
          offline.identity?.versioning == versioning) {
        return;
      }
      _activeKey = key;
      unawaited(offline.activate(
          connectionKey: key,
          instanceId: backend.instanceId,
          ownerId: ownerId,
          displayName: auth.user?.label ?? '共享书库',
          versioning: versioning));
      return;
    }
    _activeKey = null;
    offline.suspendOnline();
    if (auth.status == UserAuthStatus.anonymous &&
        !auth.canRestoreOfflineSession) {
      unawaited(_deactivate());
      return;
    }
    if (offline.identity == null) unawaited(_restore(operation));
  }

  Future<void> _deactivate() async {
    try {
      await offline.deactivate(forgetIdentity: true);
    } catch (_) {
      // The in-memory identity is cleared before disk IO; credentials are also
      // removed by AuthController, so a failed pointer write cannot reopen it.
    }
  }

  Future<void> _restore(int operation) async {
    if (!app.hasBackendConnection) return;
    try {
      final session = await auth.sessionStore.readToken(app.backendUrl) ?? '';
      if (_disposed || operation != _operation || offline.online) return;
      final key = _credentialKey(session);
      await offline.restore(
          connectionKey: key, allowStoredIdentity: app.hasBackendConnection);
    } catch (_) {
      if (!_disposed && operation == _operation) await offline.deactivate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_disposed) {
      _changed();
      if (offline.online) unawaited(offline.replayPending());
    }
  }

  void dispose() {
    _disposed = true;
    _operation++;
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(_changed);
    backend.removeListener(_changed);
    auth.removeListener(_changed);
  }
}
