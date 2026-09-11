import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api/api_client.dart';
import '../core/backend/backend_connection_manager.dart';
import '../core/backend/backend_connection_link.dart';
import '../core/backend/backend_url_validator.dart';
import '../core/backend/connection_secret_store.dart';
import '../core/backend/device_identity.dart';
import '../core/backend/local_backend_process.dart';
import '../core/backend/user_session_store.dart';
import '../core/updates/app_update_controller.dart';
import '../features/settings/widgets/app_update_card.dart';
import '../features/auth/auth_controller.dart';
import '../features/library/library_controller.dart';
import '../features/manga_translation/manga_translation_coordinator.dart';
import '../features/settings/settings_controller.dart';
import '../features/shell/app_shell.dart';
import '../features/sources/sources_controller.dart';
import '../features/tasks/tasks_controller.dart';
import '../mobile/mobile_app.dart';
import '../mobile/mobile_my_page.dart';
import '../shared/desktop_title_bar.dart';
import '../shared/responsive.dart';
import 'app_scope.dart';
import 'app_state.dart';
import 'app_theme.dart';

class QingJuanApp extends StatefulWidget {
  const QingJuanApp._({
    required this.appState,
    required this.api,
    required this.backend,
    required this.auth,
    required this.library,
    required this.sources,
    required this.tasks,
    required this.settings,
    required this.mangaTranslation,
    this.updates,
  });

  @visibleForTesting
  factory QingJuanApp.testing({
    required AppState appState,
    required ApiClient api,
    required BackendConnectionManager backend,
    required AuthController auth,
    required LibraryController library,
    required SourcesController sources,
    required TasksController tasks,
    required SettingsController settings,
    MangaTranslationCoordinator? mangaTranslation,
    AppUpdateController? updates,
  }) =>
      QingJuanApp._(
        appState: appState,
        api: api,
        backend: backend,
        auth: auth,
        library: library,
        sources: sources,
        tasks: tasks,
        settings: settings,
        mangaTranslation: mangaTranslation ?? MangaTranslationCoordinator(api),
        updates: updates,
      );

  static Future<QingJuanApp> bootstrap() async {
    final preferences = await SharedPreferences.getInstance();
    const secretStore = SecureConnectionSecretStore();
    final token = await secretStore.readToken() ?? '';
    final deviceIdentity = await DeviceIdentity.load(preferences);
    final appState = AppState(
      preferences,
      secretStore: secretStore,
      initialRemoteBackendToken: token,
      localBackendSupported: Platform.isWindows,
    );
    late final AuthController auth;
    final api = ApiClient(
      () => appState.backendUrl,
      token: () => appState.backendToken,
      userToken: () => auth.userToken,
      connectionRevision: () => appState.backendConnectionRevision,
      deviceHeaders: () => deviceIdentity.headers,
      onUserSessionExpired: () => auth.invalidateSession(),
    );
    final backend = BackendConnectionManager(
      api,
      isConfigured: () => appState.hasBackendConnection,
      isLocal: () => appState.connectionMode == BackendConnectionMode.local,
      localBackend: Platform.isWindows ? WindowsLocalBackendLifecycle() : null,
      validateConfiguration: () => validateBackendUrl(appState.backendUrl),
    );
    auth = AuthController(
      api,
      const SecureUserSessionStore(),
      backendUrl: () => appState.backendUrl,
    );
    return QingJuanApp._(
      appState: appState,
      api: api,
      backend: backend,
      auth: auth,
      library: LibraryController(api),
      sources: SourcesController(api),
      tasks: TasksController(api),
      settings: SettingsController(api),
      updates: AppUpdateController.production(exitForInstall: () async {
        await backend.dispose();
        exit(0);
      }),
      mangaTranslation: MangaTranslationCoordinator(
        api,
        preferences: preferences,
      ),
    );
  }

  final AppState appState;
  final ApiClient api;
  final BackendConnectionManager backend;
  final AuthController auth;
  final LibraryController library;
  final SourcesController sources;
  final TasksController tasks;
  final SettingsController settings;
  final MangaTranslationCoordinator mangaTranslation;
  final AppUpdateController? updates;

  @override
  State<QingJuanApp> createState() => _QingJuanAppState();
}

