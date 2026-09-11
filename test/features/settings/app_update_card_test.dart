import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/updates/app_release.dart';
import 'package:qingjuan/core/updates/app_update_controller.dart';
import 'package:qingjuan/core/updates/app_update_service.dart';
import 'package:qingjuan/features/settings/widgets/app_update_card.dart';

void main() {
  testWidgets(
      'settings check shows a release and download action at narrow width',
      (tester) async {
    final controller = AppUpdateController(
        service: _Service(),
        windows: true,
        versionLoader: () async => '2.1.1+41',
        exitForInstall: () async {});
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
            content: SingleChildScrollView(
                child: AppUpdateCard(controller: controller)))));
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 2.2.0'), findsOneWidget);
    expect(find.text('下载更新'), findsOneWidget);
    expect(find.textContaining('2.1.1+41'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup notification opens settings and can be dismissed',
      (tester) async {
    final controller = AppUpdateController(
        service: _Service(),
        windows: true,
        versionLoader: () async => '2.1.1',
        exitForInstall: () async {});
    addTearDown(controller.dispose);
    var opened = false;
    await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
            content: AppUpdateBanner(
                controller: controller, onOpenSettings: () => opened = true))));
    await controller.checkOnStartup();
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看更新'));
    expect(opened, isTrue);
    final bar = tester.widget<InfoBar>(find.byType(InfoBar));
    bar.onClose!();
    await tester.pumpAndSettle();
    expect(find.text('查看更新'), findsNothing);
  });
}

class _Service extends AppUpdateService {
  @override
  Future<AppRelease?> check({required bool windows}) async => AppRelease(
        version: const AppVersion(2, 2, 0),
        notes: '改进软件更新与安装体验。',
        pageUrl: Uri.parse(
            'https://github.com/qingscroll/QingJuan/releases/tag/v2.2.0'),
        asset: ReleaseAsset(
            name: 'setup.exe',
            url: Uri.parse(
                'https://github.com/qingscroll/QingJuan/releases/download/v2.2.0/setup.exe'),
            size: 3),
        checksum: ReleaseAsset(
            name: 'setup.exe.sha256',
            url: Uri.parse(
                'https://github.com/qingscroll/QingJuan/releases/download/v2.2.0/setup.exe.sha256'),
            size: 120),
      );
}
