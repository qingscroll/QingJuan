import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import 'manga_bookshelf_import.dart';
import 'manga_translation_controller.dart';

class MangaTranslationCoordinator extends ChangeNotifier {
  MangaTranslationCoordinator(
    this._api, {
    SharedPreferences? preferences,
    MangaWorkflowInvoker? invokeWorkflow,
    MangaBookshelfImportInvoker? importBookshelfBook,
  })  : _preferences = preferences,
        _invokeWorkflow = invokeWorkflow,
        _importBookshelfBook = importBookshelfBook {
    _controller = _createController();
    unawaited(_controller.initialize());
  }

  final ApiClient _api;
  final SharedPreferences? _preferences;
  final MangaWorkflowInvoker? _invokeWorkflow;
  final MangaBookshelfImportInvoker? _importBookshelfBook;
  late MangaTranslationController _controller;
  bool _disposed = false;

  MangaTranslationController get controller => _controller;

  void resetForBackendSwitch() {
    if (_disposed) return;
    final previous = _controller;
    _controller = _createController();
    unawaited(_controller.initialize());
    notifyListeners();
    previous.dispose();
  }

  MangaTranslationController _createController() {
    return MangaTranslationController(
      _api,
      preferences: _preferences,
      invokeWorkflow: _invokeWorkflow,
      importBookshelfBook: _importBookshelfBook,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _controller.dispose();
    super.dispose();
  }
}
