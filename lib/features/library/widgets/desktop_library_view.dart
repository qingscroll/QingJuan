import 'package:fluent_ui/fluent_ui.dart';

import '../../../app/app_scope.dart';
import '../../../core/models/book.dart';
import '../../../core/state/load_state.dart';
import '../../../shared/app_surface.dart';
import '../../../shared/feedback_widgets.dart';
import '../../../shared/page_frame.dart';
import '../../../shared/smooth_scroll.dart';
import '../library_controller.dart';
import '../import_history_page.dart';
import '../book_metadata_editor.dart';
import '../library_organization_controls.dart';
import '../book_updates_page.dart';
import 'book_card.dart';

/// Desktop presentation only; searches and imports use the existing controller.
class DesktopLibraryView extends StatefulWidget {
  const DesktopLibraryView({
    required this.controller,
    required this.onOpen,
    required this.onImport,
    super.key,
  });

  final LibraryController controller;
  final ValueChanged<Book> onOpen;
  final VoidCallback onImport;

  @override
  State<DesktopLibraryView> createState() => _DesktopLibraryViewState();
}

class _DesktopLibraryViewState extends State<DesktopLibraryView> {
  late final _query = TextEditingController(text: widget.controller.query);
  bool get _metadataEnabled =>
      context
          .dependOnInheritedWidgetOfExactType<AppScope>()
          ?.backend
          .capabilities['libraryMetadata'] ==
      true;

