import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';

import '../shared/mobile_palette.dart';

/// Windows 桌面端使用的青绿色 Fluent 强调色。
final qingJuanAccent = AccentColor.swatch(const <String, Color>{
  'darkest': Color(0xFF06433D),
  'darker': Color(0xFF075D55),
  'dark': Color(0xFF087269),
  'normal': Color(0xFF0B8278),
  'light': Color(0xFF339D94),
  'lighter': Color(0xFF72C2BB),
  'lightest': Color(0xFFD5EFEC),
});

/// Android 移动端使用中性纸白与青瓷强调色。
final qingJuanMobileAccent = AccentColor.swatch(const <String, Color>{
  'darkest': Color(0xFF1A352E),
  'darker': Color(0xFF254A40),
  'dark': Color(0xFF2C564C),
  'normal': MobilePalette.accent,
  'light': MobilePalette.accentDark,
  'lighter': Color(0xFFC6D9D1),
  'lightest': MobilePalette.accentSoft,
});

const qingJuanMobilePrimary = MobilePalette.accent;
const qingJuanPaper = MobilePalette.paper;
const qingJuanPaperSurface = MobilePalette.card;
const qingJuanInk = MobilePalette.night;
const qingJuanDarkSurface = MobilePalette.nightCard;
const qingJuanDarkElevated = MobilePalette.nightInset;

FluentThemeData buildQingJuanTheme(
  Brightness brightness, {
  TargetPlatform? platform,
}) {
  final target = platform ?? defaultTargetPlatform;
  return switch (target) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia =>
      _buildMobileTheme(brightness),
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux =>
      _buildDesktopTheme(brightness),
  };
}

FluentThemeData _buildDesktopTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return FluentThemeData(
    brightness: brightness,
    accentColor: qingJuanAccent,
    fasterAnimationDuration: const Duration(milliseconds: 60),
    fastAnimationDuration: const Duration(milliseconds: 110),
    mediumAnimationDuration: const Duration(milliseconds: 170),
    slowAnimationDuration: const Duration(milliseconds: 240),
    animationCurve: Curves.easeOutCubic,
    visualDensity: VisualDensity.standard,
    fontFamily: 'Segoe UI Variable Text',
    scaffoldBackgroundColor:
        isDark ? const Color(0xFF272727) : const Color(0xFFF9F9F9),
    micaBackgroundColor:
        isDark ? const Color(0xFF202020) : const Color(0xFFF3F3F3),
    acrylicBackgroundColor:
        isDark ? const Color(0xFF2B2B2B) : const Color(0xFFF9F9F9),
    menuColor: isDark ? const Color(0xFF2C2C2C) : const Color(0xFFFAFAFA),
    inactiveBackgroundColor:
        isDark ? const Color(0xFF303030) : const Color(0xFFEAEAEA),
    cardColor: isDark ? const Color(0xFF303030) : const Color(0xFFFFFFFF),
    navigationPaneTheme: NavigationPaneThemeData(
      animationDuration: const Duration(milliseconds: 110),
      animationCurve: Curves.easeOutCubic,
      backgroundColor:
          isDark ? const Color(0xFF202020) : const Color(0xFFF3F3F3),
      overlayBackgroundColor:
          isDark ? const Color(0xFF252525) : const Color(0xFFFAFAFA),
      headerPadding: const EdgeInsetsDirectional.only(
        start: 12,
        top: 14,
        end: 12,
        bottom: 6,
      ),
      iconPadding: const EdgeInsets.symmetric(horizontal: 12),
      labelPadding: const EdgeInsetsDirectional.only(end: 12),
    ),
    typography: Typography.raw(
      caption: TextStyle(
        fontFamily: 'Segoe UI Variable Text',
        fontSize: 12,
        color: isDark ? const Color(0xFFC7C7C7) : const Color(0xFF5D5D5D),
      ),
      body: TextStyle(
        fontFamily: 'Segoe UI Variable Text',
        fontSize: 14,
        color: isDark ? const Color(0xFFF2F2F2) : const Color(0xFF1B1B1B),
      ),
      bodyLarge: TextStyle(
        fontFamily: 'Segoe UI Variable Text',
        fontSize: 16,
        color: isDark ? const Color(0xFFF5F5F5) : const Color(0xFF171717),
      ),
      subtitle: TextStyle(
        fontFamily: 'Segoe UI Variable Display',
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: isDark ? const Color(0xFFF5F5F5) : const Color(0xFF171717),
      ),
      title: TextStyle(
        fontFamily: 'Segoe UI Variable Display',
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: isDark ? const Color(0xFFFFFFFF) : const Color(0xFF111111),
      ),
      titleLarge: TextStyle(
        fontFamily: 'Segoe UI Variable Display',
        fontSize: 32,
        fontWeight: FontWeight.w600,
        color: isDark ? const Color(0xFFFFFFFF) : const Color(0xFF111111),
      ),
      display: TextStyle(
        fontFamily: 'Segoe UI Variable Display',
        fontSize: 42,
        fontWeight: FontWeight.w600,
        color: isDark ? const Color(0xFFFFFFFF) : const Color(0xFF111111),
      ),
    ),
  );
}

