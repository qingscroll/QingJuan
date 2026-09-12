import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/library/book_metadata_editor.dart';
import 'package:qingjuan/features/library/library_organization_controls.dart';
import 'package:qingjuan/features/library/widgets/desktop_library_view.dart';
import 'package:qingjuan/shared/responsive.dart';

import '../../helpers/reliability_harness.dart';

void main() {
  testWidgets(
      'desktop library opens metadata editor and reflects a successful save',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const f.Size(1280, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harness = await ReliabilityHarness.create(MockClient(
        (request) async => _json(request.method == 'PATCH'
            ? {..._metadata, 'title': '已保存标题', 'revision': 4}
            : _metadata)));
    addTearDown(harness.dispose);
    harness.scope.backend.capabilities['libraryMetadata'] = true;
    harness.scope.library.books = [
      Book.fromJson({'id': 'book', 'title': '原标题', 'groupName': '收藏'})
    ];
    harness.scope.library.state = LoadState.ready;
    await tester.pumpWidget(harness.widget(
        UiPlatformScope(
            platform: f.TargetPlatform.windows,
            child: f.AnimatedBuilder(
                animation: harness.scope.library,
                builder: (context, _) => DesktopLibraryView(
                    controller: harness.scope.library,
                    onOpen: (_) {},
                    onImport: () {}))),
        textScale: 2));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryOrganizationControls), findsOneWidget);
    await tester.ensureVisible(find.byKey(const f.ValueKey('book-more-book')));
    await tester.tap(find.byKey(const f.ValueKey('book-more-book')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const f.ValueKey('edit-book-book')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const f.ValueKey('metadata-title')), '已保存标题');
    f.FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存修改'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(find.byType(BookMetadataEditor), findsNothing);
    expect(harness.scope.library.books.single.title, '已保存标题');
    expect(find.text('已保存标题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final mobile in [false, true]) {
    testWidgets(
        'metadata editor preserves failed drafts and clears old account at 200 percent mobile=$mobile',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize =
          mobile ? const f.Size(390, 844) : const f.Size(1100, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final patches = <JsonMap>[];
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.method == 'PATCH') {
          patches.add(jsonDecode(request.body) as JsonMap);
          return _json({'detail': '其他设备已修改作品信息，请重新加载后再保存'}, 409);
        }
        return _json(_metadata);
      }));
      addTearDown(harness.dispose);
      // The platform presentation is selected explicitly, independent of host OS.
      await tester.pumpWidget(harness.widget(
          BookMetadataEditor(bookId: 'book', mobile: mobile),
          mobile: mobile,
          textScale: 2));
      await tester.pumpAndSettle();
      final title = find.byKey(const f.ValueKey('metadata-title'));
      expect(title, findsOneWidget,
          reason: tester
              .widgetList<f.Text>(find.byType(f.Text))
              .map((w) => w.data)
              .join(' | '));
      await tester.ensureVisible(title);
      await tester.enterText(title, '修改后的标题');
      final group = find.byKey(const f.ValueKey('metadata-groupName'));
      await tester.ensureVisible(group);
      await tester.enterText(group, '收藏');
      final tags = find.byKey(const f.ValueKey('metadata-tags'));
      await tester.ensureVisible(tags);
      await tester.enterText(tags, '科幻，科幻,经典');
      f.FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存修改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(patches.single, {
        'expectedRevision': 3,
        'title': '修改后的标题',
        'groupName': '收藏',
        'tags': ['科幻', '经典']
      });
      expect(find.text('其他设备已修改作品信息，请重新加载后再保存'), findsOneWidget);
      await tester.ensureVisible(title);
      expect(find.text('修改后的标题'), findsOneWidget);
      expect(tester.takeException(), isNull);
      harness.scope.library.resetForBackendSwitch();
      await tester.pumpAndSettle();
      expect(find.text('修改后的标题'), findsNothing);
      expect(find.text('账号或服务已切换，请返回书库重新打开作品。'), findsOneWidget);
      expect(find.text('保存修改'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'source reset submits null without overriding unchanged fields mobile=$mobile',
        (tester) async {
      JsonMap? patch;
      final harness =
          await ReliabilityHarness.create(MockClient((request) async {
        if (request.method == 'PATCH') {
          patch = jsonDecode(request.body) as JsonMap;
          return _json({'detail': '测试保留页面'}, 409);
        }
        return _json({
          ..._metadata,
          'overriddenFields': ['title']
        });
      }));
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.widget(
          BookMetadataEditor(bookId: 'book', mobile: mobile),
          mobile: mobile));
      await tester.pumpAndSettle();
      expect(find.text('恢复来源书名'), findsOneWidget,
          reason: tester
              .widgetList<f.Text>(find.byType(f.Text))
              .map((w) => w.data)
              .join(' | '));
      await tester.tap(find.text('恢复来源书名'));
      await tester.ensureVisible(find.text('保存修改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(patch, {'expectedRevision': 3, 'title': null});
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'mobile filters preserve independent selection and clear together',
      (tester) async {
    final harness =
        await ReliabilityHarness.create(MockClient((_) async => _json([])));
    addTearDown(harness.dispose);
    harness.scope.library.books = [
      Book.fromJson({
        'id': '1',
        'title': '书名',
        'groupName': '我的分组',
        'tags': ['科幻']
      })
    ];
    await tester.pumpWidget(harness.widget(
        m.Scaffold(
            body: m.SingleChildScrollView(
                child: LibraryOrganizationControls(
                    controller: harness.scope.library, mobile: true))),
        mobile: true));
    await tester.tap(find.text('全部分组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的分组').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('科幻').last);
    await tester.pumpAndSettle();
    expect(harness.scope.library.groupFilter, '我的分组');
    expect(harness.scope.library.tagFilter, '科幻');
    await tester.ensureVisible(find.text('清除筛选'));
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(harness.scope.library.hasOrganizationFilters, isFalse);
    expect(tester.takeException(), isNull);
  });
}

const _metadata = <String, Object?>{
  'bookId': 'book',
  'title': '原标题',
  'author': '来源作者',
  'synopsis': '来源简介',
  'revision': 3,
  'readingState': 'unread'
};
http.Response _json(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
