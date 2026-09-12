import 'book.dart';

const readingStateLabels = <String, String>{
  'unread': '未读',
  'reading': '在读',
  'finished': '已读',
  'on_hold': '搁置',
};

class BookMetadata {
  const BookMetadata({
    required this.bookId,
    required this.title,
    required this.author,
    required this.synopsis,
    required this.revision,
    this.groupName,
    this.tags = const [],
    this.pinned = false,
    this.readingState = 'unread',
    this.updatedAt,
    this.overriddenFields = const [],
  });

  factory BookMetadata.fromJson(JsonMap json) => BookMetadata(
        bookId: json['bookId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        synopsis: json['synopsis'] as String? ?? '',
        groupName: json['groupName'] as String?,
        tags: List.unmodifiable(
            (json['tags'] as List? ?? []).whereType<String>()),
        pinned: json['pinned'] == true,
        readingState: json['readingState'] as String? ?? 'unread',
        revision: (json['revision'] as num?)?.toInt() ?? 0,
        updatedAt: json['updatedAt'] as String?,
        overriddenFields: List.unmodifiable(
            (json['overriddenFields'] as List? ?? []).whereType<String>()),
      );

  final String bookId;
  final String title;
  final String author;
  final String synopsis;
  final String? groupName;
  final List<String> tags;
  final bool pinned;
  final String readingState;
  final int revision;
  final String? updatedAt;
  final List<String> overriddenFields;

  Book applyTo(Book book) => Book(
        id: book.id,
        title: title,
        author: author,
        synopsis: synopsis,
        sourceUrl: book.sourceUrl,
        kind: book.kind,
        language: book.language,
        status: book.status,
        chapterCount: book.chapterCount,
        translated: book.translated,
        cover: book.cover,
        lastReadChapterIndex: book.lastReadChapterIndex,
        lastReadAt: book.lastReadAt,
        lastReadPageIndex: book.lastReadPageIndex,
        lastReadPageCount: book.lastReadPageCount,
        groupName: groupName,
        tags: tags,
        pinned: pinned,
        readingState: readingState,
        metadataRevision: revision,
      );
}
