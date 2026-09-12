import 'book.dart';

class OfflineIdentity {
  const OfflineIdentity(
      {required this.connectionKey,
      required this.instanceId,
      required this.ownerId,
      required this.displayName,
      required this.versioning});
  final String connectionKey;
  final String instanceId;
  final String ownerId;
  final String displayName;
  final bool versioning;
  Map<String, dynamic> toJson() => {
        'connectionKey': connectionKey,
        'instanceId': instanceId,
        'ownerId': ownerId,
        'displayName': displayName,
        'versioning': versioning
      };
  factory OfflineIdentity.fromJson(Map<String, dynamic> json) =>
      OfflineIdentity(
          connectionKey: json['connectionKey'] as String,
          instanceId: json['instanceId'] as String,
          ownerId: json['ownerId'] as String,
          displayName: json['displayName'] as String,
          versioning: json['versioning'] == true);
}

class OfflineChapter {
  const OfflineChapter(
      {required this.index,
      required this.mode,
      required this.bundle,
      required this.bytes,
      required this.imageCount});
  final int index;
  final String mode;
  final String bundle;
  final int bytes;
  final int imageCount;
  String get key => '$mode:$index';
  Map<String, dynamic> toJson() => {
        'index': index,
        'mode': mode,
        'bundle': bundle,
        'bytes': bytes,
        'imageCount': imageCount
      };
  factory OfflineChapter.fromJson(Map<String, dynamic> json) {
    final chapter = OfflineChapter(
        index: json['index'] as int,
        mode: json['mode'] as String,
        bundle: json['bundle'] as String,
        bytes: json['bytes'] as int,
        imageCount: json['imageCount'] as int);
    if (chapter.index < 1 ||
        chapter.bytes < 0 ||
        chapter.imageCount < 0 ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(chapter.bundle) ||
        !const ['original', 'translated'].contains(chapter.mode)) {
      throw const FormatException('离线章节清单无效');
    }
    return chapter;
  }
}

class OfflineBook {
  const OfflineBook(
      {required this.detail, required this.chapters, required this.savedAt});
  final BookDetail detail;
  final List<OfflineChapter> chapters;
  final DateTime savedAt;
  int get bytes => chapters.fold(0, (sum, chapter) => sum + chapter.bytes);
  List<int> indices(String mode) =>
      chapters.where((c) => c.mode == mode).map((c) => c.index).toList()
        ..sort();
}

class OfflineCacheException implements Exception {
  const OfflineCacheException(this.message);
  final String message;
  @override
  String toString() => message;
}
