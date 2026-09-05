import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/models/source.dart';
import '../features/sources/sources_controller.dart';
import 'mobile_detail_page.dart';
import 'mobile_page.dart';
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

  static const _labels = <BookSearchEngine, String>{
    BookSearchEngine.bookSources: '书源',
    BookSearchEngine.quark: '夸克',
    BookSearchEngine.fanqie: '番茄',
    BookSearchEngine.qidian: '起点',
    BookSearchEngine.biqvge: '笔趣阁',
  };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    FocusScope.of(context).unfocus();
    await AppScope.of(context).sources.search(_controller.text, engine: _engine);
  }

  Future<void> _import(SourceSearchResult result) async {
    if (_importingUrl != null) return;
    setState(() => _importingUrl = result.sourceUrl);
    try {
      final payload = result.toImportPayload();
      if (const <String>{
        'source-builtin-quark',
        'source-builtin-fanqie',
        'source-builtin-qidian',
        'source-builtin-biqvge',
      }.contains(result.sourceId)) {
        payload['downloadMode'] = 'on_demand';
      }
      final book = await AppScope.of(context).library.importFromSearch(payload);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MobileBookDetailPage(bookId: book.id),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _importingUrl = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = AppScope.of(context).sources;
    return AnimatedBuilder(
      animation: sources,
      builder: (context, _) => MobilePage(
        title: '搜索',
        subtitle: '从书源和内置站点查找作品。',
        child: Column(
          children: <Widget>[
            MiuixTextField(
              controller: _controller,
              label: '搜索书名或作者',
              useLabelAsPlaceholder: true,
              singleLine: true,
              textInputAction: TextInputAction.search,
              leadingIcon: MiuixIcon(
                vector: MiuixIcons.extended.byName('search')!,
                size: 20,
              ),
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: <Widget>[
                  for (final engine in BookSearchEngine.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: MiuixButton(
                        onPressed: () => setState(() {
                          _engine = engine;
                          sources.clearSearchResults();
                        }),
                        colors: _engine == engine
                            ? MiuixButtonDefaults.buttonColorsPrimary(context)
                            : MiuixButtonDefaults.buttonColors(context),
                        minHeight: 38,
                        cornerRadius: 19,
                        child: MiuixText(_labels[engine]!),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Expanded(child: _buildContent(sources)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(SourcesController sources) {
    if (sources.searching) {
      return MobileLoadingView('正在查询${_labels[_engine]}');
    }
    if (sources.error != null) {
      return MobileEmptyView(
        icon: MiuixIcon(vector: MiuixIcons.extended.byName('help')!),
        title: '搜索失败',
        message: sources.error!,
        action: MiuixTextButton('重试', onPressed: _search),
      );
    }
    if (sources.results.isEmpty) {
      return MobileEmptyView(
        icon: MiuixIcon(vector: MiuixIcons.extended.byName('search')!),
        title: '开始查找作品',
        message: '${_labels[_engine]}结果会显示来源、作者和简介，确认后即可加入书架。',
      );
    }
    return ListView.separated(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 18),
      itemCount: sources.results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) => _SearchResultCard(
        result: sources.results[index],
        importing: _importingUrl == sources.results[index].sourceUrl,
        onImport: () => _import(sources.results[index]),
      ),
    );
  }
}

class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({
    required this.result,
    required this.importing,
    required this.onImport,
  });

  final SourceSearchResult result;
  final bool importing;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return MobileCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            result.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textStyles.headline1.copyWith(
              color: theme.colors.onBackground,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            result.author.isEmpty ? result.sourceName : result.author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textStyles.footnote1.copyWith(
              color: theme.colors.onSurfaceVariantSummary,
            ),
          ),
          if (result.synopsis.isNotEmpty) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              result.synopsis,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textStyles.footnote1.copyWith(height: 1.4),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    MobilePill(
                      result.sourceName,
                      color: theme.colors.primary,
                    ),
                    MobilePill(result.kind),
                  ],
                ),
              ),
              MiuixTextButton(
                importing ? '导入中' : '加入书架',
                onPressed: importing ? null : onImport,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

