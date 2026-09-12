import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'startup_logo_path.dart';

/// QingJuan's own scroll mark, rendered as monochrome lines. Motion follows
/// Codex desktop: 56px, a 60ms delay / 180ms fade, and a 2.2s light sweep.
class StartupSplash extends StatelessWidget {
  const StartupSplash({this.brightness, this.status, super.key});

  final Brightness? brightness;
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final mode = brightness ?? MediaQuery.platformBrightnessOf(context);
    final dark = mode == Brightness.dark;
    return ColoredBox(
      color: dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Center(child: QingJuanStartupLogo(brightness: mode)),
          if (status != null)
            LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: EdgeInsets.fromLTRB(
                  24,
                  constraints.maxHeight / 2 + 60,
                  24,
                  24,
                ),
                child: SingleChildScrollView(
                  child: DefaultTextStyle(
                    style: TextStyle(
                      color: dark
                          ? const Color(0xFFFFFFFF)
                          : const Color(0xFF000000),
                      fontSize: 13,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                    child: status!,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class QingJuanStartupLogo extends StatefulWidget {
  const QingJuanStartupLogo({required this.brightness, super.key});

  final Brightness brightness;

  static const size = 56.0;
  static const entranceDuration = Duration(milliseconds: 240);
  static const shimmerDuration = Duration(milliseconds: 2200);

  @override
  State<QingJuanStartupLogo> createState() => _QingJuanStartupLogoState();
}

class _QingJuanStartupLogoState extends State<QingJuanStartupLogo>
    with TickerProviderStateMixin {
  late final _entrance = AnimationController(
    vsync: this,
    duration: QingJuanStartupLogo.entranceDuration,
  );
  late final _shimmer = AnimationController(
    vsync: this,
    duration: QingJuanStartupLogo.shimmerDuration,
  );
  late final _opacity = _entrance.drive(
    CurveTween(curve: const Interval(0.25, 1, curve: Cubic(0, 0, 0.58, 1))),
  );
  bool? _reducedMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion == reduced) return;
    _reducedMotion = reduced;
    if (reduced) {
      _entrance.value = 1;
      _shimmer
        ..stop()
        ..value = 0;
    } else {
      _entrance.forward();
      _shimmer.repeat();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '正在启动青卷',
      image: true,
      child: RepaintBoundary(
        child: FadeTransition(
          opacity: _opacity,
          child: CustomPaint(
            size: const Size.square(QingJuanStartupLogo.size),
            painter: _StartupLogoPainter(
              shimmer: _shimmer,
              brightness: widget.brightness,
            ),
          ),
        ),
      ),
    );
  }
}

class _StartupLogoPainter extends CustomPainter {
  _StartupLogoPainter({required this.shimmer, required this.brightness})
      : super(repaint: shimmer);

  final Animation<double> shimmer;
  final Brightness brightness;

  static final _path = createStartupLogoPath();
  static const _sweepCurve = Cubic(0.4, 0, 0.2, 1);
  static const _stops = <double>[0.22, 0.38, 0.49, 0.56, 0.74];
  static final _colors = <Color>[
    const Color(0xFFFFFFFF).withValues(alpha: 0),
    const Color(0xFFFFFFFF).withValues(alpha: 0.04),
    const Color(0xFFFFFFFF).withValues(alpha: 0.48),
    const Color(0xFFFFFFFF).withValues(alpha: 0.08),
    const Color(0xFFFFFFFF).withValues(alpha: 0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 21, size.height / 21);
    final base = brightness == Brightness.dark
        ? const Color(0xFFFFFFFF).withValues(alpha: 0.68)
        : const Color(0xFF000000).withValues(alpha: 0.24);
    canvas.drawPath(_path, Paint()..color = base);

    // CSS background-position percentages apply to (box - image) width.
    // 140% -> -105%, with background-size: 220% 100%.
    final progress = _sweepCurve.transform(shimmer.value);
    final left = (-1.68 + 2.94 * progress) * 21;
    const imageWidth = 2.2 * 21;
    const angle = 112 * math.pi / 180;
    final direction = Offset(math.sin(angle), -math.cos(angle));
    final length = imageWidth * direction.dx.abs() + 21 * direction.dy.abs();
    final center = Offset(left + imageWidth / 2, 10.5);
    final half = direction * (length / 2);
    final shader = ui.Gradient.linear(
      center - half,
      center + half,
      _colors,
      _stops,
    );
    canvas.drawPath(_path, Paint()..shader = shader);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StartupLogoPainter oldDelegate) =>
      brightness != oldDelegate.brightness || shimmer != oldDelegate.shimmer;
}
