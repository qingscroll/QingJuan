import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

/// Import history chooses controls by platform; width only changes their flow.
class ImportHistoryAction extends f.StatelessWidget {
  const ImportHistoryAction({
    required this.label,
    required this.mobile,
    required this.onPressed,
    this.primary = false,
    this.subtle = false,
    this.icon,
    super.key,
  });

  final String label;
  final bool mobile;
  final f.VoidCallback? onPressed;
  final bool primary;
  final bool subtle;
  final f.IconData? icon;

  @override
  f.Widget build(f.BuildContext context) {
    final child = f.Row(mainAxisSize: f.MainAxisSize.min, children: [
      if (icon != null) ...[
        f.Icon(icon, size: 16),
        const f.SizedBox(width: 8),
      ],
      f.Flexible(child: f.Text(label)),
    ]);
    if (mobile) {
      final style = m.TextButton.styleFrom(
        minimumSize: const f.Size(64, 48),
        padding: const f.EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      );
      if (primary) {
        return m.FilledButton(style: style, onPressed: onPressed, child: child);
      }
      if (subtle) {
        return m.TextButton(style: style, onPressed: onPressed, child: child);
      }
      return m.OutlinedButton(style: style, onPressed: onPressed, child: child);
    }
    if (primary) return f.FilledButton(onPressed: onPressed, child: child);
    if (subtle) return f.HyperlinkButton(onPressed: onPressed, child: child);
    return f.Button(onPressed: onPressed, child: child);
  }
}

class ImportHistorySurface extends f.StatelessWidget {
  const ImportHistorySurface({
    required this.mobile,
    required this.child,
    this.padding = const f.EdgeInsets.all(20),
    super.key,
  });

  final bool mobile;
  final f.Widget child;
  final f.EdgeInsetsGeometry padding;

  @override
  f.Widget build(f.BuildContext context) => f.Container(
        width: double.infinity,
        padding: padding,
        decoration: f.BoxDecoration(
          color: mobile
              ? m.Theme.of(context).colorScheme.surface
              : f.FluentTheme.of(context).cardColor,
          border: f.Border.all(
            color: mobile
                ? m.Theme.of(context).colorScheme.outlineVariant
                : f.FluentTheme.of(context).resources.cardStrokeColorDefault,
          ),
          borderRadius: f.BorderRadius.circular(mobile ? 16 : 8),
        ),
        child: child,
      );
}

f.TextStyle? importHistorySecondaryStyle(f.BuildContext context, bool mobile) =>
    mobile
        ? m.Theme.of(context).textTheme.bodySmall?.copyWith(
              color: m.Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            )
        : f.FluentTheme.of(context).typography.caption?.copyWith(
              color: f.FluentTheme.of(context).resources.textFillColorSecondary,
              height: 1.5,
            );

/// API timestamps are UTC; show an unambiguous local date and time.
String importHistoryLocalTime(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return '时间未知';
  String pad(int number) => number.toString().padLeft(2, '0');
  return '${date.year}年${date.month}月${date.day}日 '
      '${pad(date.hour)}:${pad(date.minute)}';
}
