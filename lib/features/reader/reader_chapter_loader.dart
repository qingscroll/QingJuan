import '../../core/models/book.dart';

typedef ReaderChapterLoader = Future<ChapterContent>
    Function(String bookId, int chapterIndex, {String mode, bool prefetch});
