class AudiobookPosition {
  const AudiobookPosition(
      {required this.chapterIndex,
      required this.mode,
      required this.chunkIndex,
      required this.characterOffset,
      required this.contentDigest});
  final int chapterIndex;
  final String mode;
  final int chunkIndex;
  final int characterOffset;
  final String contentDigest;

  Map<String, dynamic> toJson() => {
        'version': 1,
        'chapterIndex': chapterIndex,
        'mode': mode,
        'chunkIndex': chunkIndex,
        'characterOffset': characterOffset,
        'contentDigest': contentDigest
      };
  factory AudiobookPosition.fromJson(Map<String, dynamic> json) {
    final position = AudiobookPosition(
        chapterIndex: json['chapterIndex'] as int,
        mode: json['mode'] as String,
        chunkIndex: json['chunkIndex'] as int,
        characterOffset: json['characterOffset'] as int,
        contentDigest: json['contentDigest'] as String);
    if (json['version'] != 1 ||
        position.chapterIndex < 1 ||
        position.chunkIndex < 0 ||
        position.characterOffset < 0 ||
        !const ['original', 'translated'].contains(position.mode) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(position.contentDigest)) {
      throw const FormatException('听书位置格式无效');
    }
    return position;
  }
}
