import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

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
    return MiuixCard(
      onPressed: onPressed,
      feedbackType: onPressed == null
          ? MiuixPressFeedbackType.none
          : MiuixPressFeedbackType.sink,
      cornerRadius: 18,
      colors: MiuixCardColors(
        color: color ?? colors.surfaceContainer,
        contentColor: colors.onSurfaceContainer,
      ),
      insideMargin: padding,
      child: child,
    );
  }
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
        borderRadius: BorderRadius.circular(999),
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
