import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/backend/connection_secret_store.dart';
import '../core/models/tts_speech_style.dart';
import '../core/models/tts_voice.dart';

enum AppSection {
  library,
  search,
  sources,
  plugins,
  tasks,
  translator,
  settings,
  about,
  discovery,
}

enum AppThemeMode { system, light, dark }

enum BackendConnectionMode { local, remote }

class BackendConnectionProfile {
  const BackendConnectionProfile({required this.url, required this.token});

  final String url;
  final String token;

  bool get isConfigured => url.isNotEmpty && token.isNotEmpty;
}

enum ReaderFlowMode { paged, continuous }

enum ReaderPaletteMode { white, parchment, eyeCare, mist, night }

enum ReaderPageAnimation { cover, slide, fade, none }

enum ReaderLineSpacing { compact, standard, relaxed }

class AppState extends ChangeNotifier {
  AppState(
    this._preferences, {
    ConnectionSecretStore? secretStore,
    String initialRemoteBackendToken = '',
    bool localBackendSupported = false,
  })  : _secretStore = secretStore,
        _localBackendSupported = localBackendSupported,
        _themeMode = AppThemeMode.values.firstWhere(
          (mode) => mode.name == _preferences.getString(_themeKey),
          orElse: () => AppThemeMode.system,
        ),
        _connectionMode = _readConnectionMode(
          _preferences,
          localBackendSupported: localBackendSupported,
        ),
        _remoteBackendConnection = BackendConnectionProfile(
          url: _readRemoteBackendUrl(_preferences),
          token: initialRemoteBackendToken,
        ),
        _ttsVoice = _readTtsVoice(_preferences),
        _ttsSpeechStyle = parseTtsSpeechStyle(
          _preferences.getString(_ttsSpeechStyleKey),
        ),
        _readerFlowMode = ReaderFlowMode.values.firstWhere(
          (mode) => mode.name == _preferences.getString(_readerFlowModeKey),
          orElse: () => ReaderFlowMode.paged,
        ),
        _readerPaletteMode = ReaderPaletteMode.values.firstWhere(
          (mode) => mode.name == _preferences.getString(_readerPaletteKey),
          orElse: () => ReaderPaletteMode.parchment,
        ),
        _readerPageAnimation = ReaderPageAnimation.values.firstWhere(
          (mode) => mode.name == _preferences.getString(_readerAnimationKey),
          orElse: () => ReaderPageAnimation.cover,
        ),
        _readerLineSpacing = ReaderLineSpacing.values.firstWhere(
          (mode) => mode.name == _preferences.getString(_readerSpacingKey),
          orElse: () => ReaderLineSpacing.standard,
        ),
        _readerFontSize =
            (_preferences.getDouble(_readerFontSizeKey) ?? 19).clamp(15, 30),
        _volumeKeyReadingEnabled =
            _preferences.getBool(_volumeKeyReadingKey) ?? false {
    _section = hasBackendConnection ? AppSection.library : AppSection.settings;
    _sectionListenable = ValueNotifier<AppSection>(_section);
    _themeModeListenable = ValueNotifier<ThemeMode>(fluentThemeMode);
  }

  static const _themeKey = 'qingjuan.theme';
  static const _legacyBackendUrlKey = 'qingjuan.backendUrl';
  static const _remoteBackendUrlKey = 'qingjuan.backend.remote.url';
  static const _backendModeKey = 'qingjuan.backendMode';
  static const defaultLocalBackendUrl = 'http://127.0.0.1:19453';
  static const localBackendConnection = BackendConnectionProfile(
    url: defaultLocalBackendUrl,
    token: '',
  );
  static const _ttsVoiceKey = 'qingjuan.ttsVoice';
  static const _ttsSpeechStyleKey = 'qingjuan.ttsSpeechStyle';
  static const _readerFlowModeKey = 'qingjuan.readerFlowMode';
  static const _readerPaletteKey = 'qingjuan.readerPalette';
  static const _readerAnimationKey = 'qingjuan.readerPageAnimation';
  static const _readerSpacingKey = 'qingjuan.readerLineSpacing';
  static const _readerFontSizeKey = 'qingjuan.readerFontSize';
  static const _volumeKeyReadingKey = 'qingjuan.volumeKeyReading';

  final SharedPreferences _preferences;
  final ConnectionSecretStore? _secretStore;
  final bool _localBackendSupported;
  late AppSection _section;
  late final ValueNotifier<AppSection> _sectionListenable;
  AppThemeMode _themeMode;
  late final ValueNotifier<ThemeMode> _themeModeListenable;
  BackendConnectionMode _connectionMode;
  BackendConnectionProfile _remoteBackendConnection;
  int _backendConnectionRevision = 0;
  TtsVoice? _ttsVoice;
  TtsSpeechStyle _ttsSpeechStyle;
  ReaderFlowMode _readerFlowMode;
  ReaderPaletteMode _readerPaletteMode;
  ReaderPageAnimation _readerPageAnimation;
  ReaderLineSpacing _readerLineSpacing;
  double _readerFontSize;
  bool _volumeKeyReadingEnabled;
  String? _notice;

