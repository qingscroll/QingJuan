import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/models/translation_quality.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/translation_quality/quality_text_editor.dart';
import 'package:qingjuan/features/translation_quality/translation_quality_controller.dart';

import 'quality_fixture.dart';

void main() {
  late QualityApi api;
  late LibraryController library;
  late TranslationQualityController controller;
  setUp(() {
    api = QualityApi();
    library = LibraryController(api);
    controller = TranslationQualityController(library,
        bookId: 'quality-book', chapterIndex: 1);
  });
  tearDown(() {
    controller.dispose();
    library.dispose();
    api.close();
  });

  test(
      'loading never calls model, failed save preserves base for conflict review',
      () async {
    await controller.load();
    expect(api.calls, 0);
    final before = controller.chapter;
    api.failure = Exception('原文或译文已改变，请重新加载');
    await controller.save('用户草稿');
    expect(controller.chapter, same(before));
    expect(controller.error, contains('重新加载'));
    expect(api.lastExpected, same(before));
    expect(api.saves, 1);
  });

  test('a suggestion requires explicit apply/save and only one pending request',
      () async {
    await controller.load();
    final pending = Completer<TranslationSuggestion>();
    api.pending = () => pending.future;
    final running = controller.retranslate(1, 6);
    await controller.retranslate(1, 6);
    expect(api.calls, 1);
    expect(api.operationIds.single.length, 32);
    pending.complete(TranslationSuggestion.fromJson(suggestionJson));
    await running;
    expect(controller.suggestion?.text, '你好');
    expect(api.saves, 0);
    expect(controller.chapter?.translatedText, '旧译文内容');
    await controller.save('你好');
    expect(api.saves, 1);
    expect(api.reloads, 1);
    expect(controller.suggestion, isNull);
  });

  test('invalid range never costs a request; provider failure is not retried',
      () async {
    await controller.load();
    await controller.retranslate(3, 9999);
    expect(api.calls, 0);
    api.failure = Exception('模型暂不可用');
    await controller.retranslate(1, 6);
    expect(api.calls, 1);
    expect(controller.suggestion, isNull);
    expect(controller.error, contains('模型暂不可用'));
    expect(controller.busy, isFalse);
  });

  test('account switch clears all data and ignores a late model response',
      () async {
    await controller.load();
    final pending = Completer<TranslationSuggestion>();
    api.pending = () => pending.future;
    final running = controller.retranslate(1, 6);
    library.resetForBackendSwitch();
    pending.complete(TranslationSuggestion.fromJson(suggestionJson));
    await running;
    expect(controller.invalidated, isTrue);
    expect(controller.chapter, isNull);
    expect(controller.glossary, isNull);
    expect(controller.suggestion, isNull);
    expect(controller.usage, isEmpty);
  });

  test('history restore uses viewed revision once; glossary sends its revision',
      () async {
    await controller.load();
    await controller.viewHistory(controller.chapter!.history.single);
    final revision = controller.historical!;
    await controller.restore(revision);
    await controller.restore(revision);
    expect(api.restores, 1);
    expect(controller.chapter!.translatedText, '历史译文');
    await controller.saveGlossary(
        [const GlossaryEntry(source: 'Alice', target: '艾丽丝', kind: 'name')]);
    expect(api.glossaryRevision, 0);
    expect(controller.glossary!.revision, 1);
  });

  test(
      'UTF-16 selections convert to Unicode code points without splitting emoji',
      () {
    expect(unicodeOffset('😀Hello', 2), 1);
    expect(unicodeOffset('😀Hello', 7), 6);
    expect(() => unicodeOffset('😀Hello', 1), throwsArgumentError);
  });
}
