import 'package:fluent_ui/fluent_ui.dart';

/// Reading stays immediately available; book maintenance lives in one menu.
class DetailActionBar extends StatefulWidget {
  const DetailActionBar({
    required this.onRead,
    required this.managementActions,
    required this.busy,
    this.onListen,
    super.key,
  });

  final VoidCallback onRead;
  final VoidCallback? onListen;
  final List<DetailManagementAction> managementActions;
  final bool busy;

  @override
  State<DetailActionBar> createState() => _DetailActionBarState();
}

class _DetailActionBarState extends State<DetailActionBar> {
  VoidCallback? _pendingManagementAction;

  @override
  Widget build(BuildContext context) {
    final reading = Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        FilledButton(onPressed: widget.onRead, child: const Text('继续阅读')),
        if (widget.onListen != null)
          Button(
            onPressed: widget.onListen,
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(FluentIcons.headset, size: 16),
              SizedBox(width: 8),
              Text('听小说'),
            ]),
          ),
      ],
    );
    if (widget.managementActions.isEmpty) return reading;
    final management = DropDownButton(
      key: const ValueKey('detail-management'),
      title: const Text('作品管理'),
      disabled: widget.busy,
      placement: FlyoutPlacementMode.bottomRight,
      onOpen: () => _pendingManagementAction = null,
      onClose: () {
        final action = _pendingManagementAction;
        _pendingManagementAction = null;
        // Opening a route before the native flyout finishes maybePop leaves
        // the menu underneath it. Dispatch only after the flyout has closed.
        if (mounted && !widget.busy) action?.call();
      },
      items: [
        for (final action in widget.managementActions)
          MenuFlyoutItem(
            text: Text(action.label),
            onPressed: widget.busy
                ? null
                : () => _pendingManagementAction = action.onPressed,
          ),
      ],
    );
    return LayoutBuilder(builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      if (constraints.maxWidth < 560 * scale) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          reading,
          const SizedBox(height: 12),
          management,
        ]);
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: reading),
        const SizedBox(width: 20),
        management,
      ]);
    });
  }
}

class DetailManagementAction {
  const DetailManagementAction(this.label, this.onPressed);
  final String label;
  final VoidCallback onPressed;
}

/// Selection and operations on that selection share the chapter-list header.
class DetailChapterToolbar extends StatelessWidget {
  const DetailChapterToolbar({
    required this.selectedCount,
    required this.allSelected,
    required this.onToggleAll,
    required this.onDownload,
    required this.onTranslate,
    required this.translationLabel,
    super.key,
  });

  final int selectedCount;
  final bool allSelected;
  final VoidCallback onToggleAll;
  final VoidCallback? onDownload;
  final VoidCallback? onTranslate;
  final String translationLabel;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final selection = Wrap(
      spacing: 14,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('章节', style: theme.typography.subtitle),
        Text('已选择 $selectedCount 章',
            style: theme.typography.body
                ?.copyWith(color: theme.resources.textFillColorSecondary)),
        Button(
          key: const ValueKey('detail-select-all'),
          onPressed: onToggleAll,
          child: Text(allSelected ? '取消全选' : '全选章节'),
        ),
      ],
    );
    final operations = Wrap(spacing: 10, runSpacing: 10, children: [
      Button(
        onPressed: onDownload,
        child: Text(selectedCount == 0 ? '下载全部' : '下载所选'),
      ),
      Button(onPressed: onTranslate, child: Text(translationLabel)),
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LayoutBuilder(builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (constraints.maxWidth < 720 * scale) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                selection,
                const SizedBox(height: 12),
                operations,
              ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: selection),
          const SizedBox(width: 24),
          operations,
        ]);
      }),
    );
  }
}