  @override
  void didUpdateWidget(DesktopLibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_query.text != widget.controller.query) {
      _query.text = widget.controller.query;
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = FluentTheme.of(context);
    final books = controller.filteredBooks;
    return PageFrame(
      key: const ValueKey('desktop-library-page'),
      title: '书架',
      subtitle: '你的故事，都在这里。',
      scrollable: false,
      command: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          if (controller.imports.enabled)
            Button(
                onPressed: () => openImportHistory(context),
                child: const Text('导入记录与批量导入')),
          if (controller.linkJob != null)
            Button(
              onPressed: widget.onImport,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (controller.hasActiveLinkJob) ...<Widget>[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: ProgressRing(strokeWidth: 2.5),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(controller.hasActiveLinkJob ? '链接解析中' : '查看链接任务'),
                ],
              ),
            ),
          FilledButton(
            onPressed: widget.onImport,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(FluentIcons.add, size: 12),
                SizedBox(width: 8),
                Text('添加书籍'),
              ],
            ),
          ),
        ],
      ),
      child: Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LayoutBuilder(builder: (context, constraints) {
              final heading = Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('全部作品', style: theme.typography.subtitle),
                  const SizedBox(width: 10),
                  Text(
                    '${controller.books.length} 本',
                    style: theme.typography.caption,
                  ),
                ],
              );
              final search = Row(
                children: <Widget>[
                  Expanded(
                    child: TextBox(
                      key: const ValueKey('desktop-library-search'),
                      controller: _query,
                      placeholder: '搜索书名、作者、简介或标签',
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      suffix: const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: Icon(FluentIcons.search, size: 14),
                      ),
                      onChanged: controller.setQuery,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '刷新书架',
                    child: IconButton(
                      icon: const Icon(
                        FluentIcons.refresh,
                        size: 16,
                        semanticLabel: '刷新书架',
                      ),
                      onPressed: controller.load,
                    ),
                  ),
                ],
              );
              if (constraints.maxWidth < 680 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.3) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    heading,
                    const SizedBox(height: 12),
                    search,
                  ],
                );
              }
              return Row(
                children: <Widget>[
                  Expanded(child: heading),
                  SizedBox(width: 340, child: search),
                ],
              );
            }),
            if (_metadataEnabled) ...[
              const SizedBox(height: 16),
              LibraryOrganizationControls(controller: controller),
            ],
            if (controller.serials.error != null)
              Button(
                  onPressed: controller.serials.load,
                  child: const Text('追更状态刷新失败 · 点击重试')),
            const SizedBox(height: 20),
            Expanded(
              child: switch (controller.state) {
                LoadState.idle ||
                LoadState.loading =>
                  const LoadingView(label: '正在整理书架'),
                LoadState.error => ErrorView(
                    message: controller.error ?? '未知错误',
                    onRetry: controller.load,
                  ),
                LoadState.empty => EmptyView(
                    icon: FluentIcons.library,
                    title: '书架还是空的',
                    message: '添加网页作品或本地文本，青卷会在这里保存阅读进度。',
                    action: FilledButton(
                      onPressed: widget.onImport,
                      child: const Text('添加第一本书'),
                    ),
                  ),
                LoadState.ready when books.isEmpty => const EmptyView(
                    icon: FluentIcons.search,
                    title: '没有匹配结果',
                    message: '试试更短的书名或简介关键词。',
                  ),
                _ => _bookGrid(context, books),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _bookGrid(BuildContext context, List<Book> books) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final scaleAllowance = 112 * (textScale - 1).clamp(0.0, 6.0);
    Book? recent;
    DateTime? recentTime;
    for (final book in books) {
      final time = DateTime.tryParse(book.lastReadAt ?? '');
      if (time != null && (recentTime == null || time.isAfter(recentTime))) {
        recent = book;
        recentTime = time;
      }
    }
    final recentBook = recent;
    return LayoutBuilder(builder: (context, constraints) {
      final minimumCardWidth = 300 + 88 * (textScale - 1).clamp(0.0, 1.0);
      final columns = ((constraints.maxWidth + 12) / (minimumCardWidth + 12))
          .floor()
          .clamp(1, 6);
      return QjScrollControllerBuilder(
        debugLabel: 'desktop-library',
        builder: (context, controller) => CustomScrollView(
          controller: controller,
          slivers: <Widget>[
            if (recentBook != null && widget.controller.query.trim().isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: _RecentBook(
                    book: recentBook,
                    onOpen: () => widget.onOpen(recentBook),
                  ),
                ),
              ),
            SliverGrid.builder(
              itemCount: books.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: 232 + scaleAllowance,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemBuilder: (context, index) {
                final book = books[index];
                final owner = widget.controller;
                final generation = owner.contextGeneration;
                bool isCurrent() =>
                    mounted &&
                    identical(widget.controller, owner) &&
                    generation == owner.contextGeneration &&
                    owner.books.any((current) => current.id == book.id);
                return BookCard(
                  key: ValueKey('desktop-book-${book.id}'),
                  book: book,
                  onOpen: () {
                    if (isCurrent()) {
                      widget.onOpen(book);
                    }
                  },
                  desktopActions: DesktopBookCardActions(
                    onEditMetadata: _metadataEnabled
                        ? () {
                            if (isCurrent() && _metadataEnabled) {
                              showBookMetadataEditor(this.context,
                                  bookId: book.id);
                            }
                          }
                        : null,
                    onManageUpdates: owner.serials.enabled &&
                            book.sourceUrl.isNotEmpty
                        ? () {
                            if (isCurrent() && owner.serials.enabled) {
                              showBookUpdates(this.context, bookId: book.id);
                            }
                          }
                        : null,
                    newChapterCount:
                        owner.serials.records[book.id]?.newChapterCount ?? 0,
                  ),
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
          ],
        ),
      );
    });
  }
}

class _RecentBook extends StatelessWidget {
  const _RecentBook({required this.book, required this.onOpen});

  final Book book;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return AppSurface(
      key: const ValueKey('desktop-recent-book'),
      padding: const EdgeInsets.all(20),
      onPressed: onOpen,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 76,
            height: 108,
            child: BookCover(book: book, borderRadius: 6),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('最近阅读',
                    style: theme.typography.caption?.copyWith(color: accent)),
                const SizedBox(height: 8),
                Text(book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.subtitle),
                const SizedBox(height: 8),
                Text('上次读到${book.readingPositionLabel}',
                    style: theme.typography.caption),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Icon(FluentIcons.chevron_right, size: 14, color: accent),
        ],
      ),
    );
  }
}
