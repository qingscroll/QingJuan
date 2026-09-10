import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/models/site_plugin.dart';
import '../../core/models/source.dart';
import '../../core/state/load_state.dart';

enum BookSearchEngine {
  bookSources,
  quark,
  fanqie,
  qidian,
  biqvge,
  installedPlugins
}

class SourcesController extends ChangeNotifier {
  SourcesController(this.api);

  final ApiClient api;
  LoadState state = LoadState.idle;
  List<BookSource> sources = const [];
  List<SitePlugin> plugins = const [];
  List<SourceSearchResult> results = const [];
  final Set<String> _savingPluginIds = <String>{};
  final Set<String> _savingSourceIds = <String>{};
  int _backendGeneration = 0;
  int _searchGeneration = 0;
  bool searching = false;
  bool changingPackages = false;
  String? error;

  void resetForBackendSwitch() {
    _backendGeneration += 1;
    _searchGeneration += 1;
    sources = const [];
    plugins = const [];
    results = const [];
    _savingPluginIds.clear();
    _savingSourceIds.clear();
    searching = false;
    changingPackages = false;
    error = null;
    state = LoadState.idle;
    notifyListeners();
  }

  Future<void> load() async {
    final generation = _backendGeneration;
    state = LoadState.loading;
    error = null;
    notifyListeners();
    try {
      final loaded = await Future.wait<Object>(<Future<Object>>[
        api.fetchSources(),
        api.fetchSitePlugins(),
      ]);
      if (generation != _backendGeneration) return;
      sources = loaded[0] as List<BookSource>;
      plugins = loaded[1] as List<SitePlugin>;
      state = sources.isEmpty && plugins.isEmpty
          ? LoadState.empty
          : LoadState.ready;
    } catch (exception) {
      if (generation != _backendGeneration) return;
      error = '$exception';
      state = LoadState.error;
    }
    if (generation == _backendGeneration) notifyListeners();
  }

  bool isPluginSaving(String pluginId) => _savingPluginIds.contains(pluginId);

  bool isSourceSaving(String sourceId) => _savingSourceIds.contains(sourceId);

  bool Function() captureBackend() {
    final generation = _backendGeneration;
    return () => generation == _backendGeneration;
  }

  Future<SitePluginPackageInspection> inspectPluginPackage(
          List<int> bytes, String filename) =>
      api.inspectSitePluginPackage(bytes, filename);

  Future<void> importPluginPackage(List<int> bytes, String filename,
      {bool replace = false}) async {
    if (changingPackages) return;
    final current = captureBackend();
    changingPackages = true;
    notifyListeners();
    try {
      final installed =
          await api.importSitePluginPackage(bytes, filename, replace: replace);
      if (!current()) return;
      plugins = [
        ...plugins.where((plugin) => plugin.id != installed.id),
        installed
      ];
      state = LoadState.ready;
    } finally {
      if (current()) {
        changingPackages = false;
        notifyListeners();
      }
    }
  }

  Future<void> uninstallPlugin(SitePlugin plugin) async {
    if (changingPackages || !plugin.isInstalled) return;
    final current = captureBackend();
    changingPackages = true;
    notifyListeners();
    try {
      await api.uninstallSitePlugin(plugin.id);
      if (!current()) return;
      plugins =
          plugins.where((item) => item.id != plugin.id).toList(growable: false);
    } finally {
      if (current()) {
        changingPackages = false;
        notifyListeners();
      }
    }
  }

  Future<void> setPluginEnabled(SitePlugin plugin, bool enabled) async {
    if (!_savingPluginIds.add(plugin.id)) return;
    final generation = _backendGeneration;
    notifyListeners();
    try {
      final updated = await api.saveSitePluginEnabled(plugin.id, enabled);
      if (generation != _backendGeneration) return;
      plugins = plugins
          .map((candidate) => candidate.id == updated.id ? updated : candidate)
          .toList(growable: false);
    } finally {
      if (generation == _backendGeneration) {
        _savingPluginIds.remove(plugin.id);
        notifyListeners();
      }
    }
  }

  Future<SitePluginLoginQrCode> startPluginLogin(String pluginId) =>
      api.startSitePluginLogin(pluginId);

  Future<SitePluginLoginPoll> pollPluginLogin(
    String pluginId,
    String flowId,
  ) async {
    final result = await api.pollSitePluginLogin(pluginId, flowId);
    if (result.loggedIn) {
      setPluginAccountLoggedIn(pluginId, true);
    }
    return result;
  }

