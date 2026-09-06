import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';

import '../shared/mobile_palette.dart';
import 'mobile_tokens.dart';

/// Neutral actions; inline reading links have no persistent filled container.
ButtonStyle mobileActionStyle(
    {required bool dark, bool tonal = false, bool inline = false}) {
  final foreground = tonal
      ? (dark ? MobilePalette.nightInk : MobilePalette.ink)
      : (dark ? MobilePalette.onActionDark : MobilePalette.onAction);
  final fill = inline
      ? Colors.transparent
      : tonal
          ? (dark ? const Color(0xFF1C1E1D) : const Color(0xFFF0F2EF))
          : (dark ? MobilePalette.actionDark : MobilePalette.action);
  final line = inline
      ? Colors.transparent
      : tonal
          ? (dark ? MobilePalette.nightLine : MobilePalette.line)
          : (dark ? MobilePalette.actionLineDark : MobilePalette.actionLine);
  return FilledButton.styleFrom(
    backgroundColor: fill,
    foregroundColor: foreground,
    disabledBackgroundColor: inline
        ? Colors.transparent
        : dark
            ? MobilePalette.nightInset
            : MobilePalette.inset,
    disabledForegroundColor:
        dark ? MobilePalette.nightMuted : MobilePalette.muted,
    overlayColor: foreground.withValues(alpha: .10),
    minimumSize: const Size(MobileTokens.touch, MobileTokens.touch),
    padding: EdgeInsets.symmetric(horizontal: inline ? 0 : 16, vertical: 10),
    textStyle: const TextStyle(
      fontSize: 14,
      height: 1.25,
      fontWeight: FontWeight.w500,
      decoration: TextDecoration.none,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    elevation: 0,
    tapTargetSize: MaterialTapTargetSize.padded,
    animationDuration: MobileTokens.feedbackDuration,
  ).copyWith(
    side: WidgetStateProperty.resolveWith((states) => BorderSide(
        color: inline
            ? Colors.transparent
            : states.contains(WidgetState.disabled)
                ? (dark ? MobilePalette.nightLine : MobilePalette.line)
                : line)),
  );
}

class MobileActionButton extends StatelessWidget {
  const MobileActionButton({
    required this.child,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.tonal = false,
    this.inline = false,
    super.key,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool tonal;
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final dark = (fluent.FluentTheme.maybeOf(context)?.brightness ??
            Theme.of(context).brightness) ==
        Brightness.dark;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final inheritedText = DefaultTextStyle.of(context).style;
    final style = mobileActionStyle(dark: dark, tonal: tonal, inline: inline);
    return Semantics(
      liveRegion: busy,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: style.copyWith(
          animationDuration: MobileTokens.duration(context, true),
          textStyle: WidgetStatePropertyAll(
              style.textStyle!.resolve(const <WidgetState>{})!.copyWith(
            fontFamily: inheritedText.fontFamily,
            fontFamilyFallback: inheritedText.fontFamilyFallback,
          )),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy || icon != null) ...[
              if (busy)
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    value: reduced ? .75 : null,
                    color:
                        dark ? MobilePalette.nightMuted : MobilePalette.muted,
                    semanticsLabel: '正在处理',
                  ),
                )
              else
                Icon(icon, size: 18),
              const SizedBox(width: 8),
            ],
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}
