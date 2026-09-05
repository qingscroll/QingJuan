import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart';

import '../shared/mobile_palette.dart';

const qjMobilePrimary = MobilePalette.accent;

MiuixColors qjMobileLightColors() => _mobileColors(false);
MiuixColors qjMobileDarkColors() => _mobileColors(true);

MiuixColors _mobileColors(bool dark) {
  final accent = dark ? MobilePalette.accentDark : MobilePalette.accent;
  final accentSoft =
      dark ? MobilePalette.accentSoftDark : MobilePalette.accentSoft;
  final background = dark ? MobilePalette.night : MobilePalette.paper;
  final card = dark ? MobilePalette.nightCard : MobilePalette.card;
  final ink = dark ? MobilePalette.nightInk : MobilePalette.ink;
  final muted = dark ? MobilePalette.nightMuted : MobilePalette.muted;
  final inset = dark ? MobilePalette.nightInset : MobilePalette.inset;
  final line = dark ? MobilePalette.nightLine : MobilePalette.line;
  final onAccent = dark ? MobilePalette.night : MobilePalette.card;
  return (dark ? darkColorScheme() : lightColorScheme()).copy(
    error: dark ? MobilePalette.errorDark : MobilePalette.error,
    onError: dark ? MobilePalette.night : MobilePalette.card,
    errorContainer: dark ? const Color(0xFF412928) : const Color(0xFFFCEAE7),
    onErrorContainer: dark ? MobilePalette.errorDark : MobilePalette.error,
    primary: accent,
    onPrimary: onAccent,
    primaryVariant: accentSoft,
    onPrimaryVariant: accent,
    primaryContainer: accentSoft,
    onPrimaryContainer: accent,
    disabledPrimary: accentSoft,
    disabledOnPrimary: muted,
    disabledPrimaryButton: accentSoft,
    disabledOnPrimaryButton: muted,
    disabledPrimarySlider: accentSoft,
    secondary: inset,
    onSecondary: ink,
    secondaryVariant: inset,
    onSecondaryVariant: ink,
    disabledSecondary: inset,
    disabledOnSecondary: muted,
    disabledSecondaryVariant: inset,
    disabledOnSecondaryVariant: muted,
    secondaryContainer: inset,
    onSecondaryContainer: ink,
    secondaryContainerVariant: inset,
    onSecondaryContainerVariant: muted,
    tertiaryContainer: inset,
    onTertiaryContainer: ink,
    tertiaryContainerVariant: inset,
    background: background,
    onBackground: ink,
    onBackgroundVariant: muted,
    surface: background,
    onSurface: ink,
    surfaceVariant: inset,
    onSurfaceSecondary: muted,
    onSurfaceVariantSummary: muted,
    onSurfaceVariantActions: accent,
    disabledOnSurface: muted.withValues(alpha: .5),
    surfaceContainer: card,
    onSurfaceContainer: ink,
    onSurfaceContainerVariant: muted,
    surfaceContainerHigh: inset,
    onSurfaceContainerHigh: ink,
    surfaceContainerHighest: line,
    onSurfaceContainerHighest: ink,
    outline: line,
    dividerLine: line,
    sliderKeyPoint: accent,
    sliderKeyPointForeground: onAccent,
    sliderBackground: inset,
  );
}

MiuixTextStyles qjMobileTextStyles() {
  TextStyle body(double size) =>
      TextStyle(fontSize: size, height: 1.45, fontWeight: FontWeight.w400);
  TextStyle title(double size) =>
      TextStyle(fontSize: size, height: 1.45, fontWeight: FontWeight.w600);
  return MiuixTextStyles(
    main: body(16),
    paragraph: body(16),
    body1: body(16),
    body2: body(14),
    button: title(14),
    footnote1: body(13),
    footnote2: body(12),
    headline1: title(17),
    headline2: title(16),
    subtitle: title(16),
    title1: title(24),
    title2: title(22),
    title3: title(21),
    title4: title(18),
  );
}
