import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const captureUiReview = bool.fromEnvironment('QINGJUAN_CAPTURE_UI_REVIEW');

Future<void> loadUiReviewFonts() async {
  if (!captureUiReview) return;
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(entry['family'] as String);
    for (final font in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  final font = File('C:/Windows/Fonts/msyh.ttc');
  if (!await font.exists()) return;
  final bytes = ByteData.sublistView(await font.readAsBytes());
  for (final family in [
    'Ahem',
    'Roboto',
    'Segoe UI',
    'Segoe UI Variable Text',
    'Segoe UI Variable Display'
  ]) {
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }
}

Future<void> captureUi(
    WidgetTester tester, GlobalKey boundaryKey, String name) async {
  if (!captureUiReview) return;
  final previousShadows = debugDisableShadows;
  debugDisableShadows = false;
  void repaint(RenderObject object) {
    object.markNeedsPaint();
    object.visitChildren(repaint);
  }

  try {
    repaint(boundaryKey.currentContext!.findRenderObject()!);
    await tester.pump();
    await tester.pumpAndSettle();
    final boundary = boundaryKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/ui-review').create(recursive: true);
      await File('build/ui-review/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = previousShadows;
    repaint(boundaryKey.currentContext!.findRenderObject()!);
    await tester.pump();
  }
}
