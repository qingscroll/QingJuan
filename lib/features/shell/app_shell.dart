import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../shared/app_surface.dart';
import '../../shared/feedback_widgets.dart';
import '../../shared/motion.dart';
import '../../shared/page_frame.dart';
import '../../shared/responsive.dart';
import '../about/about_page.dart';
import '../library/library_page.dart';
import '../discovery/discovery_page.dart';
import '../manga_translation/manga_translation_page.dart';
import '../search/search_page.dart';
import '../settings/settings_page.dart';
import '../sources/plugins_page.dart';
import '../sources/sources_page.dart';
import '../tasks/tasks_page.dart';
import 'desktop_shell.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  static const _mobileSections = <AppSection>[
    AppSection.library,
    AppSection.search,
    AppSection.sources,
    AppSection.tasks,
    AppSection.settings,
  ];

  static const _desktopLocalSections = <AppSection>[
    AppSection.library,
    AppSection.discovery,
    AppSection.search,
    AppSection.sources,
    AppSection.plugins,
    AppSection.tasks,
    AppSection.translator,
    AppSection.settings,
  ];

  static const _desktopRemoteSections = <AppSection>[
    AppSection.library,
    AppSection.discovery,
    AppSection.search,
    AppSection.sources,
    AppSection.tasks,
    AppSection.translator,
    AppSection.settings,
  ];

  static const _backendSections = <AppSection>{
    AppSection.library,
    AppSection.discovery,
    AppSection.search,
    AppSection.sources,
    AppSection.plugins,
    AppSection.tasks,
    AppSection.translator,
  };

  Widget _page(AppScope scope, AppSection section) {
    final app = scope.appState;
    if (section == AppSection.plugins && !app.clientPluginManagementAvailable) {
      return const SettingsPage();
    }
    if (!app.hasBackendConnection && _backendSections.contains(section)) {
      return _BackendRequiredPage(
        section: section,
        label: _label(section),
        icon: _icon(section),
        onOpenSettings: () => _selectSection(app, AppSection.settings),
      );
    }
    if (_backendSections.contains(section) &&
        scope.backend.multiUserEnabled &&
        !scope.auth.canAccessWorkspace) {
      return _AuthenticationRequiredPage(
        section: section,
        label: _label(section),
        icon: _icon(section),
        onOpenAccount: () => _selectSection(app, AppSection.settings),
      );
    }
    return switch (section) {
      AppSection.library => const LibraryPage(),
      AppSection.discovery => DiscoveryPage(
          key: ValueKey(
              'discovery-${app.backendConnectionRevision}-${scope.auth.workspaceIdentity}'),
        ),
      AppSection.search => const SearchPage(),
      AppSection.sources => const SourcesPage(),
      AppSection.plugins => PluginsPage(
          onBack: () => _selectSection(app, AppSection.settings),
        ),
      AppSection.tasks => const TasksPage(),
      AppSection.translator => const MangaTranslationPage(),
      AppSection.settings => const SettingsPage(),
      AppSection.about => AboutPage(
          onBack: () => _selectSection(app, AppSection.settings),
        ),
    };
  }

  String _label(AppSection section) => switch (section) {
        AppSection.library => '书架',
        AppSection.discovery => '推荐',
        AppSection.search => '搜索',
        AppSection.sources => '书源管理',
        AppSection.plugins => '插件配置',
        AppSection.tasks => '任务',
        AppSection.translator => '漫画翻译',
        AppSection.settings => '设置',
        AppSection.about => '关于',
      };

  String _mobileLabel(AppSection section) => switch (section) {
        AppSection.library => '书架',
        AppSection.discovery => '推荐',
        AppSection.search => '搜索',
        AppSection.sources => '书源',
        AppSection.plugins => '插件',
        AppSection.tasks => '任务',
        AppSection.translator => '漫画翻译',
        AppSection.settings => '我的',
        AppSection.about => '关于',
      };

  IconData _icon(AppSection section) => switch (section) {
        AppSection.library => FluentIcons.library,
        AppSection.discovery => FluentIcons.favorite_star,
        AppSection.search => FluentIcons.search,
        AppSection.sources => FluentIcons.database,
        AppSection.plugins => FluentIcons.plug_connected,
        AppSection.tasks => FluentIcons.history,
        AppSection.translator => FluentIcons.translate,
        AppSection.settings => FluentIcons.settings,
        AppSection.about => FluentIcons.info,
      };

  IconData _mobileIcon(AppSection section) => switch (section) {
        AppSection.settings => FluentIcons.contact,
        _ => _icon(section),
      };

  void _selectSection(AppState app, AppSection section) {
    app.clearNotice();
    app.selectSection(section);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final app = scope.appState;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[app, scope.auth]),
      builder: (context, _) {
        final theme = FluentTheme.of(context);
        final dark = theme.brightness == Brightness.dark;
        final mobile = usesMobileUi(context);
        final allDesktopSections = app.clientPluginManagementAvailable
            ? _desktopLocalSections
            : _desktopRemoteSections;
        final desktopSections = <AppSection>[
          for (final section in allDesktopSections)
            if (section != AppSection.translator ||
                UiPlatformScope.of(context) == TargetPlatform.windows)
              section,
        ];
        final content = mobile
            ? _MobileShell(
                section: app.section,
                page: _page(scope, app.section),
                primarySections: _mobileSections,
                labelFor: _mobileLabel,
                iconFor: _mobileIcon,
                onSelected: (section) => _selectSection(app, section),
              )
            : DesktopShell(
                section: app.section,
                pageFor: (section) => _page(scope, section),
                primarySections: desktopSections,
                labelFor: _label,
                iconFor: _icon,
                onSelected: (section) => _selectSection(app, section),
              );
        if (!mobile) {
          return ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: content,
          );
        }
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: const Color(0x00000000),
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            systemNavigationBarColor: const Color(0x00000000),
            systemNavigationBarIconBrightness:
                dark ? Brightness.light : Brightness.dark,
            systemNavigationBarDividerColor: const Color(0x00000000),
          ),
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: SafeArea(child: content),
          ),
        );
      },
    );
  }
}