class _QingJuanAppState extends State<QingJuanApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _rootNavigatorKey = GlobalKey<NavigatorState>();
  String? _activeWorkspaceIdentity;
  int _workspaceGeneration = 0;
  int _backendActivationOperation = 0;
  int _handledReadyEpoch = 0;
  int _activationEpochInProgress = 0;
  bool _initializing = true;
  StreamSubscription<Uri>? _connectionLinkSubscription;
  BackendConnectionLink? _pendingConnectionLink;
  bool _showingConnectionLink = false;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_handleAuthChanged);
    widget.backend.addListener(_handleBackendChanged);
    if (Platform.isAndroid) {
      _connectionLinkSubscription = AppLinks().uriLinkStream.listen(
            _receiveConnectionLink,
            onError: (Object _) =>
                widget.appState.showNotice('无法读取连接链接，请在服务连接中重新扫码。'),
          );
    }
    unawaited(_initialize());
    // This check is independent of backend availability and account login.
    unawaited(widget.updates?.checkOnStartup());
  }

  Future<void> _initialize() async {
    await widget.backend.ensureReady();
    if (!mounted) return;
    if (!Platform.isAndroid) widget.appState.showNotice(widget.backend.message);
    if (widget.backend.status == BackendStatus.ready) {
      await _activateReadyBackend();
    } else if (!Platform.isAndroid) {
      widget.appState.selectSection(AppSection.settings);
    }
    if (!mounted) return;
    _initializing = false;
    if (widget.backend.status == BackendStatus.ready) {
      await _activateReadyBackend();
    }
    if (!mounted) return;
    await _synchronizeWorkspace();
    _openPendingConnectionLink();
  }

  void _receiveConnectionLink(Uri uri) {
    try {
      _pendingConnectionLink = BackendConnectionLink.parse(uri.toString());
      _openPendingConnectionLink();
    } on FormatException {
      widget.appState.showNotice('连接链接无效，请扫描 PC 设置中的二维码。');
    }
  }

  void _openPendingConnectionLink() {
    if (!mounted ||
        _initializing ||
        _activationEpochInProgress != 0 ||
        _showingConnectionLink ||
        _pendingConnectionLink == null) {
      return;
    }
    _showingConnectionLink = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = _navigatorKey.currentState?.overlay?.context;
      if (!mounted || context == null) {
        _showingConnectionLink = false;
        return;
      }
      final link = _pendingConnectionLink;
      _pendingConnectionLink = null;
      try {
        await showMobileConnectionPage(context, connectionLink: link);
      } finally {
        _showingConnectionLink = false;
        _openPendingConnectionLink();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _handleAuthChanged() {
    if (_initializing || _activationEpochInProgress != 0) return;
    unawaited(_checkTranslationModelForCurrentUser());
    unawaited(_synchronizeWorkspace());
  }

  void _handleBackendChanged() {
    if (_initializing || widget.backend.status != BackendStatus.ready) return;
    unawaited(_activateReadyBackend());
  }

  Future<void> _activateReadyBackend() async {
    if (!mounted || widget.backend.status != BackendStatus.ready) return;
    final readyEpoch = widget.backend.readyEpoch;
    if (readyEpoch == 0 ||
        readyEpoch == _handledReadyEpoch ||
        readyEpoch == _activationEpochInProgress) {
      return;
    }
    final operation = ++_backendActivationOperation;
    _activationEpochInProgress = readyEpoch;
    try {
      await widget.auth.initializeForCurrentBackend(
        multiUser: widget.backend.multiUserEnabled,
      );
      if (!mounted ||
          operation != _backendActivationOperation ||
          widget.backend.status != BackendStatus.ready ||
          widget.backend.readyEpoch != readyEpoch) {
        return;
      }
      _handledReadyEpoch = readyEpoch;
      await _checkTranslationModelForCurrentUser();
      if (!mounted ||
          operation != _backendActivationOperation ||
          widget.backend.status != BackendStatus.ready ||
          widget.backend.readyEpoch != readyEpoch) {
        return;
      }
      await _synchronizeWorkspace();
    } catch (error) {
      if (mounted &&
          operation == _backendActivationOperation &&
          widget.backend.readyEpoch == readyEpoch) {
        _handledReadyEpoch = readyEpoch;
        widget.appState.showNotice('账号状态恢复失败：$error');
        if (!Platform.isAndroid) {
          widget.appState.selectSection(AppSection.settings);
        }
      }
    } finally {
      if (_activationEpochInProgress == readyEpoch) {
        _activationEpochInProgress = 0;
        _openPendingConnectionLink();
      }
    }
  }

  Future<void> _checkTranslationModelForCurrentUser() async {
    if (!widget.auth.canAccessWorkspace ||
        widget.backend.status != BackendStatus.ready ||
        widget.backend.capabilities['translationModelCheck'] != true ||
        widget.backend.translationModelCheckInProgress ||
        widget.backend.translationModelCheck != null) {
      return;
    }
    await widget.backend.checkTranslationModel();
  }

  Future<void> _synchronizeWorkspace() async {
    if (!mounted) return;
    final identity = widget.auth.workspaceIdentity;
    if (identity == _activeWorkspaceIdentity) {
      if (identity == null && !Platform.isAndroid) {
        widget.appState.selectSection(AppSection.settings);
      }
      return;
    }
    _activeWorkspaceIdentity = identity;
    final generation = ++_workspaceGeneration;
    _resetWorkspaceState();
    _returnToWorkspaceRoot();
    if (identity == null) {
      if (Platform.isAndroid) {
        widget.appState.selectSection(AppSection.library);
      } else {
        widget.appState.selectSection(AppSection.settings);
      }
      return;
    }
    if (Platform.isAndroid) widget.appState.selectSection(AppSection.library);
    await Future.wait<void>(<Future<void>>[
      widget.library.load(),
      widget.sources.load(),
      widget.tasks.load(),
      widget.settings.load(),
    ]);
    if (!mounted || generation != _workspaceGeneration) return;
  }

  void _resetWorkspaceState() {
    widget.library.resetForBackendSwitch();
    widget.sources.resetForBackendSwitch();
    widget.tasks.resetForBackendSwitch();
    widget.settings.resetForBackendSwitch();
    widget.mangaTranslation.resetForBackendSwitch();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  void _returnToWorkspaceRoot() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = _navigatorKey.currentState;
      if (navigator != null) navigator.popUntil((route) => route.isFirst);
      // Fluent dialogs can target the outer app while Android pages use the
      // mobile navigator. Clear both when the active account/backend changes.
      _rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    });
  }

  Widget _buildPlatformHome() {
    if (Platform.isAndroid) {
      return MobileQingJuanApp(navigatorKey: _navigatorKey);
    }
    return const AppShell();
  }

  @override
  void dispose() {
    unawaited(_connectionLinkSubscription?.cancel());
    _backendActivationOperation += 1;
    _workspaceGeneration += 1;
    widget.auth.removeListener(_handleAuthChanged);
    widget.backend.removeListener(_handleBackendChanged);
    widget.library.dispose();
    widget.sources.dispose();
    widget.tasks.dispose();
    widget.settings.dispose();
    widget.mangaTranslation.dispose();
    widget.updates?.dispose();
    widget.auth.dispose();
    unawaited(widget.backend.dispose());
    widget.api.close();
    widget.appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      appState: widget.appState,
      api: widget.api,
      backend: widget.backend,
      auth: widget.auth,
      library: widget.library,
      sources: widget.sources,
      tasks: widget.tasks,
      settings: widget.settings,
      mangaTranslation: widget.mangaTranslation,
      updates: widget.updates,
      child: AnimatedBuilder(
        animation: widget.appState.themeModeListenable,
        builder: (context, _) {
          return FluentApp(
            navigatorKey:
                Platform.isAndroid ? _rootNavigatorKey : _navigatorKey,
            debugShowCheckedModeBanner: false,
            title: '青卷',
            themeMode: widget.appState.themeModeListenable.value,
            theme: buildQingJuanTheme(
              Brightness.light,
              platform: defaultTargetPlatform,
            ),
            darkTheme: buildQingJuanTheme(
              Brightness.dark,
              platform: defaultTargetPlatform,
            ),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en')],
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              GlobalWidgetsLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (context, child) => UiPlatformScope(
              platform: defaultTargetPlatform,
              child: DesktopWindowFrame(
                child: Column(children: <Widget>[
                  if (widget.updates case final updates?)
                    AppUpdateBanner(
                        controller: updates,
                        onOpenSettings: () =>
                            widget.appState.selectSection(AppSection.settings)),
                  Expanded(child: child ?? const SizedBox.shrink()),
                ]),
              ),
            ),
            home: _buildPlatformHome(),
          );
        },
      ),
    );
  }
}