  Future<void> logoutPluginAccount(String pluginId) async {
    final result = await api.logoutSitePluginAccount(pluginId);
    setPluginAccountLoggedIn(pluginId, result.loggedIn);
  }

  Future<void> loginPluginWithCookies(String pluginId, String cookies) async {
    final result = await api.loginSitePluginWithCookies(pluginId, cookies);
    setPluginAccountLoggedIn(pluginId, result.loggedIn);
  }

  Future<SitePluginBookshelfImportJob> startPluginBookshelfImport(
    String pluginId,
  ) =>
      api.startSitePluginBookshelfImport(pluginId);

  Future<SitePluginBookshelfImportJob> fetchPluginBookshelfImport(
    String pluginId,
    String jobId,
  ) =>
      api.fetchSitePluginBookshelfImport(pluginId, jobId);

  void setPluginAccountLoggedIn(String pluginId, bool loggedIn) {
    var changed = false;
    plugins = plugins.map((plugin) {
      if (plugin.id != pluginId || plugin.accountLoggedIn == loggedIn) {
        return plugin;
      }
      changed = true;
      return plugin.copyWith(accountLoggedIn: loggedIn);
    }).toList(growable: false);
    if (changed) notifyListeners();
  }

  Future<void> setSourceEnabled(BookSource source, bool enabled) async {
    if (!_savingSourceIds.add(source.id)) return;
    final generation = _backendGeneration;
    notifyListeners();
    try {
      final updated = await api.saveSourceEnabled(source.id, enabled);
      if (generation != _backendGeneration) return;
      sources = sources
          .map((candidate) => candidate.id == updated.id ? updated : candidate)
          .toList(growable: false);
    } finally {
      if (generation == _backendGeneration) {
        _savingSourceIds.remove(source.id);
        notifyListeners();
      }
    }
  }

  void clearSearchResults() {
    _searchGeneration += 1;
    results = const [];
    searching = false;
    error = null;
    notifyListeners();
  }

  Future<void> search(
    String keyword, {
    BookSearchEngine engine = BookSearchEngine.bookSources,
  }) async {
    final normalized = keyword.trim();
    if (normalized.isEmpty) return;
    final backendGeneration = _backendGeneration;
    final searchGeneration = ++_searchGeneration;
    searching = true;
    error = null;
    results = const [];
    notifyListeners();
    try {
      final loaded = switch (engine) {
        BookSearchEngine.installedPlugins =>
          api.searchInstalledPlugins(normalized),
        BookSearchEngine.bookSources => api.searchSources(
            normalized,
            sourceIds: sources
                .where((source) => source.enabled)
                .map((source) => source.id)
                .toList(),
          ),
        BookSearchEngine.quark => api.searchBuiltinSite(
            normalized,
            sourceId: 'source-builtin-quark',
            sourceName: '夸克小说',
            sourceLanguage: '中文',
          ),
        BookSearchEngine.fanqie => api.searchBuiltinSite(
            normalized,
            sourceId: 'source-builtin-fanqie',
            sourceName: '番茄小说',
            sourceLanguage: '中文',
          ),
        BookSearchEngine.qidian => api.searchBuiltinSite(
            normalized,
            sourceId: 'source-builtin-qidian',
            sourceName: '起点中文网',
            sourceLanguage: '中文',
          ),
        BookSearchEngine.biqvge => api.searchBuiltinSite(
            normalized,
            sourceId: 'source-builtin-biqvge',
            sourceName: '笔趣阁',
            sourceLanguage: '中文',
          ),
      };
      final searchResults = await loaded;
      if (backendGeneration != _backendGeneration ||
          searchGeneration != _searchGeneration) {
        return;
      }
      results = searchResults;
    } catch (exception) {
      if (backendGeneration != _backendGeneration ||
          searchGeneration != _searchGeneration) {
        return;
      }
      error = '$exception';
    } finally {
      if (backendGeneration == _backendGeneration &&
          searchGeneration == _searchGeneration) {
        searching = false;
        notifyListeners();
      }
    }
  }

  Future<SourceImportResult> importUrl(String url) async {
    final result = await api.importSourcesFromUrl(url.trim());
    await load();
    return result;
  }

  Future<SourceImportResult> importText(String content) async {
    final result = await api.importSourcesFromText(content);
    await load();
    return result;
  }
}
