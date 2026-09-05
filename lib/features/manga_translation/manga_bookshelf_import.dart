import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/book.dart';

class MangaBookshelfImportRequest {
  MangaBookshelfImportRequest({
    required this.workspaceIdentity,
    required this.bookId,
    required this.bookTitle,
    required this.language,
    Iterable<int> chapterIndexes = const <int>[],
  }) : chapterIndexes = (chapterIndexes.toSet().toList()..sort());

  factory MangaBookshelfImportRequest.fromBook(
    Book book, {
    required String workspaceIdentity,
    Iterable<int> chapterIndexes = const <int>[],
  }) {
    return MangaBookshelfImportRequest(
      workspaceIdentity: workspaceIdentity,
      bookId: book.id,
      bookTitle: book.title,
      language: book.language,
      chapterIndexes: chapterIndexes,
    );
  }

  final String workspaceIdentity;
  final String bookId;
  final String bookTitle;
  final String language;
  final List<int> chapterIndexes;

  String get deduplicationKey => <String>[
        workspaceIdentity,
        bookId,
        chapterIndexes.join(','),
      ].join('|');
}

class MangaBookshelfImportProgress {
  const MangaBookshelfImportProgress({
    required this.message,
    required this.completedPages,
    required this.totalPages,
  });

  final String message;
  final int completedPages;
  final int totalPages;
}

class MangaBookshelfPageTarget {
  const MangaBookshelfPageTarget({
    required this.bookId,
    required this.chapterIndex,
    required this.pageNumber,
  });

  final String bookId;
  final int chapterIndex;
  final int pageNumber;
}

class MangaBookshelfImportResult {
  const MangaBookshelfImportResult({
    required this.bookId,
    required this.bookTitle,
    required this.sourceRoot,
    required this.filePaths,
    required this.chapterCount,
    this.pageTargets = const <String, MangaBookshelfPageTarget>{},
  });

  final String bookId;
  final String bookTitle;
  final String sourceRoot;
  final List<String> filePaths;
  final int chapterCount;
  final Map<String, MangaBookshelfPageTarget> pageTargets;
}

class MangaBookshelfImportCancelled implements Exception {
  const MangaBookshelfImportCancelled();

  @override
  String toString() => '书架漫画导入已取消';
}

typedef MangaBookshelfImportInvoker = Future<MangaBookshelfImportResult>
    Function(
  MangaBookshelfImportRequest request, {
  void Function(MangaBookshelfImportProgress progress)? onProgress,
  Future<void>? abortTrigger,
});

class MangaBookshelfImporter {
  MangaBookshelfImporter(
    this._api, {
    Future<Directory> Function()? resolveApplicationSupportDirectory,
  }) : _resolveApplicationSupportDirectory =
            resolveApplicationSupportDirectory ??
                getApplicationSupportDirectory;

  final ApiClient _api;
  final Future<Directory> Function() _resolveApplicationSupportDirectory;

