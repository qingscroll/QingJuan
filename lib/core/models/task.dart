import 'book.dart';

class BookTask {
  const BookTask({
    required this.id,
    required this.bookId,
    required this.type,
    required this.status,
    required this.totalCount,
    required this.completedCount,
    required this.progress,
    required this.message,
    required this.attempts,
    required this.updatedAt,
    this.error,
  });

  factory BookTask.fromJson(JsonMap json) => BookTask(
        id: json['id'] as String? ?? '',
        bookId: json['bookId'] as String? ?? '',
        type: json['taskType'] as String? ?? '',
        status: json['status'] as String? ?? 'queued',
        totalCount: (json['totalCount'] as num?)?.toInt() ?? 0,
        completedCount: (json['completedCount'] as num?)?.toInt() ?? 0,
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        message: json['message'] as String? ?? '',
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        updatedAt: json['updatedAt'] as String? ?? '',
        error: json['error'] as String?,
      );

  final String id;
  final String bookId;
  final String type;
  final String status;
  final int totalCount;
  final int completedCount;
  final double progress;
  final String message;
  final int attempts;
  final String updatedAt;
  final String? error;

  bool get isActive => const [
        'queued',
        'running',
        'pause_requested',
        'cancel_requested'
      ].contains(status);
  bool get canPause => status == 'queued' || status == 'running';
  bool get canResume => status == 'paused';
  bool get canCancel =>
      canPause ||
      canResume ||
      status == 'pause_requested' ||
      status == 'failed';
  String get statusLabel => switch (status) {
        'queued' => '等待中',
        'running' => '进行中',
        'pause_requested' => '正在暂停',
        'paused' => '已暂停',
        'cancel_requested' => '正在取消',
        'cancelled' => '已取消',
        'completed' => '已完成',
        'failed' => '失败',
        _ => status,
      };
}

class TaskPageText {
  const TaskPageText({
    required this.order,
    required this.sourceText,
    required this.translation,
  });

  factory TaskPageText.fromJson(JsonMap json) => TaskPageText(
        order: (json['order'] as num?)?.toInt() ?? 0,
        sourceText: json['sourceText'] as String? ?? '',
        translation: json['translation'] as String? ?? '',
      );

  final int order;
  final String sourceText;
  final String translation;
}

class TaskPageResult {
  const TaskPageResult({
    required this.sequence,
    required this.taskId,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.pageNumber,
    required this.totalPages,
    required this.texts,
  });

  factory TaskPageResult.fromJson(JsonMap json) => TaskPageResult(
        sequence: (json['sequence'] as num?)?.toInt() ?? 0,
        taskId: json['taskId'] as String? ?? '',
        chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
        chapterTitle: json['chapterTitle'] as String? ?? '',
        pageNumber: (json['pageNumber'] as num?)?.toInt() ?? 0,
        totalPages: (json['totalPages'] as num?)?.toInt() ?? 0,
        texts: (json['texts'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<JsonMap>()
            .map(TaskPageText.fromJson)
            .toList(growable: false),
      );

  final int sequence;
  final String taskId;
  final int chapterIndex;
  final String chapterTitle;
  final int pageNumber;
  final int totalPages;
  final List<TaskPageText> texts;

  String get displayText => texts
      .map((text) {
        final source = text.sourceText.trim();
        final translation = text.translation.trim();
        if (source.isNotEmpty && translation.isNotEmpty) {
          return '$source → $translation';
        }
        return source.isNotEmpty ? source : translation;
      })
      .where((text) => text.isNotEmpty)
      .join('\n');
}
