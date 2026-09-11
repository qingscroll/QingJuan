import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../models/book.dart';
import '../models/settings.dart';
import 'local_backend_process.dart';
import 'lan_backend_share.dart';

enum BackendStatus { unconfigured, checking, starting, ready, failed }

class BackendConnectionManager implements Listenable {
  BackendConnectionManager(
    this.api, {
    required bool Function() isConfigured,
    bool Function()? isLocal,
    LocalBackendLifecycle? localBackend,
    void Function()? validateConfiguration,
    Duration heartbeatInterval = const Duration(seconds: 30),
  })  : _isConfigured = isConfigured,
        _isLocal = isLocal ?? (() => false),
        _localBackend = localBackend,
        _validateConfiguration = validateConfiguration,
        _heartbeatInterval = heartbeatInterval;

  final ApiClient api;
  final LanBackendShare lanShare = LanBackendShare();
  final bool Function() _isConfigured;
  final bool Function() _isLocal;
  final LocalBackendLifecycle? _localBackend;
  final void Function()? _validateConfiguration;
  final Duration _heartbeatInterval;
  final ValueNotifier<int> _notifier = ValueNotifier<int>(0);

  BackendStatus status = BackendStatus.unconfigured;
  String message = '请先配置 Linux 后端';
  TranslationModelCheck? translationModelCheck;
  bool translationModelCheckInProgress = false;
  Map<String, dynamic> capabilities = const <String, dynamic>{};
  bool multiUserEnabled = false;
  Timer? _heartbeatTimer;
  bool _heartbeatInProgress = false;
  int _generation = 0;
  int _modelCheckOperation = 0;
  int _draftProbeOperation = 0;
  int _readyEpoch = 0;
  bool _disposed = false;

