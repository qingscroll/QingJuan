import 'package:fluent_ui/fluent_ui.dart';

import '../../shared/motion.dart';
import 'reader_theme.dart';

class ReaderBottomAction extends StatelessWidget {
  const ReaderBottomAction({
    required this.icon,
    required this.label,
    required this.palette,
    required this.onPressed,
    this.selected = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final ReaderPalette palette;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final selectedText = palette.accent;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: Button(
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              elevation: const WidgetStatePropertyAll(0),
              shadowColor: const WidgetStatePropertyAll(Color(0x00000000)),
              foregroundColor: WidgetStatePropertyAll(
                selected ? selectedText : palette.text,
              ),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return selected
                      ? palette.accent.withAlpha(48)
                      : palette.controlFill.withAlpha(190);
                }
                return selected
                    ? palette.accent.withAlpha(24)
                    : const Color(0x00000000);
              }),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0x00000000)),
                ),
              ),
            ),
            onPressed: onPressed,
            child: SizedBox(
              height: 64,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(icon, size: 23),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? selectedText : palette.secondaryText,
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ReaderChoiceChip extends StatelessWidget {
  const ReaderChoiceChip({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onPressed,
    this.compact = false,
    super.key,
  });

  final String label;
  final bool selected;
  final ReaderPalette palette;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? (palette.isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF))
        : palette.text;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Button(
        style: ButtonStyle(
          elevation: const WidgetStatePropertyAll(0),
          shadowColor: const WidgetStatePropertyAll(Color(0x00000000)),
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: compact ? 13 : 18,
              vertical: compact ? 14 : 14,
            ),
          ),
          foregroundColor: WidgetStatePropertyAll(foreground),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return selected
                  ? palette.accent.withAlpha(190)
                  : palette.controlFill.withAlpha(190);
            }
            return selected
                ? palette.accent
                : palette.controlFill.withAlpha(175);
          }),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: selected ? palette.accent : const Color(0x00000000),
                width: selected ? 1 : 0,
              ),
            ),
          ),
        ),
        onPressed: onPressed,
        child: AnimatedDefaultTextStyle(
          duration: QjMotion.duration(context),
          curve: QjMotion.enterCurve,
          style: DefaultTextStyle.of(context).style.copyWith(
                color: foreground,
                fontSize: compact ? 13 : 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
          child: Text(label),
        ),
      ),
    );
  }
}

class ReaderPaletteSwatch extends StatelessWidget {
  const ReaderPaletteSwatch({
    required this.palette,
    required this.selected,
    required this.onPressed,
    super.key,
  });

  final ReaderPalette palette;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: palette.name,
      child: Semantics(
        button: true,
        selected: selected,
        label: '${palette.name}阅读背景',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox(
            width: 49,
            height: 49,
            child: Center(
              child: AnimatedContainer(
                key: ValueKey<String>('reader-palette-${palette.mode.name}'),
                duration: QjMotion.duration(context, QjMotionSpeed.slow),
                curve: QjMotion.enterCurve,
                width: selected ? 39 : 34,
                height: selected ? 39 : 34,
                decoration: BoxDecoration(
                  color: palette.background,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? palette.text : palette.divider,
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: selected
                      ? <BoxShadow>[
                          BoxShadow(
                            color: palette.text.withAlpha(20),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: selected
                    ? Icon(
                        FluentIcons.check_mark,
                        size: 14,
                        color: palette.text,
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
