import 'book_preview_chapter.dart';

typedef JsonMap = Map<String, dynamic>;

int _int(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;
double _double(Object? value, [double fallback = 0]) =>
    value is num ? value.toDouble() : fallback;
bool _bool(Object? value, [bool fallback = false]) =>
    value is bool ? value : fallback;
String _string(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;
List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

class Book {
  const Book({
    required this.id,
    required this.title,
    required this.sourceUrl,
    required this.kind,
    required this.language,
    required this.status,
    required this.chapterCount,
    required this.translated,
    required this.synopsis,
    required this.lastReadChapterIndex,
    this.cover,
    this.lastReadAt,
    this.lastReadPageIndex,
    this.lastReadPageCount,
    this.author = '',
    this.groupName,
    this.tags = const [],
    this.pinned = false,
    this.readingState = 'unread',
    this.metadataRevision = 0,
  });

  factory Book.fromJson(JsonMap json) => Book(
        id: _string(json['id']),
        title: _string(json['title'], '未命名作品'),
        sourceUrl: _string(json['sourceUrl']),
        kind: _string(json['bookKind'], '长小说'),
        language: _string(json['language'], '中文'),
        status: _string(json['status'], '待处理'),
        chapterCount: _int(json['chapterCount']),
        translated: _bool(json['translated']),
        synopsis: _string(json['synopsis']),
        cover: json['cover'] as String?,
        lastReadChapterIndex: _int(json['lastReadChapterIndex'], 1),
        lastReadAt: json['lastReadAt'] as String?,
        lastReadPageIndex: (json['lastReadPageIndex'] as num?)?.toInt(),
        lastReadPageCount: (json['lastReadPageCount'] as num?)?.toInt(),
        author: _string(json['author']),
        groupName: json['groupName'] as String?,
        tags: _strings(json['tags']),
        pinned: _bool(json['pinned']),
        readingState: _string(json['readingState'], 'unread'),
        metadataRevision: _int(json['metadataRevision']),
      );

  final String id;
  final String title;
  final String sourceUrl;
  final String kind;
  final String language;
  final String status;
  final int chapterCount;
  final bool translated;
  final String synopsis;
  final String? cover;
  final int lastReadChapterIndex;
  final String? lastReadAt;
  final int? lastReadPageIndex;
  final int? lastReadPageCount;
  final String author;
  final String? groupName;
  final List<String> tags;
  final bool pinned;
  final String readingState;
  final int metadataRevision;

  String get readingPositionLabel =>
      '第 $lastReadChapterIndex 章${lastReadPageIndex == null ? '' : ' · 第 ${lastReadPageIndex! + 1} 页'}';
}

class Chapter {
  const Chapter({
    required this.index,
    required this.title,
    required this.downloaded,
    required this.translated,
    required this.wordCount,
    required this.imageCount,
  });

  factory Chapter.fromJson(JsonMap json) => Chapter(
        index: _int(json['index']),
        title: _string(json['title'], '未命名章节'),
        downloaded: _bool(json['downloaded']),
        translated: _bool(json['translated']),
        wordCount: _int(json['wordCount']),
        imageCount: _int(json['imageCount']),
      );

  final int index;
  final String title;
  final bool downloaded;
  final bool translated;
  final int wordCount;
  final int imageCount;
}

class ReadingProgress {
  const ReadingProgress({
    required this.chapterIndex,
    required this.scrollRatio,
    this.anchorType = 'top',
    this.anchorIndex = 0,
    this.anchorOffsetRatio = 0,
    this.pageIndex,
    this.pageCount,
    this.layoutKey,
    this.contentMode,
    this.characterOffset,
    this.revision,
  });

  factory ReadingProgress.fromJson(JsonMap json) => ReadingProgress(
        chapterIndex: _int(json['lastChapterIndex'], 1),
        scrollRatio: _double(json['lastScrollRatio']),
        anchorType: _string(json['lastAnchorType'], 'top'),
        anchorIndex: _int(json['lastAnchorIndex']),
        anchorOffsetRatio: _double(json['lastAnchorOffsetRatio']),
        pageIndex: (json['lastPageIndex'] as num?)?.toInt(),
        pageCount: (json['lastPageCount'] as num?)?.toInt(),
        layoutKey: json['lastLayoutKey'] as String?,
        contentMode: json['lastContentMode'] as String?,
        characterOffset: (json['lastCharacterOffset'] as num?)?.toInt(),
        revision: (json['revision'] as num?)?.toInt(),
      );

  final int chapterIndex;
  final double scrollRatio;
  final String anchorType;
  final int anchorIndex;
  final double anchorOffsetRatio;
  final int? pageIndex;
  final int? pageCount;
  final String? layoutKey;
  final String? contentMode;
  final int? characterOffset;
  final int? revision;
}

class BookDetail {
  const BookDetail({
    required this.book,
    required this.author,
    required this.synopsis,
    required this.totalWords,
    required this.downloadedCount,
    required this.translatedCount,
    required this.progress,
    required this.chapters,
  });

  factory BookDetail.fromJson(JsonMap json) => BookDetail(
        book: Book.fromJson(json['book'] as JsonMap),
        author: json['author'] as String?,
        synopsis: _string(json['synopsis']),
        totalWords: _int(json['totalWords']),
        downloadedCount: _int(json['downloadedChapterCount']),
        translatedCount: _int(json['translatedChapterCount']),
        progress: ReadingProgress.fromJson(
            (json['progress'] as JsonMap?) ?? const {}),
        chapters: ((json['chapters'] as List?) ?? const [])
            .whereType<JsonMap>()
            .map(Chapter.fromJson)
            .toList(),
      );

  final Book book;
  final String? author;
  final String synopsis;
  final int totalWords;
  final int downloadedCount;
  final int translatedCount;
  final ReadingProgress progress;
  final List<Chapter> chapters;
}

class ChapterContent {
  const ChapterContent({
    required this.chapter,
    required this.content,
    required this.paragraphs,
    required this.mode,
    required this.translatedAvailable,
    required this.imageSources,
    required this.pageTranslations,
  });

  factory ChapterContent.fromJson(JsonMap json) => ChapterContent(
        chapter: Chapter.fromJson(json['chapter'] as JsonMap),
        content: _string(json['content']),
        paragraphs: _strings(json['paragraphs']),
        mode: _string(json['mode'], 'translated'),
        translatedAvailable: _bool(json['translatedAvailable']),
        imageSources: _strings(json['imageSources']),
        pageTranslations: _strings(json['pageTranslations']),
      );

  final Chapter chapter;
  final String content;
  final List<String> paragraphs;
  final String mode;
  final bool translatedAvailable;
  final List<String> imageSources;
  final List<String> pageTranslations;
}

class BookPreview {
  const BookPreview({
    required this.title,
    required this.author,
    required this.synopsis,
    required this.chapterCount,
    required this.kind,
    this.cover,
    this.chapters = const [],
    this.sourceStatus = 'unknown',
    this.sourceStatusEvidence,
  });

  factory BookPreview.fromJson(JsonMap json) => BookPreview(
        title: _string(json['title']),
        author: _string(json['author']),
        synopsis: _string(json['synopsis']),
        chapterCount: _int(json['chapterCount']),
        kind: _string(json['bookKind'], '长小说'),
        cover: json['cover'] as String?,
        chapters: ((json['chapters'] as List?) ?? const [])
            .indexed
            .where((entry) => entry.$2 is Map)
            .map((entry) => BookPreviewChapter.fromJson(
                Map<String, dynamic>.from(entry.$2 as Map), entry.$1 + 1))
            .toList(growable: false),
        sourceStatus: switch (json['sourceStatus']) {
          'ongoing' => 'ongoing',
          'completed' => 'completed',
          _ => 'unknown',
        },
        sourceStatusEvidence: json['sourceStatusEvidence'] as String?,
      );

  final String title;
  final String author;
  final String synopsis;
  final int chapterCount;
  final String kind;
  final String? cover;
  final List<BookPreviewChapter> chapters;
  final String sourceStatus;
  final String? sourceStatusEvidence;

  String get sourceStatusLabel => switch (sourceStatus) {
        'ongoing' => '连载中',
        'completed' => '已完结',
        _ => '状态未知',
      };
}
