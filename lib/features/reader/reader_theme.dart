import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_state.dart';
import '../../shared/mobile_palette.dart';

class ReaderPalette {
  const ReaderPalette({
    required this.mode,
    required this.name,
    required this.background,
    required this.surface,
    required this.text,
    required this.secondaryText,
    required this.divider,
    required this.controlFill,
    required this.accent,
    required this.isDark,
  });

  final ReaderPaletteMode mode;
  final String name;
  final Color background;
  final Color surface;
  final Color text;
  final Color secondaryText;
  final Color divider;
  final Color controlFill;
  final Color accent;
  final bool isDark;

  ReaderPalette withAccent(Color value) => ReaderPalette(
        mode: mode,
        name: name,
        background: background,
        surface: surface,
        text: text,
        secondaryText: secondaryText,
        divider: divider,
        controlFill: controlFill,
        accent: value,
        isDark: isDark,
      );

  /// Android uses a neutral black reading surface; desktop keeps its palette.
  ReaderPalette get mobilePalette => mode == ReaderPaletteMode.night
      ? const ReaderPalette(
          mode: ReaderPaletteMode.night,
          name: '夜间',
          background: Color(0xFF090909),
          surface: Color(0xFF151515),
          text: Color(0xFFCECFCC),
          secondaryText: Color(0xFFA8ADA9),
          divider: Color(0xFF2A2A2A),
          controlFill: Color(0xFF242424),
          accent: MobilePalette.accentDark,
          isDark: true,
        )
      : this;

  Color get overlay =>
      isDark ? const Color(0xA6000000) : const Color(0x520F0D09);

  AccentColor get fluentAccent => AccentColor.swatch(<String, Color>{
        'darkest': Color.lerp(accent, const Color(0xFF000000), 0.48)!,
        'darker': Color.lerp(accent, const Color(0xFF000000), 0.34)!,
        'dark': Color.lerp(accent, const Color(0xFF000000), 0.18)!,
        'normal': accent,
        'light': Color.lerp(accent, const Color(0xFFFFFFFF), 0.2)!,
        'lighter': Color.lerp(accent, const Color(0xFFFFFFFF), 0.42)!,
        'lightest': Color.lerp(accent, const Color(0xFFFFFFFF), 0.72)!,
      });

  static const palettes = <ReaderPalette>[
    ReaderPalette(
      mode: ReaderPaletteMode.white,
      name: '明亮',
      background: Color(0xFFFAFAF8),
      surface: Color(0xFFFFFFFF),
      text: Color(0xFF282927),
      secondaryText: Color(0xFF767670),
      divider: Color(0xFFE7E7E2),
      controlFill: Color(0xFFF0F0EC),
      accent: Color(0xFFE9644A),
      isDark: false,
    ),
    ReaderPalette(
      mode: ReaderPaletteMode.parchment,
      name: '纸张',
      background: Color(0xFFF2EBD8),
      surface: Color(0xFFF5EEDC),
      text: Color(0xFF413827),
      secondaryText: Color(0xFF786C55),
      divider: Color(0xFFE0D6BC),
      controlFill: Color(0xFFE9DFC8),
      accent: Color(0xFF9C6237),
      isDark: false,
    ),
    ReaderPalette(
      mode: ReaderPaletteMode.eyeCare,
      name: '护眼',
      background: Color(0xFFE2EBD8),
      surface: Color(0xFFE8F0DF),
      text: Color(0xFF2F3A30),
      secondaryText: Color(0xFF687567),
      divider: Color(0xFFCFDBC7),
      controlFill: Color(0xFFD6E2CE),
      accent: Color(0xFF4F8B68),
      isDark: false,
    ),
    ReaderPalette(
      mode: ReaderPaletteMode.mist,
      name: '雾蓝',
      background: Color(0xFFE1EAF1),
      surface: Color(0xFFE8F0F6),
      text: Color(0xFF2D3841),
      secondaryText: Color(0xFF64727D),
      divider: Color(0xFFCCD9E3),
      controlFill: Color(0xFFD3E0E9),
      accent: Color(0xFF4B7C9C),
      isDark: false,
    ),
    ReaderPalette(
      mode: ReaderPaletteMode.night,
      name: '夜间',
      background: Color(0xFF151715),
      surface: Color(0xFF1D201E),
      text: Color(0xFFD9D7D0),
      secondaryText: Color(0xFF92968F),
      divider: Color(0xFF2C302D),
      controlFill: Color(0xFF292D2A),
      accent: Color(0xFF65B5A8),
      isDark: true,
    ),
  ];

  static ReaderPalette fromMode(ReaderPaletteMode mode) => palettes.firstWhere(
        (palette) => palette.mode == mode,
        orElse: () => palettes[1],
      );
}

extension ReaderLineSpacingPresentation on ReaderLineSpacing {
  String get label => switch (this) {
        ReaderLineSpacing.compact => '紧凑',
        ReaderLineSpacing.standard => '标准',
        ReaderLineSpacing.relaxed => '舒展',
      };

  double get height => switch (this) {
        ReaderLineSpacing.compact => 1.62,
        ReaderLineSpacing.standard => 1.8,
        ReaderLineSpacing.relaxed => 2.04,
      };
}

extension ReaderPageAnimationPresentation on ReaderPageAnimation {
  String get label => switch (this) {
        ReaderPageAnimation.cover => '覆盖',
        ReaderPageAnimation.slide => '平移',
        ReaderPageAnimation.fade => '淡入',
        ReaderPageAnimation.none => '无动画',
      };
}
