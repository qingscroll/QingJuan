import 'book.dart';

class BookUpdate {
  const BookUpdate(
      {required this.bookId,
      this.enabled = false,
      this.automatic = false,
      this.supported = true,
      this.unsupportedReason,
      this.sourceStatus = 'unknown',
      this.sourceStatusCheckedAt,
      this.intervalHours = 6,
      this.autoDownload = false,
      this.revision = 0,
      this.checking = false,
      this.lastCheckedAt,
      this.nextCheckAt,
      this.lastError,
      this.newChapterCount = 0,
      this.latestChapterIndex = 0,
      this.acknowledgedChapterIndex = 0});

  factory BookUpdate.fromJson(JsonMap json) => BookUpdate(
      bookId: json['bookId'] as String? ?? '',
      enabled: json['enabled'] == true,
      automatic: json['automatic'] == true,
      supported: json['supported'] != false,
      unsupportedReason: json['unsupportedReason'] as String?,
      sourceStatus:
          const {'ongoing', 'completed'}.contains(json['sourceStatus'])
              ? json['sourceStatus'] as String
              : 'unknown',
      sourceStatusCheckedAt: json['sourceStatusCheckedAt'] as String?,
      intervalHours: (json['intervalHours'] as num?)?.toInt() ?? 6,
      autoDownload: json['autoDownload'] == true,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      checking: json['checking'] == true,
      lastCheckedAt: json['lastCheckedAt'] as String?,
      nextCheckAt: json['nextCheckAt'] as String?,
      lastError: json['lastError'] as String?,
      newChapterCount: (json['newChapterCount'] as num?)?.toInt() ?? 0,
      latestChapterIndex: (json['latestChapterIndex'] as num?)?.toInt() ?? 0,
      acknowledgedChapterIndex:
          (json['acknowledgedChapterIndex'] as num?)?.toInt() ?? 0);

  final String bookId;
  final bool enabled;
  final bool automatic;
  final bool supported;
  final String? unsupportedReason;
  final String sourceStatus;
  final String? sourceStatusCheckedAt;
  final int intervalHours;
  final bool autoDownload;
  final int revision;
  final bool checking;
  final String? lastCheckedAt;
  final String? nextCheckAt;
  final String? lastError;
  final int newChapterCount;
  final int latestChapterIndex;
  final int acknowledgedChapterIndex;

  String get sourceStatusLabel => switch (sourceStatus) {
        'ongoing' => '连载中',
        'completed' => '已完结',
        _ => '连载状态待确认',
      };
}
