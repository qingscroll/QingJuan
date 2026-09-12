import 'book.dart';

class LinkJobLog {
  const LinkJobLog({
    required this.sequence,
    required this.level,
    required this.message,
    required this.createdAt,
  });

  factory LinkJobLog.fromJson(JsonMap json) => LinkJobLog(
        sequence: (json['sequence'] as num?)?.toInt() ?? 0,
        level: json['level'] as String? ?? 'info',
        message: json['message'] as String? ?? '',
        createdAt: json['createdAt'] as String? ?? '',
      );

  final int sequence;
  final String level;
  final String message;
  final String createdAt;
}

class LinkJob {
  const LinkJob({
    required this.id,
    required this.mode,
    required this.status,
    required this.progress,
    required this.message,
    required this.logs,
    required this.createdAt,
    required this.updatedAt,
    this.preview,
    this.book,
    this.error,
    this.sourceUrl = '',
  });

  factory LinkJob.fromJson(JsonMap json) {
    final logs = (json['logs'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => LinkJobLog.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
    final preview = json['preview'];
    final book = json['book'];
    return LinkJob(
      id: json['id'] as String? ?? '',
      sourceUrl: json['sourceUrl'] as String? ?? '',
      mode: json['mode'] as String? ?? 'preview',
      status: json['status'] as String? ?? 'queued',
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      message: json['message'] as String? ?? '',
      logs: logs,
      preview: preview is Map
          ? BookPreview.fromJson(Map<String, dynamic>.from(preview))
          : null,
      book: book is Map ? Book.fromJson(Map<String, dynamic>.from(book)) : null,
      error: json['error'] as String?,
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
    );
  }

  final String id;
  final String mode;
  final String sourceUrl;
  final String status;
  final double progress;
  final String message;
  final List<LinkJobLog> logs;
  final BookPreview? preview;
  final Book? book;
  final String? error;
  final String createdAt;
  final String updatedAt;

  bool get isActive => status == 'queued' || status == 'running';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
}