  AppSection get section => _section;
  AppThemeMode get themeMode => _themeMode;
  bool get localBackendSupported => _localBackendSupported;
  BackendConnectionMode get connectionMode => _connectionMode;
  bool get clientPluginManagementAvailable =>
      _localBackendSupported && _connectionMode == BackendConnectionMode.local;
  BackendConnectionProfile get activeBackendConnection =>
      _connectionMode == BackendConnectionMode.local
          ? localBackendConnection
          : _remoteBackendConnection;
  BackendConnectionProfile get remoteBackendConnection =>
      _remoteBackendConnection;
  String get backendUrl => activeBackendConnection.url;
  String get backendToken => activeBackendConnection.token;
  String get remoteBackendUrl => _remoteBackendConnection.url;
  String get remoteBackendToken => _remoteBackendConnection.token;
  int get backendConnectionRevision => _backendConnectionRevision;
  bool get hasBackendConnection =>
      _connectionMode == BackendConnectionMode.local
          ? _localBackendSupported
          : _remoteBackendConnection.isConfigured;
  TtsVoice? get ttsVoice => _ttsVoice;
  TtsSpeechStyle get ttsSpeechStyle => _ttsSpeechStyle;
  ReaderFlowMode get readerFlowMode => _readerFlowMode;
  ReaderPaletteMode get readerPaletteMode => _readerPaletteMode;
  ReaderPageAnimation get readerPageAnimation => _readerPageAnimation;
  ReaderLineSpacing get readerLineSpacing => _readerLineSpacing;
  double get readerFontSize => _readerFontSize;
  bool get volumeKeyReadingEnabled => _volumeKeyReadingEnabled;
  String? get notice => _notice;
  ValueListenable<AppSection> get sectionListenable => _sectionListenable;
  ValueListenable<ThemeMode> get themeModeListenable => _themeModeListenable;

  ThemeMode get fluentThemeMode => switch (_themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };

  void selectSection(AppSection value) {
    final next = value == AppSection.plugins && !clientPluginManagementAvailable
        ? AppSection.settings
        : value;
    if (_section == next) return;
    _section = next;
    _sectionListenable.value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _sectionListenable.dispose();
    _themeModeListenable.dispose();
    super.dispose();
  }

  Future<void> setThemeMode(AppThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    _themeModeListenable.value = fluentThemeMode;
    notifyListeners();
    await _preferences.setString(_themeKey, value.name);
  }

  Future<void> saveRemoteBackendConnection({
    required String url,
    required String token,
  }) async {
    final nextConnection = _normalizeRemoteConnection(url, token);
    await _persistRemoteBackendConnection(nextConnection);
    final changed = _remoteBackendConnection.url != nextConnection.url ||
        _remoteBackendConnection.token != nextConnection.token;
    _remoteBackendConnection = nextConnection;
    if (changed && _connectionMode == BackendConnectionMode.remote) {
      _backendConnectionRevision += 1;
    }
    notifyListeners();
  }

  Future<void> applyBackendConnection({
    required BackendConnectionMode mode,
    String? remoteUrl,
    String? remoteToken,
  }) async {
    if (mode == BackendConnectionMode.local && !_localBackendSupported) {
      throw StateError('当前平台不支持本机后端');
    }
    final nextRemoteConnection = mode == BackendConnectionMode.remote
        ? _normalizeRemoteConnection(remoteUrl ?? '', remoteToken ?? '')
        : _remoteBackendConnection;

    if (mode == BackendConnectionMode.remote) {
      await _persistRemoteBackendConnection(nextRemoteConnection);
    }
    await _preferences.setString(_backendModeKey, mode.name);

    final connectionChanged = _connectionMode != mode ||
        (mode == BackendConnectionMode.remote &&
            (_remoteBackendConnection.url != nextRemoteConnection.url ||
                _remoteBackendConnection.token != nextRemoteConnection.token));
    _remoteBackendConnection = nextRemoteConnection;
    _connectionMode = mode;
    if (!clientPluginManagementAvailable && _section == AppSection.plugins) {
      _section = AppSection.settings;
      _sectionListenable.value = _section;
    }
    if (connectionChanged) {
      _backendConnectionRevision += 1;
    }
    notifyListeners();
  }

