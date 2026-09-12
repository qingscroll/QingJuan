import 'book.dart';

class AnnotationPosition {
  const AnnotationPosition(this.progress);
  final ReadingProgress progress;
  factory AnnotationPosition.fromJson(Map<String, dynamic> json) =>
      AnnotationPosition(ReadingProgress(
        chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 1,
        scrollRatio: (json['scrollRatio'] as num?)?.toDouble() ?? 0,
        anchorType: json['anchorType'] as String? ?? 'top',
        anchorIndex: (json['anchorIndex'] as num?)?.toInt() ?? 0,
        anchorOffsetRatio: (json['anchorOffsetRatio'] as num?)?.toDouble() ?? 0,
        pageIndex: (json['pageIndex'] as num?)?.toInt(),
        pageCount: (json['pageCount'] as num?)?.toInt(),
        layoutKey: json['layoutKey'] as String?,
        contentMode: json['contentMode'] as String?,
        characterOffset: (json['characterOffset'] as num?)?.toInt(),
      ));
  Map<String, dynamic> toJson() => {
        'chapterIndex': progress.chapterIndex,
        'scrollRatio': progress.scrollRatio,
        'anchorType': progress.anchorType,
        'anchorIndex': progress.anchorIndex,
        'anchorOffsetRatio': progress.anchorOffsetRatio,
        'pageIndex': progress.pageIndex,
        'pageCount': progress.pageCount,
        'layoutKey': progress.layoutKey,
        'contentMode': progress.contentMode,
        'characterOffset': progress.characterOffset,
      };
}

class ReadingAnnotation {
  const ReadingAnnotation(
      {required this.id,
      required this.bookId,
      required this.kind,
      required this.label,
      required this.quote,
      required this.note,
      required this.position,
      required this.revision,
      required this.createdAt,
      required this.updatedAt,
      this.contentHash,
      this.contentChanged = false});
  factory ReadingAnnotation.fromJson(Map<String, dynamic> json) =>
      ReadingAnnotation(
          id: json['id'] as String,
          bookId: json['bookId'] as String,
          kind: json['kind'] as String,
          label: json['label'] as String? ?? '',
          quote: json['quote'] as String? ?? '',
          note: json['note'] as String? ?? '',
          position: AnnotationPosition.fromJson(
              json['position'] as Map<String, dynamic>),
          revision: (json['revision'] as num).toInt(),
          createdAt: json['createdAt'] as String? ?? '',
          updatedAt: json['updatedAt'] as String? ?? '',
          contentHash: json['contentHash'] as String?,
          contentChanged: json['contentChanged'] == true);
  final String id, bookId, kind, label, quote, note, createdAt, updatedAt;
  final AnnotationPosition position;
  final int revision;
  final String? contentHash;
  final bool contentChanged;
}

class CachedTextHit {
  const CachedTextHit(
      {required this.chapterTitle,
      required this.snippet,
      required this.position,
      required this.contentHash});
  factory CachedTextHit.fromJson(Map<String, dynamic> json) => CachedTextHit(
      chapterTitle: json['chapterTitle'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
      position:
          AnnotationPosition.fromJson(json['position'] as Map<String, dynamic>),
      contentHash: json['contentHash'] as String);
  final String chapterTitle, snippet, contentHash;
  final AnnotationPosition position;
}

class CachedTextResults {
  const CachedTextResults(
      {required this.results,
      this.nextCursor,
      this.scannedChapters = 0,
      this.uncachedChapters = 0,
      this.skippedChapters = 0,
      this.truncated = false});
  factory CachedTextResults.fromJson(Map<String, dynamic> json) {
    if (json['offsetEncoding'] != 'utf-16') {
      throw const FormatException('服务返回了不支持的阅读位置格式');
    }
    return CachedTextResults(
        results: (json['results'] as List)
            .map((item) => CachedTextHit.fromJson(item as Map<String, dynamic>))
            .toList(),
        nextCursor: json['nextCursor'] as String?,
        scannedChapters: (json['scannedChapters'] as num?)?.toInt() ?? 0,
        uncachedChapters: (json['uncachedChapters'] as num?)?.toInt() ?? 0,
        skippedChapters: (json['skippedChapters'] as num?)?.toInt() ?? 0,
        truncated: json['truncated'] == true);
  }
  final List<CachedTextHit> results;
  final String? nextCursor;
  final int scannedChapters, uncachedChapters, skippedChapters;
  final bool truncated;
}
