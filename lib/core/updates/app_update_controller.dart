import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_metadata.dart';
import 'app_release.dart';
import 'app_update_service.dart';

enum UpdateStatus {
  idle,
  checking,
  current,
  available,
  downloading,
  ready,
  installing
}

class AppUpdateController extends ChangeNotifier {
  AppUpdateController(
      {required this.service,
      required this.windows,
      required Future<String> Function() versionLoader,
      required Future<void> Function() exitForInstall})
      : _versionLoader = versionLoader,
        _exitForInstall = exitForInstall;

  factory AppUpdateController.production(
          {required Future<void> Function() exitForInstall}) =>
      AppUpdateController(
          service: AppUpdateService(),
          windows: Platform.isWindows,
          versionLoader: () async {
            final info = await PackageInfo.fromPlatform();
            return '${info.version}+${info.buildNumber}';
          },
          exitForInstall: exitForInstall);

  final AppUpdateService service;
  final bool windows;
  final Future<String> Function() _versionLoader;
  final Future<void> Function() _exitForInstall;
  UpdateStatus status = UpdateStatus.idle;
  String? currentVersion;
  AppRelease? release;
  DownloadedUpdate? _downloaded;
  String? error;
  DateTime? checkedAt;
  double progress = 0;
  bool _disposed = false;
  bool _cancelled = false;
  bool _started = false;
  bool get busy =>
      status == UpdateStatus.checking ||
      status == UpdateStatus.downloading ||
      status == UpdateStatus.installing;
  bool get canDownload =>
      release?.asset != null && (!windows || release?.checksum != null);

  Future<void> checkOnStartup() async {
    if (_started) return;
    _started = true;
    await check();
  }

  Future<void> check() async {
    if (busy || _disposed || status == UpdateStatus.ready) return;
    status = UpdateStatus.checking;
    error = null;
    _notify();
    try {
      currentVersion ??= await _versionLoader();
      final latest = await service.check(windows: windows);
      if (_disposed) return;
      checkedAt = DateTime.now();
      release = latest != null &&
              latest.version.compareTo(AppVersion.parse(currentVersion!)) > 0
          ? latest
          : null;
      status = release == null ? UpdateStatus.current : UpdateStatus.available;
    } catch (failure) {
      if (_disposed) return;
      error = _errorMessage(failure);
      status = release == null ? UpdateStatus.idle : UpdateStatus.available;
    }
    _notify();
  }

  Future<void> download() async {
    if (busy || _disposed || !canDownload || status == UpdateStatus.ready) {
      return;
    }
    if (!windows) {
      await openRelease(downloadAsset: true);
      return;
    }
    status = UpdateStatus.downloading;
    error = null;
    progress = 0;
    _cancelled = false;
    _notify();
    try {
      _downloaded = await service.download(release!, (received, total) {
        progress = received / total;
        _notify();
      });
      if (_disposed || _cancelled) {
        await _removeDownload();
        status = UpdateStatus.available;
      } else {
        status = UpdateStatus.ready;
      }
    } catch (failure) {
      status = UpdateStatus.available;
      if (!_cancelled) error = _errorMessage(failure);
    }
    _notify();
  }

  void cancelDownload() {
    if (status != UpdateStatus.downloading) return;
    _cancelled = true;
    service.cancel();
  }

  Future<void> install() async {
    if (status != UpdateStatus.ready || _downloaded == null || _disposed) {
      return;
    }
    status = UpdateStatus.installing;
    error = null;
    _notify();
    try {
      await service.launchInstaller(_downloaded!);
      await _exitForInstall();
    } catch (failure) {
      error = _errorMessage(failure);
      // A missing or modified file must be downloaded and verified again.
      await _removeDownload();
      status = UpdateStatus.available;
    }
    _notify();
  }

  Future<void> openRelease({bool downloadAsset = false}) async {
    try {
      await service.openPage(downloadAsset
          ? release!.asset!.url
          : release?.pageUrl ?? Uri.parse('$officialReleasesUrl/latest'));
    } catch (failure) {
      error = _errorMessage(failure);
      _notify();
    }
  }

  Future<void> _removeDownload() async {
    final update = _downloaded;
    _downloaded = null;
    if (update == null) return;
    try {
      if (await update.file.exists()) await update.file.delete();
      if (await update.file.parent.exists()) await update.file.parent.delete();
    } on FileSystemException {
      // The OS may still hold the downloaded installer; the temp location is safe to retain.
    }
  }

  String _errorMessage(Object failure) => switch (failure) {
        UpdateException() => failure.message,
        TimeoutException() => '连接更新服务超时，请稍后重试',
        FormatException() => '更新信息格式或发布地址异常，请前往官方发布页面查看',
        _ => '检查或下载更新失败，请检查网络连接后重试',
      };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    service.dispose();
    if (status != UpdateStatus.installing) unawaited(_removeDownload());
    super.dispose();
  }
}
