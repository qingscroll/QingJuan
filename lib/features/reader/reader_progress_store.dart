import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core/models/reading_progress_pending.dart';
import '../../core/models/book.dart';

abstract interface class ReaderProgressStore {
  Future<PendingReadingProgress?> load();
  Future<void> save(PendingReadingProgress? entry);
}

class ReaderProgressSnapshot {
  const ReaderProgressSnapshot(this.pending, this.confirmed);
  final PendingReadingProgress? pending;
  final ReadingProgress? confirmed;
}

abstract interface class ReaderProgressSnapshotStore
    implements ReaderProgressStore {
  Future<ReaderProgressSnapshot> loadSnapshot();
  Future<void> saveSnapshot(
      PendingReadingProgress? entry, ReadingProgress? confirmed);
}

/// Only reading coordinates and random operation IDs are persisted; never credentials or book text.
class FileReaderProgressStore implements ReaderProgressSnapshotStore {
  FileReaderProgressStore(
      {required String instanceId,
      required String ownerId,
      required String bookId,
      Future<Directory> Function()? directory})
      : _scope = {
          'instanceId': instanceId,
          'ownerId': ownerId,
          'bookId': bookId
        },
        _key = sha256
            .convert(utf8.encode(jsonEncode([instanceId, ownerId, bookId])))
            .toString(),
        _directory = directory ?? getApplicationSupportDirectory {
    if (instanceId.isEmpty || ownerId.isEmpty || bookId.isEmpty) {
      throw ArgumentError('阅读进度保存需要后端实例、账号和书籍标识');
    }
  }

  final String _key;
  final Map<String, String> _scope;
  final Future<Directory> Function() _directory;
  static final Map<String, Future<void>> _locks = {};

  Future<T> _locked<T>(Future<T> Function(Directory directory) action) async {
    final root = Directory(
        path.join((await _directory()).path, 'reader-progress-v1', _key));
    final before = _locks[root.path] ?? Future<void>.value();
    final result = before.then((_) => action(root));
    final settled = result.then<void>((_) {}, onError: (Object _) {});
    _locks[root.path] = settled;
    try {
      return await result;
    } finally {
      if (identical(_locks[root.path], settled)) _locks.remove(root.path);
    }
  }

  @override
  Future<PendingReadingProgress?> load() async =>
      (await loadSnapshot()).pending;

  @override
  Future<ReaderProgressSnapshot> loadSnapshot() => _locked((root) async {
        final snapshots = await _snapshots(root);
        FormatException? failure;
        for (final file in snapshots) {
          try {
            return await _read(file);
          } on FormatException catch (error) {
            failure = error;
          }
        }
        if (failure != null) throw failure;
        return const ReaderProgressSnapshot(null, null);
      });

  Future<List<File>> _snapshots(Directory root) async {
    if (!await root.exists()) return [];
    final files = await root
        .list()
        .where((entry) =>
            entry is File &&
            RegExp(r'^snapshot-\d{20}\.json$')
                .hasMatch(path.basename(entry.path)))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<ReaderProgressSnapshot> _read(File file) async {
    if (await file.length() > 65536) throw const FormatException('待提交阅读进度文件过大');
    try {
      final raw = jsonDecode(await file.readAsString()) as Map;
      if (raw['version'] != 1 || raw['key'] != _key) {
        throw const FormatException('待提交阅读进度格式无效');
      }
      final pending = raw['entry'] == null
          ? null
          : PendingReadingProgress.fromJson(
              Map<String, dynamic>.from(raw['entry'] as Map));
      final confirmed = raw['confirmed'] == null
          ? null
          : ReadingProgress.fromJson(
              Map<String, dynamic>.from(raw['confirmed'] as Map));
      if (confirmed != null &&
          (confirmed.revision == null || confirmed.revision! < 0)) {
        throw const FormatException('已确认阅读进度版本无效');
      }
      return ReaderProgressSnapshot(pending, confirmed);
    } on TypeError {
      throw const FormatException('待提交阅读进度格式无效');
    }
  }

  @override
  Future<void> save(PendingReadingProgress? entry) => saveSnapshot(entry, null);

  @override
  Future<void> saveSnapshot(
          PendingReadingProgress? entry, ReadingProgress? confirmed) =>
      _locked((root) async {
        await root.create(recursive: true);
        final snapshots = await _snapshots(root);
        final generation = snapshots.isEmpty
            ? 1
            : int.parse(path.basename(snapshots.first.path).substring(9, 29)) +
                1;
        final current = File(path.join(root.path,
            'snapshot-${generation.toString().padLeft(20, '0')}.json'));
        final next = File(path.join(root.path, 'writing.json'));
        await next.writeAsString(
            jsonEncode({
              'version': 1,
              'key': _key,
              'scope': _scope,
              'entry': entry?.toJson(),
              if (confirmed != null)
                'confirmed': readingProgressJson(confirmed),
            }),
            flush: true);
        // Publish to a fresh name: a crash never creates a gap with no valid snapshot.
        await next.rename(current.path);
        for (final stale in snapshots.skip(1)) {
          try {
            await stale.delete();
          } on FileSystemException {
            /* The newest snapshot is already durable. */
          }
        }
      });

  /// Enumerates only this identity's durable outbox; no credentials are stored.
  static Future<List<String>> pendingBooks(
      {required String instanceId,
      required String ownerId,
      Future<Directory> Function()? directory}) async {
    final location = directory ?? getApplicationSupportDirectory;
    final root =
        Directory(path.join((await location()).path, 'reader-progress-v1'));
    if (!await root.exists()) return [];
    final result = <String>{};
    await for (final folder in root.list(followLinks: false)) {
      if (folder is! Directory) continue;
      final files = await folder
          .list(followLinks: false)
          .where((file) =>
              file is File &&
              RegExp(r'^snapshot-\d{20}\.json$')
                  .hasMatch(path.basename(file.path)))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      for (final file in files) {
        try {
          if (await file.length() > 65536) continue;
          final raw = jsonDecode(await file.readAsString()) as Map;
          final scope = raw['scope'];
          if (scope is! Map ||
              scope['instanceId'] != instanceId ||
              scope['ownerId'] != ownerId) {
            break;
          }
          final bookId = scope['bookId'] as String;
          final store = FileReaderProgressStore(
              instanceId: instanceId,
              ownerId: ownerId,
              bookId: bookId,
              directory: location);
          if (path.basename(folder.path) != store._key) break;
          final entry = await store.load();
          if (entry?.localPosition != null) result.add(bookId);
          break;
        } on FormatException {
          continue;
        } on TypeError {
          continue;
        }
      }
    }
    return result.toList();
  }
}
