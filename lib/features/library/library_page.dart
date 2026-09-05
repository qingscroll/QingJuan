import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_scope.dart';
import '../../app/app_theme.dart';
import '../../core/models/book.dart';
import '../../core/state/load_state.dart';
import '../../shared/app_surface.dart';
import '../../shared/feedback_widgets.dart';
import '../../shared/motion.dart';
import '../../shared/page_frame.dart';
import '../../shared/responsive.dart';
import '../../shared/smooth_scroll.dart';
import '../detail/book_detail_page.dart';
import 'import_book_dialog.dart';
import 'library_controller.dart';
import 'widgets/book_card.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context).library;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final compact = usesMobileUi(context);
        if (!compact) return _buildDesktopPage(context, controller);
        return PageFrame(
          title: '书架',
          subtitle: '继续阅读或管理已添加的作品。',
          scrollable: false,
          compactHeader: ReadingPageHeader(
            title: '书架',
            subtitle: _librarySubtitle(controller.books.length),
            actions: <Widget>[
              Tooltip(
                message: '刷新书架',
                child: IconButton(
                  icon: const Icon(
                    FluentIcons.refresh,
                    semanticLabel: '刷新书架',
                  ),
                  onPressed: controller.load,
                ),
              ),
              const SizedBox(width: 7),
              FilledButton(
                onPressed: () => _openImportDialog(context),
                child: const Text('添加书籍'),
              ),
            ],
          ),
          command: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (controller.linkJob != null)
                Button(
                  onPressed: () => _openImportDialog(context),
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
                      Text(
                        controller.hasActiveLinkJob ? '链接解析中' : '查看链接任务',
                      ),
                    ],
                  ),
                ),
              FilledButton(
                onPressed: () => _openImportDialog(context),
                child: const Text('添加书籍'),
              ),
            ],
          ),
          child: Expanded(
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
                  message: '导入网页作品或本地文本，阅读进度会自动保存在 Linux 后端。',
                  action: FilledButton(
                    onPressed: () => _openImportDialog(context),
                    child: const Text('添加第一本书'),
                  ),
                ),
              _ => _LibraryContent(
                  books: controller.filteredBooks,
                  allBooks: controller.books,
                  compact: compact,
                  onQueryChanged: controller.setQuery,
                  onOpen: (book) => _openBook(context, book),
                  onShowLinkJob: controller.linkJob == null
                      ? null
                      : () => _openImportDialog(context),
                ),
            },
          ),
        );
      },
    );
  }

  Widget _buildDesktopPage(
    BuildContext context,
    LibraryController controller,
  ) {
    final books = controller.filteredBooks;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final scaleAllowance = 64 * (textScale - 1).clamp(0.0, 1.5).toDouble();
    return PageFrame(
      key: const ValueKey('desktop-library-page'),
      title: '书架',
      subtitle: '集中管理下载、翻译与阅读进度。',
      scrollable: false,
      command: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          if (controller.linkJob != null)
            Button(
              onPressed: () => _openImportDialog(context),
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
            onPressed: () => _openImportDialog(context),
            child: const Text('添加书籍'),
          ),
        ],
      ),
      child: Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextBox(
                    magnifierConfiguration:
                        textInputMagnifierConfiguration(context),
                    placeholder: '搜索书名或简介',
                    prefix: const Padding(
                      padding: EdgeInsets.only(left: 10),
                      child: Icon(FluentIcons.search),
                    ),
                    onChanged: controller.setQuery,
                  ),
                ),
                const SizedBox(width: 10),
                Tooltip(
                  message: '刷新书架',
                  child: IconButton(
                    icon: const Icon(
                      FluentIcons.refresh,
                      semanticLabel: '刷新书架',
                    ),
                    onPressed: controller.load,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
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
                      onPressed: () => _openImportDialog(context),
                      child: const Text('添加第一本书'),
                    ),
                  ),
                LoadState.ready when books.isEmpty => const EmptyView(
                    icon: FluentIcons.search,
                    title: '没有匹配结果',
                    message: '试试更短的书名或作者关键词。',
                  ),
                _ => QjScrollControllerBuilder(
                    debugLabel: 'desktop-library',
                    builder: (context, scrollController) => GridView.builder(
                      controller: scrollController,
                      itemCount: books.length,
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 352,
                        mainAxisExtent: 164 + scaleAllowance,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                      ),
                      itemBuilder: (context, index) {
                        final book = books[index];
                        return BookCard(
                          book: book,
                          onOpen: () => _openBook(context, book),
                        );
                      },
                    ),
                  ),
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _librarySubtitle(int count) =>
      count == 0 ? '把想读的故事放在这里' : '$count 本作品 · 阅读进度已同步';

  static Future<void> _openBook(BuildContext context, Book book) =>
      Navigator.of(context).push<void>(
        qjPageRoute<void>(
          context: context,
          builder: (_) => BookDetailPage(bookId: book.id),
        ),
      );

  Future<void> _openImportDialog(BuildContext context) async {
    final book = await showImportBookDialog(context);
    if (book != null && context.mounted) await _openBook(context, book);
  }
}

