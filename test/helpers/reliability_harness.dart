import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:http/http.dart' as http;
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/discovery/discovery_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReliabilityHarness {
  ReliabilityHarness._(this.scope);
  final AppScope scope;
  static Future<ReliabilityHarness> create(http.Client client,
      {bool localBackendSupported = false}) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState(await SharedPreferences.getInstance(),
        localBackendSupported: localBackendSupported);
    final api =
        ApiClient(() => 'https://qingjuan.example.test', client: client);
    return ReliabilityHarness._(AppScope(
      appState: state,
      api: api,
      backend: BackendConnectionManager(api, isConfigured: () => false)
        ..capabilities = {'taskControl': true, 'linkJobHistory': true},
      auth: AuthController.localAdministrator(api),
      library: LibraryController(api)..imports.enabled = true,
      discovery: DiscoveryController(api),
      sources: SourcesController(api),
      tasks: TasksController(api),
      settings: SettingsController(api),
      child: const f.SizedBox.shrink(),
    ));
  }

  f.Widget widget(f.Widget page,
      {bool mobile = false,
      double textScale = 1,
      f.Brightness brightness = f.Brightness.light}) {
    f.Widget scale(f.BuildContext context, f.Widget? child) => f.MediaQuery(
        data: f.MediaQuery.of(context)
            .copyWith(textScaler: f.TextScaler.linear(textScale)),
        child: child!);
    final app = mobile
        ? m.MaterialApp(
            debugShowCheckedModeBanner: false, builder: scale, home: page)
        : f.FluentApp(
            debugShowCheckedModeBanner: false,
            theme: buildQingJuanTheme(brightness,
                platform: f.TargetPlatform.windows),
            builder: scale,
            home: page);
    return AppScope(
        appState: scope.appState,
        api: scope.api,
        backend: scope.backend,
        auth: scope.auth,
        library: scope.library,
        discovery: scope.discovery,
        sources: scope.sources,
        tasks: scope.tasks,
        settings: scope.settings,
        child: app);
  }

  void dispose() {
    scope.library.dispose();
    scope.discovery.dispose();
    scope.sources.dispose();
    scope.tasks.dispose();
    scope.settings.dispose();
    scope.auth.dispose();
    scope.backend.dispose();
    scope.api.close();
    scope.appState.dispose();
  }
}
