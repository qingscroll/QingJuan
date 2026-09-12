import 'package:fluent_ui/fluent_ui.dart';

import '../../../core/models/book.dart';
import '../../../core/models/book_metadata.dart';
import '../../../shared/app_surface.dart';

/// Optional management commands; the caller owns capability and context checks.
class DesktopBookCardActions {
  const DesktopBookCardActions({
    this.onEditMetadata,
    this.onManageUpdates,
    this.newChapterCount = 0,
  });

  final VoidCallback? onEditMetadata;
  final VoidCallback? onManageUpdates;
  final int newChapterCount;
}

/// The reading target and management menu are siblings, so commands never open
/// the book through a surrounding card tap handler.
class DesktopBookCard extends StatelessWidget {
  const DesktopBookCard({
    required this.book,
    required this.onOpen,
    required this.actions,
    required this.cover,
    super.key,
  });

  final Book book;
  final VoidCallback onOpen;
  final DesktopBookCardActions actions;
  final Widget cover;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final secondary = theme.resources.textFillColorSecondary;
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    final description = [
      if (book.author.trim().isNotEmpty) book.author,
      book.kind,
      book.language,
    ].join(' · ');
    final progress = book.chapterCount <= 0
        ? 0.0
        : (book.lastReadChapterIndex / book.chapterCount * 100)
            .clamp(0, 100)
            .toDouble();
    final hasMenu =
        actions.onEditMetadata != null || actions.onManageUpdates != null;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: '打开${book.title}',
              child: HoverButton(
                key: ValueKey('book-content-${book.id}'),
                onPressed: onOpen,
                builder: (context, states) => FocusBorder(
                  focused: states.isFocused,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: states.isHovered || states.isPressed
                          ? theme.resources.subtleFillColorSecondary
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 76, height: 112, child: cover),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Tooltip(
                                message: book.title,
                                child: Text(book.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.typography.body?.copyWith(
                                        fontWeight: FontWeight.w600)),
                              ),
                              const SizedBox(height: 6),
                              Tooltip(
                                message: description,
                                child: Text(description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.typography.caption
                                        ?.copyWith(color: secondary)),
                              ),
                              const Spacer(),
                              Tooltip(
                                message: '上次读到${book.readingPositionLabel}',
                                child: Text(
                                  '读到${book.readingPositionLabel}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.typography.caption
                                      ?.copyWith(color: secondary),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${book.chapterCount} 章${book.translated ? ' · 已翻译' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.typography.caption?.copyWith(
                                    color:
                                        book.translated ? accent : secondary),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: ProgressBar(
                                    value: progress, strokeWidth: 3),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (actions.onEditMetadata != null ||
              (actions.onManageUpdates != null &&
                  actions.newChapterCount > 0)) ...[
            const SizedBox(height: 12),
            _OrganizationLine(
              book: book,
              showMetadata: actions.onEditMetadata != null,
              newChapterCount:
                  actions.onManageUpdates != null ? actions.newChapterCount : 0,
            ),
          ],
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, constraints) {
            final shortLabel = hasMenu &&
                constraints.maxWidth <
                    104 + MediaQuery.textScalerOf(context).scale(84);
            final label = book.lastReadAt == null ? '打开阅读' : '继续阅读';
            return Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Tooltip(
                      message: label,
                      child: HyperlinkButton(
                        key: ValueKey('read-book-${book.id}'),
                        onPressed: onOpen,
                        child: Text(
                          shortLabel
                              ? (book.lastReadAt == null ? '阅读' : '续读')
                              : label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
                if (hasMenu) ...[
                  const SizedBox(width: 8),
                  _BookManagementMenu(book: book, actions: actions),
                ],
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _BookManagementMenu extends StatefulWidget {
  const _BookManagementMenu({required this.book, required this.actions});
  final Book book;
  final DesktopBookCardActions actions;

  @override
  State<_BookManagementMenu> createState() => _BookManagementMenuState();
}

class _BookManagementMenuState extends State<_BookManagementMenu> {
  VoidCallback? _pendingAction;

  @override
  Widget build(BuildContext context) {
    final actions = widget.actions;
    final book = widget.book;
    return Tooltip(
      message: '管理《${book.title}》',
      child: DropDownButton(
        key: ValueKey('book-more-${book.id}'),
        title: const Text('更多'),
        placement: FlyoutPlacementMode.bottomRight,
        onOpen: () => _pendingAction = null,
        // A command can push a route. Wait for the native menu's maybePop to
        // finish so it cannot accidentally close the newly opened destination.
        onClose: () {
          final action = _pendingAction;
          _pendingAction = null;
          if (mounted) action?.call();
        },
        items: [
          if (actions.onEditMetadata != null)
            MenuFlyoutItem(
              key: ValueKey('edit-book-${book.id}'),
              leading: const Icon(FluentIcons.edit, size: 14),
              text: const Text('编辑信息'),
              onPressed: () => _pendingAction = actions.onEditMetadata,
            ),
          if (actions.onManageUpdates != null)
            MenuFlyoutItem(
              key: ValueKey('book-updates-${book.id}'),
              leading: const Icon(FluentIcons.sync, size: 14),
              text: const Text('连载追更'),
              onPressed: () => _pendingAction = actions.onManageUpdates,
            ),
        ],
      ),
    );
  }
}

class _OrganizationLine extends StatelessWidget {
  const _OrganizationLine({
    required this.book,
    required this.showMetadata,
    required this.newChapterCount,
  });
  final Book book;
  final bool showMetadata;
  final int newChapterCount;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final group = book.groupName?.trim();
    final details = [
      if (group != null && group.isNotEmpty) group,
      ...book.tags.map((tag) => '#$tag'),
    ].join(' · ');
    final state = readingStateLabels[book.readingState] ?? '未读';
    return Tooltip(
      message: [
        if (showMetadata) ...[
          if (book.pinned) '已置顶',
          state,
          if (details.isNotEmpty) details,
        ],
        if (newChapterCount > 0) '新增 $newChapterCount 章',
      ].join(' · '),
      child: Row(
        children: [
          if (showMetadata && book.pinned) ...[
            Icon(FluentIcons.pinned,
                size: 12,
                color: theme.accentColor.defaultBrushFor(theme.brightness),
                semanticLabel: '已置顶'),
            const SizedBox(width: 6),
          ],
          if (showMetadata)
            Text(state,
                style: theme.typography.caption?.copyWith(
                    color: book.readingState == 'reading'
                        ? theme.accentColor.defaultBrushFor(theme.brightness)
                        : theme.resources.textFillColorSecondary)),
          if (showMetadata && details.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(details,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.caption?.copyWith(
                      color: theme.resources.textFillColorSecondary)),
            ),
          ] else
            const Spacer(),
          if (newChapterCount > 0) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text('新增 $newChapterCount 章',
                  key: ValueKey('book-update-count-${book.id}'),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.caption?.copyWith(
                      color:
                          theme.accentColor.defaultBrushFor(theme.brightness))),
            ),
          ],
        ],
      ),
    );
  }
}
