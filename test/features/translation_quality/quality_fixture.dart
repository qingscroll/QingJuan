import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/translation_quality.dart';

JsonMap chapterJson({String text = '旧译文内容', int revision = 0}) => {
      'bookId': 'quality-book',
      'chapterIndex': 1,
      'title': '第一章',
      'sourceText': '😀Hello Alice.',
      'translatedText': text,
      'sourceHash': 'source-hash',
      'translationHash': 'translation-$revision',
      'revision': revision,
      'history': [historyJson],
    };
const historyJson = <String, dynamic>{
  'id': 'history-one',
  'revision': 0,
  'kind': 'initial',
  'createdAt': '2026-09-11T00:00:00Z',
  'sourceHash': 'source-hash',
  'translationHash': 'translation-0',
};
const glossaryJson = <String, dynamic>{
  'bookId': 'quality-book',
  'revision': 0,
  'entries': []
};
const suggestionJson = <String, dynamic>{
  'operationId': 'model-request-one',
  'sourceStart': 1,
  'sourceEnd': 6,
  'text': '你好',
  'usage': null
};

class QualityApi extends ApiClient {
  QualityApi() : super(() => 'http://127.0.0.1:19453');
  int calls = 0;
  int saves = 0;
  int restores = 0;
  int reloads = 0;
  int? glossaryRevision;
  ChapterTranslation? lastExpected;
  Object? failure;
  Future<TranslationSuggestion> Function()? pending;
  Future<ChapterTranslation> Function()? savePending;
  List<String> operationIds = [];

  @override
  Future<ChapterTranslation> fetchChapterTranslation(
      String bookId, int chapterIndex) async {
    if (failure != null) throw failure!;
    return ChapterTranslation.fromJson(chapterJson());
  }

  @override
  Future<BookGlossary> fetchBookGlossary(String bookId) async =>
      BookGlossary.fromJson(glossaryJson);
  @override
  Future<List<TranslationUsage>> fetchTranslationUsage(String bookId) async =>
      [];
  @override
  Future<BookGlossary> saveBookGlossary(String bookId,
      {required int expectedRevision,
      required List<GlossaryEntry> entries}) async {
    glossaryRevision = expectedRevision;
    return BookGlossary(
        bookId: bookId, revision: expectedRevision + 1, entries: entries);
  }

  @override
  Future<ChapterTranslation> saveChapterTranslation(ChapterTranslation expected,
      {required String text}) async {
    saves++;
    lastExpected = expected;
    if (failure != null) throw failure!;
    return savePending?.call() ??
        ChapterTranslation.fromJson(chapterJson(text: text, revision: 1));
  }

  @override
  Future<TranslationRevision> fetchTranslationRevision(
          String bookId, int chapterIndex, String historyId) async =>
      TranslationRevision.fromJson({...historyJson, 'text': '历史译文'});
  @override
  Future<ChapterTranslation> restoreTranslationRevision(
      ChapterTranslation expected,
      {required String historyId}) async {
    restores++;
    return ChapterTranslation.fromJson(
        chapterJson(text: '历史译文', revision: expected.revision + 1));
  }

  @override
  Future<TranslationSuggestion> retranslateSelection(
      ChapterTranslation expected,
      {required String operationId,
      required int sourceStart,
      required int sourceEnd}) async {
    calls++;
    operationIds.add(operationId);
    if (failure != null) throw failure!;
    return pending?.call() ?? TranslationSuggestion.fromJson(suggestionJson);
  }

  @override
  Future<List<Book>> fetchBooks() async {
    reloads++;
    return [];
  }
}
