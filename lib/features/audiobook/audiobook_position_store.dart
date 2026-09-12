import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../../core/models/audiobook_position.dart';

abstract interface class AudiobookPositionStore {
  Future<AudiobookPosition?> load();
  Future<void> save(AudiobookPosition position);
}

class FileAudiobookPositionStore implements AudiobookPositionStore {
  FileAudiobookPositionStore(
      {required String instanceId,
      required String ownerId,
      required String bookId,
      Future<Directory> Function()? directory})
      : _key = sha256
            .convert(utf8.encode(jsonEncode([instanceId, ownerId, bookId])))
            .toString(),
        _directory = directory ?? getApplicationSupportDirectory {
    if (instanceId.isEmpty || ownerId.isEmpty || bookId.isEmpty) {
      throw ArgumentError('听书位置需要后端实例、账号与书籍标识');
    }
  }
  final String _key;
  final Future<Directory> Function() _directory;
  static final Map<String, Future<void>> _locks = {};
  Future<T> _locked<T>(Future<T> Function(Directory directory) action) async {
    final root = Directory(
        path.join((await _directory()).path, 'audiobook-position-v1', _key));
    final result =
        (_locks[root.path] ?? Future<void>.value()).then((_) => action(root));
    final settled = result.then<void>((_) {}, onError: (Object _) {});
    _locks[root.path] = settled;
    try {
      return await result;
    } finally {
      if (identical(_locks[root.path], settled)) _locks.remove(root.path);
    }
  }

  Future<List<File>> _files(Directory root) async {
    if (!await root.exists()) return [];
    final files = await root
        .list(followLinks: false)
        .where((file) =>
            file is File &&
            RegExp(r'^position-\d{20}\.json$')
                .hasMatch(path.basename(file.path)))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  @override
  Future<AudiobookPosition?> load() => _locked((root) async {
        final files = await _files(root);
        for (final file in files) {
          try {
            if (await file.length() > 4096) continue;
            final json = jsonDecode(await file.readAsString()) as Map;
            if (json['scope'] != _key) continue;
            return AudiobookPosition.fromJson(
                Map<String, dynamic>.from(json['position'] as Map));
          } on FormatException {
            continue;
          } on TypeError {
            continue;
          }
        }
        if (files.isNotEmpty) throw const FormatException('本机听书位置无法读取');
        return null;
      });
  @override
  Future<void> save(AudiobookPosition position) => _locked((root) async {
        await root.create(recursive: true);
        final files = await _files(root);
        final sequence = files.isEmpty
            ? 1
            : int.parse(path.basename(files.first.path).substring(9, 29)) + 1;
        final temporary = File(path.join(root.path, 'writing.json'));
        await temporary.writeAsString(
            jsonEncode({'scope': _key, 'position': position.toJson()}),
            flush: true);
        await temporary.rename(path.join(root.path,
            'position-${sequence.toString().padLeft(20, '0')}.json'));
        for (final old in files.skip(1)) {
          try {
            await old.delete();
          } on FileSystemException {
            // The new position is durable; stale snapshot cleanup is best effort.
          }
        }
      });
}
