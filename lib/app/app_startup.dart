import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../shared/startup_splash.dart';
import 'qingjuan_app.dart';

typedef AppBootstrap = Future<Widget> Function(VoidCallback onReady);

/// Draws the first frame before reading preferences or starting the backend.
/// The application stays mounted behind the splash throughout initialization.
class AppStartup extends StatefulWidget {
  const AppStartup({this.bootstrap, super.key});

  final AppBootstrap? bootstrap;

  @override
  State<AppStartup> createState() => _AppStartupState();
}

class _AppStartupState extends State<AppStartup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _opacity;
  Widget? _app;
  ValueListenable<ThemeMode>? _themeMode;
  Timer? _minimumTimer;
  Timer? _slowTimer;
  int _attempt = 0;
  bool _ready = false;
  bool _minimumElapsed = false;
  bool _slow = false;
  bool _failed = false;
  bool _visible = true;
  bool _exiting = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _opacity = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: 1,
    );
    _start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_reduceMotion && _exiting) {
      _opacity.stop();
      _visible = false;
    }
    _dismissWhenReady();
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    _minimumTimer?.cancel();
    _slowTimer?.cancel();
    _ready = false;
    _minimumElapsed = false;
    _slow = false;
    _failed = false;
    _minimumTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted || attempt != _attempt) return;
      _minimumElapsed = true;
      _dismissWhenReady();
    });
    _slowTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || attempt != _attempt || !_visible || _failed) return;
      setState(() => _slow = true);
    });
    try {
      final bootstrap = widget.bootstrap ??
          (onReady) => QingJuanApp.bootstrap(onInitialized: onReady);
      final app = await bootstrap(() {
        if (!mounted || attempt != _attempt) return;
        _ready = true;
        _dismissWhenReady();
      });
      if (!mounted || attempt != _attempt) return;
      if (app is QingJuanApp) {
        _themeMode = app.appState.themeModeListenable;
        _themeMode!.addListener(_themeChanged);
      }
      setState(() => _app = app);
      _dismissWhenReady();
    } catch (_) {
      if (!mounted || attempt != _attempt) return;
      _minimumTimer?.cancel();
      _slowTimer?.cancel();
      setState(() => _failed = true);
    }
  }

  void _themeChanged() {
    if (mounted && _visible) setState(() {});
  }

  void _dismissWhenReady() {
    if (!_ready || _app == null || (!_minimumElapsed && !_reduceMotion)) return;
    _dismiss();
  }

  Future<void> _dismiss() async {
    if (!_visible || _exiting || _app == null) return;
    _exiting = true;
    _minimumTimer?.cancel();
    _slowTimer?.cancel();
    if (!_reduceMotion) {
      await _opacity.reverse();
      if (!mounted) return;
    }
    if (mounted) setState(() => _visible = false);
  }

  void _retry() {
    setState(() => _failed = false);
    unawaited(_start());
  }

  Brightness _brightness(BuildContext context) => switch (_themeMode?.value) {
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
        _ =>
          MediaQuery.maybeOf(context)?.platformBrightness ?? Brightness.light,
      };

  @override
  Widget build(BuildContext context) {
    final brightness = _brightness(context);
    final foreground = brightness == Brightness.dark
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF000000);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: TextStyle(color: foreground, fontSize: 13),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ExcludeFocus(
              excluding: _visible,
              child: ExcludeSemantics(
                excluding: _visible,
                child: IgnorePointer(
                  ignoring: _visible,
                  child: _app ?? const SizedBox.shrink(),
                ),
              ),
            ),
            if (_visible)
              FadeTransition(
                key: const ValueKey('startup-overlay'),
                opacity: _opacity,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    StartupSplash(
                      key: const ValueKey('startup-splash'),
                      brightness: brightness,
                      status: _failed
                          ? _StartupStatus(
                              message: '暂时无法启动应用',
                              action: '重试',
                              actionKey: const ValueKey('startup-retry'),
                              onPressed: _retry,
                              foreground: foreground,
                            )
                          : _slow
                              ? _StartupStatus(
                                  message: '启动时间较长，仍在准备中',
                                  action: _app != null ? '进入应用' : null,
                                  actionKey: const ValueKey('startup-continue'),
                                  onPressed: _app != null ? _dismiss : null,
                                  foreground: foreground,
                                )
                              : null,
                    ),
                    if (defaultTargetPlatform == TargetPlatform.windows)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 48,
                        child: _StartupWindowControls(foreground: foreground),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _attempt += 1;
    _minimumTimer?.cancel();
    _slowTimer?.cancel();
    _themeMode?.removeListener(_themeChanged);
    _opacity.dispose();
    super.dispose();
  }
}

class _StartupStatus extends StatelessWidget {
  const _StartupStatus({
    required this.message,
    required this.foreground,
    this.action,
    this.actionKey,
    this.onPressed,
  });

  final String message;
  final Color foreground;
  final String? action;
  final Key? actionKey;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...<Widget>[
            const SizedBox(height: 16),
            _StartupButton(
              key: actionKey,
              label: action!,
              onPressed: onPressed!,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: foreground.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(action!),
              ),
            ),
          ],
        ],
      );
}

class _StartupWindowControls extends StatelessWidget {
  const _StartupWindowControls({required this.foreground});

  final Color foreground;

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          _StartupButton(
            key: const ValueKey('startup-window-close'),
            label: '关闭窗口',
            onPressed: () => unawaited(windowManager.close()),
            child: SizedBox(
              width: 48,
              height: 48,
              child:
                  Icon(FluentIcons.chrome_close, size: 12, color: foreground),
            ),
          ),
        ],
      );
}

class _StartupButton extends StatefulWidget {
  const _StartupButton({
    required this.label,
    required this.onPressed,
    required this.child,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final Widget child;

  @override
  State<_StartupButton> createState() => _StartupButtonState();
}

class _StartupButtonState extends State<_StartupButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed();
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          label: widget.label,
          onTap: widget.onPressed,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: _focused
                      ? DefaultTextStyle.of(context).style.color!
                      : const Color(0x00000000),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: widget.child,
            ),
          ),
        ),
      );
}
