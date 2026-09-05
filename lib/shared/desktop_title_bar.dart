import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/window/desktop_tray.dart';
import 'responsive.dart';

const desktopTitleBarHeight = 32.0;

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

/// v1.3.4 Windows 自绘标题栏。
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
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Semantics(
                      liveRegion: _trayError != null,
                      child: Text(
                        _trayError == null ? '青卷' : '青卷 · $_trayError',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.typography.body?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _CaptionButton(
              key: const ValueKey('window-hide-to-tray'),
              tooltip: _isHidingToTray ? '正在收起到托盘' : '收起到托盘（后台继续运行）',
              icon: FluentIcons.mini_contract,
              onPressed:
                  _isHidingToTray ? null : () => unawaited(_hideToTray()),
            ),
            _CaptionButton(
              key: const ValueKey('window-minimize'),
              tooltip: '最小化',
              icon: FluentIcons.chrome_minimize,
              onPressed: () => unawaited(windowManager.minimize()),
            ),
            _CaptionButton(
              key: const ValueKey('window-maximize'),
              tooltip: _isMaximized ? '还原' : '最大化',
              icon: _isMaximized
                  ? FluentIcons.chrome_restore
                  : FluentIcons.chrome_full_screen,
              onPressed: () => unawaited(
                _isMaximized
                    ? windowManager.unmaximize()
                    : windowManager.maximize(),
              ),
            ),
            _CaptionButton(
              key: const ValueKey('window-close'),
              tooltip: '关闭',
              icon: FluentIcons.chrome_close,
              isClose: true,
              onPressed: () => unawaited(windowManager.close()),
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.isClose = false,
    super.key,
  });

  final String tooltip;
  final IconData icon;
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
              if (isClose && states.isHovered) {
                return const Color(0xFFC42B1C);
              }
              if (isClose && states.isPressed) {
                return const Color(0xFFB32A1C);
              }
              if (states.isHovered) {
                return theme.resources.subtleFillColorSecondary;
              }
              if (states.isPressed) {
                return theme.resources.subtleFillColorTertiary;
              }
              return const Color(0x00000000);
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (isClose && (states.isHovered || states.isPressed)) {
                return const Color(0xFFFFFFFF);
              }
              return theme.resources.textFillColorPrimary;
            }),
          ),
          icon: Icon(icon, size: 12, semanticLabel: tooltip),
          onPressed: onPressed,
        ),
      ),
    );
  }
}
