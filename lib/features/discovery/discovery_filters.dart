import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

import '../../shared/app_surface.dart';
import 'discovery_controller.dart';

class DiscoveryFilters extends StatelessWidget {
  const DiscoveryFilters({required this.controller, super.key});

  final DiscoveryController controller;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final site = controller.selectedSite;
    return AppSurface(
      child: LayoutBuilder(builder: (context, constraints) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: <Widget>[
                SizedBox(
                  width: math.min(260, constraints.maxWidth),
                  child: InfoLabel(
                    label: '站点',
                    child: ComboBox<String>(
                      key: const ValueKey('discovery-site'),
                      isExpanded: true,
                      value: site?.site,
                      items: [
                        for (final item in controller.sites)
                          ComboBoxItem(
                            value: item.site,
                            child: Text(
                              '${item.siteName} · ${item.content == 'comic' ? '漫画' : '小说'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) controller.selectSite(value);
                      },
                    ),
                  ),
                ),
                Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
                  for (final entry
                      in const {'recommend': '推荐', 'rank': '排行榜'}.entries)
                    ToggleButton(
                      key: ValueKey('discovery-kind-${entry.key}'),
                      checked: controller.kind == entry.key,
                      onChanged: (_) => controller.selectKind(entry.key),
                      child: Text(entry.value),
                    ),
                ]),
                if (controller.channels.isNotEmpty)
                  SizedBox(
                    width: math.min(340, constraints.maxWidth),
                    child: InfoLabel(
                      label: controller.kind == 'rank' ? '榜单' : '推荐栏目',
                      child: ComboBox<String>(
                        key: const ValueKey('discovery-channel'),
                        isExpanded: true,
                        value: controller.selectedChannel?.key,
                        items: [
                          for (final channel in controller.channels)
                            ComboBoxItem(
                              value: channel.key,
                              child: Text(
                                [channel.group, channel.name]
                                    .where((s) => s.isNotEmpty)
                                    .join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) controller.selectChannel(value);
                        },
                      ),
                    ),
                  ),
              ],
            ),
            if (site != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                '${site.channels.where((c) => c.kind == 'recommend').length} 个推荐栏目 · '
                '${site.channels.where((c) => c.kind == 'rank').length} 个排行榜'
                '${site.requiresLogin ? ' · 部分内容需要站点登录' : ''}',
                style: theme.typography.caption
                    ?.copyWith(color: theme.resources.textFillColorSecondary),
              ),
            ],
          ],
        );
      }),
    );
  }
}
