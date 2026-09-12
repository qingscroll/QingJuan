import 'book.dart';

Map<String, dynamic> readingProgressJson(ReadingProgress value) => {
      'lastChapterIndex': value.chapterIndex,
      'lastScrollRatio': value.scrollRatio,
      'lastAnchorType': value.anchorType,
      'lastAnchorIndex': value.anchorIndex,
      'lastAnchorOffsetRatio': value.anchorOffsetRatio,
      'lastPageIndex': value.pageIndex,
      'lastPageCount': value.pageCount,
      'lastLayoutKey': value.layoutKey,
      'lastContentMode': value.contentMode,
      'lastCharacterOffset': value.characterOffset,
      if (value.revision != null) 'revision': value.revision,
    };

class PendingProgressWrite {
  const PendingProgressWrite(
      {required this.operationId,
      required this.expectedRevision,
      required this.position});
  final String operationId;
  final int expectedRevision;
  final ReadingProgress position;
  factory PendingProgressWrite.fromJson(Map<String, dynamic> json) {
    final value = PendingProgressWrite(
      operationId: json['operationId'] as String,
      expectedRevision: json['expectedRevision'] as int,
      position: ReadingProgress.fromJson(
          Map<String, dynamic>.from(json['position'] as Map)),
    );
    if (value.expectedRevision < 0 ||
        !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(value.operationId)) {
      throw const FormatException('待提交进度的版本或操作标识无效');
    }
    return value;
  }
  Map<String, dynamic> toJson() => {
        'operationId': operationId,
        'expectedRevision': expectedRevision,
        'position': readingProgressJson(position)
      };
}

class PendingReadingProgress {
  const PendingReadingProgress(
      {required this.baseRevision, this.sending, this.queued, this.conflict});
  final int baseRevision;
  final PendingProgressWrite? sending;
  final ReadingProgress? queued;
  final ReadingProgress? conflict;
  ReadingProgress? get localPosition => queued ?? sending?.position;

  factory PendingReadingProgress.fromJson(Map<String, dynamic> json) {
    ReadingProgress? position(Object? value) => value == null
        ? null
        : ReadingProgress.fromJson(Map<String, dynamic>.from(value as Map));
    final value = PendingReadingProgress(
        baseRevision: json['baseRevision'] as int,
        sending: json['sending'] == null
            ? null
            : PendingProgressWrite.fromJson(
                Map<String, dynamic>.from(json['sending'] as Map)),
        queued: position(json['queued']),
        conflict: position(json['conflict']));
    if (value.baseRevision < 0 ||
        (value.conflict != null &&
            (value.conflict!.revision == null ||
                value.conflict!.revision! < 0))) {
      throw const FormatException('待提交进度的版本无效');
    }
    return value;
  }
  Map<String, dynamic> toJson() => {
        'baseRevision': baseRevision,
        if (sending != null) 'sending': sending!.toJson(),
        if (queued != null) 'queued': readingProgressJson(queued!),
        if (conflict != null) 'conflict': readingProgressJson(conflict!)
      };
}
