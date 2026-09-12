import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/models/book.dart';
import '../core/state/load_state.dart';
import '../features/detail/book_detail_page.dart';
import '../features/library/library_controller.dart';
import '../features/library/import_history_page.dart';
import '../features/library/book_metadata_editor.dart';
import '../features/library/library_organization_controls.dart';
import '../features/library/book_updates_page.dart';
import 'mobile_action_button.dart';
import 'mobile_import_progress.dart';
import 'mobile_import_sheet.dart';
import 'mobile_library_tiles.dart';
import 'mobile_page.dart';
import 'mobile_search_field.dart';
import 'mobile_sheet.dart';
import 'mobile_state.dart';
import 'mobile_widgets.dart';

class MobileLibraryPage extends StatefulWidget {
  const MobileLibraryPage({super.key});
  @override
  State<MobileLibraryPage> createState() => _MobileLibraryPageState();
}

class _MobileLibraryPageState extends State<MobileLibraryPage> {
  final _queryController = TextEditingController();
  final _selected = <String>{};
  _ShelfFilter _filter = _ShelfFilter.all;
  bool _showSearch = false;
  bool _selecting = false;
  bool _deleting = false;
  bool _initialized = false;
  int _generation = -1;
  bool get _metadataEnabled =>
      AppScope.of(context).backend.capabilities['libraryMetadata'] == true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _queryController.text = AppScope.of(context).library.query;
    _showSearch = _queryController.text.isNotEmpty;
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _addBook() async {
    final book = await showMobileImportSheet(context);
    if (!mounted || book == null) return;
    _openBook(book);
  }

