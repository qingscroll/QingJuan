import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../app/app_state.dart';
import '../app/app_theme.dart';
import '../core/backend/backend_connection_manager.dart';
import '../features/about/about_page.dart';
import '../features/sources/plugins_page.dart';
import '../shared/motion.dart';
import '../shared/mobile_palette.dart';
import 'mobile_library_page.dart';
import 'mobile_auth_page.dart';
import 'mobile_my_page.dart';
import 'mobile_page.dart';
import 'mobile_search_page.dart';
import 'mobile_sources_page.dart';
import 'mobile_state.dart';
import 'mobile_tasks_page.dart';
import 'mobile_theme.dart';
import 'mobile_tokens.dart';
import 'mobile_action_button.dart';

class MobileQingJuanApp extends StatelessWidget {
  const MobileQingJuanApp({this.navigatorKey, super.key});

  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context).appState;
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appState.themeModeListenable,
      builder: (context, mode, _) => MiuixThemeController(
        colorSchemeMode: switch (mode) {
          ThemeMode.system => MiuixColorSchemeMode.system,
          ThemeMode.light => MiuixColorSchemeMode.light,
          ThemeMode.dark => MiuixColorSchemeMode.dark,
        },
        lightColors: qjMobileLightColors(),
        darkColors: qjMobileDarkColors(),
        textStyles: qjMobileTextStyles(),
        child: Builder(
          builder: (context) {
            final theme = MiuixTheme.of(context);
            final colors = theme.colors;
            return fluent.FluentTheme(
              data: buildQingJuanTheme(
                theme.brightness,
                platform: TargetPlatform.android,
              ),
              child: MaterialApp(
                navigatorKey: navigatorKey,
                debugShowCheckedModeBanner: false,
                title: '青卷',
                theme: ThemeData(
                  useMaterial3: true,
                  brightness: theme.brightness,
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: colors.primary,
                    brightness: theme.brightness,
                    surface: colors.surfaceContainer,
                    primary: colors.primary,
                    onPrimary: colors.onPrimary,
                    primaryContainer: colors.primaryContainer,
                    onPrimaryContainer: colors.onPrimaryContainer,
                    secondary: colors.onBackgroundVariant,
                    onSecondary: colors.background,
                    secondaryContainer: colors.secondaryContainer,
                    onSecondaryContainer: colors.onSecondaryContainer,
                    onSurface: colors.onSurface,
                    onSurfaceVariant: colors.onBackgroundVariant,
                    outline: colors.outline,
                    outlineVariant: colors.dividerLine,
                    error: theme.brightness == Brightness.dark
                        ? MobilePalette.errorDark
                        : MobilePalette.error,
                  ),
                  scaffoldBackgroundColor: colors.background,
                  textTheme: TextTheme(
                    labelLarge: theme.textStyles.button.copyWith(
                      color: colors.onBackground,
                    ),
                    bodySmall: theme.textStyles.footnote1.copyWith(
                      color: colors.onBackgroundVariant,
                    ),
                    titleMedium: theme.textStyles.subtitle.copyWith(
                      color: colors.onBackground,
                    ),
                    bodyMedium: theme.textStyles.body2.copyWith(
                      color: colors.onBackground,
                    ),
                    bodyLarge: theme.textStyles.body1.copyWith(
                      color: colors.onBackground,
                    ),
                    titleLarge: theme.textStyles.title3.copyWith(
                      color: colors.onBackground,
                    ),
                  ),
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: colors.onBackground.withValues(alpha: 0.06),
                  iconButtonTheme: IconButtonThemeData(
                    style: IconButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: colors.onBackground,
                    ),
                  ),
                  filledButtonTheme: FilledButtonThemeData(
                    style: mobileActionStyle(
                        dark: theme.brightness == Brightness.dark),
                  ),
                  textButtonTheme: TextButtonThemeData(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  outlinedButtonTheme: OutlinedButtonThemeData(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  inputDecorationTheme: InputDecorationTheme(
                    filled: true,
                    fillColor: colors.surfaceContainer,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colors.outline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colors.outline),
                    ),
                  ),
                  dividerTheme: DividerThemeData(
                    color: colors.dividerLine,
                    thickness: 1,
                    space: 1,
                  ),
                  snackBarTheme: SnackBarThemeData(
                    behavior: SnackBarBehavior.floating,
                    backgroundColor: colors.onBackground,
                    contentTextStyle: TextStyle(
                      color: colors.background,
                      fontSize: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  pageTransitionsTheme: const PageTransitionsTheme(
                    builders: {
                      TargetPlatform.android: MobilePageTransitionsBuilder(),
                      TargetPlatform.iOS: MobilePageTransitionsBuilder(),
                    },
                  ),
                  dialogTheme: DialogThemeData(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
                locale: const Locale('zh', 'CN'),
                supportedLocales: const <Locale>[
                  Locale('zh', 'CN'),
                  Locale('en'),
                ],
                localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                  fluent.FluentLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: const MobileHomeShell(),
              ),
            );
          },
        ),
      ),
    );
  }
}

