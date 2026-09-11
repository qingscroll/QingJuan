import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/updates/app_release.dart';
import 'package:qingjuan/core/updates/app_update_controller.dart';
import 'package:qingjuan/core/updates/app_update_service.dart';

const _name = 'QingJuan-v2.2.0-windows-x64-setup.exe';
const _base = 'https://github.com/qingscroll/QingJuan/releases';
Map<String, dynamic> releaseJson() => {
      'tag_name': 'v2.2.0',
      'draft': false,
      'prerelease': false,
      'html_url': '$_base/tag/v2.2.0',
      'body': '更新说明',
      'assets': [
        for (final name in [_name, '$_name.sha256'])
          {
            'name': name,
            'state': 'uploaded',
            'size': name == _name ? 3 : 120,
            'browser_download_url': '$_base/download/v2.2.0/$name',
          }
      ],
    };
AppRelease release() => AppRelease.fromJson(releaseJson(), windows: true)!;

void main() {
  test('stable versions compare numerically without build metadata', () {
    expect(AppVersion.parse('v2.10.0').compareTo(AppVersion.parse('2.9.9')),
        greaterThan(0));
    expect(AppVersion.parse('V2.2.0+42').compareTo(AppVersion.parse('2.2.0+1')),
        0);
    expect(() => AppVersion.parse('2.2.0-rc.1'), throwsFormatException);
  });

  test('only official, stable, platform-specific assets are accepted', () {
    expect(release().asset!.name, _name);
    expect(AppRelease.fromJson(releaseJson(), windows: false)!.asset, isNull);
    expect(
        AppRelease.fromJson(releaseJson()..['prerelease'] = true,
            windows: true),
        isNull);
    expect(AppRelease.fromJson(releaseJson()..['draft'] = true, windows: true),
        isNull);
    final invalid = releaseJson();
    (invalid['assets'] as List).first['browser_download_url'] =
        'https://evil.test/$_name';
    expect(() => AppRelease.fromJson(invalid, windows: true),
        throwsFormatException);
    for (final url in [
      'http://github.com/qingscroll/QingJuan/releases/latest',
      'https://github.com/Tavre/QingJuan/releases/latest',
      'https://github.com/other/repo/releases/latest',
      'https://github.com/qingscroll/QingJuan-other/releases/latest',
      '$_base/latest?redirect=evil',
      'https://github.com:8443/qingscroll/QingJuan/releases/latest'
    ]) {
      expect(() => trustedReleaseUri(url), throwsFormatException);
    }
  });

  test('migrated repository response checks successfully without a downgrade',
      () async {
    final service = AppUpdateService(
        clientFactory: () => MockClient((request) async {
              expect(request.url.toString(),
                  'https://api.github.com/repos/qingscroll/QingJuan/releases/latest');
              return http.Response.bytes(
                  utf8.encode(jsonEncode({
                    'tag_name': 'v2.1.1',
                    'draft': false,
                    'prerelease': false,
                    'html_url': '$_base/tag/v2.1.1',
                    'body': '正式版',
                    // Older releases have a ZIP but no automatic installer.
                    'assets': [
                      {
                        'name': 'QingJuan-v2.1.1-windows-x64.zip',
                        'state': 'uploaded',
                        'size': 100,
                        'browser_download_url':
                            '$_base/download/v2.1.1/QingJuan-v2.1.1-windows-x64.zip',
                      }
                    ],
                  })),
                  200);
            }));
    final controller = _makeController(service, version: '2.1.2+42');
    addTearDown(controller.dispose);
    await controller.check();
    expect(controller.status, UpdateStatus.current);
    expect(controller.error, isNull);
    expect(controller.checkedAt, isNotNull);
    expect(controller.release, isNull);
  });

  test('release and asset URLs must match the official repository and tag', () {
    final wrongPage = releaseJson()..['html_url'] = '$_base/tag/v2.1.1';
    expect(() => AppRelease.fromJson(wrongPage, windows: true),
        throwsFormatException);
    for (final url in [
      'https://github.com/Tavre/QingJuan/releases/download/v2.2.0/$_name',
      '$_base/download/v2.1.1/$_name',
      '$_base/download/v2.2.0/unexpected.exe',
    ]) {
      final invalid = releaseJson();
      (invalid['assets'] as List).first['browser_download_url'] = url;
      expect(() => AppRelease.fromJson(invalid, windows: true),
          throwsFormatException);
    }
  });

  test('malformed release information is not reported as a network failure',
      () async {
    for (final body in [
      'not JSON',
      jsonEncode(releaseJson()
        ..['html_url'] = 'https://github.com/other/repo/releases/tag/v2.2.0'),
    ]) {
      final service = AppUpdateService(
          clientFactory: () => MockClient(
              (_) async => http.Response.bytes(utf8.encode(body), 200)));
      final controller = _makeController(service);
      await controller.check();
      expect(controller.status, UpdateStatus.idle);
      expect(controller.error, contains('更新信息格式或发布地址异常'));
      expect(controller.error, isNot(contains('网络')));
      controller.dispose();
    }
  });

  test('release page fallback opens the current official repository', () async {
    final service = _FakeService();
    final controller = _makeController(service);
    addTearDown(controller.dispose);
    await controller.openRelease();
    expect(service.openedPage,
        Uri.parse('https://github.com/qingscroll/QingJuan/releases/latest'));
    expect(controller.error, isNull);
  });

  test(
      'startup check runs once, manual retry works and duplicate checks coalesce',
      () async {
    final pending = Completer<AppRelease?>();
    final service = _FakeService()..nextCheck = pending.future;
    final controller = _makeController(service);
    addTearDown(controller.dispose);
    final check = controller.checkOnStartup();
    await Future<void>.delayed(Duration.zero);
    await controller.checkOnStartup();
    await controller.check();
    expect(service.checks, 1);
    pending.complete(release());
    await check;
    expect(controller.status, UpdateStatus.available);
    expect(controller.checkedAt, isNotNull);
    service.nextCheck = Future.value(null);
    await controller.check();
    expect(service.checks, 2);
    expect(controller.status, UpdateStatus.current);
  });

  test('same and older releases never offer a downgrade', () async {
    for (final version in ['2.2.0+42', '2.10.0+50']) {
      final service = _FakeService();
      final controller = _makeController(service, version: version);
      await controller.check();
      expect(controller.status, UpdateStatus.current);
      expect(controller.release, isNull);
      controller.dispose();
    }
  });

  test('failed version lookup can retry, and offline checks do not throw',
      () async {
    var lookups = 0;
    final service = _FakeService();
    final controller = AppUpdateController(
        service: service,
        windows: true,
        versionLoader: () async {
          if (++lookups == 1) throw StateError('native failed');
          return '2.1.1+41';
        },
        exitForInstall: () async {});
    addTearDown(controller.dispose);
    await controller.check();
    expect(controller.error, isNotNull);
    await controller.check();
    expect(controller.status, UpdateStatus.available);
    service.failCheck = true;
    await controller.check();
    expect(controller.error, contains('超时'));
    expect(controller.release, isNotNull);
  });

  group('download integrity', () {
    late Directory temp;
    setUp(() async =>
        temp = await Directory.systemTemp.createTemp('qingjuan-update-test-'));
    tearDown(() async => temp.delete(recursive: true));

    AppUpdateService service(
            {String? hash,
            List<int> bytes = const [1, 2, 3],
            int status = 200}) =>
        AppUpdateService(
            temporaryDirectory: () async => temp,
            clientFactory: () => MockClient((request) async {
                  expect(request.headers.containsKey('authorization'), isFalse);
                  if (request.url == AppUpdateService.latestUri) {
                    return http.Response.bytes(
                        utf8.encode(jsonEncode(releaseJson())), status);
                  }
                  if (request.url.path.endsWith('.sha256')) {
                    return http.Response(
                        '${hash ?? sha256.convert([1, 2, 3])}  $_name\n', 200);
                  }
                  return http.Response.bytes(bytes, 200);
                }));

    test(
        'streams download, checks length and SHA-256 then rechecks before launch',
        () async {
      final client = service();
      final latest = await client.check(windows: true);
      var progress = 0;
      final downloaded =
          await client.download(latest!, (received, _) => progress = received);
      expect(progress, 3);
      expect(await downloaded.file.readAsBytes(), [1, 2, 3]);
      await downloaded.file.writeAsBytes([3, 2, 1]);
      await expectLater(
          client.verify(downloaded), throwsA(isA<UpdateException>()));
    });

    test(
        'mismatched, truncated and oversized packages leave no executable behind',
        () async {
      for (final bytes in [
        [3, 2, 1],
        [1, 2],
        [1, 2, 3, 4]
      ]) {
        await expectLater(service(bytes: bytes).download(release(), (_, __) {}),
            throwsA(isA<UpdateException>()));
        expect(await temp.list().toList(), isEmpty);
      }
    });

    test('invalid checksum and incomplete publishing fail safely', () async {
      await expectLater(service(hash: 'bad').download(release(), (_, __) {}),
          throwsA(isA<UpdateException>()));
      final incomplete =
          AppRelease.fromJson(releaseJson()..['assets'] = [], windows: true)!;
      await expectLater(service().download(incomplete, (_, __) {}),
          throwsA(isA<UpdateException>()));
      expect(await temp.list().toList(), isEmpty);
    });

    test('rate limits have a useful error', () async {
      await expectLater(
          service(status: 403).check(windows: true),
          throwsA(isA<UpdateException>()
              .having((e) => e.message, 'message', contains('频繁'))));
    });

    test(
        'cancelled download can be retried and install failure keeps the app open',
        () async {
      final client = _FakeService();
      var exited = false;
      final controller = AppUpdateController(
          service: client,
          windows: true,
          versionLoader: () async => '2.1.1',
          exitForInstall: () async => exited = true);
      addTearDown(controller.dispose);
      await controller.check();
      client.pendingDownload = Completer<DownloadedUpdate>();
      final downloading = controller.download();
      controller.cancelDownload();
      client.pendingDownload!.completeError(const UpdateException('cancelled'));
      await downloading;
      expect(controller.error, isNull);
      expect(controller.status, UpdateStatus.available);
      final downloaded = await service().download(release(), (_, __) {});
      client.pendingDownload = Completer<DownloadedUpdate>()
        ..complete(downloaded);
      await controller.download();
      expect(controller.status, UpdateStatus.ready);
      client.failInstall = true;
      await controller.install();
      expect(exited, isFalse);
      expect(controller.status, UpdateStatus.available);
      expect(controller.error, isNotNull);
    });

    test('successful installer launch precedes client exit', () async {
      final client = _FakeService();
      final controller = AppUpdateController(
          service: client,
          windows: true,
          versionLoader: () async => '2.1.1',
          exitForInstall: () async => expect(client.installs, 1));
      final downloaded = await service().download(release(), (_, __) {});
      client.pendingDownload = Completer<DownloadedUpdate>()
        ..complete(downloaded);
      await controller.check();
      await controller.download();
      await controller.install();
      expect(controller.status, UpdateStatus.installing);
      controller.dispose();
    });
  });
}

AppUpdateController _makeController(AppUpdateService service,
        {String version = '2.1.1+41'}) =>
    AppUpdateController(
        service: service,
        windows: true,
        versionLoader: () async => version,
        exitForInstall: () async {});

class _FakeService extends AppUpdateService {
  int checks = 0;
  int installs = 0;
  bool failCheck = false;
  bool failInstall = false;
  Future<AppRelease?>? nextCheck;
  Uri? openedPage;
  Completer<DownloadedUpdate>? pendingDownload;
  @override
  Future<AppRelease?> check({required bool windows}) async {
    checks++;
    if (failCheck) throw TimeoutException('offline');
    return nextCheck ?? Future.value(release());
  }

  @override
  Future<DownloadedUpdate> download(
          AppRelease release, void Function(int, int) onProgress) =>
      pendingDownload!.future;
  @override
  Future<void> launchInstaller(DownloadedUpdate update) async {
    if (failInstall) throw const UpdateException('无法启动安装程序');
    installs++;
  }

  @override
  Future<void> openPage(Uri uri) async {
    openedPage = trustedReleaseUri(uri.toString());
  }
}