  BackendConnectionProfile _normalizeRemoteConnection(
    String url,
    String token,
  ) {
    final normalized = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty) {
      throw StateError('Linux 后端地址不能为空');
    }
    return BackendConnectionProfile(url: normalized, token: token.trim());
  }

  Future<void> _persistRemoteBackendConnection(
    BackendConnectionProfile connection,
  ) async {
    final secretStore = _secretStore;
    if (secretStore != null) {
      if (connection.token.isEmpty) {
        await secretStore.deleteToken();
      } else {
        await secretStore.writeToken(connection.token);
      }
    }
    await _preferences.setString(_remoteBackendUrlKey, connection.url);
    await _preferences.remove(_legacyBackendUrlKey);
  }

  Future<void> selectBackendMode(BackendConnectionMode mode) async {
    if (mode == BackendConnectionMode.local && !_localBackendSupported) {
      throw StateError('当前平台不支持本机后端');
    }
    if (_connectionMode == mode) return;
    _connectionMode = mode;
    _backendConnectionRevision += 1;
    if (!clientPluginManagementAvailable && _section == AppSection.plugins) {
      _section = AppSection.settings;
      _sectionListenable.value = _section;
    }
    await _preferences.setString(_backendModeKey, mode.name);
    notifyListeners();
  }

  Future<void> setTtsVoice(TtsVoice? value) async {
    if (_ttsVoice == value) return;
    _ttsVoice = value;
    notifyListeners();
    if (value == null) {
      await _preferences.remove(_ttsVoiceKey);
    } else {
      await _preferences.setString(_ttsVoiceKey, jsonEncode(value.toJson()));
    }
  }

  Future<void> setTtsSpeechStyle(TtsSpeechStyle value) async {
    if (_ttsSpeechStyle == value) return;
    _ttsSpeechStyle = value;
    notifyListeners();
    await _preferences.setString(_ttsSpeechStyleKey, value.name);
  }

  Future<void> setReaderFlowMode(ReaderFlowMode value) async {
    if (_readerFlowMode == value) return;
    _readerFlowMode = value;
    notifyListeners();
    await _preferences.setString(_readerFlowModeKey, value.name);
  }

  Future<void> setReaderPaletteMode(ReaderPaletteMode value) async {
    if (_readerPaletteMode == value) return;
    _readerPaletteMode = value;
    notifyListeners();
    await _preferences.setString(_readerPaletteKey, value.name);
  }

  Future<void> setReaderPageAnimation(ReaderPageAnimation value) async {
    if (_readerPageAnimation == value) return;
    _readerPageAnimation = value;
    notifyListeners();
    await _preferences.setString(_readerAnimationKey, value.name);
  }

  Future<void> setReaderLineSpacing(ReaderLineSpacing value) async {
    if (_readerLineSpacing == value) return;
    _readerLineSpacing = value;
    notifyListeners();
    await _preferences.setString(_readerSpacingKey, value.name);
  }

  Future<void> setReaderFontSize(double value) async {
    final normalized = value.clamp(15, 30).toDouble();
    if (_readerFontSize == normalized) return;
    _readerFontSize = normalized;
    notifyListeners();
    await _preferences.setDouble(_readerFontSizeKey, normalized);
  }

  Future<void> setVolumeKeyReadingEnabled(bool value) async {
    if (_volumeKeyReadingEnabled == value) return;
    _volumeKeyReadingEnabled = value;
    notifyListeners();
    await _preferences.setBool(_volumeKeyReadingKey, value);
  }

  void showNotice(String message) {
    _notice = message;
    notifyListeners();
  }

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  static TtsVoice? _readTtsVoice(SharedPreferences preferences) {
    final raw = preferences.getString(_ttsVoiceKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final voice = TtsVoice.fromJson(Map<String, dynamic>.from(json));
      return voice.name.isEmpty || voice.locale.isEmpty ? null : voice;
    } catch (_) {
      return null;
    }
  }

  static BackendConnectionMode _readConnectionMode(
    SharedPreferences preferences, {
    required bool localBackendSupported,
  }) {
    if (!localBackendSupported) return BackendConnectionMode.remote;
    final persisted = preferences.getString(_backendModeKey);
    if (persisted == BackendConnectionMode.local.name) {
      return BackendConnectionMode.local;
    }
    if (persisted == BackendConnectionMode.remote.name) {
      return BackendConnectionMode.remote;
    }
    return _readRemoteBackendUrl(preferences).isEmpty
        ? BackendConnectionMode.local
        : BackendConnectionMode.remote;
  }

  static String _readRemoteBackendUrl(SharedPreferences preferences) {
    final value = (preferences.getString(_remoteBackendUrlKey) ??
            preferences.getString(_legacyBackendUrlKey))
        ?.trim();
    final normalized = (value ?? '').replaceAll(RegExp(r'/+$'), '');
    return normalized == defaultLocalBackendUrl ? '' : normalized;
  }
}
