import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/shared/desktop_title_bar.dart';
import 'package:qingjuan/shared/responsive.dart';

void main() {
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
