import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../core/backend/backend_connection_manager.dart';
import '../../core/backend/backend_url_validator.dart';
import '../../shared/mobile_sheet.dart';
import '../../shared/page_frame.dart';
import '../../shared/responsive.dart';
import '../audiobook/tts_voice_service.dart';
import '../audiobook/audiobook_resume_entry.dart';
import '../auth/widgets/auth_account_card.dart';
import '../backups/backups_dialog.dart';
import 'widgets/backend_connection_card.dart';
import 'widgets/backend_share_card.dart';
import 'widgets/app_update_card.dart';
import 'widgets/mobile_my_dashboard.dart';
import 'widgets/desktop_settings_workspace.dart';
import 'widgets/settings_section_card.dart';
import 'widgets/theme_settings_card.dart';
import 'widgets/translation_model_card.dart';
import 'widgets/tts_voice_settings_card.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({this.voiceService, super.key});

  final TtsVoiceService? voiceService;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _backendController = TextEditingController();
  final _backendTokenController = TextEditingController();
  BackendConnectionMode _connectionMode = BackendConnectionMode.remote;
  bool _savingConnection = false;
  bool _modelChecking = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final scope = AppScope.of(context);
    _backendController.text = scope.appState.remoteBackendUrl;
    _backendTokenController.text = scope.appState.remoteBackendToken;
    _connectionMode = scope.appState.connectionMode;
  }

  Future<void> _save() async {
    final scope = AppScope.of(context);
    setState(() => _savingConnection = true);
    try {
      final backendUrl = _backendController.text.trim();
      final backendToken = _backendTokenController.text.trim();
      final connectionChanged = scope.appState.connectionMode !=
              _connectionMode ||
          (_connectionMode == BackendConnectionMode.remote &&
              (scope.appState.remoteBackendUrl.replaceAll(RegExp(r'/+$'), '') !=
                      backendUrl.replaceAll(RegExp(r'/+$'), '') ||
                  scope.appState.remoteBackendToken != backendToken));
      if (_connectionMode == BackendConnectionMode.remote) {
        validateBackendUrl(backendUrl);
        if (backendToken.isEmpty) {
          throw StateError('Linux 后端必须填写连接 Token');
        }
        await scope.backend.testRemoteConnection(
          baseUrl: backendUrl,
          token: backendToken,
        );
      }
      if (connectionChanged) {
        await scope.appState.applyBackendConnection(
          mode: _connectionMode,
          remoteUrl: backendUrl,
          remoteToken: backendToken,
        );
        await scope.auth.clearForBackendSwitch();
      }
      await scope.backend.ensureReady();
      if (scope.backend.status != BackendStatus.ready) {
        throw StateError(scope.backend.message);
      }
      await scope.auth.initializeForCurrentBackend(
        multiUser: scope.backend.multiUserEnabled,
      );
      if (scope.auth.canAccessWorkspace &&
          scope.backend.capabilities['translationModelCheck'] == true &&
          !scope.backend.translationModelCheckInProgress) {
        await scope.backend.checkTranslationModel();
      }
      scope.appState.clearNotice();
      if (mounted) {
        final modelReady =
            scope.backend.translationModelCheck?.available == true;
        displayInfoBar(
          context,
          builder: (_, __) => InfoBar(
            title: Text(modelReady ? '连接与模型自检已完成' : '连接已保存'),
            content: Text(scope.backend.message),
            severity:
                modelReady ? InfoBarSeverity.success : InfoBarSeverity.warning,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        displayInfoBar(
          context,
          builder: (_, __) => InfoBar(
            title: const Text('保存失败'),
            content: Text('$error'),
            severity: InfoBarSeverity.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingConnection = false);
    }
  }

  @override
  void dispose() {
    _backendController.dispose();
    _backendTokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final settings = scope.settings;
    final compact = usesMobileUi(context);
    return AnimatedBuilder(
      animation: Listenable.merge(
        <Listenable>[
          scope.appState,
          scope.auth,
          scope.library,
          scope.tasks,
          settings,
          scope.backend,
        ],
      ),
      builder: (context, _) => PageFrame(
        title: compact ? '我的' : '设置',
        subtitle: '管理服务连接、阅读偏好与应用数据。',
        scrollable: compact,
        maxContentWidth: compact ? null : 1440,
        compactHeader: ReadingPageHeader(
          title: '我的',
          subtitle: scope.auth.canAccessWorkspace ? '你的账户与阅读空间' : '登录后使用独立书架',
          actions: <Widget>[
            Tooltip(
              message: '外观主题',
              child: IconButton(
                key: const ValueKey('settings-theme-button'),
                icon: const Icon(
                  FluentIcons.brightness,
                  semanticLabel: '外观主题',
                ),
                onPressed: () => unawaited(_openThemeSettings(scope)),
              ),
            ),
            const SizedBox(width: 7),
            Tooltip(
              message: '关于青卷',
              child: IconButton(
                key: const ValueKey('settings-about-button'),
                icon: const Icon(
                  FluentIcons.info,
                  semanticLabel: '关于青卷',
                ),
                onPressed: () => scope.appState.selectSection(AppSection.about),
              ),
            ),
            const SizedBox(width: 7),
          ],
        ),
        child: compact
            ? _buildMobileDashboard(scope)
            : Expanded(child: _buildDesktopSettings(scope)),
      ),
    );
  }

  Widget _buildMobileDashboard(AppScope scope) {
    final app = scope.appState;
    final auth = scope.auth;
    final user = auth.user;
    final localMode = app.connectionMode == BackendConnectionMode.local;
    final connected = scope.backend.status == BackendStatus.ready;
    final authenticated = auth.isAuthenticated && user != null;
    final displayName = auth.isLocalAdministrator || localMode
        ? '本机管理员'
        : authenticated
            ? user.label
            : auth.isBusy
                ? '正在恢复账户'
                : '登录青卷';
    final roleLabel = auth.isLocalAdministrator || localMode
        ? '管理员'
        : authenticated
            ? user.isAdministrator
                ? '管理员'
                : '普通用户'
            : auth.isBusy
                ? '连接中'
                : '未登录';
    final profileSubtitle = auth.isLocalAdministrator || localMode
        ? 'Windows 本机后端 · 当前设备专用'
        : authenticated
            ? '@${user.username} · Linux 独立书架'
            : '注册或登录后使用独立书架与阅读进度';
    final connectionLabel = connected
        ? localMode
            ? '本机已连接'
            : '服务器已连接'
        : '后端待连接';
    final backendLabel = connected
        ? localMode
            ? 'Windows 本机后端'
            : 'Linux 服务器已连接'
        : '检查服务器连接';
    final themeLabel = switch (app.themeMode) {
      AppThemeMode.system => '跟随系统外观',
      AppThemeMode.light => '浅色外观',
      AppThemeMode.dark => '深色外观',
    };
    final translationLabel =
        scope.backend.translationModelCheck?.available == true
            ? '模型可用'
            : scope.settings.value.translationModel.enabled
                ? '已配置，等待检测'
                : localMode
                    ? '尚未启用'
                    : '由服务器统一管理';
    final completedTaskCount =
        scope.tasks.tasks.where((task) => task.status == 'completed').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MobileMyDashboard(
          displayName: displayName,
          profileSubtitle: profileSubtitle,
          roleLabel: roleLabel,
          avatarText: _firstDisplayCharacter(displayName),
          connectionLabel: connectionLabel,
          connected: connected,
          canAccessWorkspace: auth.canAccessWorkspace,
          bookCount: scope.library.books.length,
          activeTaskCount: scope.tasks.activeCount,
          completedTaskCount: completedTaskCount,
          backendLabel: backendLabel,
          themeLabel: themeLabel,
          voiceLabel: app.ttsVoice?.name ?? '跟随系统声音',
          translationLabel: translationLabel,
          inlineAccount: !auth.canAccessWorkspace && !localMode
              ? AuthAccountCard(
                  auth: auth,
                  backend: scope.backend,
                  isLocalMode: false,
                  backendUrl: app.backendUrl,
                  backendRevision: app.backendConnectionRevision,
                )
              : null,
          onOpenAccount: () => unawaited(_openAccountSettings(scope)),
          onOpenBackend: () => unawaited(_openBackendSettings(scope)),
          onOpenTheme: () => unawaited(_openThemeSettings(scope)),
          onOpenVoice: () => unawaited(_openVoiceSettings(scope)),
          onOpenTranslation: () => unawaited(_openTranslationSettings(scope)),
          onOpenTasks: () => app.selectSection(AppSection.tasks),
          onOpenPlugins: app.clientPluginManagementAvailable
              ? () => app.selectSection(AppSection.plugins)
              : null,
          onOpenAbout: () => app.selectSection(AppSection.about),
        ),
        if (scope.updates case final updates?) ...<Widget>[
          const SizedBox(height: 16),
          AppUpdateCard(controller: updates),
        ],
        if (scope.settings.error case final error?) ...<Widget>[
          const SizedBox(height: 16),
          InfoBar(
            title: const Text('设置服务不可用'),
            content: Text(error),
            severity: InfoBarSeverity.warning,
          ),
        ],
      ],
    );
  }

  Widget _buildDesktopSettings(AppScope scope) {
    final settings = scope.settings;
    final localMode =
        scope.appState.connectionMode == BackendConnectionMode.local;
    return DesktopSettingsWorkspace(sections: [
      DesktopSettingsSection(
        category: SettingsCategory.connection,
        title: '服务连接',
        description: '选择当前服务，或将连接分享给其他设备。',
        icon: FluentIcons.plug_connected,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          BackendConnectionCard(
            backend: scope.backend,
            activeMode: scope.appState.connectionMode,
            draftMode: _connectionMode,
            localBackendSupported: scope.appState.localBackendSupported,
            backendUrlController: _backendController,
            backendTokenController: _backendTokenController,
            onModeChanged: (mode) => setState(() => _connectionMode = mode),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton(
              key: const ValueKey('save-backend-connection'),
              onPressed: _savingConnection || settings.saving ? null : _save,
              child: Text(_savingConnection ? '正在保存' : '保存连接'),
            ),
          ),
          const SizedBox(height: 24),
          const BackendShareCard(),
        ]),
      ),
      DesktopSettingsSection(
        category: SettingsCategory.account,
        title: '账户管理',
        description: '查看当前账户，管理登录状态与个人信息。',
        icon: FluentIcons.contact,
        child: AuthAccountCard(
          auth: scope.auth,
          backend: scope.backend,
          isLocalMode: localMode,
          backendUrl: scope.appState.backendUrl,
          backendRevision: scope.appState.backendConnectionRevision,
        ),
      ),
      DesktopSettingsSection(
        category: SettingsCategory.appearance,
        title: '外观与听书',
        description: '设置界面主题，选择适合你的听书声音。',
        icon: FluentIcons.color,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ThemeSettingsCard(
            themeMode: scope.appState.themeMode,
            onChanged: (mode) => unawaited(scope.appState.setThemeMode(mode)),
          ),
          const SizedBox(height: 24),
          TtsVoiceSettingsCard(
            appState: scope.appState,
            compact: false,
            voiceService: widget.voiceService,
          ),
          if (scope.audiobook case final audiobook?) ...[
            const SizedBox(height: 24),
            AudiobookResumeEntry(
              coordinator: audiobook,
              voice: scope.appState.ttsVoice,
              onStyleChanged: scope.appState.setTtsSpeechStyle,
            ),
          ],
        ]),
      ),
      DesktopSettingsSection(
        category: SettingsCategory.translation,
        title: '翻译服务',
        description: localMode ? '配置翻译模型，检查服务是否可用。' : '查看服务器的翻译配置与模型状态。',
        icon: FluentIcons.translate,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TranslationModelCard(
            backend: scope.backend,
            settings: settings,
            localConfiguration: localMode,
            checking: _modelChecking,
            onCheck: (force) => _checkTranslationModel(scope, force: force),
          ),
          if (settings.error case final error?) ...[
            const SizedBox(height: 16),
            InfoBar(
              title: const Text('设置服务不可用'),
              content: Text(error),
              severity: InfoBarSeverity.warning,
            ),
          ],
        ]),
      ),
      DesktopSettingsSection(
        category: SettingsCategory.application,
        title: '数据与应用',
        description: localMode ? '管理本机数据，查看应用更新与版本信息。' : '查看应用更新、版本信息与项目说明。',
        icon: FluentIcons.database,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (scope.appState.localBackendSupported &&
              localMode &&
              scope.backend.capabilities['backups'] == true) ...[
            SettingsSectionCard(
              icon: FluentIcons.database,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('备份与恢复',
                        style: FluentTheme.of(context).typography.subtitle),
                    const SizedBox(height: 8),
                    const Text('完整备份书库、阅读记录、任务、设置和插件，也可从已有备份恢复。'),
                    const SizedBox(height: 16),
                    Button(
                      key: const ValueKey('settings-backups-button'),
                      onPressed: scope.backend.status == BackendStatus.ready
                          ? () => unawaited(_openBackups(scope))
                          : null,
                      child: const Text('管理备份'),
                    ),
                  ]),
            ),
            const SizedBox(height: 24),
          ],
          if (scope.updates case final updates?) ...[
            AppUpdateCard(controller: updates),
            const SizedBox(height: 24),
          ],
          SettingsSectionCard(
            icon: FluentIcons.info,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('关于青卷', style: FluentTheme.of(context).typography.subtitle),
              const SizedBox(height: 8),
              const Text('版本信息、项目许可与开发说明。'),
              const SizedBox(height: 16),
              Button(
                key: const ValueKey('settings-about-card-button'),
                onPressed: () => scope.appState.selectSection(AppSection.about),
                child: const Text('查看版本信息'),
              ),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Future<void> _openBackups(AppScope scope) => showDialog<void>(
        context: context,
        builder: (_) => BackupsDialog(
          api: scope.api,
          appState: scope.appState,
          backend: scope.backend,
          onRestored: () async {
            scope.library.resetForBackendSwitch();
            scope.tasks.resetForBackendSwitch();
            scope.sources.resetForBackendSwitch();
            scope.settings.resetForBackendSwitch();
            scope.mangaTranslation?.resetForBackendSwitch();
            scope.library.imports.enabled =
                scope.backend.capabilities['linkJobHistory'] == true;
            await Future.wait<void>([
              scope.library.load(),
              scope.tasks.load(),
              scope.sources.load(),
              scope.settings.load(),
            ]);
            if (scope.library.error != null ||
                scope.tasks.error != null ||
                scope.sources.error != null ||
                scope.settings.error != null) {
              throw StateError('恢复后的客户端数据刷新未完成');
            }
          },
        ),
      );

  Future<void> _openAccountSettings(AppScope scope) => _showSettingsSheet(
        title: '账号管理',
        subtitle: '登录、注册或查看当前账户',
        animation: Listenable.merge(
          <Listenable>[scope.appState, scope.auth, scope.backend],
        ),
        childBuilder: () => AuthAccountCard(
          auth: scope.auth,
          backend: scope.backend,
          isLocalMode:
              scope.appState.connectionMode == BackendConnectionMode.local,
          backendUrl: scope.appState.backendUrl,
          backendRevision: scope.appState.backendConnectionRevision,
        ),
      );

  Future<void> _openThemeSettings(AppScope scope) => _showSettingsSheet(
        title: '外观主题',
        subtitle: '选择青卷在当前设备上的显示方式',
        animation: scope.appState,
        childBuilder: () => ThemeSettingsCard(
          themeMode: scope.appState.themeMode,
          onChanged: (mode) => unawaited(scope.appState.setThemeMode(mode)),
        ),
      );

  Future<void> _openVoiceSettings(AppScope scope) => _showSettingsSheet(
        title: '听书声音',
        subtitle: '选择系统声音并试听',
        animation: scope.appState,
        childBuilder: () => TtsVoiceSettingsCard(
          appState: scope.appState,
          compact: true,
          voiceService: widget.voiceService,
        ),
      );

  Future<void> _openTranslationSettings(AppScope scope) {
    var checking = false;
    return showMobileSheet<void>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => AnimatedBuilder(
          animation: Listenable.merge(
            <Listenable>[scope.settings, scope.backend],
          ),
          builder: (context, _) => MobileSheet(
            title: '翻译服务',
            subtitle: '查看模型配置与连接状态',
            onClose: () => Navigator.of(sheetContext).pop(),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: TranslationModelCard(
                backend: scope.backend,
                settings: scope.settings,
                localConfiguration: scope.appState.connectionMode ==
                    BackendConnectionMode.local,
                checking: checking,
                onCheck: (force) async {
                  setSheetState(() => checking = true);
                  await _checkTranslationModel(scope, force: force);
                  if (sheetContext.mounted) {
                    setSheetState(() => checking = false);
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openBackendSettings(AppScope scope) {
    var draftMode = _connectionMode;
    var saving = false;
    return showMobileSheet<void>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => AnimatedBuilder(
          animation: Listenable.merge(
            <Listenable>[scope.appState, scope.settings, scope.backend],
          ),
          builder: (context, _) => MobileSheet(
            title: '后端连接',
            subtitle: '选择本机或 Linux 服务器',
            onClose: () => Navigator.of(sheetContext).pop(),
            actions: <Widget>[
              FilledButton(
                key: const ValueKey('save-backend-connection'),
                onPressed: saving || scope.settings.saving
                    ? null
                    : () async {
                        setSheetState(() => saving = true);
                        _connectionMode = draftMode;
                        await _save();
                        if (sheetContext.mounted) {
                          setSheetState(() => saving = false);
                        }
                      },
                child: Text(saving ? '正在保存' : '保存连接'),
              ),
            ],
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: BackendConnectionCard(
                backend: scope.backend,
                activeMode: scope.appState.connectionMode,
                draftMode: draftMode,
                localBackendSupported: scope.appState.localBackendSupported,
                backendUrlController: _backendController,
                backendTokenController: _backendTokenController,
                onModeChanged: (mode) {
                  draftMode = mode;
                  _connectionMode = mode;
                  setSheetState(() {});
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSettingsSheet({
    required String title,
    required String subtitle,
    required Listenable animation,
    required Widget Function() childBuilder,
  }) {
    return showMobileSheet<void>(
      context: context,
      builder: (sheetContext) => AnimatedBuilder(
        animation: animation,
        builder: (context, _) => MobileSheet(
          title: title,
          subtitle: subtitle,
          onClose: () => Navigator.of(sheetContext).pop(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: childBuilder(),
          ),
        ),
      ),
    );
  }

  String _firstDisplayCharacter(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '青';
    return String.fromCharCode(trimmed.runes.first);
  }

  Future<void> _checkTranslationModel(
    AppScope scope, {
    bool force = false,
  }) async {
    setState(() => _modelChecking = true);
    final result = await scope.backend.checkTranslationModel(force: force);
    if (!mounted) return;
    setState(() => _modelChecking = false);
    displayInfoBar(
      context,
      builder: (_, __) => InfoBar(
        title: Text(result.available ? '模型自检通过' : '模型自检未通过'),
        content: Text(result.message),
        severity: result.available
            ? InfoBarSeverity.success
            : InfoBarSeverity.warning,
      ),
    );
  }
}
