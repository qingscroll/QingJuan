import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../app/app_state.dart';
import '../../core/api/api_client.dart';
import '../../core/backend/backend_connection_manager.dart';
import '../auth/auth_controller.dart';
import 'audiobook_coordinator.dart';

/// App lifetime binding: route changes preserve playback, identity changes stop it.
class AudiobookWorkspaceBinding with WidgetsBindingObserver {
  AudiobookWorkspaceBinding(
      {required this.app,
      required this.api,
      required this.backend,
      required this.auth,
      required this.coordinator}) {
    _guard = api.captureContextGuard();
    _instance = backend.instanceId;
    _identity = auth.workspaceIdentity;
    app.addListener(_changed);
    backend.addListener(_changed);
    auth.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }
  final AppState app;
  final ApiClient api;
  final BackendConnectionManager backend;
  final AuthController auth;
  final AudiobookCoordinator coordinator;
  late bool Function() _guard;
  late String _instance;
  String? _identity;

  void _changed() {
    if (!_guard() ||
        _instance != backend.instanceId ||
        _identity != auth.workspaceIdentity ||
        !auth.canAccessWorkspace) {
      unawaited(coordinator.stopAndClear());
    }
    _guard = api.captureContextGuard();
    _instance = backend.instanceId;
    _identity = auth.workspaceIdentity;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _changed();
      coordinator.sleepTimer.checkOnResume();
    }
  }

  void dispose() {
    app.removeListener(_changed);
    backend.removeListener(_changed);
    auth.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
  }
}
