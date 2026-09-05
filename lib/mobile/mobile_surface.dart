import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';

import '../shared/mobile_palette.dart';

/// Opaque elevated surface: stable contrast without per-frame backdrop blur.
class MobileOverlaySurface extends StatelessWidget {
  const MobileOverlaySurface({
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.padding = EdgeInsets.zero,
    this.isDark,
    super.key,
  });
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final bool? isDark;

  @override
  Widget build(BuildContext context) {
    final dark = isDark ??
        ((fluent.FluentTheme.maybeOf(context)?.brightness ??
                Theme.of(context).brightness) ==
            Brightness.dark);
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Material(
          color: dark ? MobilePalette.nightCard : MobilePalette.card,
          shape: RoundedRectangleBorder(
            borderRadius: borderRadius,
            side: BorderSide(
                color: dark ? MobilePalette.nightLine : MobilePalette.line),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
