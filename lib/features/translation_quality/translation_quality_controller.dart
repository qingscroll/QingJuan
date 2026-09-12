import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/models/translation_quality.dart';
import '../library/library_controller.dart';

class TranslationQualityController extends ChangeNotifier {
  TranslationQualityController(this.library,
      {required this.bookId, required this.chapterIndex})
      : _generation = library.contextGeneration {
    library.addListener(_contextChanged);
  }
  final LibraryController library;
  final String bookId;
  final int? chapterIndex;
  final int _generation;
  ChapterTranslation? chapter;
  BookGlossary? glossary;
  TranslationRevision? historical;
  TranslationSuggestion? suggestion;
  List<TranslationUsage> usage = [];
  bool busy = false;
  bool invalidated = false;
  bool changed = false;
  bool _disposed = false;
  String? error;
  String? message;
  bool get usable => !_disposed && !invalidated;

  void _contextChanged() {
    if (_disposed || invalidated || _generation == library.contextGeneration) {
      return;
    }
    invalidated = true;
    chapter = null;
    glossary = null;
    historical = null;
    suggestion = null;
    usage = [];
    busy = false;
    error = '账号或后端已切换，请返回书库重新打开。';
    message = null;
    notifyListeners();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (!usable || busy) return;
    busy = true;
    error = null;
    message = null;
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
        final index = chapterIndex;
        if (index == null) {
          final result = await library.api.fetchBookGlossary(bookId);
          if (usable) glossary = result;
          return;
        }
        final values = await Future.wait<Object>([
          library.api.fetchChapterTranslation(bookId, index),
          library.api.fetchBookGlossary(bookId),
          library.api.fetchTranslationUsage(bookId),
        ]);
        if (!usable) return;
        chapter = values[0] as ChapterTranslation;
        glossary = values[1] as BookGlossary;
        usage = values[2] as List<TranslationUsage>;
        historical = null;
        suggestion = null;
      });

  Future<void> save(String text) async {
    final expected = chapter;
    if (expected == null || text.trim().isEmpty || text.runes.length > 200000) {
      if (usable) {
        error = '请输入 20 万字符以内的非空译文。';
        notifyListeners();
      }
      return;
    }
    await _run(() async {
      final result =
          await library.api.saveChapterTranslation(expected, text: text);
      if (!usable) return;
      chapter = result;
      historical = null;
      suggestion = null;
      changed = true;
      message = '译文已保存，阅读与导出将使用此版本。';
      await library.load();
    });
  }

  Future<void> saveGlossary(List<GlossaryEntry> entries) async {
    final expected = glossary;
    if (expected == null) return;
    await _run(() async {
      final result = await library.api.saveBookGlossary(bookId,
          expectedRevision: expected.revision, entries: entries);
      if (!usable) return;
      glossary = result;
      message = '术语表已保存，后续小说翻译和选段重译会使用匹配的译名。';
    });
  }

  Future<void> viewHistory(TranslationHistoryItem item) => _run(() async {
        final index = chapterIndex;
        if (index == null) return;
        final result =
            await library.api.fetchTranslationRevision(bookId, index, item.id);
        if (!usable) return;
        historical = result;
      });

  Future<void> restore(TranslationRevision confirmed) async {
    final expected = chapter;
    if (expected == null || !identical(historical, confirmed)) return;
    await _run(() async {
      historical = null;
      final result = await library.api
          .restoreTranslationRevision(expected, historyId: confirmed.id);
      if (!usable) return;
      chapter = result;
      suggestion = null;
      changed = true;
      message = '历史译文已恢复，并保留为一个新版本。';
      await library.load();
    });
  }

  Future<void> retranslate(int sourceStart, int sourceEnd) async {
    final expected = chapter;
    if (expected == null) return;
    if (sourceStart < 0 ||
        sourceEnd <= sourceStart ||
        sourceEnd > expected.sourceText.runes.length ||
        sourceEnd - sourceStart > 4000) {
      error = '请在原文中选择 1–4000 个字符。';
      notifyListeners();
      return;
    }
    await _run(() async {
      suggestion = null;
      final random = Random.secure();
      final operationId = List.generate(
              16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      final result = await library.api.retranslateSelection(expected,
          operationId: operationId,
          sourceStart: sourceStart,
          sourceEnd: sourceEnd);
      if (!usable || !identical(chapter, expected)) return;
      suggestion = result;
      if (result.usage case final record?) usage = [record, ...usage];
      message = '已生成候选译文；核对后替换到草稿，再点击保存。';
    });
  }

  void discardSuggestion() {
    if (!usable || suggestion == null) return;
    suggestion = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    library.removeListener(_contextChanged);
    super.dispose();
  }
}
