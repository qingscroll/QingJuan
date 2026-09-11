import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import '../app/app_scope.dart';
import '../app/app_state.dart';
import '../core/backend/backend_connection_manager.dart';
import '../core/backend/backend_connection_link.dart';
import '../core/backend/backend_url_validator.dart';
import '../features/audiobook/tts_voice_service.dart';
import '../features/settings/widgets/app_update_card.dart';
import 'mobile_action_button.dart';
import 'mobile_connection_scanner.dart';
import 'mobile_auth_page.dart';
import 'mobile_page.dart';
import 'mobile_settings_route.dart';
import 'mobile_voice_page.dart';
import 'mobile_widgets.dart';

part 'mobile_my_panels.dart';

Future<void> showMobileConnectionPage(BuildContext context,
    {BackendConnectionLink? connectionLink}) async {
  await showMobileSettingsPage<void>(
      context: context,
      title: '服务连接',
      child: _BackendSettingsPanel(connectionLink: connectionLink));
}

class MobileMyPage extends StatelessWidget {
  const MobileMyPage({this.voiceService, super.key});
  final TtsVoiceService? voiceService;
  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        scope.appState,
        scope.auth,
        scope.backend,
        scope.sources,
        scope.settings
      ]),
      builder: (context, _) {
        final app = scope.appState;
        final backend = scope.backend;
        final connected = backend.status == BackendStatus.ready;
        final auth = scope.auth;
        final user = auth.user;
        final signedIn = auth.isAuthenticated && user != null;
        final name = signedIn
            ? user.label
            : auth.isBusy
                ? '正在恢复账号'
                : auth.isLocalAdministrator
                    ? 'PC 共享书库'
                    : '登录青卷';
        final subtitle = signedIn
            ? '@${user.username} · ${user.isAdministrator ? '管理员' : '读者'}'
            : auth.isLocalAdministrator
                ? '与 PC 共用书库、任务和阅读进度'
                : connected
                    ? '登录后同步你的书库与阅读进度'
                    : '连接服务，开始你的阅读';
        final theme = MiuixTheme.of(context);
        return MobilePage(
            title: '我的',
            child: ListView(
              key: const PageStorageKey<String>('mobile-my-scroll'),
              padding:
                  EdgeInsets.only(bottom: mobileNavigationClearance(context)),
              children: <Widget>[
                MobilePressable(
                    key: const ValueKey('mobile-my-profile'),
                    onPressed: () => connected && !auth.isLocalAdministrator
                        ? showMobileAccountPage(context)
                        : showMobileConnectionPage(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(children: <Widget>[
                        CircleAvatar(
                            radius: 26,
                            backgroundColor: theme.colors.primaryContainer,
                            foregroundColor: theme.colors.primary,
                            child: signedIn
                                ? Text(name.characters.first,
                                    style: const TextStyle(fontSize: 22))
                                : const Icon(Icons.person_outline_rounded)),
                        const SizedBox(width: 14),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                              Text(name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textStyles.title4
                                      .copyWith(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text(subtitle,
                                  style: theme.textStyles.footnote1.copyWith(
                                      color: theme.colors.onBackgroundVariant)),
                            ])),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right_rounded, size: 22),
                      ]),
                    )),
                if (!connected || auth.error != null) ...<Widget>[
                  MobileSettingsNotice(
                    title: !connected
                        ? _connectionLabel(backend.status)
                        : '账号需要重新验证',
                    message: !connected
                        ? (backend.status == BackendStatus.unconfigured
                            ? '使用管理员提供的服务地址和连接密钥，访问你的个人书库。'
                            : backend.message)
                        : auth.error!,
                    error: backend.status == BackendStatus.failed ||
                        auth.error != null,
                    action: backend.status == BackendStatus.checking
                        ? const LinearProgressIndicator()
                        : MobileActionButton(
                            icon: connected
                                ? Icons.login_rounded
                                : Icons.link_rounded,
                            onPressed: () => connected
                                ? showMobileAccountPage(context)
                                : showMobileConnectionPage(context),
                            child: Text(connected ? '重新登录' : '连接服务')),
                  ),
                  const SizedBox(height: 20),
                ],
                const _ThemeCard(),
                const SizedBox(height: 24),
                _PreferenceGroup(title: '阅读偏好', children: <Widget>[
                  _PreferenceRow(
                      key: const ValueKey('my-voice-entry'),
                      icon: Icons.headphones_outlined,
                      title: '听书声音',
                      subtitle: app.ttsVoice?.name ?? '跟随系统声音',
                      onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                              builder: (_) => MobileVoicePage(
                                  voiceService: voiceService)))),
                  _PreferenceRow(
                      key: const ValueKey('my-sources-entry'),
                      icon: Icons.layers_outlined,
                      title: '内容书源',
                      subtitle:
                          '${scope.sources.sources.where((source) => source.enabled).length} 个已启用 · ${auth.canManageServiceConfiguration ? '导入与管理' : '查看可用来源'}',
                      onPressed: () => app.selectSection(AppSection.sources)),
                ]),
                const SizedBox(height: 24),
                _PreferenceGroup(title: '账号与服务', children: <Widget>[
                  _PreferenceRow(
                      icon: Icons.person_outline_rounded,
                      title: '账号管理',
                      subtitle: signedIn ? '账号安全与退出登录' : '登录或创建账号',
                      onPressed: () => showMobileAccountPage(context)),
                  _PreferenceRow(
                      key: const ValueKey('my-backend-entry'),
                      icon: Icons.cloud_outlined,
                      title: '服务连接',
                      subtitle:
                          '${_connectionLabel(backend.status)}${connected ? ' · ${Uri.tryParse(app.backendUrl)?.host ?? ''}' : ''}',
                      onPressed: () => showMobileConnectionPage(context)),
                  _PreferenceRow(
                      key: const ValueKey('my-translation-entry'),
                      icon: Icons.translate_rounded,
                      title: '翻译服务',
                      subtitle: backend.translationModelCheckInProgress
                          ? '正在检查可用性'
                          : backend.translationModelCheck?.available == true
                              ? '可以翻译'
                              : '查看服务可用性',
                      onPressed: () => showMobileSettingsPage<void>(
                          context: context,
                          title: '翻译服务',
                          child: const _TranslationSettingsPanel())),
                  _PreferenceRow(
                      key: const ValueKey('my-about-entry'),
                      icon: Icons.info_outline_rounded,
                      title: '关于青卷',
                      subtitle: '版本与开源许可',
                      onPressed: () => app.selectSection(AppSection.about)),
                  if (scope.updates case final updates?)
                    _PreferenceRow(
                        key: const ValueKey('my-update-entry'),
                        icon: Icons.system_update_outlined,
                        title: '软件更新',
                        subtitle: '检查并下载新版本 · 启动自动检查',
                        onPressed: () => showMobileSettingsPage<void>(
                            context: context,
                            title: '软件更新',
                            child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: AppUpdateCard(controller: updates)))),
                ]),
              ],
            ));
      },
    );
  }
}

