import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/shared/startup_splash.dart';

const _captureStartup = bool.fromEnvironment('QINGJUAN_CAPTURE_STARTUP');

void main() {
  testWidgets('reduced motion shows the logo without scheduling animation', (
    tester,
  ) async {
    await tester.pumpWidget(const _SplashHarness(disableAnimations: true));
    await tester.pump();

    expect(find.byType(QingJuanStartupLogo), findsOneWidget);
    expect(_logoOpacity(tester), 1);
    expect(
        tester.getSize(find.byType(QingJuanStartupLogo)), const Size(56, 56));
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pump(const Duration(seconds: 3));
    expect(_logoOpacity(tester), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('enabling reduced motion stops an already running splash', (
    tester,
  ) async {
    await tester.pumpWidget(const _SplashHarness());
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(const _SplashHarness(disableAnimations: true));
    await tester.pump();
    expect(_logoOpacity(tester), 1);
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pump(const Duration(seconds: 3));
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(const _SplashHarness());
    await tester.pump(const Duration(milliseconds: 100));
    expect(_logoOpacity(tester), 1);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('theme changes swap black and white while preserving geometry', (
    tester,
  ) async {
    await tester.pumpWidget(const _SplashHarness());
    final initialRect = tester.getRect(find.byType(QingJuanStartupLogo));
    expect(initialRect.size, const Size(56, 56));
    expect(initialRect.center, const Offset(400, 300));
    expect(_background(tester), const Color(0xFFFFFFFF));

    await tester.pumpWidget(
      const _SplashHarness(brightness: Brightness.dark),
    );
    expect(_background(tester), const Color(0xFF000000));
    expect(tester.getRect(find.byType(QingJuanStartupLogo)), initialRect);
    expect(
      tester
          .widget<QingJuanStartupLogo>(find.byType(QingJuanStartupLogo))
          .brightness,
      Brightness.dark,
    );

    await tester.pumpWidget(const _SplashHarness());
    expect(_background(tester), const Color(0xFFFFFFFF));
    expect(tester.getRect(find.byType(QingJuanStartupLogo)), initialRect);
  });

  testWidgets('status text does not move the centered logo on a phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const _SplashHarness());
    final initialRect = tester.getRect(find.byType(QingJuanStartupLogo));
    expect(initialRect.center, const Offset(195, 422));

    await tester.pumpWidget(
      const _SplashHarness(
        status: Text('Starting QingJuan\nConnecting to the local service'),
      ),
    );

    expect(find.textContaining('Connecting'), findsOneWidget);
    expect(tester.getRect(find.byType(QingJuanStartupLogo)), initialRect);
    expect(
      tester.getRect(find.textContaining('Connecting')).top,
      greaterThan(initialRect.bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing the splash disposes its active tickers',
      (tester) async {
    await tester.pumpWidget(const _SplashHarness());
    await tester.pump(const Duration(milliseconds: 550));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });

  if (_captureStartup) {
    testWidgets('capture desktop and mobile startup at a fixed animation frame',
        (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final brightness in Brightness.values) {
        for (final viewport in <String, Size>{
          'desktop': const Size(1360, 860),
          'mobile': const Size(390, 844),
        }.entries) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.binding.setSurfaceSize(viewport.value);
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            _SplashHarness(
              brightness: brightness,
              boundaryKey: boundaryKey,
            ),
          );
          await tester.pump(const Duration(milliseconds: 550));
          await _capture(
            tester,
            boundaryKey,
            '${brightness.name}-${viewport.key}-0550ms',
          );
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('capture one dark startup cycle in 100ms steps',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        _SplashHarness(
          brightness: Brightness.dark,
          boundaryKey: boundaryKey,
        ),
      );
      for (var milliseconds = 0; milliseconds <= 2200; milliseconds += 100) {
        if (milliseconds > 0) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await _capture(
          tester,
          boundaryKey,
          'frames/dark-${milliseconds.toString().padLeft(4, '0')}ms',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

double _logoOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: find.byType(QingJuanStartupLogo),
        matching: find.byType(FadeTransition),
      ),
    )
    .opacity
    .value;

Color _background(WidgetTester tester) => tester
    .widget<ColoredBox>(
      find.descendant(
        of: find.byType(StartupSplash),
        matching: find.byType(ColoredBox),
      ),
    )
    .color;

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String name,
) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/startup-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

class _SplashHarness extends StatelessWidget {
  const _SplashHarness({
    this.brightness = Brightness.light,
    this.disableAnimations = false,
    this.status,
    this.boundaryKey,
  });

  final Brightness brightness;
  final bool disableAnimations;
  final Widget? status;
  final GlobalKey? boundaryKey;

  @override
  Widget build(BuildContext context) => MediaQuery(
        data: MediaQueryData(
          platformBrightness: brightness,
          disableAnimations: disableAnimations,
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: boundaryKey,
            child: StartupSplash(status: status),
          ),
        ),
      );
}
