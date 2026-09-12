import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/shared/desktop_subpage.dart';

import '../helpers/ui_review_capture.dart';

void main() {
  setUpAll(loadUiReviewFonts);
  for (final (width, scale) in [(1920.0, 1.0), (900.0, 1.0), (420.0, 2.0)]) {
    testWidgets('subpage heading aligns with content at $width / $scale',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final boundary = GlobalKey();
      const backKey = ValueKey('subpage-back');
      const contentKey = ValueKey('subpage-content-start');
      await tester.pumpWidget(FluentApp(
        debugShowCheckedModeBanner: false,
        theme: buildQingJuanTheme(Brightness.light,
            platform: TargetPlatform.windows),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: boundary, child: child!),
        ),
        home: Builder(
            builder: (context) => NavigationView(
                    content: Center(
                  child: Button(
                      onPressed: () => Navigator.of(context).push(
                            FluentPageRoute(
                                builder: (_) => DesktopSubpage(
                                      title: '编辑作品信息',
                                      maxContentWidth: 720,
                                      backKey: backKey,
                                      child: ListView(
                                          padding: const EdgeInsets.all(20),
                                          children: const [
                                            Text('书名', key: contentKey),
                                            SizedBox(height: 12),
                                            TextBox(placeholder: '输入作品名称'),
                                            SizedBox(height: 24),
                                            Text('作者'),
                                            SizedBox(height: 12),
                                            TextBox(placeholder: '输入作者'),
                                          ]),
                                    )),
                          ),
                      child: const Text('打开作品设置')),
                ))),
      ));
      await tester.tap(find.text('打开作品设置'));
      await tester.pumpAndSettle();
      final back = tester.getRect(find.byKey(backKey));
      final navigationTitle = tester.getRect(
          find.byKey(const ValueKey('desktop-subpage-navigation-title')));
      final title = tester
          .getRect(find.byKey(const ValueKey('desktop-subpage-content-title')));
      final content = tester.getRect(find.byKey(contentKey));
      expect(back.left, lessThan(24));
      expect(navigationTitle.left - back.right, greaterThanOrEqualTo(10));
      expect(navigationTitle.top, lessThan(back.bottom));
      expect(title.left, closeTo(content.left, 0.5));
      expect(title.top, greaterThan(navigationTitle.bottom));
      expect(title.bottom, lessThan(content.top));
      expect(title.right, lessThanOrEqualTo(width - 20));
      expect(tester.takeException(), isNull);
      await captureUi(tester, boundary,
          'subpage-header-${width.toInt()}-${scale.toInt()}x');
      await tester.tap(find.byKey(backKey));
      await tester.pumpAndSettle();
      expect(find.text('打开作品设置'), findsOneWidget);
      expect(find.text('编辑作品信息'), findsNothing);
    });
  }
}