String _connectionLabel(BackendStatus status) => switch (status) {
      BackendStatus.unconfigured => '尚未连接',
      BackendStatus.checking || BackendStatus.starting => '正在验证连接',
      BackendStatus.ready => '已连接',
      BackendStatus.failed => '连接中断',
    };

class _PreferenceGroup extends StatelessWidget {
  const _PreferenceGroup({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 10),
            child: Text(title,
                style: MiuixTheme.of(context).textStyles.footnote1.copyWith(
                    color: MiuixTheme.of(context).colors.onBackgroundVariant))),
        MobileCard(
            padding: EdgeInsets.zero,
            child: Column(children: <Widget>[
              for (var index = 0; index < children.length; index++) ...<Widget>[
                if (index > 0)
                  const Padding(
                      padding: EdgeInsets.only(left: 52),
                      child: Divider(height: 1)),
                children[index],
              ],
            ])),
      ]);
}

class _PreferenceRow extends StatelessWidget {
  const _PreferenceRow(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onPressed,
      super.key});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return MobilePressable(
        onPressed: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(children: <Widget>[
              Icon(icon, size: 22, color: theme.colors.onBackgroundVariant),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                    Text(title,
                        style: theme.textStyles.body2
                            .copyWith(fontWeight: FontWeight.w500)),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textStyles.footnote1
                            .copyWith(color: theme.colors.onBackgroundVariant)),
                  ])),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: theme.colors.onBackgroundVariant),
            ])));
  }
}
