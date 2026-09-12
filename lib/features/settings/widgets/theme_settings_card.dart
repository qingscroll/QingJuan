import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' show Icons;

import '../../../app/app_state.dart';
import '../../../shared/app_surface.dart';
import '../../../shared/responsive.dart';
import 'settings_section_card.dart';

class ThemeSettingsCard extends StatelessWidget {
  const ThemeSettingsCard({
    required this.themeMode,
    required this.onChanged,
    super.key,
  });

  final AppThemeMode themeMode;
  final ValueChanged<AppThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final mobile = usesMobileUi(context);
    final platformLabel = switch (UiPlatformScope.of(context)) {
      TargetPlatform.windows => 'Windows',
      TargetPlatform.android => 'Android',
      _ => '当前设备',
    };
    return SettingsSectionCard(
      icon: FluentIcons.color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '外观模式',
            style: FluentTheme.of(context)
                .typography
                .bodyLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '跟随系统可自动响应$platformLabel的浅色与深色设置。',
            style: FluentTheme.of(context).typography.caption,
          ),
          const SizedBox(height: 14),
          if (mobile)
            Row(
              children: <Widget>[
                for (var index = 0;
                    index < AppThemeMode.values.length;
                    index++) ...<Widget>[
                  if (index > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _ThemeModeChoice(
                      key: ValueKey<String>(
                        'theme-mode-${AppThemeMode.values[index].name}',
                      ),
                      label: _label(AppThemeMode.values[index]),
                      icon: _icon(
                        AppThemeMode.values[index],
                        mobile: true,
                      ),
                      selected: themeMode == AppThemeMode.values[index],
                      onPressed: () => onChanged(AppThemeMode.values[index]),
                    ),
                  ),
                ],
              ],
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: AppThemeMode.values.map((mode) {
                final label = switch (mode) {
                  AppThemeMode.system => '跟随系统',
                  AppThemeMode.light => '浅色',
                  AppThemeMode.dark => '深色',
                };
                return _ThemeModeChoice(
                  key: ValueKey<String>('theme-mode-${mode.name}'),
                  label: label,
                  icon: _icon(mode, mobile: false),
                  selected: themeMode == mode,
                  onPressed: () => onChanged(mode),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  String _label(AppThemeMode mode) => switch (mode) {
        AppThemeMode.system => '跟随系统',
        AppThemeMode.light => '浅色',
        AppThemeMode.dark => '深色',
      };

  IconData _icon(AppThemeMode mode, {required bool mobile}) => switch (mode) {
        AppThemeMode.system =>
          mobile ? Icons.brightness_auto_rounded : FluentIcons.system,
        AppThemeMode.light =>
          mobile ? Icons.light_mode_rounded : FluentIcons.brightness,
        AppThemeMode.dark =>
          mobile ? Icons.dark_mode_rounded : FluentIcons.clear_night,
      };
}

class _ThemeModeChoice extends StatelessWidget {
  const _ThemeModeChoice({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final mobile = usesMobileUi(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return SizedBox(
      width: mobile
          ? double.infinity
          : 20 + MediaQuery.textScalerOf(context).scale(12) * 6,
      child: AppSurface(
        onPressed: onPressed,
        selected: selected,
        tone: selected ? AppSurfaceTone.accent : AppSurfaceTone.muted,
        borderRadius: mobile ? 16 : 8,
        padding: EdgeInsets.symmetric(
          horizontal: mobile ? 4 : 10,
          vertical: 12,
        ),
        child: Column(
          children: <Widget>[
            Icon(
              icon,
              semanticLabel: '$label外观',
              size: 20,
              color: selected ? accent : theme.resources.textFillColorSecondary,
            ),
            const SizedBox(height: 7),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: theme.typography.caption?.copyWith(
                  color: selected ? accent : null,
                  fontWeight: selected ? FontWeight.w700 : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
