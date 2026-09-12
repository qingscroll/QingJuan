import 'package:fluent_ui/fluent_ui.dart';

import '../../core/state/load_state.dart';
import 'discovery_controller.dart';

class DiscoveryPagination extends StatelessWidget {
  const DiscoveryPagination({super.key, required this.controller});

  final DiscoveryController controller;

  @override
  Widget build(BuildContext context) {
    final result = controller.result;
    final loaded = const {LoadState.ready, LoadState.empty}
        .contains(controller.contentState);
    if (controller.selectedChannel == null ||
        (result == null && !(controller.isPageable && controller.page > 1))) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (controller.isPageable) ...[
            Button(
              key: const ValueKey('discovery-previous'),
              onPressed: controller.canPreviousPage
                  ? () => controller.previousPage()
                  : null,
              child: const Text('上一页'),
            ),
            Text(loaded && result != null
                ? '第 ${controller.page} 页 · ${result.items.length} 部作品'
                : '第 ${controller.page} 页'),
            Button(
              key: const ValueKey('discovery-next'),
              onPressed:
                  controller.canNextPage ? () => controller.nextPage() : null,
              child: const Text('下一页'),
            ),
            if (loaded && !controller.hasMore) const Text('已到最后一页'),
          ] else if (loaded && result != null) ...[
            Text('共 ${result.items.length} 部作品'),
            const Text('该栏目不支持翻页，可刷新或切换栏目'),
          ],
          if (loaded && result?.cached == true) const Text('已缓存 · 刷新可获取最新内容'),
        ],
      ),
    );
  }
}
