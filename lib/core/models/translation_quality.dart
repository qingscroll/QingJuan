import 'book.dart';

class GlossaryEntry {
  const GlossaryEntry(
      {required this.source,
      required this.target,
      this.kind = 'term',
      this.note = ''});
  factory GlossaryEntry.fromJson(JsonMap json) => GlossaryEntry(
      source: json['source'] as String,
      target: json['target'] as String,
      kind: json['kind'] as String,
      note: json['note'] as String? ?? '');
  final String source;
  final String target;
  final String kind;
  final String note;
  JsonMap toJson() =>
      {'source': source, 'target': target, 'kind': kind, 'note': note};
}

class BookGlossary {
  const BookGlossary(
      {required this.bookId,
      required this.revision,
      required this.entries,
      this.updatedAt});
  factory BookGlossary.fromJson(JsonMap json) => BookGlossary(
      bookId: json['bookId'] as String,
      revision: json['revision'] as int,
      entries: _maps(json['entries']).map(GlossaryEntry.fromJson).toList(),
      updatedAt: json['updatedAt'] as String?);
  final String bookId;
  final int revision;
  final List<GlossaryEntry> entries;
  final String? updatedAt;
}

class TranslationHistoryItem {
  const TranslationHistoryItem(
      {required this.id,
      required this.revision,
      required this.kind,
      required this.createdAt,
      required this.sourceHash,
      required this.translationHash});
  factory TranslationHistoryItem.fromJson(JsonMap json) =>
      TranslationHistoryItem(
          id: json['id'] as String,
          revision: json['revision'] as int,
          kind: json['kind'] as String,
          createdAt: json['createdAt'] as String,
          sourceHash: json['sourceHash'] as String,
          translationHash: json['translationHash'] as String);
  final String id;
  final int revision;
  final String kind;
  final String createdAt;
  final String sourceHash;
  final String translationHash;
  String get kindLabel => switch (kind) {
        'initial' => '初始译文',
        'edit' => '人工校对',
        'restore' => '历史恢复',
        'translate' => '模型翻译',
        _ => '外部更新',
      };
}

class TranslationRevision extends TranslationHistoryItem {
  const TranslationRevision(
      {required super.id,
      required super.revision,
      required super.kind,
      required super.createdAt,
      required super.sourceHash,
      required super.translationHash,
      required this.text});
  factory TranslationRevision.fromJson(JsonMap json) => TranslationRevision(
      id: json['id'] as String,
      revision: json['revision'] as int,
      kind: json['kind'] as String,
      createdAt: json['createdAt'] as String,
      sourceHash: json['sourceHash'] as String,
      translationHash: json['translationHash'] as String,
      text: json['text'] as String);
  final String text;
}

class ChapterTranslation {
  const ChapterTranslation(
      {required this.bookId,
      required this.chapterIndex,
      required this.title,
      required this.sourceText,
      required this.translatedText,
      required this.sourceHash,
      required this.translationHash,
      required this.revision,
      required this.history});
  factory ChapterTranslation.fromJson(JsonMap json) => ChapterTranslation(
      bookId: json['bookId'] as String,
      chapterIndex: json['chapterIndex'] as int,
      title: json['title'] as String,
      sourceText: json['sourceText'] as String,
      translatedText: json['translatedText'] as String,
      sourceHash: json['sourceHash'] as String,
      translationHash: json['translationHash'] as String,
      revision: json['revision'] as int,
      history:
          _maps(json['history']).map(TranslationHistoryItem.fromJson).toList());
  final String bookId;
  final int chapterIndex;
  final String title;
  final String sourceText;
  final String translatedText;
  final String sourceHash;
  final String translationHash;
  final int revision;
  final List<TranslationHistoryItem> history;
  JsonMap get casJson => {
        'expectedRevision': revision,
        'sourceHash': sourceHash,
        'translationHash': translationHash,
      };
}

class TranslationUsage {
  const TranslationUsage(
      {required this.id,
      required this.chapterIndex,
      required this.operation,
      required this.model,
      required this.durationMs,
      required this.status,
      required this.createdAt,
      this.inputTokens,
      this.outputTokens,
      this.totalTokens});
  factory TranslationUsage.fromJson(JsonMap json) => TranslationUsage(
      id: json['id'] as String,
      chapterIndex: json['chapterIndex'] as int,
      operation: json['operation'] as String,
      model: json['model'] as String,
      durationMs: json['durationMs'] as int,
      status: json['status'] as String,
      createdAt: json['createdAt'] as String,
      inputTokens: json['inputTokens'] as int?,
      outputTokens: json['outputTokens'] as int?,
      totalTokens: json['totalTokens'] as int?);
  final String id;
  final int chapterIndex;
  final String operation;
  final String model;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final int durationMs;
  final String status;
  final String createdAt;
}

class TranslationSuggestion {
  const TranslationSuggestion(
      {required this.operationId,
      required this.sourceStart,
      required this.sourceEnd,
      required this.text,
      this.usage});
  factory TranslationSuggestion.fromJson(JsonMap json) => TranslationSuggestion(
      operationId: json['operationId'] as String,
      sourceStart: json['sourceStart'] as int,
      sourceEnd: json['sourceEnd'] as int,
      text: json['text'] as String,
      usage: json['usage'] == null
          ? null
          : TranslationUsage.fromJson(
              Map<String, dynamic>.from(json['usage'] as Map)));
  final String operationId;
  final int sourceStart;
  final int sourceEnd;
  final String text;
  final TranslationUsage? usage;
}

Iterable<JsonMap> _maps(Object? value) =>
    (value as List).map((item) => Map<String, dynamic>.from(item as Map));
