import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'mobile_tokens.dart';

// Navigation occupies its own Scaffold slot; lists need only an end gutter.
double mobileNavigationClearance(BuildContext context) => 24;

class MobileCard extends StatelessWidget {
  const MobileCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.onPressed,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? colors.surfaceContainer,
        borderRadius: BorderRadius.circular(MobileTokens.surfaceRadius),
      ),
      child: MobilePressable(
        onPressed: onPressed,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Shared touch feedback: a subtle opacity overlay, without scale or ripples.
class MobilePressable extends StatelessWidget {
  const MobilePressable({
    required this.child,
    required this.onPressed,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    super.key,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) => MiuixPressable(
        onPressed: onPressed,
        borderRadius: borderRadius,
        child: child,
      );
}

class MobileSection extends StatelessWidget {
  const MobileSection({required this.title, this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: theme.textStyles.subtitle.copyWith(
                color: theme.colors.onBackground,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class MobilePill extends StatelessWidget {
  const MobilePill(this.label, {this.color, super.key});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final foreground = color ?? colors.onSurfaceContainerVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: MiuixTheme.of(context).textStyles.footnote2.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
