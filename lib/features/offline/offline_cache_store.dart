import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core/models/book.dart';
import '../../core/models/offline_cache.dart';
import 'offline_codec.dart';
import 'offline_files.dart';

class OfflineCacheStore {
  OfflineCacheStore(
      {Future<Directory> Function()? directory,
      this.limitBytes = 512 * 1024 * 1024})
      : directory = directory ?? getApplicationSupportDirectory;
  final Future<Directory> Function() directory;
  final int limitBytes;

  Future<Directory> _root() async =>
      Directory(path.join((await directory()).path, 'offline-v1'));
  Future<Directory> _identityRoot(OfflineIdentity identity) async =>
      Directory(path.join((await _root()).path, 'books',
          offlineHash([identity.instanceId, identity.ownerId])));
  Future<Directory> _bookRoot(OfflineIdentity identity, String bookId) async =>
      Directory(
          path.join((await _identityRoot(identity)).path, offlineHash(bookId)));
  Future<Directory> _identityPointer(String key) async => Directory(
      path.join((await _root()).path, 'identities', offlineHash(key)));

  Future<void> remember(OfflineIdentity identity) async {
    final root = await _identityPointer(identity.connectionKey);
    await OfflineFiles.locked(
        root.path, () => OfflineFiles.publish(root, identity.toJson()));
  }

  Future<OfflineIdentity?> recall(String key) async {
    final root = await _identityPointer(key);
    return OfflineFiles.locked(root.path, () async {
      final json = await OfflineFiles.read(root);
      if (json == null || json['forgotten'] == true) return null;
      final identity = OfflineIdentity.fromJson(json);
      return identity.connectionKey == key ? identity : null;
    });
  }

  Future<void> forget(String key) async {
    final root = await _identityPointer(key);
    await OfflineFiles.locked(
        root.path, () => OfflineFiles.publish(root, {'forgotten': true}));
  }

  Future<List<OfflineBook>> list(OfflineIdentity identity) async {
    final root = await _identityRoot(identity);
    if (!await root.exists()) return [];
    final result = <OfflineBook>[];
    await for (final item in root.list(followLinks: false)) {
      if (item is! Directory) continue;
      final json =
          await OfflineFiles.locked(item.path, () => OfflineFiles.read(item));
      if (json == null) continue;
      final book = offlineBookFromJson(json);
      if (path.basename(item.path) != offlineHash(book.detail.book.id)) {
        throw const OfflineCacheException('离线书籍归属校验失败');
      }
      if (book.chapters.isNotEmpty) result.add(book);
    }
    result.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return result;
  }

  Future<OfflineBook?> find(OfflineIdentity identity, String bookId) async {
    final root = await _bookRoot(identity, bookId);
    final json =
        await OfflineFiles.locked(root.path, () => OfflineFiles.read(root));
    if (json == null) return null;
    final book = offlineBookFromJson(json);
    if (book.detail.book.id != bookId) {
      throw const OfflineCacheException('离线书籍归属校验失败');
    }
    return book;
  }

  Future<int> bytesUsed(OfflineIdentity identity) async {
    final root = await _identityRoot(identity);
    return OfflineFiles.locked(root.path, () => _measureBytes(root));
  }

  Future<int> _measureBytes(Directory root) async {
    if (!await root.exists()) return 0;
    var bytes = 0;
    await for (final item in root.list(recursive: true, followLinks: false)) {
      if (item is File) bytes += await item.length();
    }
    return bytes;
  }

  Future<void> saveChapter(
      OfflineIdentity identity, BookDetail detail, ChapterContent content,
      {required Future<List<int>> Function(String) imageLoader,
      required bool Function() isCurrent}) async {
    final root = await _bookRoot(identity, detail.book.id);
    final identityRoot = await _identityRoot(identity);
    await OfflineFiles.locked(
        identityRoot.path,
        () => OfflineFiles.locked(root.path, () async {
              if (!isCurrent()) return;
              await root.create(recursive: true);
              final nonce = offlineNonce();
              final stage = Directory(path.join(root.path, 'staging-$nonce'));
              final bundle = Directory(path.join(root.path, nonce));
              await stage.create();
              var committed = false;
              try {
                final remaining =
                    limitBytes - await _measureBytes(identityRoot);
                var total = 0;
                Future<void> write(String name, List<int> bytes) async {
                  total += bytes.length;
                  if (total > remaining || total > 64 * 1024 * 1024) {
                    throw const OfflineCacheException('离线容量不足，请先清理已保存章节');
                  }
                  await File(path.join(stage.path, name))
                      .writeAsBytes(bytes, flush: true);
                }

                final body =
                    utf8.encode(jsonEncode(offlineContentJson(content)));
                if (body.length > 16 * 1024 * 1024) {
                  throw const OfflineCacheException('章节正文过大，无法离线保存');
                }
                await write('content.json', body);
                for (var index = 0;
                    index < content.imageSources.length;
                    index++) {
                  final bytes = await imageLoader(content.imageSources[index]);
                  if (!isCurrent()) return;
                  if (bytes.isEmpty) {
                    throw const OfflineCacheException('图片内容为空，章节未保存');
                  }
                  await write('image-$index.bin', bytes);
                }
                if (!isCurrent()) return;
                await stage.rename(bundle.path);
                final json = await OfflineFiles.read(root);
                final previous =
                    json == null ? null : offlineBookFromJson(json);
                final entry = OfflineChapter(
                    index: content.chapter.index,
                    mode: content.mode,
                    bundle: nonce,
                    bytes: total,
                    imageCount: content.imageSources.length);
                final book = OfflineBook(
                    detail: previous != null &&
                            (previous.detail.progress.revision ?? -1) >
                                (detail.progress.revision ?? -1)
                        ? offlineWithProgress(detail, previous.detail.progress)
                        : detail,
                    savedAt: DateTime.now(),
                    chapters: [
                      ...?previous?.chapters.where((c) => c.key != entry.key),
                      entry
                    ]);
                final manifest = offlineBookJson(book);
                final manifestBytes = utf8.encode(jsonEncode(manifest)).length;
                if (manifestBytes > 16 * 1024 * 1024 ||
                    total + manifestBytes > remaining) {
                  throw const OfflineCacheException('离线容量不足，请先清理已保存章节');
                }
                committed = await OfflineFiles.publish(root, manifest,
                    isCurrent: isCurrent);
                if (committed) await _cleanBundles(root, book);
              } finally {
                if (await stage.exists()) await stage.delete(recursive: true);
                if (!committed && await bundle.exists()) {
                  await bundle.delete(recursive: true);
                }
              }
            }));
  }

