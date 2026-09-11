import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../../app/app_state.dart';
import '../../shared/motion.dart';
import '../../shared/responsive.dart';

/// Store-style navigation, kept separate from the mobile shell.
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    required this.section,
    required this.pageFor,
    required this.primarySections,
    required this.labelFor,
    required this.iconFor,
    required this.onSelected,
    super.key,
  });

  final AppSection section;
  final Widget Function(AppSection) pageFor;
  final List<AppSection> primarySections;
  final String Function(AppSection) labelFor;
  final IconData Function(AppSection) iconFor;
  final ValueChanged<AppSection> onSelected;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  static const _minimumPaneWidth = 220.0;
  static const _maximumPaneWidth = 420.0;

  double _paneWidth = 240;
  bool _paneCollapsed = true;
  bool _resizeHandleHovered = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent || !HardwareKeyboard.instance.isControlPressed) {
      return false;
    }
    // Keep existing Ctrl+1…8 destinations, including settings and about.
    final sections = <AppSection>[
      ...widget.primarySections,
      AppSection.about,
    ];
    for (var index = 0; index < sections.length; index++) {
      if (event.logicalKey == _shortcutKey(index) ||
          event.physicalKey == _shortcutPhysicalKey(index)) {
        widget.onSelected(sections[index]);
        return true;
      }
    }
    return false;
  }

  void _resizePane(DragUpdateDetails details, double maximumWidth) {
    setState(() {
      _paneWidth = (_paneWidth + details.delta.dx)
          .clamp(_minimumPaneWidth, maximumWidth)
          .toDouble();
    });
  }

  PaneItem _paneItem(AppSection section, {required bool compact}) {
    final label = widget.labelFor(section);
    return PaneItem(
      key: ValueKey('desktop-navigation-${section.name}'),
      icon: compact
          ? _RailLabel(icon: widget.iconFor(section), label: label)
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Icon(widget.iconFor(section), size: 18),
            ),
      title: Text(label),
      selectedTileColor: WidgetStateProperty.resolveWith((states) {
        final theme = FluentTheme.of(context);
        return states.isPressed
            ? theme.resources.subtleFillColorTertiary
            : states.isHovered
                ? Color.lerp(theme.cardColor, theme.micaBackgroundColor, .35)
                : theme.cardColor;
      }),
      body: widget.pageFor(section),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final canExpand = windowClassOf(context) == WindowClass.expanded;
    final compact = !canExpand || _paneCollapsed;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final railWidth = 80 + 40 * (textScale - 1).clamp(0.0, 1.0);
    final maximumPaneWidth = (MediaQuery.sizeOf(context).width * 0.36)
        .clamp(_minimumPaneWidth, _maximumPaneWidth)
        .toDouble();
    final paneWidth =
        _paneWidth.clamp(_minimumPaneWidth, maximumPaneWidth).toDouble();
    final mainSections = widget.primarySections
        .where((section) => section != AppSection.settings)
        .toList();
    final footerSections = <AppSection>[
      if (widget.primarySections.contains(AppSection.settings))
        AppSection.settings,
      AppSection.about,
    ];
    final sections = <AppSection>[...mainSections, ...footerSections];
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);

    return Stack(
      key: const ValueKey('desktop-shell'),
      children: <Widget>[
        NavigationPaneTheme.merge(
          data: NavigationPaneThemeData(
            animationDuration: QjMotion.duration(context, QjMotionSpeed.fast),
            animationCurve: QjMotion.enterCurve,
            backgroundColor: theme.micaBackgroundColor,
            iconPadding: compact
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 16),
            selectedIconColor: WidgetStatePropertyAll(accent),
            unselectedIconColor:
                WidgetStatePropertyAll(theme.resources.textFillColorSecondary),
            selectedTextStyle: WidgetStatePropertyAll(
              theme.typography.body!.copyWith(
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            unselectedTextStyle: WidgetStatePropertyAll(
              theme.typography.body!.copyWith(
                color: theme.resources.textFillColorSecondary,
              ),
            ),
          ),
          child: NavigationView(
            key: const ValueKey('tablet-navigation'),
            transitionBuilder: (child, _) => QjPageSwitcher(
              pageKey: child.key ?? widget.section,
              beginOffset: const Offset(0.018, 0),
              child: child,
            ),
            pane: NavigationPane(
              selected: sections.indexOf(widget.section),
              displayMode:
                  compact ? PaneDisplayMode.compact : PaneDisplayMode.open,
              onChanged: (index) => widget.onSelected(sections[index]),
              indicator: const StickyNavigationIndicator(
                indicatorSize: 3,
              ),
              size: NavigationPaneSize(
                compactWidth: railWidth,
                openWidth: paneWidth,
                openMinWidth: _minimumPaneWidth,
                openMaxWidth: maximumPaneWidth,
              ),
              menuButton: canExpand
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
                      child: SizedBox(
                        width: compact ? railWidth - 12 : double.infinity,
                        height: 32,
                        child: Tooltip(
                          message: compact ? '展开导航栏' : '收起导航栏',
                          child: IconButton(
                            key: const ValueKey('navigation-pane-toggle'),
                            icon: Icon(
                              FluentIcons.global_nav_button,
                              size: 16,
                              semanticLabel: compact ? '展开导航栏' : '收起导航栏',
                            ),
                            onPressed: () => setState(
                                () => _paneCollapsed = !_paneCollapsed),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox(height: 8),
              items: <NavigationPaneItem>[
                for (final section in mainSections)
                  _paneItem(section, compact: compact),
              ],
              footerItems: <NavigationPaneItem>[
                for (final section in footerSections)
                  _paneItem(section, compact: compact),
              ],
            ),
          ),
        ),
        if (!compact)
          PositionedDirectional(
            start: paneWidth - 4,
            top: 0,
            bottom: 0,
            width: 8,
            child: Semantics(
              label: '调整导航栏宽度',
              child: MouseRegion(
                key: const ValueKey('navigation-pane-resizer'),
                cursor: SystemMouseCursors.resizeColumn,
                onEnter: (_) => setState(() => _resizeHandleHovered = true),
                onExit: (_) => setState(() => _resizeHandleHovered = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (details) =>
                      _resizePane(details, maximumPaneWidth),
                  child: Center(
                    child: AnimatedContainer(
                      duration:
                          QjMotion.duration(context, QjMotionSpeed.faster),
                      curve: QjMotion.enterCurve,
                      width: _resizeHandleHovered ? 2 : 1,
                      color: _resizeHandleHovered
                          ? accent
                          : theme.resources.cardStrokeColorDefault,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  LogicalKeyboardKey _shortcutKey(int index) => switch (index) {
        0 => LogicalKeyboardKey.digit1,
        1 => LogicalKeyboardKey.digit2,
        2 => LogicalKeyboardKey.digit3,
        3 => LogicalKeyboardKey.digit4,
        4 => LogicalKeyboardKey.digit5,
        5 => LogicalKeyboardKey.digit6,
        6 => LogicalKeyboardKey.digit7,
        _ => LogicalKeyboardKey.digit8,
      };

  PhysicalKeyboardKey _shortcutPhysicalKey(int index) => switch (index) {
        0 => PhysicalKeyboardKey.digit1,
        1 => PhysicalKeyboardKey.digit2,
        2 => PhysicalKeyboardKey.digit3,
        3 => PhysicalKeyboardKey.digit4,
        4 => PhysicalKeyboardKey.digit5,
        5 => PhysicalKeyboardKey.digit6,
        6 => PhysicalKeyboardKey.digit7,
        _ => PhysicalKeyboardKey.digit8,
      };
}

class _RailLabel extends StatelessWidget {
  const _RailLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    // PaneItem supplies keyboard focus, tooltips, and selection semantics.
    return ExcludeSemantics(
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 21),
              const SizedBox(height: 7),
              Text(
                label,
                maxLines: textScale > 1.3 ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.typography.caption?.copyWith(
                  fontSize: 11,
                  height: 1.25,
                  color: IconTheme.of(context).color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
