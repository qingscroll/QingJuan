import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/models/book.dart';
import '../core/models/source.dart';
import '../features/detail/book_detail_page.dart';
import '../features/sources/sources_controller.dart';
import 'mobile_action_button.dart';
import 'mobile_book_cover.dart';
import 'mobile_import_progress.dart';
import 'mobile_import_sheet.dart';
import 'mobile_page.dart';
import 'mobile_search_field.dart';
import 'mobile_sheet.dart';
import 'mobile_state.dart';
import 'mobile_widgets.dart';

class MobileSearchPage extends StatefulWidget {
  const MobileSearchPage({super.key});
  @override
  State<MobileSearchPage> createState() => _MobileSearchPageState();
}

class _MobileSearchPageState extends State<MobileSearchPage> {
  final _controller = TextEditingController();
  BookSearchEngine _engine = BookSearchEngine.bookSources;
  String? _importingUrl;
  String? _submittedQuery;
  String? _importError;

  static const _labels = <BookSearchEngine, String>{
    BookSearchEngine.installedPlugins: '导入插件',
    BookSearchEngine.bookSources: '我的书源',
    BookSearchEngine.quark: '夸克',
    BookSearchEngine.fanqie: '番茄',
    BookSearchEngine.qidian: '起点',
    BookSearchEngine.biqvge: '笔趣阁',
  };

