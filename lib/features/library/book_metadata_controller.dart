import 'package:flutter/foundation.dart';

import '../../core/models/book.dart';
import '../../core/models/book_metadata.dart';
import 'library_controller.dart';

class BookMetadataController extends ChangeNotifier {
  BookMetadataController(this.library, this.bookId)
      : _generation = library.contextGeneration {
    library.addListener(_contextChanged);
  }
  final LibraryController library;
  final String bookId;
  final int _generation;
  BookMetadata? metadata;
  String? error;
  bool loading = false;
  bool saving = false;
  bool invalidated = false;
  bool _disposed = false;
  int _request = 0;

  void _contextChanged() {
    if (invalidated || _generation == library.contextGeneration) return;
    invalidated = true;
    metadata = null;
    loading = saving = false;
    error = '账号或服务已切换，请返回书库重新打开作品。';
    _request++;
    notifyListeners();
  }

  Future<void> load() async {
    if (_disposed || invalidated || saving) return;
    final request = ++_request;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final value = await library.api.fetchBookMetadata(bookId);
      if (_disposed || invalidated || request != _request) return;
      metadata = value;
    } catch (exception) {
      if (_disposed || invalidated || request != _request) return;
      error = '$exception';
    } finally {
      if (!_disposed && !invalidated && request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> save(JsonMap changes) async {
    if (_disposed || invalidated || saving || loading || metadata == null) {
      return false;
    }
    saving = true;
    error = null;
    notifyListeners();
    try {
      final value = await library.updateMetadata(
          bookId, {...changes, 'expectedRevision': metadata!.revision});
      if (_disposed || invalidated || value == null) return false;
      metadata = value;
      return true;
    } catch (exception) {
      if (!_disposed && !invalidated) error = '$exception';
      return false;
    } finally {
      if (!_disposed && !invalidated) {
        saving = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    library.removeListener(_contextChanged);
    super.dispose();
  }
}
