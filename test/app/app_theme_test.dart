import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/app/app_theme.dart';

void main() {
  test('theme uses short responsive motion timings', () {
    final theme = buildQingJuanTheme(
      Brightness.light,
      platform: TargetPlatform.windows,
    );

    expect(theme.fasterAnimationDuration, const Duration(milliseconds: 60));
    expect(theme.fastAnimationDuration, const Duration(milliseconds: 110));
    expect(theme.mediumAnimationDuration, const Duration(milliseconds: 170));
    expect(theme.slowAnimationDuration, const Duration(milliseconds: 240));
    expect(theme.animationCurve, Curves.easeOutCubic);
    expect(
      theme.navigationPaneTheme.animationDuration,
      const Duration(milliseconds: 110),
    );
  });

  test('Windows keeps the v1.3.4 Fluent desktop palette and typography', () {
    final theme = buildQingJuanTheme(
      Brightness.light,
      platform: TargetPlatform.windows,
    );

    expect(theme.accentColor.normal, const Color(0xFF0B8278));
    expect(theme.scaffoldBackgroundColor, const Color(0xFFF3F3F3));
    expect(theme.cardColor, const Color(0xFFFBFBFB));
    expect(theme.typography.body?.fontFamily, 'Segoe UI Variable Text');
    expect(theme.typography.title?.fontFamily, 'Segoe UI Variable Text');
  });

  test('Android uses the independent neutral and celadon palette', () {
    final theme = buildQingJuanTheme(
      Brightness.light,
      platform: TargetPlatform.android,
    );

    expect(theme.accentColor.normal, const Color(0xFF315F55));
    expect(theme.scaffoldBackgroundColor, qingJuanPaper);
    expect(theme.cardColor, qingJuanPaperSurface);
    expect(theme.typography.body?.fontFamily, isNot('Segoe UI Variable Text'));
  });
}
