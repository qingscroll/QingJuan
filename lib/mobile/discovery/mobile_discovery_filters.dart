import 'package:flutter/material.dart';

import '../../features/discovery/discovery_controller.dart';

class MobileDiscoveryFilters extends StatelessWidget {
  const MobileDiscoveryFilters(
      {required this.controller,
      required this.onSitePressed,
      required this.onChannelPressed,
      super.key});

  final DiscoveryController controller;
  final VoidCallback onSitePressed;
  final VoidCallback onChannelPressed;

  @override
  Widget build(BuildContext context) {
    if (controller.sites.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton(
            key: const ValueKey('mobile-discovery-site-picker'),
            onPressed: onSitePressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.public_outlined, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(controller.selectedSite?.siteName ?? '选择站点')),
                  const Icon(Icons.expand_more_rounded),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final kind in const ['recommend', 'rank'])
                Expanded(
                  child: Padding(
                    padding:
                        EdgeInsets.only(right: kind == 'recommend' ? 8 : 0),
                    child: Semantics(
                      selected: controller.kind == kind,
                      child: TextButton(
                        key: ValueKey('mobile-discovery-kind-$kind'),
                        style: TextButton.styleFrom(
                          backgroundColor: controller.kind == kind
                              ? colors.secondaryContainer
                              : colors.surface,
                          foregroundColor: controller.kind == kind
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                        onPressed: () => controller.selectKind(kind),
                        child: Text(kind == 'rank' ? '排行榜' : '推荐书籍'),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (controller.selectedChannel case final channel?) ...[
            const SizedBox(height: 10),
            TextButton(
              key: const ValueKey('mobile-discovery-channel-picker'),
              onPressed: onChannelPressed,
              child: Row(
                children: [
                  Expanded(
                    child: Text(channel.group.isEmpty
                        ? channel.name
                        : '${channel.group} · ${channel.name}'),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.expand_more_rounded),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