  Future<MangaBookshelfImportResult> importBook(
    MangaBookshelfImportRequest request, {
    void Function(MangaBookshelfImportProgress progress)? onProgress,
    Future<void>? abortTrigger,
  }) async {
    final detail = await _withAbort(
      _api.fetchBookDetail(request.bookId),
      abortTrigger,
    );
    if (detail.book.kind != '漫画') {
      throw const ApiException('只有漫画书籍可以导入漫画翻译工作台');
    }

    final selectedIndexes = request.chapterIndexes.isEmpty
        ? detail.chapters.map((chapter) => chapter.index).toList()
        : List<int>.from(request.chapterIndexes);
    if (selectedIndexes.isEmpty) {
      throw const ApiException('这本漫画还没有可导入的章节');
    }
    final chaptersByIndex = <int, Chapter>{
      for (final chapter in detail.chapters) chapter.index: chapter,
    };
    final missing = selectedIndexes
        .where((chapterIndex) => !chaptersByIndex.containsKey(chapterIndex))
        .toList();
    if (missing.isNotEmpty) {
      throw ApiException('找不到所选章节：${missing.join('、')}');
    }

    final supportDirectory =
        await _withAbort(_resolveApplicationSupportDirectory(), abortTrigger);
    final workspaceHash = _stableHash(request.workspaceIdentity);
    final bookDirectory = Directory(
      path.join(
        supportDirectory.path,
        'manga_translation',
        'bookshelf',
        workspaceHash,
        _safeIdentifier(request.bookId),
      ),
    );
    final sourceDirectory = Directory(path.join(bookDirectory.path, 'source'));
    await sourceDirectory.create(recursive: true);

    var completedPages = 0;
    var totalPages = selectedIndexes.fold<int>(
      0,
      (total, chapterIndex) =>
          total + (chaptersByIndex[chapterIndex]?.imageCount ?? 0),
    );
    final importedPaths = <String>[];
    final pageTargets = <String, MangaBookshelfPageTarget>{};
    for (final chapterIndex in selectedIndexes) {
      final chapter = chaptersByIndex[chapterIndex]!;
      onProgress?.call(
        MangaBookshelfImportProgress(
          message: '正在读取 ${chapter.index}. ${chapter.title}',
          completedPages: completedPages,
          totalPages: totalPages,
        ),
      );
      final content = await _withAbort(
        _api.fetchChapter(
          request.bookId,
          chapter.index,
          mode: 'original',
          prefetch: true,
        ),
        abortTrigger,
      );
      if (content.imageSources.isEmpty) {
        throw ApiException('${chapter.index}. ${chapter.title} 没有可导入的漫画图片');
      }
      totalPages += content.imageSources.length - chapter.imageCount;
      if (totalPages < completedPages + content.imageSources.length) {
        totalPages = completedPages + content.imageSources.length;
      }

      final chapterDirectory = Directory(
        path.join(
          sourceDirectory.path,
          '${chapter.index.toString().padLeft(4, '0')}-${_safeSegment(chapter.title)}',
        ),
      );
      await chapterDirectory.create(recursive: true);
      final currentChapterTargets = <String>{};
      for (var pageIndex = 0;
          pageIndex < content.imageSources.length;
          pageIndex++) {
        final source = content.imageSources[pageIndex];
        final extension = _supportedExtension(source);
        final target = File(
          path.join(
            chapterDirectory.path,
            'page-${(pageIndex + 1).toString().padLeft(4, '0')}$extension',
          ),
        );
        currentChapterTargets.add(_pathKey(target.path));
        onProgress?.call(
          MangaBookshelfImportProgress(
            message:
                '正在导入 ${chapter.index}. ${chapter.title} · 第 ${pageIndex + 1}/${content.imageSources.length} 页',
            completedPages: completedPages,
            totalPages: totalPages,
          ),
        );
        await _api.downloadUrlToFile(
          source,
          target.path,
          abortTrigger: abortTrigger,
        );
        importedPaths.add(target.path);
        pageTargets[_pathKey(target.path)] = MangaBookshelfPageTarget(
          bookId: request.bookId,
          chapterIndex: chapter.index,
          pageNumber: pageIndex + 1,
        );
        completedPages += 1;
        onProgress?.call(
          MangaBookshelfImportProgress(
            message:
                '已导入 ${chapter.index}. ${chapter.title} · $completedPages/$totalPages 页',
            completedPages: completedPages,
            totalPages: totalPages,
          ),
        );
      }
      await _removeStaleManagedPages(
        chapterDirectory,
        currentChapterTargets,
      );
    }

    if (importedPaths.isEmpty) {
      throw const ApiException('这本漫画没有可导入的图片');
    }
    return MangaBookshelfImportResult(
      bookId: request.bookId,
      bookTitle: request.bookTitle,
      sourceRoot: bookDirectory.path,
      filePaths: importedPaths,
      chapterCount: selectedIndexes.length,
      pageTargets: pageTargets,
    );
  }

  Future<T> _withAbort<T>(
    Future<T> operation,
    Future<void>? abortTrigger,
  ) {
    if (abortTrigger == null) return operation;
    return Future.any<T>(<Future<T>>[
      operation,
      abortTrigger.then<T>(
        (_) => throw const MangaBookshelfImportCancelled(),
      ),
    ]);
  }

  Future<void> _removeStaleManagedPages(
    Directory directory,
    Set<String> retainedPaths,
  ) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File ||
          !RegExp(r'^page-\d{4}\.[^.]+$', caseSensitive: false)
              .hasMatch(path.basename(entity.path)) ||
          retainedPaths.contains(_pathKey(entity.path))) {
        continue;
      }
      await entity.delete();
    }
  }

  String _supportedExtension(String source) {
    final resolved = _api.resolveUrl(source);
    final uri = Uri.tryParse(resolved);
    final extension =
        path.extension(Uri.decodeComponent(uri?.path ?? '')).toLowerCase();
    return const <String>{
      '.png',
      '.jpg',
      '.jpeg',
      '.jfif',
      '.webp',
      '.avif',
      '.bmp',
      '.tif',
      '.tiff',
      '.heic',
      '.heif',
    }.contains(extension)
        ? extension
        : '.png';
  }

  String _safeIdentifier(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').trim();
    if (safe.isEmpty) return _stableHash(value);
    return safe.length > 64 ? safe.substring(0, 64) : safe;
  }

  String _safeSegment(String value) {
    var safe = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]+'), '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty) safe = '未命名章节';
    if (safe.length > 72) safe = safe.substring(0, 72).trimRight();
    return safe;
  }

  String _stableHash(String value) {
    var hash = 0x811C9DC5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _pathKey(String value) {
    final normalized = path.normalize(File(value).absolute.path);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