  int get readyEpoch => _readyEpoch;

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);

  Future<void> ensureReady() async {
    final generation = ++_generation;
    _cancelHeartbeat();
    _resetHealthState();
    if (_isLocal()) {
      await _ensureLocalReady(generation);
      return;
    }

    await lanShare.stop();
    await _localBackend?.stop();
    if (!_isCurrent(generation)) return;
    if (!_isConfigured()) {
      status = BackendStatus.unconfigured;
      message = '请先填写 Linux 后端地址和连接 Token';
      _notifyListeners();
      return;
    }

    status = BackendStatus.checking;
    message = '正在连接 Linux 后端';
    _notifyListeners();
    var configurationValid = false;
    try {
      _validateConfiguration?.call();
      configurationValid = true;
      final meta = await api.fetchServiceMeta();
      if (!_isCurrent(generation)) return;
      _finishReady(meta, label: 'Linux 后端');
    } catch (error) {
      if (!_isCurrent(generation)) return;
      status = BackendStatus.failed;
      message = 'Linux 后端连接失败：$error';
      _notifyListeners();
    } finally {
      if (configurationValid &&
          _isCurrent(generation) &&
          !_isLocal() &&
          _isConfigured()) {
        _startHeartbeat(generation);
      }
    }
  }

  Future<JsonMap> testRemoteConnection({
    required String baseUrl,
    required String token,
  }) async {
    final operation = ++_draftProbeOperation;
    final meta = await api.testConnection(baseUrl: baseUrl, token: token);
    if (_disposed || operation != _draftProbeOperation) {
      throw const ApiException('后端连接信息已发生变化，请重新保存');
    }
    final rawCapabilities = meta['capabilities'];
    if (rawCapabilities is! Map ||
        (rawCapabilities['multiUser'] != true &&
            rawCapabilities['desktopSharing'] != true)) {
      throw const ApiException('Linux 后端版本过旧，不支持多用户书架，请先升级服务端');
    }
    return meta;
  }

  Future<void> _ensureLocalReady(int generation) async {
    final localBackend = _localBackend;
    if (localBackend == null) {
      status = BackendStatus.failed;
      message = '当前平台不支持 Windows 本机后端';
      _notifyListeners();
      return;
    }

    status = BackendStatus.starting;
    message = '正在检查并启动本机后端';
    _notifyListeners();
    try {
      final meta = await localBackend.ensureRunning(api);
      if (!_isCurrent(generation)) return;
      _finishReady(meta, label: '本机后端', requireMultiUser: false);
    } catch (error) {
      await lanShare.stop();
      await localBackend.stop();
      if (!_isCurrent(generation)) return;
      status = BackendStatus.failed;
      message = '本机后端不可用：$error';
      _notifyListeners();
    }
  }

  void _finishReady(
    JsonMap meta, {
    required String label,
    bool requireMultiUser = true,
  }) {
    final becameReady = status != BackendStatus.ready;
    final rawCapabilities = meta['capabilities'];
    capabilities = rawCapabilities is Map
        ? Map<String, dynamic>.from(rawCapabilities)
        : const <String, dynamic>{};
    multiUserEnabled = capabilities['multiUser'] == true;
    if (requireMultiUser &&
        !multiUserEnabled &&
        capabilities['desktopSharing'] != true) {
      throw const ApiException('Linux 后端版本过旧，不支持多用户书架，请先升级服务端');
    }
    status = BackendStatus.ready;
    message =
        capabilities['desktopSharing'] == true ? 'PC 局域网后端已连接' : '$label已连接';
    if (becameReady) _readyEpoch += 1;
    _notifyListeners();
  }

  void _startHeartbeat(int generation) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      unawaited(_probeRemoteHealth(generation));
    });
  }

  @visibleForTesting
  Future<void> probeRemoteHealth() => _probeRemoteHealth(_generation);

  Future<void> _probeRemoteHealth(int generation) async {
    if (_heartbeatInProgress ||
        !_isCurrent(generation) ||
        _isLocal() ||
        !_isConfigured()) {
      return;
    }
    _heartbeatInProgress = true;
    try {
      final meta = await api.fetchServiceMeta(quick: true);
      if (!_isCurrent(generation)) return;
      final wasReady = status == BackendStatus.ready;
      _finishReady(meta, label: 'Linux 后端');
      if (!wasReady) {
        translationModelCheck = null;
        _notifyListeners();
      }
      unawaited(api.sendDeviceHeartbeat().catchError((_) {}));
    } catch (_) {
      if (!_isCurrent(generation)) return;
      final changed =
          status != BackendStatus.failed || !message.contains('正在等待服务恢复');
      status = BackendStatus.failed;
      message = 'Linux 后端连接中断，正在等待服务恢复';
      _invalidateModelCheck();
      if (changed) _notifyListeners();
    } finally {
      _heartbeatInProgress = false;
    }
  }

  Future<TranslationModelCheck> checkTranslationModel({
    bool force = false,
  }) async {
    if (status != BackendStatus.ready) {
      translationModelCheck = TranslationModelCheck.clientFailure();
      _notifyListeners();
      return translationModelCheck!;
    }
    final generation = _generation;
    final operation = ++_modelCheckOperation;
    translationModelCheckInProgress = true;
    _notifyListeners();
    late final TranslationModelCheck result;
    try {
      result = await api.checkTranslationModel(force: force);
    } catch (_) {
      result = TranslationModelCheck.clientFailure();
    }
    if (_isCurrent(generation) && operation == _modelCheckOperation) {
      translationModelCheck = result;
      translationModelCheckInProgress = false;
      _notifyListeners();
    }
    return result;
  }

  void _resetHealthState() {
    _invalidateModelCheck();
    capabilities = const <String, dynamic>{};
    multiUserEnabled = false;
  }

  void _invalidateModelCheck() {
    _modelCheckOperation += 1;
    translationModelCheck = null;
    translationModelCheckInProgress = false;
  }

  void _cancelHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatInProgress = false;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _notifyListeners() {
    if (!_disposed) _notifier.value += 1;
  }

  Future<void> dispose() async {
    _disposed = true;
    ++_generation;
    ++_modelCheckOperation;
    ++_draftProbeOperation;
    _cancelHeartbeat();
    await lanShare.stop();
    lanShare.dispose();
    await _localBackend?.stop();
    _notifier.dispose();
  }
}
