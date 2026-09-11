import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/window/desktop_tray.dart';
import 'brand_logo.dart';
import 'responsive.dart';

const desktopTitleBarHeight = 48.0;

/// Keeps the Windows window chrome outside the app [Navigator].
///
/// Routes are rendered in [child], so pushing a detail page or reader never
/// replaces the title bar. Mobile platforms keep using their native system
/// chrome and therefore receive [child] unchanged.
class DesktopWindowFrame extends StatelessWidget {
  const DesktopWindowFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (UiPlatformScope.of(context) != TargetPlatform.windows) return child;
    return Column(
      key: const ValueKey('desktop-window-frame'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const DesktopTitleBar(),
        Expanded(child: child),
      ],
    );
  }
}

/// Windows 自绘标题栏，与侧栏使用相同的 Mica 底色。
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key});

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool _isMaximized = false;
  bool _isHidingToTray = false;
  String? _trayError;

  Future<void> _hideToTray() async {
    if (_isHidingToTray) return;
    setState(() {
      _isHidingToTray = true;
      _trayError = null;
    });
    try {
      await DesktopTray.hideToTray();
    } on PlatformException {
      if (mounted) {
        setState(() => _trayError = '无法收起到托盘，请重试');
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() => _trayError = '当前程序不支持托盘，请更新完整客户端');
      }
    } finally {
      if (mounted) setState(() => _isHidingToTray = false);
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return SizedBox(
      key: const ValueKey('desktop-title-bar'),
      height: desktopTitleBarHeight,
      child: ColoredBox(
        color: theme.micaBackgroundColor,
        child: Row(
          children: <Widget>[
            Expanded(
              child: DragToMoveArea(
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 16),
                  child: Row(
                    children: <Widget>[
                      const QingJuanLogo(size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Semantics(
                          liveRegion: _trayError != null,
                          child: Text(
                            _trayError == null ? '青卷' : '青卷 · $_trayError',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.typography.body?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _CaptionButton(
              key: const ValueKey('window-hide-to-tray'),
              tooltip: _isHidingToTray ? '正在收起到托盘' : '收起到托盘（后台继续运行）',
              icon: _CaptionGlyph.hideToTray,
              onPressed:
                  _isHidingToTray ? null : () => unawaited(_hideToTray()),
            ),
            _CaptionButton(
              key: const ValueKey('window-minimize'),
              tooltip: '最小化',
              icon: _CaptionGlyph.minimize,
              onPressed: () => unawaited(windowManager.minimize()),
            ),
            _CaptionButton(
              key: const ValueKey('window-maximize'),
              tooltip: _isMaximized ? '还原' : '最大化',
              icon:
                  _isMaximized ? _CaptionGlyph.restore : _CaptionGlyph.maximize,
              onPressed: () => unawaited(
                _isMaximized
                    ? windowManager.unmaximize()
                    : windowManager.maximize(),
              ),
            ),
            _CaptionButton(
              key: const ValueKey('window-close'),
              tooltip: '关闭',
              icon: _CaptionGlyph.close,
              isClose: true,
              onPressed: () => unawaited(windowManager.close()),
            ),
          ],
        ),
      ),
    );
  }
}

enum _CaptionGlyph { hideToTray, minimize, maximize, restore, close }

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.isClose = false,
    super.key,
  });

  final String tooltip;
  final _CaptionGlyph icon;
  final VoidCallback? onPressed;
  final bool isClose;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 46,
        height: desktopTitleBarHeight,
        child: IconButton(
          style: ButtonStyle(
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (isClose && states.isPressed) {
                return const Color(0xFFB32A1C);
              }
              if (isClose && states.isHovered) {
                return const Color(0xFFC42B1C);
              }
              if (states.isPressed) {
                return theme.resources.subtleFillColorTertiary;
              }
              if (states.isHovered) {
                return theme.resources.subtleFillColorSecondary;
              }
              return const Color(0x00000000);
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.isDisabled) {
                return theme.resources.textFillColorDisabled;
              }
              if (isClose && (states.isHovered || states.isPressed)) {
                return const Color(0xFFFFFFFF);
              }
              return theme.resources.textFillColorPrimary;
            }),
          ),
          icon: Semantics(
            label: tooltip,
            child: _CaptionIcon(glyph: icon),
          ),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

/// Draw the familiar Windows caption symbols without an icon font or native
/// window decorations. IconTheme keeps hover, pressed and dark-mode colors in
/// sync with the surrounding Fluent button.
class _CaptionIcon extends StatelessWidget {
  const _CaptionIcon({required this.glyph});

  final _CaptionGlyph glyph;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(12, 12),
      painter: _CaptionIconPainter(
        glyph: glyph,
        color: IconTheme.of(context).color ??
            FluentTheme.of(context).resources.textFillColorPrimary,
      ),
    );
  }
}

class _CaptionIconPainter extends CustomPainter {
  const _CaptionIconPainter({required this.glyph, required this.color});

  final _CaptionGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.save();
    canvas.scale(size.width / 12, size.height / 12);
    switch (glyph) {
      case _CaptionGlyph.hideToTray:
        canvas.drawPath(
          Path()
            ..moveTo(1.5, 8)
            ..lineTo(1.5, 10.5)
            ..lineTo(10.5, 10.5)
            ..lineTo(10.5, 8)
            ..moveTo(6, 1)
            ..lineTo(6, 7)
            ..moveTo(3, 4)
            ..lineTo(6, 7)
            ..lineTo(9, 4),
          pen,
        );
      case _CaptionGlyph.minimize:
        canvas.drawLine(const Offset(1, 6.5), const Offset(11, 6.5), pen);
      case _CaptionGlyph.maximize:
        canvas.drawRect(const Rect.fromLTWH(1.5, 1.5, 9, 9), pen);
      case _CaptionGlyph.restore:
        canvas.drawPath(
          Path()
            ..moveTo(3.5, 3.5)
            ..lineTo(3.5, 1.5)
            ..lineTo(10.5, 1.5)
            ..lineTo(10.5, 8.5)
            ..lineTo(8.5, 8.5),
          pen,
        );
        canvas.drawRect(const Rect.fromLTWH(1.5, 3.5, 7, 7), pen);
      case _CaptionGlyph.close:
        canvas.drawLine(const Offset(1.5, 1.5), const Offset(10.5, 10.5), pen);
        canvas.drawLine(const Offset(10.5, 1.5), const Offset(1.5, 10.5), pen);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CaptionIconPainter oldDelegate) =>
      glyph != oldDelegate.glyph || color != oldDelegate.color;
}