class MobilePageTransitionsBuilder extends PageTransitionsBuilder {
  const MobilePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      QjPageTransition(
        animation: animation,
        beginOffset: const Offset(0.12, 0),
        child: child,
      );
}

class MobileHomeShell extends StatefulWidget {
  const MobileHomeShell({super.key});

  static const primarySections = <AppSection>[
    AppSection.library,
    AppSection.search,
    AppSection.tasks,
    AppSection.settings,
  ];
  static String label(AppSection section) => switch (section) {
        AppSection.library => '书库',
        AppSection.search => '发现',
        AppSection.tasks => '任务',
        AppSection.settings => '我的',
        AppSection.sources => '书源',
        AppSection.about => '关于青卷',
        AppSection.plugins => '插件',
        AppSection.translator => '漫画翻译',
      };
  static IconData icon(AppSection section) => switch (section) {
        AppSection.library => Icons.auto_stories_outlined,
        AppSection.search => Icons.search_rounded,
        AppSection.tasks => Icons.downloading_rounded,
        _ => Icons.person_outline_rounded,
      };

  @override
  State<MobileHomeShell> createState() => _MobileHomeShellState();
}

class _MobileHomeShellState extends State<MobileHomeShell> {
  final _visited = <AppSection>{AppSection.library};
  var _bucket = PageStorageBucket();
  String? _identity;

  void _select(AppSection section) {
    FocusManager.instance.primaryFocus?.unfocus();
    final app = AppScope.of(context).appState;
    app.clearNotice();
    app.selectSection(section);
  }

