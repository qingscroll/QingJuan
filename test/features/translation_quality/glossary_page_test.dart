import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/features/detail/book_detail_page.dart';
import 'package:qingjuan/features/translation_quality/translation_quality_page.dart';
import 'package:qingjuan/shared/responsive.dart';

import '../../helpers/reliability_harness.dart';

http.Response response(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
        'uncached book glossary saves, retains conflicts and reloads ($mobile)',
        (tester) async {
      tester.view.physicalSize =
          mobile ? const f.Size(390, 844) : const f.Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var revision = 0;
      var entries = <dynamic>[];
      final submitted = <Map<String, dynamic>>[];
      final unexpected = <String>[];
      var conflict = false;
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.url.path.endsWith('/books/quality-book')) {
          return response({
            'book': {
              'id': 'quality-book',
              'title': '未下载的小说',
              'bookKind': '长小说',
              'language': '英语',
              'sourceUrl': '',
              'chapterCount': 0,
            },
            'chapters': [],
            'downloadedChapterCount': 0,
          });
        }
        if (!request.url.path.endsWith('/glossary')) {
          unexpected.add(request.url.path);
          return response({'detail': '章节尚未下载'}, 404);
        }
        if (request.method == 'PUT') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          submitted.add(body);
          if (conflict) return response({'detail': '术语表已改变，请重新加载'}, 409);
          expect(body['expectedRevision'], revision);
          entries = body['entries'] as List<dynamic>;
          revision++;
        }
        return response({
          'bookId': 'quality-book',
          'revision': revision,
          'entries': entries
        });
      }));
      addTearDown(harness.dispose);
      harness.scope.backend.capabilities = {'translationQuality': true};
      await tester.pumpWidget(harness.widget(f.FluentApp(
          theme: buildQingJuanTheme(f.Brightness.light),
          localizationsDelegates: const [
            m.DefaultMaterialLocalizations.delegate
          ],
          home: UiPlatformScope(
              platform:
                  mobile ? f.TargetPlatform.android : f.TargetPlatform.windows,
              child: const BookDetailPage(bookId: 'quality-book')))));
      await tester.pumpAndSettle();
      if (mobile) {
        await tester.tap(find.byIcon(f.FluentIcons.more));
        await tester.pumpAndSettle();
      } else {
        await tester.ensureVisible(find.text('作品管理'));
        await tester.tap(find.text('作品管理'));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.text('术语与人名'));
      await tester.tap(find.text('术语与人名'));
      await tester.pumpAndSettle();
      expect(find.byType(TranslationQualityPage), findsOneWidget);
      expect(unexpected, isEmpty);
      await tester.tap(find.byKey(const f.ValueKey('quality-add-term')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const f.ValueKey('quality-term-source')), 'Alice');
      await tester.enterText(
          find.byKey(const f.ValueKey('quality-term-target')), '艾丽丝');
      await tester.tap(find.text('人名'));
      await tester.tap(find.text('保存术语'));
      await tester.pumpAndSettle();
      expect(submitted.single['expectedRevision'], 0);
      expect((submitted.single['entries'] as List).single['kind'], 'name');
      expect(find.text('Alice → 艾丽丝'), findsOneWidget);
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const f.ValueKey('quality-term-target')), '爱丽丝');
      conflict = true;
      await tester.tap(find.text('保存术语'));
      await tester.pumpAndSettle();
      expect(submitted.last['expectedRevision'], 1);
      expect(find.textContaining('术语表已改变'), findsWidgets);
      final field = find.byKey(const f.ValueKey('quality-term-target'));
      final draft = mobile
          ? tester.widget<m.TextField>(field).controller!
          : tester.widget<f.TextBox>(field).controller!;
      expect(draft.text, '爱丽丝');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      entries = [
        {'source': 'Alice', 'target': '另一设备译名', 'kind': 'name', 'note': ''}
      ];
      revision = 2;
      await tester.tap(find.byKey(const f.ValueKey('quality-reload')));
      await tester.pumpAndSettle();
      expect(find.text('Alice → 另一设备译名'), findsOneWidget);
      expect(unexpected, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('glossary ignores late save after account switch ($mobile)',
        (tester) async {
      final pending = Completer<http.Response>();
      var saves = 0;
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.method == 'PUT') {
          saves++;
          return pending.future;
        }
        return response(
            {'bookId': 'quality-book', 'revision': 0, 'entries': []});
      }));
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.widget(
          TranslationQualityPage.glossary(
              bookId: 'quality-book', mobile: mobile),
          mobile: mobile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const f.ValueKey('quality-add-term')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const f.ValueKey('quality-term-source')), 'Alice');
      await tester.enterText(
          find.byKey(const f.ValueKey('quality-term-target')), '艾丽丝');
      await tester.tap(find.text('保存术语'));
      await tester.pump();
      harness.scope.library.resetForBackendSwitch();
      await tester.pumpAndSettle();
      expect(find.byKey(const f.ValueKey('quality-term-source')), findsNothing);
      expect(find.textContaining('账号、后端或术语表已变化'), findsOneWidget);
      pending.complete(response({
        'bookId': 'quality-book',
        'revision': 1,
        'entries': [
          {'source': 'Alice', 'target': '艾丽丝', 'kind': 'name', 'note': ''}
        ]
      }));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(find.text('Alice → 艾丽丝'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('账号或后端已切换，请返回书库重新打开。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
