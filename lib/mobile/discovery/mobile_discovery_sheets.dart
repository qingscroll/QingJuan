import 'package:flutter/material.dart';

import '../../features/discovery/discovery_controller.dart';
import '../mobile_sheet.dart';

Future<String?> showMobileDiscoverySites(
        BuildContext context, DiscoveryController controller) =>
    showMobileSheet<String>(
      context: context,
      title: '选择站点',
      subtitle: '分别查看各站点提供的推荐和排行榜',
      child: Column(
        children: [
          for (final site in controller.sites)
            ListTile(
              key: ValueKey('mobile-discovery-site-${site.site}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              title: Text(site.siteName),
              selected: controller.selectedSite?.site == site.site,
              trailing: controller.selectedSite?.site == site.site
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(context, site.site),
            ),
        ],
      ),
    );

Future<String?> showMobileDiscoveryChannels(
        BuildContext context, DiscoveryController controller) =>
    showMobileSheet<String>(
      context: context,
      title: controller.kind == 'rank' ? '选择排行榜' : '选择推荐栏目',
      subtitle: controller.selectedSite?.siteName,
      child: Column(
        children: [
          for (final channel in controller.channels)
            ListTile(
              key: ValueKey('mobile-discovery-channel-${channel.key}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              title: Text(channel.name),
              subtitle: channel.group.isEmpty ? null : Text(channel.group),
              selected: controller.selectedChannel?.key == channel.key,
              trailing: controller.selectedChannel?.key == channel.key
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.pop(context, channel.key),
            ),
        ],
      ),
    );
