import 'package:flutter/services.dart';

/// Windows owns the icon and hides the existing window only after the icon is
/// available. No route, controller or backend process is disposed by this call.
abstract final class DesktopTray {
  static const channel = MethodChannel('qingjuan/window_tray');

  static Future<void> hideToTray() async {
    final hidden = await channel.invokeMethod<bool>('hideToTray');
    if (hidden != true) {
      throw PlatformException(
        code: 'tray_unavailable',
        message: '无法创建托盘图标，窗口保持打开。',
      );
    }
  }
}
