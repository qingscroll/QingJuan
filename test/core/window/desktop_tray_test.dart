import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/window/desktop_tray.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(DesktopTray.channel, null);
  });

  test('hide uses one native operation with an explicit success result',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(DesktopTray.channel, (call) async {
      calls.add(call);
      return true;
    });

    await DesktopTray.hideToTray();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'hideToTray');
    expect(calls.single.arguments, isNull);
  });

  for (final reply in <bool?>[false, null]) {
    test('a $reply reply is not treated as a successful hide', () async {
      messenger.setMockMethodCallHandler(
          DesktopTray.channel, (_) async => reply);

      await expectLater(
        DesktopTray.hideToTray(),
        throwsA(isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'tray_unavailable',
        )),
      );
    });
  }

  test('native errors are surfaced without a separate window hide', () async {
    messenger.setMockMethodCallHandler(DesktopTray.channel, (_) async {
      throw PlatformException(code: 'tray_unavailable');
    });

    await expectLater(
        DesktopTray.hideToTray(), throwsA(isA<PlatformException>()));
  });

  test('an older native runner reports its missing capability', () async {
    await expectLater(
      DesktopTray.hideToTray(),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
