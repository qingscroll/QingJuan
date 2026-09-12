import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_scope.dart';
import '../../core/models/book.dart';
import '../../core/models/discovery.dart';
import '../../core/state/load_state.dart';
import '../../shared/feedback_widgets.dart';
import '../../shared/motion.dart';
import '../../shared/page_frame.dart';
import '../detail/book_detail_page.dart';
import '../preview/book_preview_page.dart';
import 'discovery_book_card.dart';
import 'discovery_controller.dart';
import 'discovery_filters.dart';
import 'discovery_pagination.dart';

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({super.key});

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage> {
  DiscoveryController? _controller;
  final _scroll = ScrollController();
  String? _importingUrl;
  String? _importError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppScope.of(context).discovery;
    if (_controller == controller) return;
    _controller = controller;
    if (controller.sitesState == LoadState.idle) {
      unawaited(controller.loadSites());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _open(Book book) => Navigator.of(context).push<void>(
        qjPageRoute<void>(
            context: context, builder: (_) => BookDetailPage(bookId: book.id)),
      );

  Future<void> _preview(DiscoveryBook book, DiscoverySite site) =>
      showBookPreview(context,
          payload: {...book.toImportPayload(site), 'author': book.author});

  Future<void> _import(DiscoveryBook item) async {
    if (_importingUrl != null || item.url.isEmpty) return;
    final scope = AppScope.of(context);
    final site = scope.discovery.selectedSite;
    if (site == null) return;
    final library = scope.library;
    final existing =
        library.books.where((book) => book.sourceUrl == item.url).firstOrNull;
    if (existing != null) {
      await _open(existing);
      return;
    }
    final generation = library.contextGeneration;
    setState(() {
      _importingUrl = item.url;
      _importError = null;
    });
    try {
      final book = await library.importFromSearch(item.toImportPayload(site));
      if (mounted && library.contextGeneration == generation) await _open(book);
    } catch (error) {
      if (mounted && library.contextGeneration == generation) {
        setState(() => _importError = '加入书架失败：$error');
      }
    } finally {
      if (mounted) setState(() => _importingUrl = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final controller = scope.discovery;
    return AnimatedBuilder(
      animation: Listenable.merge([controller, scope.library]),
      builder: (context, _) => PageFrame(
        key: const ValueKey('desktop-discovery-page'),
        title: '推荐',
        subtitle: '发现各站点的推荐作品与热门榜单。',
        scrollable: false,
        command: Button(
          key: const ValueKey('discovery-refresh'),
          onPressed: controller.sitesState == LoadState.loading ||
                  controller.contentState == LoadState.loading
              ? null
              : () => controller.refresh(),
          child: const Text('刷新'),
        ),
        child: Expanded(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (controller.sites.isNotEmpty)
              DiscoveryFilters(controller: controller),
            if (_importError != null) ...<Widget>[
              const SizedBox(height: 12),
              InfoBar(
                  title: const Text('导入失败'),
                  content: Text(_importError!),
                  severity: InfoBarSeverity.error,
                  onClose: () => setState(() => _importError = null)),
            ],
            const SizedBox(height: 16),
            Expanded(
              child: controller.contentState == LoadState.ready
                  ? _content(controller)
                  : SingleChildScrollView(child: _content(controller)),
            ),
            DiscoveryPagination(controller: controller),
          ],
        )),
      ),
    );
  }

  Widget _content(DiscoveryController controller) {
    if (controller.sitesState == LoadState.loading ||
        controller.sitesState == LoadState.idle) {
      return const LoadingView(label: '正在加载站点');
    }
    if (controller.sitesState == LoadState.error) {
      return ErrorView(
          message: controller.sitesError ?? '站点加载失败',
          onRetry: () => controller.loadSites());
    }
    if (controller.sites.isEmpty) {
      return EmptyView(
          icon: FluentIcons.book_answers,
          title: '暂无可用站点',
          message: '刷新站点列表后重试。',
          action: Button(
              onPressed: () => controller.loadSites(),
              child: const Text('重试')));
    }
    if (controller.contentState == LoadState.loading) {
      return const LoadingView(label: '正在加载作品');
    }
    if (controller.contentState == LoadState.error) {
      return ErrorView(
          message: controller.error ?? '作品加载失败',
          onRetry: () => controller.refresh());
    }
    final items = controller.result?.items ?? const <DiscoveryBook>[];
    if (items.isEmpty) {
      return EmptyView(
          icon: FluentIcons.book_answers,
          title: controller.channels.isEmpty
              ? '该站点暂无${controller.kind == 'rank' ? '排行榜' : '推荐栏目'}'
              : '暂无作品',
          message: '可以切换站点、栏目或查看${controller.kind == 'rank' ? '推荐' : '排行榜'}。',
          action: Button(
              onPressed: () => controller.refresh(), child: const Text('重试')));
    }
    final library = AppScope.of(context).library;
    return ListView.separated(
      key: ValueKey(
          '${controller.selectedSite?.site}-${controller.selectedChannel?.key}-${controller.page}'),
      controller: _scroll,
      itemCount: items.length,
      separatorBuilder: (_, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = items[index];
        final site = controller.selectedSite;
        return DiscoveryBookCard(
          book: item,
          onPreview: item.url.isEmpty || site == null
              ? null
              : () => _preview(item, site),
          importing: _importingUrl == item.url,
          inLibrary: library.books.any((book) => book.sourceUrl == item.url),
          onImport: _importingUrl != null || item.url.isEmpty
              ? null
              : () => _import(item),
        );
      },
    );
  }
}
