import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const captureMobileFixtures = bool.fromEnvironment(
  'QINGJUAN_CAPTURE_MOBILE_UI',
);

Future<void> loadMobileCaptureFonts() async {
  if (!captureMobileFixtures) return;
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(entry['family'] as String);
    for (final font in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  final file = File('C:/Windows/Fonts/msyh.ttc');
  if (!await file.exists()) return;
  final bytes = ByteData.sublistView(await file.readAsBytes());
  for (final family in [
    'Roboto',
    'Ahem',
    'Segoe UI Variable Text',
    'Segoe UI Variable Display',
  ]) {
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }
}

Future<void> saveMobileFixture(
  WidgetTester tester,
  GlobalKey key,
  String name, {
  bool settle = true,
}) async {
  if (!captureMobileFixtures) return;
  if (settle) await tester.pumpAndSettle();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/mobile-ui-preview');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
