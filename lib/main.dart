import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app_startup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) AppLinks();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    final windowOptions = WindowOptions(
      size: const Size(1360, 860),
      minimumSize: const Size(960, 640),
      center: true,
      backgroundColor:
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                  Brightness.dark
              ? const Color(0xFF000000)
              : const Color(0xFFFFFFFF),
      skipTaskbar: false,
      title: '青卷',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    unawaited(
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      }),
    );
  } else {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  runApp(const AppStartup());
}
