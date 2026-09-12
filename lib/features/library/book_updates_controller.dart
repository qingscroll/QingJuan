import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_client.dart';
import '../../core/models/book_update.dart';

class BookUpdatesController extends ChangeNotifier {
  BookUpdatesController(this.api);
  final ApiClient api;
  bool _enabled = false;
  bool _disposed = false;
  bool loading = false;
  String? error;
  int _generation = 0;
  int _listRequest = 0;
  Timer? _timer;
  final _records = <String, BookUpdate>{};
  final _pending = <String>{};
  final _versions = <String, int>{};
  Future<void> Function()? onBooksChanged;
  int get contextGeneration => _generation;
  bool get enabled => _enabled;
  Map<String, BookUpdate> get records => Map.unmodifiable(_records);
  bool isPending(String id) => _pending.contains(id);

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _timer?.cancel();
    _timer = value
        ? Timer.periodic(const Duration(seconds: 30), (_) => unawaited(load()))
        : null;
    if (!value) reset();
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
    _enabled = false;
    _generation++;
    _listRequest++;
    _records.clear();
    _pending.clear();
    _versions.clear();
    error = null;
    loading = false;
    notifyListeners();
  }

  Future<void> load() async {
    if (_disposed || !_enabled || loading) return;
    final generation = _generation;
    final request = ++_listRequest;
    loading = true;
    try {
      final result = await api.fetchBookUpdates();
      if (_disposed || generation != _generation || request != _listRequest) {
        return;
      }
      _records
        ..clear()
        ..addEntries(result.map((item) => MapEntry(item.bookId, item)));
      error = null;
    } catch (exception) {
      if (!_disposed && generation == _generation && request == _listRequest) {
        error = '$exception';
      }
    } finally {
      if (!_disposed && generation == _generation && request == _listRequest) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void _invalidateList() {
    _listRequest++;
    loading = false;
  }

  Future<BookUpdate?> refresh(String id) async {
    if (_disposed || !_enabled || _pending.contains(id)) return null;
    final generation = _generation;
    final version = (_versions[id] ?? 0) + 1;
    _versions[id] = version;
    final result = await api.fetchBookUpdate(id);
    if (_disposed || generation != _generation || _versions[id] != version) {
      return null;
    }
    _invalidateList();
    _records[id] = result;
    notifyListeners();
    return result;
  }

  Future<BookUpdate?> _change(String id, Future<BookUpdate> Function() action,
      {bool refreshBooks = false}) async {
    if (_disposed || !_enabled || !_pending.add(id)) return null;
    final generation = _generation;
    _versions[id] = (_versions[id] ?? 0) + 1;
    _invalidateList();
    notifyListeners();
    try {
      final result = await action();
      if (_disposed || generation != _generation) return null;
      _invalidateList();
      _records[id] = result;
      error = null;
      if (refreshBooks) await onBooksChanged?.call();
      return result;
    } finally {
      if (!_disposed && generation == _generation) {
        _invalidateList();
        _pending.remove(id);
        notifyListeners();
      }
    }
  }

  Future<BookUpdate?> check(String id) =>
      _change(id, () => api.checkBookUpdates(id), refreshBooks: true);
  Future<BookUpdate?> configure(String id,
          {required int expectedRevision,
          required int intervalHours,
          required bool autoDownload}) =>
      _change(
          id,
          () => api.configureBookUpdates(id,
              expectedRevision: expectedRevision,
              intervalHours: intervalHours,
              autoDownload: autoDownload));
  Future<BookUpdate?> acknowledge(String id, int throughIndex) => _change(id,
      () => api.acknowledgeBookUpdates(id, throughChapterIndex: throughIndex));

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
