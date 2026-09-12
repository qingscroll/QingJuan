import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

String offlineHash(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString().substring(0, 32);
String offlineNonce() {
  final random = Random.secure();
  return List.generate(
      16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class OfflineFiles {
  static final Map<String, Future<void>> _locks = {};
  static Future<T> locked<T>(String key, Future<T> Function() action) async {
    final result = (_locks[key] ?? Future<void>.value()).then((_) => action());
    final settled = result.then<void>((_) {}, onError: (Object _) {});
    _locks[key] = settled;
    try {
      return await result;
    } finally {
      if (identical(_locks[key], settled)) _locks.remove(key);
    }
  }

  static Future<List<File>> snapshots(Directory directory) async {
    if (!await directory.exists()) return [];
    final files = await directory
        .list(followLinks: false)
        .where((entry) =>
            entry is File &&
            RegExp(r'^manifest-\d{20}\.json$')
                .hasMatch(path.basename(entry.path)))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  static Future<Map<String, dynamic>?> read(Directory directory) async {
    final files = await snapshots(directory);
    for (final file in files) {
      try {
        if (await file.length() > 16 * 1024 * 1024) continue;
        return Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()) as Map);
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    if (files.isNotEmpty) throw const FormatException('离线清单损坏，请清理后重新保存');
    return null;
  }

  static Future<bool> publish(Directory directory, Map<String, dynamic> value,
      {bool Function()? isCurrent}) async {
    await directory.create(recursive: true);
    final files = await snapshots(directory);
    final generation = files.isEmpty
        ? 1
        : int.parse(path.basename(files.first.path).substring(9, 29)) + 1;
    final temporary = File(path.join(directory.path, 'writing.json'));
    var committed = false;
    try {
      await temporary.writeAsString(jsonEncode(value), flush: true);
      // Recheck after staging I/O, immediately before atomic publication.
      if (isCurrent != null && !isCurrent()) return false;
      await temporary.rename(path.join(directory.path,
          'manifest-${generation.toString().padLeft(20, '0')}.json'));
      committed = true;
      // Fresh-name publication leaves the previous manifest intact until commit.
      for (final previous in files) {
        try {
          await previous.delete();
        } on FileSystemException {
          // The new manifest is committed; a cleanup failure must not undo it.
        }
      }
      return true;
    } finally {
      if (!committed) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } on FileSystemException {
          // Retain the original failure; an unpublished temporary file is ignored.
        }
      }
    }
  }
}
