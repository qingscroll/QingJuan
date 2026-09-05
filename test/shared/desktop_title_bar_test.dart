import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/window/desktop_tray.dart';
import 'package:qingjuan/shared/desktop_title_bar.dart';
import 'package:qingjuan/shared/responsive.dart';

void main() {
  Future<void> pumpTitleBar(WidgetTester tester) async {
    await tester.pumpWidget(
      FluentApp(
        theme: buildQingJuanTheme(
          Brightness.light,
          platform: TargetPlatform.windows,
        ),
        builder: (context, child) => UiPlatformScope(
          platform: TargetPlatform.windows,
          child: DesktopWindowFrame(child: child ?? const SizedBox.shrink()),
        ),
        home: const Text('正在下载的页面'),
      ),
    );
  }

  void mockTray(Future<Object?> Function(MethodCall)? handler) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DesktopTray.channel, handler);
    addTearDown(() {
      messenger.setMockMethodCallHandler(DesktopTray.channel, null);
    });
  }

  testWidgets('tray control is separate from minimize and close',
      (tester) async {
    final calls = <String>[];
    mockTray((call) async {
      calls.add('tray:${call.method}');
      return true;
    });
    const windowChannel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      calls.add('window:${call.method}');
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));
    await pumpTitleBar(tester);

    await tester.tap(find.byKey(const ValueKey('window-hide-to-tray')));
    await tester.pump();
    expect(calls, <String>['tray:hideToTray']);
    expect(find.text('正在下载的页面'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('window-minimize')));
    await tester.tap(find.byKey(const ValueKey('window-close')));
    await tester.pump();
    expect(calls, <String>[
      'tray:hideToTray',
      'window:minimize',
      'window:close',
    ]);
    await tester.pumpAndSettle();
  });

  testWidgets('pending tray requests cannot be sent twice', (tester) async {
    final pending = Completer<bool>();
    var calls = 0;
    mockTray((_) {
      calls++;
      return pending.future;
    });
    await pumpTitleBar(tester);

    final button = find.byKey(const ValueKey('window-hide-to-tray'));
    await tester.tap(button);
    await tester.pump();
    final pendingButton = tester.widget<IconButton>(find.descendant(
      of: button,
      matching: find.byType(IconButton),
    ));
    expect(pendingButton.onPressed, isNull);
    expect(calls, 1);

    pending.complete(true);
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.descendant(
            of: button,
            matching: find.byType(IconButton),
          ))
          .onPressed,
      isNotNull,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('a tray failure keeps the page and permits retry',
      (tester) async {
    var attempts = 0;
    mockTray((_) async {
      if (++attempts == 1) throw PlatformException(code: 'tray_unavailable');
      return true;
    });
    await pumpTitleBar(tester);
    final button = find.byKey(const ValueKey('window-hide-to-tray'));

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.textContaining('无法收起到托盘，请重试'), findsOneWidget);
    expect(find.text('正在下载的页面'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.textContaining('无法收起到托盘，请重试'), findsNothing);
  });

  testWidgets('missing native support shows an update message', (tester) async {
    mockTray((_) async => throw MissingPluginException());
    await pumpTitleBar(tester);

    await tester.tap(find.byKey(const ValueKey('window-hide-to-tray')));
    await tester.pumpAndSettle();

    expect(find.textContaining('请更新完整客户端'), findsOneWidget);
    expect(find.text('正在下载的页面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending completion is safe after the frame is disposed',
      (tester) async {
    final pending = Completer<bool>();
    mockTray((_) => pending.future);
    await pumpTitleBar(tester);
    await tester.tap(find.byKey(const ValueKey('window-hide-to-tray')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    pending.completeError(PlatformException(code: 'tray_unavailable'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Windows chrome stays unique while detail and reader routes are pushed',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        FluentApp(
          theme: buildQingJuanTheme(
            Brightness.light,
            platform: TargetPlatform.windows,
          ),
          builder: (context, child) => UiPlatformScope(
            platform: TargetPlatform.windows,
            child: DesktopWindowFrame(
              child: child ?? const SizedBox.shrink(),
            ),
          ),
          home: const _RouteLauncher(),
        ),
      );

      expect(
          find.byKey(const ValueKey('desktop-window-frame')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-title-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('window-hide-to-tray')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('desktop-title-bar'))).width,
        900,
      );
      var closeRect = tester.getRect(
        find.byKey(const ValueKey('window-close')),
      );
      var frameRect = tester.getRect(
        find.byKey(const ValueKey('desktop-window-frame')),
      );
      expect(frameRect.right, 900);
      expect(closeRect.right, frameRect.right);
      expect(closeRect.size, const Size(46, desktopTitleBarHeight));

      await tester.tap(find.byKey(const ValueKey('open-detail')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('detail-route')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-title-bar')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('open-reader')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('reader-route')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-title-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('window-hide-to-tray')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-route')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-title-bar')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('route-root')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-title-bar')), findsOneWidget);

      await tester.binding.setSurfaceSize(const Size(620, 700));
      await tester.pump();
      closeRect = tester.getRect(find.byKey(const ValueKey('window-close')));
      frameRect = tester.getRect(
        find.byKey(const ValueKey('desktop-window-frame')),
      );
      expect(frameRect.right, 620);
      expect(closeRect.right, frameRect.right);
      expect(closeRect.size, const Size(46, desktopTitleBarHeight));
    },
  );

  testWidgets('mobile routes do not render custom Windows chrome',
      (tester) async {
    await tester.pumpWidget(
      FluentApp(
        builder: (context, child) => UiPlatformScope(
          platform: TargetPlatform.android,
          child: DesktopWindowFrame(
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: const _RouteLauncher(),
      ),
    );

    expect(find.byKey(const ValueKey('desktop-window-frame')), findsNothing);
    expect(find.byKey(const ValueKey('desktop-title-bar')), findsNothing);
    expect(find.byKey(const ValueKey('window-hide-to-tray')), findsNothing);
  });
}

class _RouteLauncher extends StatelessWidget {
  const _RouteLauncher();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const ValueKey('route-root'),
      color: const Color(0xFFFFFFFF),
      child: Center(
        child: Button(
          key: const ValueKey('open-detail'),
          onPressed: () => Navigator.of(context).push<void>(
            FluentPageRoute<void>(builder: (_) => const _DetailRoute()),
          ),
          child: const Text('打开详情'),
        ),
      ),
    );
  }
}

class _DetailRoute extends StatelessWidget {
  const _DetailRoute();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const ValueKey('detail-route'),
      color: const Color(0xFFFFFFFF),
      child: Center(
        child: Button(
          key: const ValueKey('open-reader'),
          onPressed: () => Navigator.of(context).push<void>(
            FluentPageRoute<void>(
              builder: (_) => const ColoredBox(
                key: ValueKey('reader-route'),
                color: Color(0xFFFFFFFF),
              ),
            ),
          ),
          child: const Text('进入阅读器'),
        ),
      ),
    );
  }
}
