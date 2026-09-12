import '../../core/models/book.dart';
import '../../core/models/offline_cache.dart';
import '../../core/models/reading_progress_pending.dart';

BookDetail offlineWithProgress(BookDetail value, ReadingProgress progress) =>
    BookDetail(
        book: value.book,
        author: value.author,
        synopsis: value.synopsis,
        totalWords: value.totalWords,
        downloadedCount: value.downloadedCount,
        translatedCount: value.translatedCount,
        progress: progress,
        chapters: value.chapters);

Map<String, dynamic> offlineChapterJson(Chapter value) => {
      'index': value.index,
      'title': value.title,
      'downloaded': value.downloaded,
      'translated': value.translated,
      'wordCount': value.wordCount,
      'imageCount': value.imageCount
    };

// Cache only display metadata. Source/cover URLs can contain temporary credentials.
Map<String, dynamic> offlineDetailJson(BookDetail value) => {
      'book': {
        'id': value.book.id,
        'title': value.book.title,
        'sourceUrl': '',
        'bookKind': value.book.kind,
        'language': value.book.language,
        'status': value.book.status,
        'chapterCount': value.chapters.length,
        'translated': value.book.translated,
        'synopsis': value.synopsis,
        'lastReadChapterIndex': value.progress.chapterIndex
      },
      'author': value.author,
      'synopsis': value.synopsis,
      'totalWords': value.totalWords,
      'downloadedChapterCount': value.downloadedCount,
      'translatedChapterCount': value.translatedCount,
      'progress': readingProgressJson(value.progress),
      'chapters': value.chapters.map(offlineChapterJson).toList()
    };

Map<String, dynamic> offlineContentJson(ChapterContent value) => {
      'chapter': offlineChapterJson(value.chapter),
      'content': value.content,
      'paragraphs': value.paragraphs,
      'mode': value.mode,
      'translatedAvailable': value.translatedAvailable,
      'imageSources': <String>[],
      'pageTranslations': value.pageTranslations
    };

Map<String, dynamic> offlineBookJson(OfflineBook value) => {
      'version': 1,
      'detail': offlineDetailJson(value.detail),
      'chapters': value.chapters.map((c) => c.toJson()).toList(),
      'savedAt': value.savedAt.toUtc().toIso8601String()
    };

OfflineBook offlineBookFromJson(Map<String, dynamic> json) {
  if (json['version'] != 1) throw const FormatException('离线书籍版本无效');
  return OfflineBook(
      detail:
          BookDetail.fromJson(Map<String, dynamic>.from(json['detail'] as Map)),
      chapters: (json['chapters'] as List)
          .map((c) =>
              OfflineChapter.fromJson(Map<String, dynamic>.from(c as Map)))
          .toList(),
      savedAt: DateTime.parse(json['savedAt'] as String));
}
