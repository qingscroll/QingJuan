import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/features/reader/reader_theme.dart';

void main() {
  test('Android night reading is neutral black without changing desktop', () {
    final desktop = ReaderPalette.fromMode(ReaderPaletteMode.night);
    final mobile = desktop.mobilePalette;
    expect(desktop.background, const Color(0xFF151715));
    expect(mobile.background, const Color(0xFF090909));
    expect(mobile.surface, const Color(0xFF151515));
    expect(mobile.controlFill, const Color(0xFF242424));
    expect(_contrast(mobile.text, mobile.background), greaterThan(7));
    expect(
        _contrast(mobile.secondaryText, mobile.background), greaterThan(4.5));
  });

  test('reader palettes expose unique backgrounds and readable text', () {
    final backgrounds = ReaderPalette.palettes
        .map((palette) => palette.background.toARGB32())
        .toSet();

    expect(ReaderPalette.palettes, hasLength(5));
    expect(backgrounds, hasLength(5));
    for (final palette in ReaderPalette.palettes) {
      expect(_contrast(palette.text, palette.background), greaterThan(4.5));
    }
    expect(ReaderPalette.fromMode(ReaderPaletteMode.night).isDark, isTrue);
  });

  test('reader preference labels cover every persisted option', () {
    expect(ReaderPageAnimation.values.map((value) => value.label), <String>[
      '覆盖',
      '平移',
      '淡入',
      '无动画',
    ]);
    expect(ReaderLineSpacing.values.map((value) => value.label), <String>[
      '紧凑',
      '标准',
      '舒展',
    ]);
  });
}

double _contrast(Color foreground, Color background) {
  final bright = foreground.computeLuminance();
  final dark = background.computeLuminance();
  final lighter = bright > dark ? bright : dark;
  final darker = bright > dark ? dark : bright;
  return (lighter + 0.05) / (darker + 0.05);
}