class _AuthenticationRequiredPage extends StatelessWidget {
  const _AuthenticationRequiredPage({
    required this.section,
    required this.label,
    required this.icon,
    required this.onOpenAccount,
  });

  final AppSection section;
  final String label;
  final IconData icon;
  final VoidCallback onOpenAccount;

  @override
  Widget build(BuildContext context) {
    final visibleLabel = usesMobileUi(context)
        ? switch (section) {
            AppSection.sources => '书源',
            _ => label,
          }
        : label;
    return PageFrame(
      key: ValueKey<String>('auth-required-${section.name}'),
      title: visibleLabel,
      subtitle: '登录后加载你的个人工作区。',
      child: EmptyView(
        icon: icon,
        title: '请先登录 Linux 后端',
        message: '每个用户拥有独立书架、阅读进度和任务记录。',
        action: FilledButton(
          key: const ValueKey('auth-required-open-account'),
          onPressed: onOpenAccount,
          child: const Text('前往“我的”登录'),
        ),
      ),
    );
  }
}

class _BackendRequiredPage extends StatelessWidget {
  const _BackendRequiredPage({
    required this.section,
    required this.label,
    required this.icon,
    required this.onOpenSettings,
  });

  final AppSection section;
  final String label;
  final IconData icon;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final visibleLabel = usesMobileUi(context)
        ? switch (section) {
            AppSection.sources => '书源',
            AppSection.plugins => '站点插件',
            AppSection.settings => '我的',
            _ => label,
          }
        : label;
    return PageFrame(
      key: ValueKey<String>('backend-required-${section.name}'),
      title: visibleLabel,
      subtitle: '此区域的数据由 Linux 后端提供。',
      child: EmptyView(
        icon: icon,
        title: '尚未连接 Linux 后端',
        message: '导航已经可用。连接服务器后，青卷会在这里加载最新数据。',
        action: FilledButton(
          key: const ValueKey('backend-required-open-settings'),
          onPressed: onOpenSettings,
          child: const Text('前往设置'),
        ),
      ),
    );
  }
}

class _MobileShell extends StatelessWidget {
  const _MobileShell({
    required this.section,
    required this.page,
    required this.primarySections,
    required this.labelFor,
    required this.iconFor,
    required this.onSelected,
  });

  final AppSection section;
  final Widget page;
  final List<AppSection> primarySections;
  final String Function(AppSection) labelFor;
  final IconData Function(AppSection) iconFor;
  final ValueChanged<AppSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return PopScope(
      canPop: section != AppSection.about && section != AppSection.plugins,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) onSelected(AppSection.settings);
      },
      child: ColoredBox(
        color: theme.scaffoldBackgroundColor,
        child: Column(
          children: <Widget>[
            Expanded(
              child: QjPageSwitcher(
                pageKey: section,
                child: page,
              ),
            ),
            _MobileNavigationBar(
              section:
                  section == AppSection.about || section == AppSection.plugins
                      ? AppSection.settings
                      : section,
              sections: primarySections,
              labelFor: labelFor,
              iconFor: iconFor,
              onSelected: onSelected,
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileNavigationBar extends StatelessWidget {
  const _MobileNavigationBar({
    required this.section,
    required this.sections,
    required this.labelFor,
    required this.iconFor,
    required this.onSelected,
  });

  final AppSection section;
  final List<AppSection> sections;
  final String Function(AppSection) labelFor;
  final IconData Function(AppSection) iconFor;
  final ValueChanged<AppSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final textScaler = TextScaler.linear(
      MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.2),
    );
    return SizedBox(
      key: const ValueKey('mobile-bottom-navigation'),
      height: 82,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: AppGlassSurface(
          key: const ValueKey('mobile-bottom-navigation-glass'),
          borderRadius: 22,
          blurSigma: 16,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: Row(
              children: <Widget>[
                for (final item in sections)
                  Expanded(
                    child: Semantics(
                      selected: item == section,
                      button: true,
                      label: labelFor(item),
                      child: Button(
                        key: ValueKey<String>(
                          'mobile-navigation-${item.name}',
                        ),
                        style: ButtonStyle(
                          padding: const WidgetStatePropertyAll(
                            EdgeInsets.zero,
                          ),
                          shape: WidgetStatePropertyAll(
                            RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          backgroundColor: const WidgetStatePropertyAll(
                            Color(0x00000000),
                          ),
                        ),
                        onPressed: () => onSelected(item),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            AnimatedScale(
                              duration: QjMotion.duration(
                                context,
                                QjMotionSpeed.fast,
                              ),
                              curve: QjMotion.enterCurve,
                              scale: item == section ? 1.06 : 1,
                              child: AnimatedContainer(
                                duration: QjMotion.duration(
                                  context,
                                  QjMotionSpeed.fast,
                                ),
                                curve: QjMotion.enterCurve,
                                width: 42,
                                height: 27,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: item == section
                                      ? theme.accentColor.withAlpha(
                                          dark ? 62 : 28,
                                        )
                                      : const Color(0x00000000),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  iconFor(item),
                                  size: 19,
                                  color: item == section
                                      ? theme.accentColor
                                      : theme.resources.textFillColorSecondary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              labelFor(item),
                              maxLines: 1,
                              style: theme.typography.caption?.copyWith(
                                fontSize: 10.5,
                                fontWeight: item == section
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: item == section
                                    ? theme.accentColor
                                    : theme.resources.textFillColorSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
