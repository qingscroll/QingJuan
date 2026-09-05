import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/models/book.dart';
import '../core/state/load_state.dart';
import 'mobile_detail_page.dart';
import 'mobile_import_sheet.dart';
import 'mobile_page.dart';
import 'mobile_state.dart';

class MobileLibraryPage extends StatefulWidget {
  const MobileLibraryPage({super.key});

  @override
  State<MobileLibraryPage> createState() => _MobileLibraryPageState();
}

class _MobileLibraryPageState extends State<MobileLibraryPage> {
  final _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _addBook() async {
    final book = await showMobileImportSheet(context);
    if (!mounted || book == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MobileBookDetailPage(bookId: book.id),
      ),
    );
  }

  void _openBook(Book book) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MobileBookDetailPage(bookId: book.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final books = library.filteredBooks;
        return MobilePage(
          title: '书架',
          subtitle: library.books.isEmpty
              ? '把想读的故事放在这里'
              : '${library.books.length} 本作品 · 阅读进度已同步',
          actions: <Widget>[
            MiuixIconButton(
              onPressed: () => library.load(),
              child: MiuixIcon(
                vector: MiuixIcons.extended.byName('refresh')!,
                contentDescription: '刷新书架',
              ),
            ),
            const SizedBox(width: 8),
            MiuixIconButton(
              onPressed: _addBook,
              backgroundColor: MiuixTheme.of(context).colors.primary,
              child: MiuixIcon(
                vector: MiuixIcons.extended.byName('add')!,
                tint: MiuixTheme.of(context).colors.onPrimary,
                contentDescription: '添加书籍',
              ),
            ),
          ],
          child: Column(
            children: <Widget>[
              MiuixTextField(
                controller: _queryController,
                label: '搜索书名或简介',
                useLabelAsPlaceholder: true,
                singleLine: true,
                leadingIcon: MiuixIcon(
                  vector: MiuixIcons.extended.byName('search')!,
                  size: 20,
                ),
                onChanged: library.setQuery,
              ),
              const SizedBox(height: 14),
              Expanded(child: _buildContent(library, books)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContent(dynamic library, List<Book> books) {
    if (library.state == LoadState.idle || library.state == LoadState.loading) {
      return const MobileLoadingView('正在整理书架');
    }
    if (library.state == LoadState.error) {
      return MobileEmptyView(
        icon: MiuixIcon(vector: MiuixIcons.extended.byName('help')!),
        title: '暂时无法加载书架',
        message: library.error ?? '未知错误',
        action: MiuixTextButton('重试', onPressed: () => library.load()),
      );
    }
    if (books.isEmpty) {
      return MobileEmptyView(
        icon: MiuixIcon(vector: MiuixIcons.extended.byName('contactsBook')!),
        title: library.state == LoadState.empty ? '书架还是空的' : '没有匹配结果',
        message: library.state == LoadState.empty
            ? '导入网页作品或本地文本，阅读进度会保存在当前后端。'
            : '试试更短的书名、作者或简介关键词。',
        action: library.state == LoadState.empty
            ? MiuixButton(
                onPressed: _addBook,
                colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                child: const MiuixText('添加第一本书'),
              )
            : null,
      );
    }
    return GridView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 18),
      itemCount: books.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 176,
        mainAxisExtent: 250,
        crossAxisSpacing: 13,
        mainAxisSpacing: 16,
      ),
      itemBuilder: (context, index) => _BookCard(
        book: books[index],
        onOpen: () => _openBook(books[index]),
      ),
    );
  }
}


class _BookCard extends StatelessWidget {
  const _BookCard({required this.book, required this.onOpen});

  final Book book;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final progress = book.chapterCount <= 0
        ? 0.0
        : (book.lastReadChapterIndex / book.chapterCount)
            .clamp(0.0, 1.0)
            .toDouble();
    return MiuixPressable(
      onPressed: onOpen,
      feedbackType: MiuixPressFeedbackType.sink,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: _BookCover(book: book)),
          const SizedBox(height: 8),
          Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textStyles.body2.copyWith(
              color: theme.colors.onBackground,
              fontWeight: FontWeight.w600,
              height: 1.22,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            book.chapterCount <= 0
                ? book.kind
                : '${book.lastReadChapterIndex}/${book.chapterCount} 章',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textStyles.footnote2.copyWith(
              color: theme.colors.onSurfaceVariantSummary,
            ),
          ),
          const SizedBox(height: 6),
          MiuixLinearProgressIndicator(progress: progress, height: 4),
        ],
      ),
    );
  }
}


class _BookCover extends StatelessWidget {
  const _BookCover({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final api = AppScope.of(context).api;
    final cover = book.cover?.trim();
    final placeholder = ColoredBox(
      color: theme.colors.secondaryContainer,
      child: Center(
        child: MiuixIcon(
          vector: MiuixIcons.extended.byName('contactsBook')!,
          tint: theme.colors.primary,
          size: 30,
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: cover == null || cover.isEmpty
          ? placeholder
          : Image.network(
              api.resolveUrl(cover),
              headers: api.headersForUrl(cover),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (_, __, ___) => placeholder,
            ),
    );
  }
}

