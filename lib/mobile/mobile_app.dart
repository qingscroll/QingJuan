import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../app/app_state.dart';
import 'mobile_theme.dart';

class MobileQingJuanApp extends StatelessWidget {
  const MobileQingJuanApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context).appState;
    final mode = appState.themeModeListenable.value;
    final colorMode = switch (mode) {
      ThemeMode.system => MiuixColorSchemeMode.system,
      ThemeMode.light => MiuixColorSchemeMode.light,
      ThemeMode.dark => MiuixColorSchemeMode.dark,
    };
    return MiuixThemeController(
      colorSchemeMode: colorMode,
      lightColors: qjMobileLightColors(),
      darkColors: qjMobileDarkColors(),
      child: Builder(
        builder: (context) {
          final theme = MiuixTheme.of(context);
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: '青卷',
            theme: ThemeData(
              useMaterial3: true,
              brightness: theme.brightness,
              colorScheme: ColorScheme.fromSeed(
                seedColor: theme.colors.primary,
                brightness: theme.brightness,
              ),
              scaffoldBackgroundColor: theme.colors.background,
              splashFactory: NoSplash.splashFactory,
            ),
            locale: const Locale('zh', 'CN'),
            supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en')],
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              GlobalWidgetsLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const MobileHomeShell(),
          );
        },
      ),
    );
  }
}

class MobileHomeShell extends StatelessWidget {
  const MobileHomeShell({super.key});

  static const _sections = <AppSection>[
    AppSection.library,
    AppSection.search,
    AppSection.sources,
    AppSection.tasks,
    AppSection.settings,
  ];

  @override
  Widget build(BuildContext context) {
    final appState = AppScope.of(context).appState;
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final section = switch (appState.section) {
          AppSection.about ||
          AppSection.plugins ||
          AppSection.translator =>
            AppSection.settings,
          final section => section,
        };
        return MiuixScaffold(
          bottomBar: MiuixNavigationBar(
            children: <Widget>[
              for (final item in _sections)
                MiuixNavigationBarItem(
                  key: ValueKey<String>('mobile-navigation-${item.name}'),
                  selected: item == section,
                  onPressed: () => appState.selectSection(item),
                  icon: MiuixIcon(
                    vector: MiuixIcons.extended.byName(_iconName(item))!,
                  ),
                  label: _label(item),
                ),
            ],
          ),
          content: (padding) => Padding(
            padding: padding,
            child: Center(child: Text(_label(section))),
          ),
        );
      },
    );
  }

  String _label(AppSection section) => switch (section) {
        AppSection.library => '书架',
        AppSection.search => '搜索',
        AppSection.sources => '书源',
        AppSection.tasks => '任务',
        AppSection.translator => '漫画翻译',
        AppSection.settings => '我的',
        AppSection.plugins => '插件',
        AppSection.about => '关于',
      };

  String _iconName(AppSection section) => switch (section) {
        AppSection.library => 'home',
        AppSection.search => 'search',
        AppSection.sources => 'layers',
        AppSection.tasks => 'tasks',
        AppSection.translator => 'layers',
        AppSection.settings => 'contacts',
        AppSection.plugins => 'layers',
        AppSection.about => 'info',
      };
}
