import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../core/models/audiobook_position.dart';

String audiobookContentDigest(List<String> chunks) =>
    sha256.convert(utf8.encode(chunks.join())).toString();

AudiobookPosition captureAudiobookPosition(
    {required int chapterIndex,
    required String mode,
    required int chunkIndex,
    required List<String> chunks}) {
  final index = chunks.isEmpty ? 0 : chunkIndex.clamp(0, chunks.length - 1);
  return AudiobookPosition(
      chapterIndex: chapterIndex,
      mode: mode,
      chunkIndex: index,
      characterOffset:
          chunks.take(index).fold(0, (total, text) => total + text.length),
      contentDigest: audiobookContentDigest(chunks));
}

int restoreAudiobookChunk(List<String> chunks, AudiobookPosition position) {
  if (chunks.isEmpty) return 0;
  if (audiobookContentDigest(chunks) == position.contentDigest) {
    return position.chunkIndex.clamp(0, chunks.length - 1);
  }
  var offset = 0;
  for (var index = 0; index < chunks.length; index++) {
    offset += chunks[index].length;
    if (offset > position.characterOffset) return index;
  }
  return chunks.length - 1;
}
