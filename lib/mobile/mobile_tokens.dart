import 'package:flutter/material.dart';

/// Mobile-only geometry. Desktop Fluent styles never depend on these values.
abstract final class MobileTokens {
  static const space4 = 4.0;
  static const space8 = 8.0;
  static const space12 = 12.0;
  static const space16 = 16.0;
  static const space24 = 24.0;
  static const space32 = 32.0;
  static const touch = 48.0;
  static const coverRadius = 6.0;
  static const controlRadius = 12.0;
  static const surfaceRadius = 16.0;
  static const sheetRadius = 24.0;
  static const tablet = 840.0;
  static const contentWidth = 1120.0;
  static const pageDuration = Duration(milliseconds: 240);
  static const feedbackDuration = Duration(milliseconds: 160);

  static Duration duration(BuildContext context, [bool feedback = false]) =>
      MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : feedback
              ? feedbackDuration
              : pageDuration;
}
