import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/mobile/mobile_theme.dart';
import 'package:qingjuan/shared/mobile_palette.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  for (final dark in [false, true]) {
    test(
      'mobile ${dark ? 'dark' : 'light'} text and feedback have readable contrast',
      () {
        final colors = dark ? qjMobileDarkColors() : qjMobileLightColors();
        for (final pair in [
          (colors.onBackground, colors.background),
          (colors.onBackgroundVariant, colors.background),
          (colors.onSurfaceContainerVariant, colors.surfaceContainer),
          (colors.onPrimary, colors.primary),
          (colors.primary, colors.primaryContainer),
          (colors.error, colors.errorContainer),
          (
            dark ? MobilePalette.onActionDark : MobilePalette.onAction,
            dark ? MobilePalette.actionDark : MobilePalette.action
          ),
        ]) {
          expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
        }
      },
    );
  }
}
