import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_scope.dart';
import '../../core/models/source.dart';
import '../../shared/app_surface.dart';
import '../../shared/feedback_widgets.dart';
import '../../shared/motion.dart';
import '../../shared/page_frame.dart';
import '../../shared/responsive.dart';
import '../detail/book_detail_page.dart';
import '../preview/book_preview_page.dart';
import '../sources/sources_controller.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  BookSearchEngine _engine = BookSearchEngine.bookSources;
  String? _importingSourceUrl;

  String get _engineName => switch (_engine) {
        BookSearchEngine.installedPlugins => '导入插件',
        BookSearchEngine.bookSources => '书源',
        BookSearchEngine.quark => '夸克',
        BookSearchEngine.fanqie => '番茄',
        BookSearchEngine.qidian => '起点',
        BookSearchEngine.biqvge => '笔趣阁',
      };

  String get _loadingLabel => switch (_engine) {
        BookSearchEngine.installedPlugins => '正在查询导入插件',
        BookSearchEngine.bookSources => '正在查询书源',
        BookSearchEngine.quark => '正在查询夸克小说',
        BookSearchEngine.fanqie => '正在查询番茄小说',
        BookSearchEngine.qidian => '正在查询起点中文网',
        BookSearchEngine.biqvge => '正在查询笔趣阁',
      };

  String get _emptyMessage => switch (_engine) {
        BookSearchEngine.installedPlugins => '搜索当前后端已导入并启用的插件，可在加入书架前核对作品。',
        BookSearchEngine.bookSources => '搜索结果会按书源返回，可在导入前核对作者和简介。',
        BookSearchEngine.quark => '夸克结果来自书旗网页内核，可在加入书架前核对作者和简介。',
        BookSearchEngine.fanqie => '番茄结果来自匿名公开搜索，可在加入书架前核对作者和简介。',
        BookSearchEngine.qidian => '起点结果来自移动站公开搜索，可在加入书架前核对作者和简介。',
        BookSearchEngine.biqvge =>
          '八零小说网使用动态搜索；b520 与笔趣看来自公开目录索引，目录可能不完整或受区域限制。',
      };

  String get _heroMessage => switch (_engine) {
        BookSearchEngine.installedPlugins => '输入书名或作者，通过已导入的插件查找作品。',
        BookSearchEngine.bookSources => '输入书名或作者，同时查询已启用且兼容搜索的书源。',
        BookSearchEngine.quark => '输入书名或作者，通过夸克小说的书旗网页内核查找作品。',
        BookSearchEngine.fanqie => '输入书名或作者，通过番茄小说的匿名公开搜索查找作品。',
        BookSearchEngine.qidian => '输入书名或作者，通过起点中文网移动站的公开搜索查找作品。',
        BookSearchEngine.biqvge => '输入书名或作者，优先通过八零小说网搜索，并聚合可用的笔趣阁镜像目录。',
      };

  String _availabilityLabel(SourcesController sources) => switch (_engine) {
        BookSearchEngine.installedPlugins =>
          '${sources.plugins.where((plugin) => plugin.isInstalled && plugin.enabled && plugin.capabilities.contains('search')).length} 个插件可搜索',
        BookSearchEngine.bookSources =>
          '${sources.sources.where((source) => source.enabled).length} 个书源可用',
        BookSearchEngine.quark => '夸克小说',
        BookSearchEngine.fanqie => '番茄小说',
        BookSearchEngine.qidian => '起点中文网',
        BookSearchEngine.biqvge => '三站聚合 · 镜像可能受限',
      };

  String get _resultOriginLabel => switch (_engine) {
        BookSearchEngine.installedPlugins => '结果来自导入插件',
        BookSearchEngine.bookSources => '结果来自已启用书源',
        BookSearchEngine.quark => '结果来自书旗网页内核',
        BookSearchEngine.fanqie => '结果来自番茄公开搜索',
        BookSearchEngine.qidian => '结果来自起点移动站',
        BookSearchEngine.biqvge => '结果来自笔趣阁',
      };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _import(SourceSearchResult result) async {
    final mobile = usesMobileUi(context);
    if (mobile && _importingSourceUrl != null) return;
    if (mobile) setState(() => _importingSourceUrl = result.sourceUrl);
    try {
      final payload = result.toImportPayload();
      if (mobile &&
          const <String>{
            'source-builtin-quark',
            'source-builtin-fanqie',
            'source-builtin-qidian',
            'source-builtin-biqvge',
          }.contains(result.sourceId)) {
        payload['downloadMode'] = 'on_demand';
      }
      final library = AppScope.of(context).library;
      final book = mobile
          ? await library.importFromSearch(payload)
          : await library.import(payload);
      if (mounted) {
        await Navigator.of(context).push<void>(
          qjPageRoute<void>(
            context: context,
            builder: (_) => BookDetailPage(bookId: book.id),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        displayInfoBar(
          context,
          builder: (_, __) => InfoBar(
            title: const Text('导入失败'),
            content: Text('$error'),
            severity: InfoBarSeverity.error,
          ),
        );
      }
    } finally {
      if (mobile && mounted) setState(() => _importingSourceUrl = null);
    }
  }

  Future<void> _search(SourcesController sources) =>
      sources.search(_controller.text, engine: _engine);

  Future<void> _preview(SourceSearchResult result) => showBookPreview(
        context,
        payload: {
          ...result.toImportPayload(),
          'author': result.author,
          if (usesMobileUi(context) &&
              const <String>{
                'source-builtin-quark',
                'source-builtin-fanqie',
                'source-builtin-qidian',
                'source-builtin-biqvge',
              }.contains(result.sourceId))
            'downloadMode': 'on_demand',
        },
      );

  void _setEngine(
    SourcesController sources,
    BookSearchEngine engine,
  ) {
    if (_engine == engine) return;
    setState(() => _engine = engine);
    sources.clearSearchResults();
  }

  Widget _engineSelector(SourcesController sources) {
    return ComboBox<BookSearchEngine>(
      key: const ValueKey('search-engine-selector'),
      value: _engine,
      isExpanded: true,
      items: const <ComboBoxItem<BookSearchEngine>>[
        ComboBoxItem<BookSearchEngine>(
            value: BookSearchEngine.installedPlugins, child: Text('导入插件')),
        ComboBoxItem<BookSearchEngine>(
          value: BookSearchEngine.bookSources,
          child: Text('书源'),
        ),
        ComboBoxItem<BookSearchEngine>(
          value: BookSearchEngine.quark,
          child: Text('夸克'),
        ),
        ComboBoxItem<BookSearchEngine>(
          value: BookSearchEngine.fanqie,
          child: Text('番茄'),
        ),
        ComboBoxItem<BookSearchEngine>(
          value: BookSearchEngine.qidian,
          child: Text('起点'),
        ),
        ComboBoxItem<BookSearchEngine>(
          value: BookSearchEngine.biqvge,
          child: Text('笔趣阁'),
        ),
      ],
      onChanged: sources.searching
          ? null
          : (value) {
              if (value != null) _setEngine(sources, value);
            },
    );
  }

  Widget _searchInput(SourcesController sources) {
    return Row(
      children: <Widget>[
        Expanded(
          child: TextBox(
            key: const ValueKey('search-query-input'),
            controller: _controller,
            magnifierConfiguration: textInputMagnifierConfiguration(context),
            placeholder: '输入书名或作者',
            onSubmitted: (_) => _search(sources),
            prefix: const Padding(
              padding: EdgeInsets.only(left: 10),
              child: Icon(FluentIcons.search, size: 18),
            ),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton(
          key: const ValueKey('search-submit-button'),
          onPressed: sources.searching ? null : () => _search(sources),
          child: const Text('搜索'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sources = AppScope.of(context).sources;
    return AnimatedBuilder(
      animation: sources,
      builder: (context, _) {
        if (!usesMobileUi(context)) return _buildDesktopPage(sources);
        return PageFrame(
          title: '搜索',
          subtitle: '搜索作品，先查看目录和正文，再决定加入书架。',
          compactHeader: ReadingPageHeader(
            title: '搜索',
            subtitle: '当前使用$_engineName搜索',
            actions: const <Widget>[],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FeatureHero(
                icon: FluentIcons.search,
                title: '搜索书籍',
                message: _heroMessage,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    InfoLabel(
                      label: '搜索引擎',
                      child: _engineSelector(sources),
                    ),
                    const SizedBox(height: 10),
                    _searchInput(sources),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        StatusPill(
                          _availabilityLabel(sources),
                          accented: true,
                          icon: FluentIcons.database,
                        ),
                        StatusPill(_resultOriginLabel),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              if (sources.searching)
                LoadingView(label: _loadingLabel)
              else if (sources.error != null)
                ErrorView(
                  message: sources.error!,
                  onRetry: () => _search(sources),
                )
              else if (sources.results.isEmpty)
                const AppSurface(
                  tone: AppSurfaceTone.muted,
                  padding: EdgeInsets.symmetric(horizontal: 22, vertical: 24),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      AccentIcon(FluentIcons.lightbulb, size: 46),
                      SizedBox(width: 15),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '搜索小提示',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            SizedBox(height: 6),
                            Text(
                              '使用作品完整名称更容易命中；加入书架前可以核对作者、来源和简介。',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )
              else ...<Widget>[
                SectionTitle(
                  '搜索结果',
                  trailing: Text(
                    '${sources.results.length} 本',
                    style: FluentTheme.of(context).typography.caption,
                  ),
                ),
                ...sources.results.map(
                  (result) => _SearchResultTile(
                    result: result,
                    onPreview: () => _preview(result),
                    importing: _importingSourceUrl == result.sourceUrl,
                    onImport: _importingSourceUrl == null
                        ? () => _import(result)
                        : null,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildDesktopPage(SourcesController sources) {
    return PageFrame(
      key: const ValueKey('desktop-search-page'),
      title: '全网搜索',
      subtitle: '搜索作品，先查看目录和正文，再决定加入书架。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              SizedBox(
                width: 148,
                child: InfoLabel(
                  label: '搜索引擎',
                  child: _engineSelector(sources),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InfoLabel(
                  label: '书名或作者',
                  child: TextBox(
                    key: const ValueKey('search-query-input'),
                    controller: _controller,
                    magnifierConfiguration:
                        textInputMagnifierConfiguration(context),
                    placeholder: '输入书名或作者',
                    onSubmitted: (_) => _search(sources),
                    prefix: const Padding(
                      padding: EdgeInsets.only(left: 10),
                      child: Icon(FluentIcons.search),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                key: const ValueKey('search-submit-button'),
                onPressed: sources.searching ? null : () => _search(sources),
                child: const Text('搜索'),
              ),
            ],
          ),
          const SizedBox(height: 22),
          if (sources.searching)
            LoadingView(label: _loadingLabel)
          else if (sources.error != null)
            ErrorView(
              message: sources.error!,
              onRetry: () => _search(sources),
            )
          else if (sources.results.isEmpty)
            EmptyView(
              icon: FluentIcons.search_issue,
              title: '输入关键词开始搜索',
              message: _emptyMessage,
            )
          else
            ...sources.results.map(
              (result) => _SearchResultTile(
                result: result,
                onPreview: () => _preview(result),
                importing: false,
                onImport: () => _import(result),
              ),
            ),
        ],
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.result,
    required this.importing,
    required this.onImport,
    required this.onPreview,
  });

  final SourceSearchResult result;
  final bool importing;
  final VoidCallback? onImport;
  final VoidCallback onPreview;

  Widget _previewTarget(Widget child) => HoverButton(
        onPressed: onPreview,
        cursor: SystemMouseCursors.click,
        builder: (context, states) =>
            FocusBorder(focused: states.isFocused, child: child),
      );

  Widget _importButton({required bool compact}) => Button(
        key: ValueKey('search-import-${result.sourceUrl}'),
        onPressed: onImport,
        child: importing
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: ProgressRing(strokeWidth: 2),
                  ),
                  const SizedBox(width: 7),
                  Text(compact ? '加入中' : '正在加入'),
                ],
              )
            : Text(compact ? '加入' : '加入书架'),
      );

  Widget _actions({required bool compact}) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
              key: ValueKey('search-preview-${result.sourceUrl}'),
              onPressed: onPreview,
              child: const Text('查看内容')),
          _importButton(compact: compact),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final compact = usesMobileUi(context);
    if (!compact) {
      return AppSurface(
        margin: const EdgeInsets.only(bottom: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 700 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.3;
            final details = _previewTarget(Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const AccentIcon(FluentIcons.book_answers),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        result.title,
                        style: theme.typography.bodyLarge
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          if (result.author.isNotEmpty)
                            StatusPill(result.author),
                          StatusPill(result.sourceName, accented: true),
                          StatusPill(result.kind),
                        ],
                      ),
                      if (result.synopsis.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 9),
                        Text(
                          result.synopsis,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.typography.body?.copyWith(
                            color: theme.resources.textFillColorSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ));
            if (narrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  details,
                  const SizedBox(height: 14),
                  _actions(compact: false),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(child: details),
                const SizedBox(width: 20),
                _actions(compact: false),
              ],
            );
          },
        ),
      );
    }
    return AppSurface(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(compact ? 14 : 16),
      tone: AppSurfaceTone.elevated,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _previewTarget(SizedBox(
            width: compact ? 70 : 62,
            height: compact ? 98 : 88,
            child: _SearchCover(result: result),
          )),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _previewTarget(Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      result.author.isEmpty ? result.sourceName : result.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.caption?.copyWith(
                        color: theme.resources.textFillColorSecondary,
                      ),
                    ),
                    if (result.synopsis.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        result.synopsis,
                        maxLines: compact ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.typography.caption?.copyWith(height: 1.4),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        StatusPill(result.sourceName, accented: true),
                        StatusPill(result.kind),
                      ],
                    ),
                  ],
                )),
                const SizedBox(height: 8),
                _actions(compact: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchCover extends StatelessWidget {
  const _SearchCover({required this.result});

  final SourceSearchResult result;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final cover = result.cover?.trim();
    final api = AppScope.of(context).api;
    final fallback = ColoredBox(
      color: theme.accentColor.withAlpha(
        theme.brightness == Brightness.dark ? 56 : 26,
      ),
      child: Icon(
        FluentIcons.book_answers,
        color: theme.accentColor,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: cover == null || cover.isEmpty
          ? fallback
          : Image.network(
              api.resolveUrl(cover),
              headers: api.headersForUrl(cover),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
  }
}
