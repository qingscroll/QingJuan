import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/reading_progress_pending.dart';
import 'package:qingjuan/features/reader/reader_progress_notice.dart';
import 'package:qingjuan/features/reader/reader_progress_writer.dart';
import 'package:qingjuan/shared/responsive.dart';

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
        'conflict actions are explicit and fit narrow large type mobile=$mobile',
        (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const remote = ReadingProgress(
          chapterIndex: 8, scrollRatio: 0.4, pageIndex: 5, revision: 7);
      final api = ApiClient(() => 'https://reader.test',
          client: MockClient((request) async {
        if (request.method == 'GET') {
          return _json(readingProgressJson(remote), 200);
        }
        return _json({
          'detail': {
            'code': 'reading_progress_conflict',
            'current': readingProgressJson(remote)
          }
        }, 409);
      }));
      final writer = ReaderProgressWriter(api, 'book',
          versioning: true,
          initialProgress: const ReadingProgress(
              chapterIndex: 1, scrollRatio: 0, revision: 0));
      await writer.save(const ReadingProgress(
          chapterIndex: 3, scrollRatio: 0.2, pageIndex: 2));
      ReadingProgress? chosen;
      final notice = ReaderProgressNotice(
          writer: writer,
          onUseServer: (value) async {
            chosen = value;
          });
      final child = mobile
          ? MiuixThemeController(
              child: fluent.FluentTheme(
                  data: fluent.FluentThemeData(),
                  child: MaterialApp(
                      builder: (context, child) => MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                              textScaler: const TextScaler.linear(1.8)),
                          child: child!),
                      home: Scaffold(
                          body: SingleChildScrollView(child: notice)))))
          : fluent.FluentApp(
              home: MediaQuery(
                  data:
                      const MediaQueryData(textScaler: TextScaler.linear(1.8)),
                  child: SingleChildScrollView(child: notice)));
      await tester.pumpWidget(UiPlatformScope(
          platform: mobile ? TargetPlatform.android : TargetPlatform.windows,
          child: child));
      await tester.pumpAndSettle();
      expect(find.textContaining('本机第 3 章'), findsOneWidget);
      expect(find.textContaining('服务端第 8 章'), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-progress-keep-local')),
          findsOneWidget);
      expect(chosen, isNull);
      final server = find.byKey(const ValueKey('reader-progress-use-server'));
      await tester.ensureVisible(server);
      await tester.tap(server);
      await tester.pumpAndSettle();
      expect(chosen?.chapterIndex, 8);
      expect(writer.hasPending, isFalse);
      expect(find.text('阅读进度发生冲突'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      writer.dispose();
      api.close();
    });
  }
}

http.Response _json(Object value, int status) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json'});