  String get _sourceHint => _engine == BookSearchEngine.biqvge
      ? '八零小说网使用动态搜索；b520 与笔趣看来自目录索引，目录可能不完整或受区域限制。'
      : '输入书名或作者，在${_labels[_engine]}中搜索。\n已有作品链接或文件，也可以直接导入。';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    final sources = AppScope.of(context).sources;
    if (query.isEmpty || sources.searching) return;
    FocusScope.of(context).unfocus();
    setState(() => _submittedQuery = query);
    await sources.search(query, engine: _engine);
  }

  void _selectEngine(BookSearchEngine engine, SourcesController sources) {
    if (_engine == engine) return;
    setState(() {
      _engine = engine;
      _submittedQuery = null;
    });
    sources.clearSearchResults();
  }

  void _openBook(Book book) => Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => BookDetailPage(bookId: book.id)));

  Future<void> _import(SourceSearchResult result) async {
    if (_importingUrl != null) return;
    final library = AppScope.of(context).library;
    if (library.hasActiveLinkJob) {
      setState(() => _importError = '已有作品正在导入，请查看上方进度，完成后再添加下一本。');
      return;
    }
    setState(() {
      _importingUrl = result.sourceUrl;
      _importError = null;
    });
    try {
      final payload = result.toImportPayload();
      if (const <String>{
        'source-builtin-quark',
        'source-builtin-fanqie',
        'source-builtin-qidian',
        'source-builtin-biqvge'
      }.contains(result.sourceId)) {
        payload['downloadMode'] = 'on_demand';
      }
      await library.startLinkJob('import', payload);
      if (!mounted) return;
      if (library.linkJob?.isFailed == true) {
        setState(() => _importError =
            '导入失败：${library.linkJob!.error ?? library.linkJob!.message}');
      }
    } catch (error) {
      if (mounted) setState(() => _importError = '导入失败：$error');
    } finally {
      if (mounted) setState(() => _importingUrl = null);
    }
  }

  Future<void> _preview(SourceSearchResult result) async {
    final existing = AppScope.of(context)
        .library
        .books
        .where((book) => book.sourceUrl == result.sourceUrl)
        .firstOrNull;
    final add = await showMobileSheet<bool>(
      context: context,
      title: '作品预览',
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                      width: 86,
                      height: 122,
                      child: MobileBookCover(
                          title: result.title, cover: result.cover)),
                  const SizedBox(width: 16),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                        Text(result.title,
                            style: MiuixTheme.of(context).textStyles.subtitle),
                        const SizedBox(height: 8),
                        if (result.author.isNotEmpty) Text(result.author),
                        const SizedBox(height: 6),
                        Text('${result.kind} · ${result.language}'),
                        const SizedBox(height: 6),
                        Text(result.sourceName),
                      ])),
                ]),
            const SizedBox(height: 24),
            Text(
                result.synopsis.isEmpty
                    ? '书源暂未提供简介。导入后可查看作品目录。'
                    : result.synopsis,
                style: MiuixTheme.of(context)
                    .textStyles
                    .body2
                    .copyWith(height: 1.65)),
            const SizedBox(height: 24),
            MobileActionButton(
                onPressed: () => Navigator.pop(context, true),
                icon: existing != null
                    ? Icons.auto_stories_outlined
                    : Icons.library_add_outlined,
                child: Text(existing != null ? '打开书库中的作品' : '加入书库')),
          ]),
    );
    if (!mounted || add != true) return;
    if (existing != null) {
      _openBook(existing);
    } else {
      await _import(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final sources = scope.sources;
    final theme = MiuixTheme.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[sources, scope.library]),
      builder: (context, _) => MobilePage(
        title: '发现',
        actions: <Widget>[
          IconButton(
              tooltip: '导入作品',
              icon: const Icon(Icons.add_rounded),
              onPressed: () async {
                final book = await showMobileImportSheet(context);
                if (mounted && book != null) _openBook(book);
              }),
        ],
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(children: <Widget>[
                Expanded(
                    child: MobileSearchField(
                        key: const ValueKey('mobile-store-query'),
                        controller: _controller,
                        hintText: '搜索书名或作者',
                        onSubmitted: (_) => _search())),
                const SizedBox(width: 4),
                MobileActionButton(
                    key: const ValueKey('mobile-store-search-submit'),
                    onPressed: sources.searching ? null : _search,
                    busy: sources.searching,
                    child: const Text('搜索')),
              ]),
              const SizedBox(height: 10),
              SizedBox(
                height: (MediaQuery.textScalerOf(context).scale(14) * 1.5 + 22)
                    .clamp(48, double.infinity),
                child: ListView(
                    scrollDirection: Axis.horizontal,
                    key: const PageStorageKey('mobile-store-categories'),
                    children: <Widget>[
                      for (final engine in BookSearchEngine.values)
                        Semantics(
                            selected: _engine == engine,
                            child: TextButton(
                              key: ValueKey(
                                  'mobile-store-category-${engine.name}'),
                              onPressed: () => _selectEngine(engine, sources),
                              style: TextButton.styleFrom(
                                  foregroundColor: _engine == engine
                                      ? theme.colors.primary
                                      : theme.colors.onBackgroundVariant),
                              child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: <Widget>[
                                    Text(_labels[engine]!,
                                        style: TextStyle(
                                            fontWeight: _engine == engine
                                                ? FontWeight.w700
                                                : FontWeight.w400)),
                                    const SizedBox(height: 4),
                                    Container(
                                        width: 16,
                                        height: 2,
                                        color: _engine == engine
                                            ? theme.colors.primary
                                            : Colors.transparent),
                                  ]),
                            )),
                    ]),
              ),
              const SizedBox(height: 12),
              Expanded(child: _content(sources)),
            ]),
      ),
    );
  }

  Widget _content(SourcesController sources) {
    if (sources.searching) return MobileLoadingView('正在${_labels[_engine]}中查找');
    if (sources.error != null) {
      return MobileEmptyView(
          icon: const Icon(Icons.cloud_off_outlined),
          title: '暂时无法搜索此来源',
          message: '${sources.error!}\n可以重试，或切换其他来源。',
          action: MobileActionButton(
              onPressed: _search,
              icon: Icons.refresh_rounded,
              child: const Text('重新搜索')));
    }
    if (sources.results.isEmpty) {
      return Column(children: <Widget>[
        MobileImportProgress(onOpenBook: _openBook),
        Expanded(
            child: MobileEmptyView(
          icon: const Icon(Icons.search_outlined),
          title: _submittedQuery == null ? '找一本想读的作品' : '没有找到相关作品',
          message: _submittedQuery == null
              ? (_engine == BookSearchEngine.bookSources &&
                      sources.sources.where((source) => source.enabled).isEmpty
                  ? '当前没有启用的书源。可切换上方内置来源，或在我的页面管理书源。'
                  : _sourceHint)
              : '试试更短的关键词，或切换上方来源继续寻找。',
          action: _submittedQuery == null
              ? MobileActionButton(
                  tonal: true,
                  icon: Icons.library_add_outlined,
                  onPressed: () async {
                    final book = await showMobileImportSheet(context);
                    if (mounted && book != null) _openBook(book);
                  },
                  child: const Text('导入作品'))
              : null,
        )),
      ]);
    }
    final library = AppScope.of(context).library;
    final theme = MiuixTheme.of(context);
    return ListView.builder(
      key: PageStorageKey(
          'mobile-store-results-${_engine.name}-$_submittedQuery'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(bottom: mobileNavigationClearance(context)),
      itemCount: sources.results.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                MobileImportProgress(onOpenBook: _openBook),
                if (_importError != null)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Semantics(
                          liveRegion: true,
                          child: Text(_importError!,
                              style: TextStyle(
                                  color: theme.colors.error, height: 1.5)))),
                Text('${sources.results.length} 个结果 · ${_labels[_engine]}',
                    style: theme.textStyles.footnote1
                        .copyWith(color: theme.colors.onBackgroundVariant)),
                const SizedBox(height: 14),
              ]);
        }
        final result = sources.results[index - 1];
        final existing = library.books
            .where((book) => book.sourceUrl == result.sourceUrl)
            .firstOrNull;
        final active = library.hasActiveLinkJob &&
            library.linkJobPayload?['sourceUrl'] == result.sourceUrl;
        return _SearchResultRow(
          key: ValueKey('mobile-store-result-${result.sourceUrl}'),
          result: result,
          importing: _importingUrl == result.sourceUrl || active,
          existing: existing != null,
          onPreview: () => _preview(result),
          onImport: _importingUrl != null || active
              ? null
              : () => existing != null ? _openBook(existing) : _import(result),
        );
      },
    );
  }
}

