import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/features/settings/widgets/desktop_settings_workspace.dart';

Future<void> selectSettingsCategory(
    WidgetTester tester, SettingsCategory category) async {
  final button = find.byKey(ValueKey('settings-category-${category.name}'));
  if (button.evaluate().isNotEmpty) {
    await tester.tap(button);
  } else {
    final picker = find.byKey(const ValueKey('settings-category-picker'));
    final item = tester
        .widget<ComboBox<SettingsCategory>>(picker)
        .items!
        .singleWhere((item) => item.value == category);
    final label = (item.child as Text).data!;
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
  }
  await tester.pumpAndSettle();
}
