/// Directory metadata is not a downloaded or imported bookshelf chapter.
class BookPreviewChapter {
  const BookPreviewChapter({
    required this.index,
    required this.title,
    this.url = '',
    this.pageCount = 0,
    this.accessRestricted = false,
  });

  factory BookPreviewChapter.fromJson(Map<String, dynamic> json, int index) =>
      BookPreviewChapter(
        index: index,
        title: json['title'] as String? ?? '未命名章节',
        url: json['url'] as String? ?? '',
        pageCount: (json['pageCount'] as num?)?.toInt() ?? 0,
        accessRestricted: json['accessRestricted'] == true,
      );

  final int index;
  final String title;
  final String url;
  final int pageCount;
  final bool accessRestricted;
}