class _LibraryContent extends StatelessWidget {
  const _LibraryContent({
    required this.books,
    required this.allBooks,
    required this.compact,
    required this.onQueryChanged,
    required this.onOpen,
    this.onShowLinkJob,
  });

  final List<Book> books;
  final List<Book> allBooks;
  final bool compact;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<Book> onOpen;
  final VoidCallback? onShowLinkJob;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final scaleAllowance = 48 * (textScale - 1).clamp(0.0, 1.0).toDouble();
    final recent = _mostRecentBook(allBooks);
    return CustomScrollView(
      scrollCacheExtent: ScrollCacheExtent.pixels(compact ? 360 : 520),
      slivers: <Widget>[
        if (compact && recent != null) ...<Widget>[
          SliverToBoxAdapter(
            child: _ContinueReadingCard(
              book: recent,
              onPressed: () => onOpen(recent),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 26)),
        ],
        SliverToBoxAdapter(
          child: SectionTitle(
            '我的藏书',
            trailing: Text(
              '${allBooks.length} 本',
              style: FluentTheme.of(context).typography.caption,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: TextBox(
            magnifierConfiguration: textInputMagnifierConfiguration(context),
            placeholder: '搜索书名或简介',
            prefix: const Padding(
              padding: EdgeInsets.only(left: 11),
              child: Icon(FluentIcons.search, size: 18),
            ),
            onChanged: onQueryChanged,
          ),
        ),
        if (onShowLinkJob != null) ...<Widget>[
          const SliverToBoxAdapter(child: SizedBox(height: 10)),
          SliverToBoxAdapter(
            child: Button(
              onPressed: onShowLinkJob,
              child: const Text('查看最近的链接导入任务'),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        if (books.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyView(
              icon: FluentIcons.search,
              title: '没有匹配结果',
              message: '试试更短的书名或简介关键词。',
            ),
          )
        else
          SliverGrid(
            gridDelegate: compact
                ? SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisExtent: 226 + scaleAllowance,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 20,
                  )
                : const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 352,
                    mainAxisExtent: 164,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final book = books[index];
                return BookCard(book: book, onOpen: () => onOpen(book));
              },
              childCount: books.length,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  Book? _mostRecentBook(List<Book> source) {
    if (source.isEmpty) return null;
    final sorted = List<Book>.of(source)
      ..sort((left, right) {
        final leftTime = DateTime.tryParse(left.lastReadAt ?? '');
        final rightTime = DateTime.tryParse(right.lastReadAt ?? '');
        if (leftTime == null && rightTime == null) return 0;
        if (leftTime == null) return 1;
        if (rightTime == null) return -1;
        return rightTime.compareTo(leftTime);
      });
    return sorted.first;
  }
}

class _ContinueReadingCard extends StatelessWidget {
  const _ContinueReadingCard({required this.book, required this.onPressed});

  final Book book;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final progress = book.chapterCount <= 0
        ? 0.0
        : (book.lastReadChapterIndex / book.chapterCount * 100)
            .clamp(0, 100)
            .toDouble();
    final textScaler = TextScaler.linear(
      MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.3),
    );
    return SizedBox(
      key: const ValueKey('continue-reading-card'),
      height: 154,
      child: AppSurface(
        tone: AppSurfaceTone.accent,
        borderRadius: 18,
        padding: const EdgeInsets.all(14),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 76,
                height: 112,
                child: BookCover(
                  book: book,
                  borderRadius: 10,
                  showShadow: true,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '继续阅读',
                      style: theme.typography.caption?.copyWith(
                        color: theme.accentColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.bodyLarge?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '读到${book.readingPositionLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.caption,
                    ),
                    const Spacer(),
                    ProgressBar(
                      value: progress,
                      strokeWidth: 4,
                      activeColor: qingJuanMobilePrimary,
                    ),
                    const SizedBox(height: 9),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: FilledButton(
                        onPressed: onPressed,
                        child: const Text('继续'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