  Future<ChapterContent> loadChapter(OfflineIdentity identity, String bookId,
      int chapterIndex, String mode) async {
    final root = await _bookRoot(identity, bookId);
    return OfflineFiles.locked(root.path, () async {
      final json = await OfflineFiles.read(root);
      final book = json == null ? null : offlineBookFromJson(json);
      final entries = book?.chapters
          .where((c) => c.index == chapterIndex && c.mode == mode);
      if (entries == null || entries.isEmpty) {
        throw OfflineCacheException(
            '第 $chapterIndex 章${mode == 'original' ? '原文' : '译文'}尚未保存到本机，请联网后选章保存');
      }
      final entry = entries.first;
      final bundle = Directory(path.join(root.path, entry.bundle));
      final file = File(path.join(bundle.path, 'content.json'));
      if (!await file.exists() || await file.length() > 16 * 1024 * 1024) {
        throw const OfflineCacheException('离线章节不完整，请联网后重新保存');
      }
      final content = ChapterContent.fromJson(Map<String, dynamic>.from(
          jsonDecode(await file.readAsString()) as Map));
      if (content.chapter.index != chapterIndex || content.mode != mode) {
        throw const OfflineCacheException('离线章节校验失败，请重新保存');
      }
      final images = <String>[];
      for (var index = 0; index < entry.imageCount; index++) {
        final image = File(path.join(bundle.path, 'image-$index.bin'));
        if (!await image.exists() || await image.length() == 0) {
          throw const OfflineCacheException('离线图片不完整，请联网后重新保存');
        }
        images.add(image.uri.toString());
      }
      return ChapterContent(
          chapter: content.chapter,
          content: content.content,
          paragraphs: content.paragraphs,
          mode: mode,
          translatedAvailable: content.translatedAvailable,
          imageSources: images,
          pageTranslations: content.pageTranslations);
    });
  }

  Future<void> remove(OfflineIdentity identity, String bookId,
      {Set<int>? indices, String? mode}) async {
    final root = await _bookRoot(identity, bookId);
    final identityRoot = await _identityRoot(identity);
    await OfflineFiles.locked(
        identityRoot.path,
        () => OfflineFiles.locked(root.path, () async {
              final json = await OfflineFiles.read(root);
              if (json == null) return;
              final previous = offlineBookFromJson(json);
              final book = OfflineBook(
                  detail: previous.detail,
                  savedAt: previous.savedAt,
                  chapters: previous.chapters
                      .where((entry) => !((indices == null ||
                              indices.contains(entry.index)) &&
                          (mode == null || entry.mode == mode)))
                      .toList());
              await OfflineFiles.publish(root, offlineBookJson(book));
              await _cleanBundles(root, book);
            }));
  }

  Future<void> clear(OfflineIdentity identity) async {
    final root = await _identityRoot(identity);
    await OfflineFiles.locked(root.path, () async {
      if (!await root.exists()) return;
      await for (final entry in root.list(followLinks: false)) {
        if (entry is Directory &&
            RegExp(r'^[a-f0-9]{32}$').hasMatch(path.basename(entry.path))) {
          await entry.delete(recursive: true);
        }
      }
    });
  }

  Future<void> _cleanBundles(Directory root, OfflineBook book) async {
    final retained = book.chapters.map((c) => c.bundle).toSet();
    await for (final entry in root.list(followLinks: false)) {
      final name = path.basename(entry.path);
      if (entry is Directory &&
          (RegExp(r'^[a-f0-9]{32}$').hasMatch(name) ||
              name.startsWith('staging-')) &&
          !retained.contains(name)) {
        await entry.delete(recursive: true);
      }
    }
  }
}