  void _openBook(Book book, {bool read = false}) {
    Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => BookDetailPage(bookId: book.id, openReaderOnLoad: read),
    ));
  }

  void _toggleSelection(Book book) => setState(() {
        _selecting = true;
        if (!_selected.add(book.id)) _selected.remove(book.id);
      });

  Future<void> _options() async {
    final library = AppScope.of(context).library;
    final value = await showMobileSheet<String>(
      context: context,
      title: '书库整理',
      child: Column(children: <Widget>[
        if (AppScope.of(context).library.imports.enabled)
          ListTile(
              title: const Text('导入记录与批量导入'),
              onTap: () => Navigator.pop(context, 'imports')),
        if (_metadataEnabled)
          LibraryOrganizationControls(controller: library, mobile: true),
        if (!_metadataEnabled)
          for (final sort in LibrarySort.values)
            ListTile(
              minVerticalPadding: 12,
              title: Text(sort.label),
              trailing:
                  library.sort == sort ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.pop(context, sort.name),
            ),
        const Divider(height: 1),
        ListTile(
          minVerticalPadding: 12,
          leading: const Icon(Icons.checklist_rounded),
          title: const Text('批量管理'),
          subtitle: const Text('选择作品并从书库删除'),
          onTap: () => Navigator.pop(context, 'select'),
        ),
      ]),
    );
    if (!mounted || value == null) return;
    if (value == 'imports') {
      await openImportHistory(context, mobile: true);
      return;
    }
    setState(() {
      if (value == 'select') {
        _selecting = true;
      } else {
        library.setSort(LibrarySort.values.byName(value));
      }
    });
  }

  Future<void> _deleteSelected() async {
    final library = AppScope.of(context).library;
    final generation = library.contextGeneration;
    final books =
        library.books.where((book) => _selected.contains(book.id)).toList();
    if (books.isEmpty || _deleting) return;
    final confirmed = await showMobileSheet<bool>(
      context: context,
      title: '删除 ${books.length} 本作品？',
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(books.take(4).map((book) => '《${book.title}》').join('、') +
                (books.length > 4 ? '等作品' : '')),
            const SizedBox(height: 12),
            const Text('将删除作品、已下载章节与阅读记录。此操作无法撤销，需要重新导入后才能再次阅读。'),
            const SizedBox(height: 20),
            MiuixButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('确认删除',
                    style:
                        TextStyle(color: MiuixTheme.of(context).colors.error))),
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('保留作品')),
          ]),
    );
    if (!mounted ||
        confirmed != true ||
        generation != library.contextGeneration) {
      return;
    }
    setState(() => _deleting = true);
    var removed = 0;
    try {
      for (final book in books) {
        if (!mounted || generation != library.contextGeneration) return;
        await library.delete(book.id);
        if (!mounted || generation != library.contextGeneration) return;
        _selected.remove(book.id);
        removed++;
      }
      if (mounted) setState(() => _selecting = false);
    } catch (error) {
      if (mounted && generation == library.contextGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已删除 $removed 本，其余作品未删除：$error')));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  List<Book> _books(LibraryController library) {
    return library.filteredBooks.where(_filter.matches).toList();
  }

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    final theme = MiuixTheme.of(context);
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_deleting) {
          setState(() {
            _selecting = false;
            _selected.clear();
          });
        }
      },
      child: AnimatedBuilder(
        animation: library,
        builder: (context, _) {
          if (_generation != library.contextGeneration) {
            _generation = library.contextGeneration;
            _selected.clear();
            _selecting = _deleting = false;
            _filter = _ShelfFilter.all;
            _queryController.text = library.query;
          }
          return MobilePage(
            title: _selecting ? '选择作品' : '书库',
            actions: <Widget>[
              if (_selecting)
                TextButton(
                    onPressed: _deleting
                        ? null
                        : () => setState(() {
                              _selecting = false;
                              _selected.clear();
                            }),
                    child: const Text('完成'))
              else ...<Widget>[
                IconButton(
                  key: const ValueKey('mobile-library-search-toggle'),
                  tooltip: _showSearch ? '收起书库搜索' : '搜索书库',
                  onPressed: () => setState(() {
                    _showSearch = !_showSearch;
                    if (!_showSearch) FocusScope.of(context).unfocus();
                  }),
                  icon: const Icon(Icons.search_outlined),
                ),
                IconButton(
                    key: const ValueKey('mobile-library-add'),
                    tooltip: '导入作品',
                    onPressed: _addBook,
                    icon: const Icon(Icons.add_rounded)),
              ],
            ],
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (_showSearch) ...<Widget>[
                    MobileSearchField(
                        key: const ValueKey('mobile-library-query'),
                        controller: _queryController,
                        hintText: '搜索书名、作者、简介或标签',
                        autofocus: true,
                        onChanged: library.setQuery),
                    const SizedBox(height: 8),
                  ],
                  if (library.books.isNotEmpty)
                    Row(children: <Widget>[
                      Expanded(
                          child: SizedBox(
                        height:
                            (MediaQuery.textScalerOf(context).scale(13) * 1.5 +
                                    20)
                                .clamp(48, double.infinity),
                        child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: <Widget>[
                              for (final filter in _ShelfFilter.values)
                                Semantics(
                                    selected: _filter == filter,
                                    child: TextButton(
                                      key: ValueKey(
                                          'mobile-library-filter-${filter.name}'),
                                      onPressed: () =>
                                          setState(() => _filter = filter),
                                      style: TextButton.styleFrom(
                                          foregroundColor: _filter == filter
                                              ? theme.colors.primary
                                              : theme
                                                  .colors.onBackgroundVariant),
                                      child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: <Widget>[
                                            Text(
                                                '${filter.label} ${library.books.where(filter.matches).length}',
                                                style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight:
                                                        _filter == filter
                                                            ? FontWeight.w700
                                                            : FontWeight.w400)),
                                            const SizedBox(height: 3),
                                            Container(
                                                height: 2,
                                                width: 16,
                                                color: _filter == filter
                                                    ? theme.colors.primary
                                                    : Colors.transparent),
                                          ]),
                                    )),
                            ]),
                      )),
                      IconButton(
                          key: const ValueKey('mobile-library-organize'),
                          tooltip: '排序与批量管理',
                          onPressed: _options,
                          icon: const Icon(Icons.tune_rounded, size: 21)),
                    ]),
                  if (_selecting)
                    Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: <Widget>[
                          Text('已选 ${_selected.length} 本',
                              style: theme.textStyles.footnote1),
                          TextButton(
                              onPressed: _deleting
                                  ? null
                                  : () => setState(() => _selected.addAll(
                                      _books(library).map((book) => book.id))),
                              child: const Text('全选')),
                          if (_metadataEnabled && _selected.length == 1)
                            TextButton(
                                onPressed: _deleting
                                    ? null
                                    : () => showBookMetadataEditor(context,
                                        bookId: _selected.single, mobile: true),
                                child: const Text('编辑信息')),
                          if (library.serials.enabled && _selected.length == 1)
                            TextButton(
                                onPressed: _deleting
                                    ? null
                                    : () => showBookUpdates(context,
                                        bookId: _selected.single, mobile: true),
                                child: const Text('连载追更')),
                          TextButton(
                              onPressed: _deleting || _selected.isEmpty
                                  ? null
                                  : _deleteSelected,
                              child: Text(_deleting ? '删除中' : '删除所选',
                                  style: TextStyle(color: theme.colors.error))),
                        ]),
                  if (library.hasOrganizationFilters)
                    TextButton(
                        onPressed: _options,
                        child:
                            Text('筛选中 · ${_books(library).length} 本 · 调整筛选')),
                  if (library.serials.error != null)
                    TextButton(
                        onPressed: library.serials.load,
                        child: const Text('追更状态刷新失败 · 点击重试')),
                  const SizedBox(height: 8),
                  Expanded(child: _content(library)),
                ]),
          );
        },
      ),
    );
  }

  Widget _content(LibraryController library) {
    if (library.state == LoadState.idle || library.state == LoadState.loading) {
      return const MobileLoadingView('正在加载书库');
    }
    if (library.state == LoadState.error && library.books.isEmpty) {
      return MobileEmptyView(
          icon: const Icon(Icons.cloud_off_outlined),
          title: '暂时无法加载书库',
          message: library.error ?? '检查服务连接后重试。',
          action: MobileActionButton(
              onPressed: () => library.load(),
              icon: Icons.refresh_rounded,
              child: const Text('重新加载')));
    }
    final books = _books(library);
    if (books.isEmpty && library.linkJob == null) {
      final empty = library.books.isEmpty;
      return MobileEmptyView(
        icon: const Icon(Icons.auto_stories_outlined),
        title: empty
            ? '把想读的故事放进书库'
            : library.query.trim().isNotEmpty
                ? '没有找到这本书'
                : '这里还没有${_filter.label}',
        message: empty ? '在发现页搜索作品，或导入作品链接与本地文件。' : '调整关键词或类型，查看书库中的其他作品。',
        action: empty
            ? MobileActionButton(
                onPressed: _addBook,
                icon: Icons.library_add_outlined,
                child: const Text('导入第一本作品'))
            : MobileActionButton(
                tonal: true,
                onPressed: () {
                  setState(() => _filter = _ShelfFilter.all);
                  _queryController.clear();
                  library.setQuery('');
                  library.setOrganization();
                },
                child: const Text('查看全部藏书')),
      );
    }
    final recents = books
        .where((book) => book.lastReadAt?.isNotEmpty == true)
        .toList()
      ..sort((a, b) => b.lastReadAt!.compareTo(a.lastReadAt!));
    final continueBook = !_selecting &&
            _filter == _ShelfFilter.all &&
            library.query.trim().isEmpty &&
            recents.isNotEmpty
        ? recents.first
        : null;
    return LayoutBuilder(builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      // Keep narrow phones compact; reserve wider tiles for large text.
      final columns = scale > 1.5
          ? (constraints.maxWidth / 170).floor().clamp(2, 5)
          : (constraints.maxWidth / 112).floor().clamp(3, 7);
      const spacing = 12.0;
      final coverWidth =
          (constraints.maxWidth - (columns - 1) * spacing) / columns;
      return RefreshIndicator(
        onRefresh: () => library.load(silent: true),
        child: CustomScrollView(
          key: const PageStorageKey('mobile-library-grid'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            SliverToBoxAdapter(
                child: MobileImportProgress(onOpenBook: _openBook)),
            if (library.state == LoadState.error)
              SliverToBoxAdapter(
                  child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text('刷新失败，正在显示已加载的书库。${library.error ?? ''}',
                          style: TextStyle(
                              color: MiuixTheme.of(context).colors.error)))),
            if (continueBook != null)
              SliverToBoxAdapter(
                  child: MobileContinueReading(
                      book: continueBook,
                      onRead: () => _openBook(continueBook, read: true),
                      onDetails: () => _openBook(continueBook))),
            if (continueBook != null)
              SliverToBoxAdapter(
                  child: MobileSection(
                      title: '全部作品',
                      trailing: Text(library.sort.label,
                          style: MiuixTheme.of(context).textStyles.footnote1))),
            SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: coverWidth * 1.42 +
                      12 +
                      MediaQuery.textScalerOf(context).scale(14) * 4.3,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: 16),
              delegate: SliverChildBuilderDelegate((context, index) {
                final book = books[index];
                return MobileLibraryTile(
                    key: ValueKey('mobile-library-book-${book.id}'),
                    book: book,
                    newChapterCount:
                        library.serials.records[book.id]?.newChapterCount ?? 0,
                    selecting: _selecting,
                    selected: _selected.contains(book.id),
                    onOpen: () =>
                        _selecting ? _toggleSelection(book) : _openBook(book),
                    onSelect: () => _toggleSelection(book));
              }, childCount: books.length),
            ),
            SliverToBoxAdapter(
                child: SizedBox(height: mobileNavigationClearance(context))),
          ],
        ),
      );
    });
  }
}

enum _ShelfFilter {
  all('全部'),
  novels('小说'),
  manga('漫画');

  const _ShelfFilter(this.label);
  final String label;
  bool matches(Book book) => switch (this) {
        _ShelfFilter.all => true,
        _ShelfFilter.novels => book.kind != '漫画',
        _ShelfFilter.manga => book.kind == '漫画'
      };
}
