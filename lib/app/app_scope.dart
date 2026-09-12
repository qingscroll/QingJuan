import 'package:flutter/widgets.dart';

import '../core/api/api_client.dart';
import '../core/backend/backend_connection_manager.dart';
import '../core/updates/app_update_controller.dart';
import '../features/library/library_controller.dart';
import '../features/audiobook/audiobook_coordinator.dart';
import '../features/offline/offline_reading_controller.dart';
import '../features/discovery/discovery_controller.dart';
import '../features/manga_translation/manga_translation_coordinator.dart';
import '../features/auth/auth_controller.dart';
import '../features/settings/settings_controller.dart';
import '../features/sources/sources_controller.dart';
import '../features/tasks/tasks_controller.dart';
import 'app_state.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    required this.appState,
    required this.api,
    required this.backend,
    required this.auth,
    required this.library,
    required this.sources,
    required this.tasks,
    required this.settings,
    this.mangaTranslation,
    this.updates,
    this.offline,
    this.audiobook,
    DiscoveryController? discovery,
    required super.child,
    super.key,
  }) : _discovery = discovery;

  final AppState appState;
  final ApiClient api;
  final BackendConnectionManager backend;
  final AuthController auth;
  final LibraryController library;
  final SourcesController sources;
  final TasksController tasks;
  final SettingsController settings;
  final MangaTranslationCoordinator? mangaTranslation;
  final AppUpdateController? updates;
  final OfflineReadingController? offline;
  final AudiobookCoordinator? audiobook;
  final DiscoveryController? _discovery;

  DiscoveryController get discovery {
    assert(_discovery != null, 'DiscoveryController is missing from AppScope');
    return _discovery!;
  }

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this context');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) {
    return appState != oldWidget.appState ||
        api != oldWidget.api ||
        auth != oldWidget.auth ||
        updates != oldWidget.updates ||
        offline != oldWidget.offline ||
        audiobook != oldWidget.audiobook ||
        _discovery != oldWidget._discovery ||
        mangaTranslation != oldWidget.mangaTranslation;
  }
}