FluentThemeData _buildMobileTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return FluentThemeData(
    brightness: brightness,
    accentColor: qingJuanMobileAccent,
    fasterAnimationDuration: const Duration(milliseconds: 60),
    fastAnimationDuration: const Duration(milliseconds: 110),
    mediumAnimationDuration: const Duration(milliseconds: 170),
    slowAnimationDuration: const Duration(milliseconds: 240),
    animationCurve: Curves.easeOutCubic,
    visualDensity: VisualDensity.standard,
    scaffoldBackgroundColor: isDark ? qingJuanInk : qingJuanPaper,
    micaBackgroundColor: isDark ? qingJuanInk : qingJuanPaper,
    acrylicBackgroundColor:
        isDark ? qingJuanDarkElevated : qingJuanPaperSurface,
    menuColor: isDark ? qingJuanDarkElevated : qingJuanPaperSurface,
    inactiveBackgroundColor:
        isDark ? MobilePalette.nightInset : MobilePalette.inset,
    cardColor: isDark ? qingJuanDarkSurface : qingJuanPaperSurface,
    navigationPaneTheme: NavigationPaneThemeData(
      animationDuration: const Duration(milliseconds: 110),
      animationCurve: Curves.easeOutCubic,
      backgroundColor: isDark ? qingJuanInk : qingJuanPaper,
      overlayBackgroundColor:
          isDark ? qingJuanDarkElevated : qingJuanPaperSurface,
      headerPadding: const EdgeInsetsDirectional.only(
        start: 12,
        top: 14,
        end: 12,
        bottom: 6,
      ),
      iconPadding: const EdgeInsets.symmetric(horizontal: 12),
      labelPadding: const EdgeInsetsDirectional.only(end: 12),
    ),
    typography: Typography.raw(
      caption: TextStyle(
        fontSize: 12,
        color: isDark ? MobilePalette.nightMuted : MobilePalette.muted,
      ),
      body: TextStyle(
        fontSize: 14,
        color: isDark ? MobilePalette.nightInk : MobilePalette.ink,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        color: isDark ? MobilePalette.nightInk : MobilePalette.ink,
      ),
      subtitle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: isDark ? MobilePalette.nightInk : MobilePalette.ink,
      ),
      title: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: isDark ? MobilePalette.nightInk : MobilePalette.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w700,
        color: isDark ? MobilePalette.nightInk : MobilePalette.ink,
      ),
      display: TextStyle(
        fontSize: 42,
        fontWeight: FontWeight.w600,
        color: isDark ? MobilePalette.nightInk : MobilePalette.ink,
      ),
    ),
  );
}