  Widget _page(AppSection section) {
    final scope = AppScope.of(context);
    final app = scope.appState;
    final protected =
        section != AppSection.settings && section != AppSection.about;
    if (protected &&
        (!app.hasBackendConnection ||
            (scope.backend.multiUserEnabled &&
                !scope.auth.canAccessWorkspace))) {
      final connection = !app.hasBackendConnection;
      if (scope.auth.isBusy) return const MobileLoadingView('正在恢复登录状态…');
      return MobilePage(
        title: MobileHomeShell.label(section),
        child: MobileEmptyView(
          key: ValueKey(
            '${connection ? 'backend' : 'auth'}-required-${section.name}',
          ),
          icon: Icon(connection ? Icons.cloud_outlined : Icons.lock_outline),
          title: connection ? '连接你的阅读空间' : '登录后，继续阅读',
          message: connection
              ? '青卷将作品和进度保存在你的服务器。\n连接一次，下次自动恢复。'
              : scope.auth.error ?? '服务已连接。登录账号即可打开个人书库。',
          action: MobileActionButton(
            icon: connection ? Icons.link : Icons.login,
            child: Text(connection ? '连接服务' : '登录账号'),
            onPressed: () => connection
                ? showMobileConnectionPage(context)
                : showMobileAccountPage(context),
          ),
        ),
      );
    }
    return switch (section) {
      AppSection.library => const MobileLibraryPage(),
      AppSection.search => const MobileSearchPage(),
      AppSection.tasks => const MobileTasksPage(),
      AppSection.sources => const MobileSourcesPage(),
      AppSection.about => AboutPage(onBack: () => _select(AppSection.settings)),
      AppSection.plugins when app.clientPluginManagementAvailable =>
        PluginsPage(onBack: () => _select(AppSection.settings)),
      _ => const MobileMyPage(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([scope.appState, scope.auth, scope.backend]),
      builder: (context, _) {
        final app = scope.appState;
        final identity =
            '${app.backendConnectionRevision}:${scope.auth.workspaceIdentity}';
        if (_identity != identity) {
          _identity = identity;
          _visited.clear();
          _bucket = PageStorageBucket();
        }
        final section = app.section;
        final secondary = !MobileHomeShell.primarySections.contains(section);
        if (!secondary) _visited.add(section);
        final colors = MiuixTheme.of(context).colors;
        final dark = MiuixTheme.of(context).brightness == Brightness.dark;
        final tablet = MediaQuery.sizeOf(context).width >= MobileTokens.tablet;
        final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
        final currentIndex = MobileHomeShell.primarySections.indexOf(section);
        final navSection = secondary ? AppSection.settings : section;
        final content = PageStorage(
          bucket: _bucket,
          child: Stack(
            children: [
              // Keep visited destinations alive: text input, scroll and filters
              // survive tab changes. Scope identity destroys stale account views.
              Offstage(
                offstage: secondary,
                child: IndexedStack(
                  key: ValueKey(identity),
                  index: currentIndex < 0 ? 3 : currentIndex,
                  children: [
                    for (final item in MobileHomeShell.primarySections)
                      TickerMode(
                        enabled: item == section,
                        child: _visited.contains(item)
                            ? KeyedSubtree(
                                key: PageStorageKey(item),
                                child: _page(item),
                              )
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
              if (secondary)
                Column(
                  children: [
                    if (section != AppSection.about)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          tooltip: '返回我的',
                          onPressed: () => _select(AppSection.settings),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      ),
                    Expanded(child: _page(section)),
                  ],
                ),
            ],
          ),
        );
        return PopScope(
          canPop: section == AppSection.library,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              _select(secondary ? AppSection.settings : AppSection.library);
            }
          },
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness:
                  dark ? Brightness.light : Brightness.dark,
              systemNavigationBarColor: colors.surfaceContainer,
              systemNavigationBarIconBrightness:
                  dark ? Brightness.light : Brightness.dark,
            ),
            child: Scaffold(
              body: SafeArea(
                bottom: tablet || secondary || keyboard,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (tablet && !secondary)
                      _MobileNavigationRail(
                        section: navSection,
                        onSelected: _select,
                      ),
                    Expanded(
                      child: Column(
                        children: [
                          if (app.hasBackendConnection &&
                              scope.backend.status != BackendStatus.ready &&
                              section != AppSection.settings)
                            _ConnectionNotice(),
                          if (app.notice case final notice?)
                            Material(
                              color: colors.secondaryContainer,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 16),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Semantics(
                                        liveRegion: true,
                                        child: Text(notice),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '关闭提示',
                                      onPressed: app.clearNotice,
                                      icon: const Icon(Icons.close, size: 18),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          Expanded(child: content),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              bottomNavigationBar: tablet || secondary || keyboard
                  ? null
                  : MobileBottomNavigation(
                      section: navSection,
                      onSelected: _select,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _ConnectionNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final backend = AppScope.of(context).backend;
    final checking = backend.status == BackendStatus.checking ||
        backend.status == BackendStatus.starting;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: checking ? colors.secondaryContainer : colors.errorContainer,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(
            children: [
              Icon(
                checking ? Icons.sync : Icons.cloud_off_outlined,
                size: 18,
                color: checking
                    ? colors.onSecondaryContainer
                    : colors.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    checking ? '正在连接服务…' : '连接中断 · 已保留当前内容',
                    style: TextStyle(
                      fontSize: 13,
                      color: checking
                          ? colors.onSecondaryContainer
                          : colors.onErrorContainer,
                    ),
                  ),
                ),
              ),
              if (!checking)
                TextButton(
                  onPressed: backend.ensureReady,
                  child: const Text('重试'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class MobileBottomNavigation extends StatelessWidget {
  const MobileBottomNavigation({
    required this.section,
    required this.onSelected,
    super.key,
  });
  final AppSection section;
  final ValueChanged<AppSection> onSelected;
  static double heightOf(BuildContext context) =>
      56 +
      (MediaQuery.textScalerOf(context).scale(11) - 11).clamp(0, 32) * 1.25;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final dark = MiuixTheme.of(context).brightness == Brightness.dark;
    final reduced = MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.highContrastOf(context);
    final selected =
        MobileHomeShell.primarySections.indexOf(section).clamp(0, 3);
    return SafeArea(
      key: const ValueKey('mobile-bottom-navigation'),
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
        child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 344),
              child: SizedBox(
                height: heightOf(context),
                child: RepaintBoundary(
                    child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(100),
                    boxShadow: reduced
                        ? null
                        : [
                            BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: dark ? .3 : .07),
                                blurRadius: 12,
                                offset: const Offset(0, 3))
                          ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(100),
                    child: BackdropFilter(
                      enabled: !reduced,
                      filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Material(
                        color: dark
                            ? const Color(0xED191919)
                            : const Color(0xEFFFFFFF),
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(100),
                            border: Border.all(
                                color: dark
                                    ? const Color(0xFF414141)
                                    : const Color(0xFFE2E7E3)),
                            gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white
                                      .withValues(alpha: dark ? .035 : .30),
                                  Colors.white.withValues(alpha: 0)
                                ]),
                          ),
                          padding: const EdgeInsets.all(4),
                          child: LayoutBuilder(
                              builder: (context, constraints) =>
                                  Stack(children: [
                                    AnimatedPositionedDirectional(
                                      duration: MobileTokens.duration(context),
                                      curve: Curves.easeOutCubic,
                                      start:
                                          constraints.maxWidth / 4 * selected,
                                      width: constraints.maxWidth / 4,
                                      top: 0,
                                      bottom: 0,
                                      child: DecoratedBox(
                                          decoration: BoxDecoration(
                                        color: dark
                                            ? const Color(0xFF303832)
                                            : colors.primaryContainer,
                                        borderRadius:
                                            BorderRadius.circular(100),
                                        border: Border.all(
                                            color: Colors.white.withValues(
                                                alpha: dark ? .10 : .80)),
                                      )),
                                    ),
                                    Material(
                                      type: MaterialType.transparency,
                                      child: Row(children: [
                                        for (final destination
                                            in MobileHomeShell.primarySections)
                                          Expanded(
                                            child: _NavigationItem(
                                              destination: destination,
                                              selected: section == destination,
                                              capsule: true,
                                              onPressed: () =>
                                                  onSelected(destination),
                                            ),
                                          ),
                                      ]),
                                    ),
                                  ])),
                        ),
                      ),
                    ),
                  ),
                )),
              ),
            )),
      ),
    );
  }
}

class _MobileNavigationRail extends StatelessWidget {
  const _MobileNavigationRail({
    required this.section,
    required this.onSelected,
  });
  final AppSection section;
  final ValueChanged<AppSection> onSelected;
  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return SizedBox(
      width: 96,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          border: Border(right: BorderSide(color: colors.dividerLine)),
        ),
        child: SingleChildScrollView(
          child: Column(
            children: [
              const SizedBox(height: 24),
              Text(
                '青卷',
                style: TextStyle(
                  fontSize: 18,
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 32),
              for (final destination in MobileHomeShell.primarySections)
                SizedBox(
                  height: 88,
                  child: _NavigationItem(
                    destination: destination,
                    selected: section == destination,
                    onPressed: () => onSelected(destination),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.destination,
    required this.selected,
    required this.onPressed,
    this.capsule = false,
  });
  final AppSection destination;
  final bool selected;
  final VoidCallback onPressed;
  final bool capsule;
  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final color = selected ? colors.primary : colors.onBackgroundVariant;
    return Semantics(
      selected: selected,
      button: true,
      onTap: onPressed,
      label: MobileHomeShell.label(destination),
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('mobile-navigation-${destination.name}'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(capsule ? 100 : 12),
        child: Center(
          child: Padding(
            padding:
                EdgeInsets.symmetric(vertical: capsule ? 4 : 6, horizontal: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (capsule)
                  Icon(MobileHomeShell.icon(destination),
                      color: color, size: 20)
                else
                  AnimatedContainer(
                    duration: MobileTokens.duration(context, true),
                    width: 48,
                    height: 30,
                    decoration: BoxDecoration(
                      color: selected
                          ? colors.primaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      MobileHomeShell.icon(destination),
                      color: color,
                      size: 23,
                    ),
                  ),
                SizedBox(height: capsule ? 2 : 3),
                Text(
                  MobileHomeShell.label(destination),
                  style: TextStyle(
                    fontSize: capsule ? 11 : 12,
                    height: 1.25,
                    color: color,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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
