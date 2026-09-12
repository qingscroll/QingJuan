import 'package:flutter/foundation.dart';

import '../../core/models/storage.dart';
import '../library/library_controller.dart';

class BookStorageController extends ChangeNotifier {
  BookStorageController(this.library, {required this.bookId})
      : _generation = library.contextGeneration {
    library.addListener(_contextChanged);
  }
  final LibraryController library;
  final String bookId;
  final int _generation;
  BookStorageReport? report;
  StorageCleanupPreview? preview;
  bool busy = false, invalidated = false, _disposed = false;
  String? error, message;
  bool get usable => !_disposed && !invalidated;

  void _contextChanged() {
    if (!usable || _generation == library.contextGeneration) return;
    invalidated = true;
    busy = false;
    report = null;
    preview = null;
    message = null;
    error = '账号或后端已切换，请返回书库重新打开。';
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (!usable || busy) return;
    busy = true;
    error = message = null;
    notifyListeners();
    try {
      await operation();
    } catch (exception) {
      if (usable) error = '$exception';
    } finally {
      if (usable) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> load() => _run(() async {
        preview = null;
        final value = await library.api.fetchBookStorage(bookId);
        if (usable) report = value;
      });

  Future<void> inspect() => _run(() async {
        preview = null;
        final value = await library.api.previewBookStorageCleanup(bookId);
        if (usable) preview = value;
      });

  Future<void> cleanup(StorageCleanupPreview confirmed) async {
    if (!usable || !identical(preview, confirmed) || confirmed.fileCount == 0) {
      return;
    }
    await _run(() async {
      preview = null;
      final result = await library.api.cleanupBookStorage(confirmed);
      if (!usable) return;
      report = result.storage;
      message =
          '已清理 ${result.deletedFiles} 个导出文件，释放 ${formatStorageBytes(result.deletedBytes)}。'
          '${result.warnings.isEmpty ? '' : '\n${result.warnings.join('\n')}'}';
    });
  }

  @override
  void dispose() {
    _disposed = true;
    library.removeListener(_contextChanged);
    super.dispose();
  }
}

String formatStorageBytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}
