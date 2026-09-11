import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_metadata.dart';
import 'app_release.dart';

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DownloadedUpdate {
  const DownloadedUpdate(this.file, this.digest);
  final File file;
  final String digest;
}

class AppUpdateService {
  AppUpdateService(
      {http.Client Function()? clientFactory,
      Future<Directory> Function()? temporaryDirectory})
      : _clientFactory = clientFactory ?? http.Client.new,
        _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static final latestUri = Uri.parse(
      'https://api.github.com/repos/$officialGitHubRepository/releases/latest');
  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _temporaryDirectory;
  http.Client? _activeClient;

  Future<http.StreamedResponse> _send(http.Client client, Uri uri) async {
    final response = await client
        .send(http.Request('GET', uri)
          ..headers.addAll(const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'QingJuan-Updater'
          }))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw UpdateException(switch (response.statusCode) {
        403 || 429 => '更新服务请求过于频繁，请稍后重试',
        404 => '尚未发布版本或更新文件暂不可用',
        _ => '更新服务暂不可用（HTTP ${response.statusCode}）',
      });
    }
    return response;
  }

  Future<String> _readText(http.Client client, Uri uri, int limit) async {
    final response = await _send(client, uri);
    final bytes = <int>[];
    await for (final chunk
        in response.stream.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > limit) throw const UpdateException('更新信息超过大小限制');
    }
    return utf8.decode(bytes);
  }

  Future<AppRelease?> check({required bool windows}) async {
    final client = _clientFactory();
    _activeClient = client;
    try {
      final body = await _readText(client, latestUri, 2 * 1024 * 1024);
      return AppRelease.fromJson(jsonDecode(body) as Map<String, dynamic>,
          windows: windows);
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  Future<DownloadedUpdate> download(AppRelease release,
      void Function(int received, int total) onProgress) async {
    final asset = release.asset;
    final checksum = release.checksum;
    if (asset == null || checksum == null) {
      throw const UpdateException('此版本尚未提供完整安装包及校验文件，请稍后重试');
    }
    final client = _clientFactory();
    _activeClient = client;
    Directory? directory;
    var keep = false;
    try {
      final text = (await _readText(client, checksum.url, 4096)).trim();
      final match = RegExp(r'^([a-fA-F0-9]{64})\s+\*?(.+)$').firstMatch(text);
      if (match == null || match[2] != asset.name) {
        throw const UpdateException('安装包校验信息无效');
      }
      final expected = match[1]!.toLowerCase();
      directory =
          await (await _temporaryDirectory()).createTemp('qingjuan-update-');
      final file = File(path.join(directory.path, asset.name));
      final response = await _send(client, asset.url);
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk
            in response.stream.timeout(const Duration(seconds: 30))) {
          received += chunk.length;
          if (received > asset.size) {
            throw const UpdateException('安装包大小与发布信息不符');
          }
          sink.add(chunk);
          await sink.flush();
          onProgress(received, asset.size);
        }
      } finally {
        await sink.close();
      }
      if (received != asset.size) throw const UpdateException('安装包下载不完整，请重新下载');
      final downloaded = DownloadedUpdate(file, expected);
      await verify(downloaded);
      keep = true;
      return downloaded;
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
      if (!keep && directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  Future<void> verify(DownloadedUpdate update) async {
    final actual = await sha256.bind(update.file.openRead()).first;
    if (actual.toString() != update.digest) {
      throw const UpdateException('安装包 SHA-256 校验失败，请重新下载');
    }
  }

  Future<void> launchInstaller(DownloadedUpdate update) async {
    await verify(update);
    await Process.start(
        update.file.path,
        <String>[
          '/DIR=${path.dirname(Platform.resolvedExecutable)}',
          '/UPDATEPID=$pid',
        ],
        mode: ProcessStartMode.detached,
        runInShell: false);
  }

  Future<void> openPage(Uri uri) async {
    if (!await launchUrl(trustedReleaseUri(uri.toString()),
        mode: LaunchMode.externalApplication)) {
      throw const UpdateException('无法打开浏览器，请检查系统默认浏览器');
    }
  }

  void cancel() => _activeClient?.close();
  void dispose() => cancel();
}