class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow(
      {required this.result,
      required this.importing,
      required this.existing,
      required this.onPreview,
      this.onImport,
      super.key});
  final SourceSearchResult result;
  final bool importing;
  final bool existing;
  final VoidCallback onPreview;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(children: <Widget>[
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Semantics(
              button: true,
              label: '预览${result.title}',
              child: GestureDetector(
                  onTap: onPreview,
                  child: SizedBox(
                      width: 72,
                      height: 104,
                      child: MobileBookCover(
                          title: result.title, cover: result.cover)))),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                GestureDetector(
                    onTap: onPreview,
                    child: Text(result.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textStyles.body1.copyWith(
                            color: theme.colors.onBackground,
                            fontWeight: FontWeight.w600,
                            height: 1.45))),
                const SizedBox(height: 4),
                Text(result.author.isEmpty ? result.sourceName : result.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textStyles.footnote1
                        .copyWith(color: theme.colors.onBackgroundVariant)),
                const SizedBox(height: 6),
                Text(
                    result.synopsis.isEmpty ? '暂无简介，点按作品查看详情' : result.synopsis,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textStyles.footnote1.copyWith(
                        color: theme.colors.onBackgroundVariant, height: 1.55)),
                const SizedBox(height: 6),
                Text('${result.kind} · ${result.sourceName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textStyles.footnote2
                        .copyWith(color: theme.colors.onBackgroundVariant)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
                  MobileActionButton(
                      tonal: true,
                      onPressed: onPreview,
                      child: const Text('预览')),
                  MobileActionButton(
                      onPressed: onImport,
                      busy: importing,
                      icon: existing
                          ? Icons.auto_stories_outlined
                          : Icons.library_add_outlined,
                      child: Text(importing
                          ? '正在加入…'
                          : existing
                              ? '打开作品'
                              : '加入书库')),
                ]),
              ])),
        ]),
        Divider(
            height: 16,
            thickness: 1,
            indent: 86,
            color: theme.colors.dividerLine),
      ]),
    );
  }
}
