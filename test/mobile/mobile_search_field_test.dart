import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/mobile/mobile_search_field.dart';
import 'package:qingjuan/mobile/mobile_theme.dart';

void main() {
  for (final dark in <bool>[false, true]) {
    for (final scale in <double>[1, 2]) {
      testWidgets(
          'search stays aligned at $scale x in ${dark ? 'dark' : 'light'}',
          (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        String? changed;
        String? submitted;
        await tester.pumpWidget(MiuixThemeController(
          colorSchemeMode:
              dark ? MiuixColorSchemeMode.dark : MiuixColorSchemeMode.light,
          lightColors: qjMobileLightColors(),
          darkColors: qjMobileDarkColors(),
          textStyles: qjMobileTextStyles(),
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(20),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: MobileSearchField(
                    controller: controller,
                    hintText: '搜索书名或作者，不应换行撑高输入框',
                    onChanged: (value) => changed = value,
                    onSubmitted: (value) => submitted = value,
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final field = find.byType(TextField);
        final before = tester.getRect(field);
        final iconBefore = tester.getRect(find.byIcon(Icons.search_rounded));
        expect(before.height, inInclusiveRange(48, 80));
        expect(iconBefore.left - before.left, greaterThanOrEqualTo(12));
        expect(iconBefore.center.dy, closeTo(before.center.dy, 1));

        await tester.enterText(field, '一段超过输入区域宽度的搜索文字，需要保持单行');
        await tester.pumpAndSettle();
        final iconAfter = tester.getRect(find.byIcon(Icons.search_rounded));
        expect(iconAfter, iconBefore);
        expect(tester.getSize(field).height, before.height);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        expect(submitted, controller.text);
        await tester.tap(find.bySemanticsLabel('清除搜索'));
        await tester.pumpAndSettle();
        expect(controller.text, isEmpty);
        expect(changed, isEmpty);
        expect(find.byIcon(Icons.cancel_outlined), findsNothing);
        expect(tester.getRect(find.byIcon(Icons.search_rounded)), iconBefore);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
