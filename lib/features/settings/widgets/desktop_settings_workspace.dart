import 'package:fluent_ui/fluent_ui.dart';

import '../../../shared/smooth_scroll.dart';

enum SettingsCategory {
  connection,
  account,
  appearance,
  translation,
  application
}

class DesktopSettingsSection {
  const DesktopSettingsSection({
    required this.category,
    required this.title,
    required this.description,
    required this.icon,
    required this.child,
  });

  final SettingsCategory category;
  final String title;
  final String description;
  final IconData icon;
  final Widget child;
}

/// Keeps section state alive so navigating settings never discards a draft.
class DesktopSettingsWorkspace extends StatefulWidget {
  const DesktopSettingsWorkspace({required this.sections, super.key});

  final List<DesktopSettingsSection> sections;

  @override
  State<DesktopSettingsWorkspace> createState() =>
      _DesktopSettingsWorkspaceState();
}

class _DesktopSettingsWorkspaceState extends State<DesktopSettingsWorkspace> {
  SettingsCategory _selected = SettingsCategory.connection;
  final _scrollController = QjScrollController(debugLabel: 'settings-section');

  void _select(SettingsCategory category) {
    if (category == _selected) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _selected = category);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 860 ||
          MediaQuery.textScalerOf(context).scale(14) > 21;
      final body = Scrollbar(
        controller: _scrollController,
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.only(right: 12, bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final section in widget.sections)
                Offstage(
                  key: ValueKey(section.category),
                  offstage: _selected != section.category,
                  child: ExcludeFocus(
                    excluding: _selected != section.category,
                    child: TickerMode(
                      enabled: _selected == section.category,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(section.title, style: theme.typography.subtitle),
                          const SizedBox(height: 6),
                          Text(section.description,
                              style: theme.typography.body?.copyWith(
                                  color:
                                      theme.resources.textFillColorSecondary)),
                          const SizedBox(height: 20),
                          section.child,
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      return Flex(
          direction: compact ? Axis.vertical : Axis.horizontal,
          crossAxisAlignment:
              compact ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: compact ? null : 204,
              child: compact
                  ? ComboBox<SettingsCategory>(
                      key: const ValueKey('settings-category-picker'),
                      value: _selected,
                      isExpanded: true,
                      items: [
                        for (final section in widget.sections)
                          ComboBoxItem(
                              value: section.category,
                              child: Text(section.title,
                                  textAlign: TextAlign.start)),
                      ],
                      onChanged: (value) {
                        if (value != null) _select(value);
                      },
                    )
                  : SingleChildScrollView(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final section in widget.sections)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Semantics(
                                  selected: _selected == section.category,
                                  child: Button(
                                    key: ValueKey(
                                        'settings-category-${section.category.name}'),
                                    onPressed: () => _select(section.category),
                                    style: ButtonStyle(
                                      padding: const WidgetStatePropertyAll(
                                          EdgeInsets.zero),
                                      backgroundColor:
                                          WidgetStateProperty.resolveWith(
                                              (states) {
                                        if (states.isPressed ||
                                            states.isHovered) {
                                          return theme.resources
                                              .subtleFillColorSecondary;
                                        }
                                        return _selected == section.category
                                            ? theme.resources
                                                .subtleFillColorSecondary
                                            : Colors.transparent;
                                      }),
                                      shape: WidgetStatePropertyAll(
                                          RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(6))),
                                    ),
                                    child: ConstrainedBox(
                                      constraints:
                                          const BoxConstraints(minHeight: 46),
                                      child: Row(children: [
                                        Container(
                                            width: 3,
                                            height: 18,
                                            decoration: BoxDecoration(
                                                color: _selected ==
                                                        section.category
                                                    ? theme.accentColor
                                                    : Colors.transparent,
                                                borderRadius:
                                                    BorderRadius.circular(2))),
                                        const SizedBox(width: 14),
                                        Icon(section.icon, size: 17),
                                        const SizedBox(width: 12),
                                        Expanded(
                                            child: Text(section.title,
                                                textAlign: TextAlign.start)),
                                        const SizedBox(width: 12),
                                      ]),
                                    ),
                                  ),
                                ),
                              ),
                          ]),
                    ),
            ),
            SizedBox(width: compact ? 0 : 24, height: compact ? 20 : 0),
            Expanded(child: body),
          ]);
    });
  }
}
