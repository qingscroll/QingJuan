import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/discovery.dart';
import '../../core/state/load_state.dart';

class DiscoveryController extends ChangeNotifier {
  DiscoveryController(this.api);

  final ApiClient api;
  LoadState _sitesState = LoadState.idle;
  LoadState _contentState = LoadState.idle;
  List<DiscoverySite> _sites = const [];
  DiscoverySite? _selectedSite;
  DiscoveryChannel? _selectedChannel;
  DiscoveryResult? _result;
  String _kind = 'recommend';
  String? _sitesError;
  String? _error;
  int _page = 1;
  int _sitesGeneration = 0;
  int _contentGeneration = 0;
  bool _disposed = false;

  LoadState get sitesState => _sitesState;
  LoadState get contentState => _contentState;
  List<DiscoverySite> get sites => _sites;
  DiscoverySite? get selectedSite => _selectedSite;
  DiscoveryChannel? get selectedChannel => _selectedChannel;
  DiscoveryResult? get result => _result;
  String get kind => _kind;
  String? get sitesError => _sitesError;
  String? get error => _error;
  int get page => _page;
  bool get isPageable => _selectedChannel?.pageable == true;
  bool get hasMore => isPageable && _result?.hasMore == true;
  bool get canPreviousPage =>
      !_disposed &&
      isPageable &&
      _page > 1 &&
      _sitesState == LoadState.ready &&
      _contentState != LoadState.loading;
  bool get canNextPage =>
      !_disposed &&
      hasMore &&
      _page < 1000 &&
      _sitesState == LoadState.ready &&
      const {LoadState.ready, LoadState.empty}.contains(_contentState);
  List<DiscoveryChannel> get channels => List.unmodifiable(
        _selectedSite?.channels.where((channel) => channel.kind == _kind) ??
            const <DiscoveryChannel>[],
      );

  Future<void> loadSites() async {
    if (_disposed || _sitesState == LoadState.loading) return;
    final generation = ++_sitesGeneration;
    final current = api.captureContextGuard();
    _sitesState = LoadState.loading;
    _sitesError = null;
    notifyListeners();
    try {
      final loaded = await api.fetchDiscoverySites();
      if (_disposed || generation != _sitesGeneration || !current()) return;
      final previousId = _selectedSite?.site;
      _sites = List.unmodifiable(loaded);
      _selectedSite =
          _sites.where((site) => site.site == previousId).firstOrNull;
      _selectedSite ??= _sites.firstOrNull;
      _sitesState = _sites.isEmpty ? LoadState.empty : LoadState.ready;
      await _selectFirstChannel();
    } catch (exception) {
      if (_disposed || generation != _sitesGeneration || !current()) return;
      _sitesState = LoadState.error;
      _sitesError = _message(exception, '无法获取推荐站点，请稍后重试。');
      notifyListeners();
    }
  }

  Future<void> selectSite(String siteId) async {
    if (_disposed || _selectedSite?.site == siteId) return;
    final selected = _sites.where((site) => site.site == siteId).firstOrNull;
    if (selected == null) return;
    _selectedSite = selected;
    await _selectFirstChannel();
  }

  Future<void> selectKind(String value) async {
    if (_disposed ||
        _kind == value ||
        !const {'rank', 'recommend'}.contains(value)) {
      return;
    }
    _kind = value;
    await _selectFirstChannel();
  }

  Future<void> selectChannel(String key) async {
    if (_disposed || _selectedChannel?.key == key) return;
    final selected =
        channels.where((channel) => channel.key == key).firstOrNull;
    if (selected == null) return;
    _selectedChannel = selected;
    _clearContent();
    await _loadContent();
  }

  Future<void> _selectFirstChannel() async {
    _selectedChannel = channels.firstOrNull;
    _clearContent();
    if (_selectedChannel == null) {
      _contentState = LoadState.empty;
      notifyListeners();
      return;
    }
    await _loadContent();
  }

  Future<void> refresh() async {
    if (_disposed || _contentState == LoadState.loading) return;
    if (_selectedSite == null ||
        const {LoadState.idle, LoadState.empty, LoadState.error}
            .contains(_sitesState)) {
      await loadSites();
      return;
    }
    await _loadContent(refresh: true);
  }

  Future<void> nextPage() async {
    if (!canNextPage) return;
    _page += 1;
    await _loadContent();
  }

  Future<void> previousPage() async {
    if (!canPreviousPage) return;
    _page -= 1;
    await _loadContent();
  }

  Future<void> _loadContent({bool refresh = false}) async {
    final site = _selectedSite;
    final channel = _selectedChannel;
    if (_disposed || site == null || channel == null) return;
    final generation = ++_contentGeneration;
    final current = api.captureContextGuard();
    _contentState = LoadState.loading;
    _result = null;
    _error = null;
    notifyListeners();
    try {
      final loaded = await api.fetchDiscoveryChannel(
        site.site,
        channel.key,
        page: _page,
        limit: 100,
        refresh: refresh,
      );
      if (_disposed || generation != _contentGeneration || !current()) return;
      _result = loaded;
      _page = loaded.page;
      _error = loaded.error?.trim();
      if (_error?.isEmpty == true) _error = null;
      _contentState = _error != null
          ? LoadState.error
          : loaded.items.isEmpty
              ? LoadState.empty
              : LoadState.ready;
    } catch (exception) {
      if (_disposed || generation != _contentGeneration || !current()) return;
      _error = _message(exception, '无法加载该频道，请稍后重试。');
      _contentState = LoadState.error;
    }
    notifyListeners();
  }

  void _clearContent() {
    _contentGeneration += 1;
    _page = 1;
    _result = null;
    _error = null;
    _contentState = LoadState.idle;
  }

  void resetForBackendChange() {
    if (_disposed) return;
    _sitesGeneration += 1;
    _sites = const [];
    _selectedSite = null;
    _selectedChannel = null;
    _kind = 'recommend';
    _sitesState = LoadState.idle;
    _sitesError = null;
    _clearContent();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sitesGeneration += 1;
    _contentGeneration += 1;
    super.dispose();
  }

  String _message(Object error, String fallback) =>
      error is ApiException ? error.message : fallback;
}
