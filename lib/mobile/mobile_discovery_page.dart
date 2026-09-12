import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../core/models/book.dart';
import '../core/models/discovery.dart';
import '../core/state/load_state.dart';
import '../features/detail/book_detail_page.dart';
import '../features/preview/book_preview_page.dart';
import '../features/discovery/discovery_controller.dart';
import 'discovery/mobile_discovery_book_row.dart';
import 'discovery/mobile_discovery_filters.dart';
import 'discovery/mobile_discovery_sheets.dart';
import 'discovery/mobile_discovery_status.dart';
import 'mobile_action_button.dart';
import 'mobile_import_progress.dart';
import 'mobile_page.dart';
import 'mobile_state.dart';
import 'mobile_widgets.dart';

class MobileDiscoveryPage extends StatefulWidget {
  const MobileDiscoveryPage({super.key});

  @override
  State<MobileDiscoveryPage> createState() => _MobileDiscoveryPageState();
}

class _MobileDiscoveryPageState extends State<MobileDiscoveryPage> {
  DiscoveryController? _controller;
  String? _importingUrl;
  String? _importError;
  bool Function()? _importContextCurrent;

  String? get _activeImportingUrl =>
      _importContextCurrent?.call() == false ? null : _importingUrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = AppScope.of(context).discovery;
    if (_controller == controller) return;
    _controller = controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && controller.sitesState == LoadState.idle) {
        unawaited(controller.loadSites());
      }
    });
  }

  void _openBook(Book book) => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BookDetailPage(bookId: book.id),
        ),
      );

  Book? _existingBook(DiscoveryBook book) {
    final library = AppScope.of(context).library;
    final existing = library.books
        .where((candidate) => candidate.sourceUrl == book.url)
        .firstOrNull;
    if (existing != null) return existing;
    if (library.linkJob?.isCompleted == true &&
        library.linkJobPayload?['sourceUrl'] == book.url) {
      return library.linkJob?.book;
    }
    return null;
  }

  Future<void> _import(DiscoveryBook book, DiscoverySite site) async {
    if (book.url.trim().isEmpty) return;
    final existing = _existingBook(book);
    if (existing != null) {
      _openBook(existing);
      return;
    }
    if (_activeImportingUrl != null) return;
    final scope = AppScope.of(context);
    final library = scope.library;
    final isCurrent = scope.api.captureContextGuard();
    final generation = library.contextGeneration;
    bool contextCurrent() =>
        isCurrent() && generation == library.contextGeneration;
    bool canUpdate() => mounted && contextCurrent();
    _importContextCurrent = contextCurrent;
    if (library.hasActiveLinkJob) {
      setState(() => _importError = '已有作品正在导入，请等待当前任务完成。');
      return;
    }
    setState(() {
      _importingUrl = book.url;
      _importError = null;
    });
    try {
      await library.startLinkJob('import', book.toImportPayload(site));
      if (!canUpdate()) return;
      if (library.linkJob?.isFailed == true) {
        setState(() => _importError =
            '导入失败：${library.linkJob!.error ?? library.linkJob!.message}');
      }
    } catch (error) {
      if (canUpdate()) setState(() => _importError = '导入失败：$error');
    } finally {
      if (canUpdate()) setState(() => _importingUrl = null);
    }
  }

  Future<void> _preview(DiscoveryBook book, DiscoverySite site) async {
    await showBookPreview(context,
        payload: {...book.toImportPayload(site), 'author': book.author},
        existingBook: _existingBook(book));
  }

  Future<void> _chooseSite(DiscoveryController controller) async {
    final isCurrent = AppScope.of(context).api.captureContextGuard();
    final site = await showMobileDiscoverySites(context, controller);
    if (mounted && isCurrent() && site != null) {
      await controller.selectSite(site);
    }
  }

  Future<void> _chooseChannel(DiscoveryController controller) async {
    final isCurrent = AppScope.of(context).api.captureContextGuard();
    final selectedSite = controller.selectedSite?.site;
    final kind = controller.kind;
    final channel = await showMobileDiscoveryChannels(context, controller);
    if (mounted &&
        isCurrent() &&
        controller.selectedSite?.site == selectedSite &&
        controller.kind == kind &&
        channel != null) {
      await controller.selectChannel(channel);
    }
  }

  Future<void> _refresh(DiscoveryController controller) =>
      controller.sites.isEmpty ? controller.loadSites() : controller.refresh();

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final controller = scope.discovery;
    return AnimatedBuilder(
      animation: Listenable.merge([controller, scope.library]),
      builder: (context, _) => MobilePage(
        title: '推荐',
        actions: [
          IconButton(
            key: const ValueKey('mobile-discovery-refresh'),
            tooltip: '刷新推荐和排行',
            onPressed: controller.sitesState == LoadState.loading ||
                    controller.contentState == LoadState.loading
                ? null
                : () => _refresh(controller),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        child: RefreshIndicator(
          onRefresh: () => _refresh(controller),
          child: CustomScrollView(
            key: PageStorageKey(
                'mobile-discovery-${controller.selectedSite?.site}-${controller.kind}-${controller.selectedChannel?.key}-${controller.page}'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                  child: MobileDiscoveryFilters(
                      controller: controller,
                      onSitePressed: () => _chooseSite(controller),
                      onChannelPressed: () => _chooseChannel(controller))),
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MobileImportProgress(onOpenBook: _openBook),
                    if (_importError != null &&
                        _importContextCurrent?.call() != false)
                      MobileDiscoveryNotice(message: _importError!),
                  ],
                ),
              ),
              ..._content(controller),
              SliverToBoxAdapter(
                child: SizedBox(height: mobileNavigationClearance(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _content(DiscoveryController controller) {
    final sitesLoading = controller.sites.isEmpty &&
        (controller.sitesState == LoadState.idle ||
            controller.sitesState == LoadState.loading);
    if (sitesLoading) {
      return const [
        SliverToBoxAdapter(
          child: SizedBox(height: 220, child: MobileLoadingView('正在加载站点')),
        ),
      ];
    }
    if (controller.sites.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: MobileDiscoveryStatus(
            icon: Icons.public_off_outlined,
            title: controller.sitesError == null ? '暂无可用站点' : '站点加载失败',
            message: controller.sitesError ?? '服务暂未提供推荐和排行榜站点，请刷新后重试。',
            onRetry: controller.loadSites,
          ),
        ),
      ];
    }
    if (controller.channels.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: MobileDiscoveryStatus(
            icon: Icons.auto_stories_outlined,
            title: controller.kind == 'rank' ? '该站点暂无排行榜' : '该站点暂无推荐栏目',
            message: '可以切换上方内容类型，或选择其他站点。',
          ),
        ),
      ];
    }
    final books = controller.result?.items ?? const <DiscoveryBook>[];
    if (controller.contentState == LoadState.loading && books.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: SizedBox(height: 220, child: MobileLoadingView('正在加载作品')),
        ),
      ];
    }
    if (books.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: MobileDiscoveryStatus(
            icon: controller.error == null
                ? Icons.menu_book_outlined
                : Icons.cloud_off_outlined,
            title: controller.error == null ? '此栏目暂无作品' : '暂时无法加载作品',
            message: controller.error ?? '可以刷新内容，或选择其他栏目。',
            onRetry: controller.refresh,
          ),
        ),
        _pagination(controller),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (controller.contentState == LoadState.loading)
              const SizedBox(height: 48, child: MobileLoadingView('正在更新作品')),
            if (controller.error != null)
              MobileDiscoveryNotice(
                  message: controller.error!, onRetry: controller.refresh),
            if (controller.sitesError != null)
              MobileDiscoveryNotice(
                  message: controller.sitesError!,
                  onRetry: controller.loadSites),
            Semantics(
              liveRegion: true,
              child: Text(
                '${controller.isPageable ? '${books.length} 部作品 · 第 ${controller.page} 页' : '共 ${books.length} 部作品'}${controller.result?.cached == true ? ' · 已缓存' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
      SliverList.builder(
        itemCount: books.length,
        itemBuilder: (context, index) {
          final book = books[index];
          final site = controller.selectedSite!;
          final library = AppScope.of(context).library;
          final existing = _existingBook(book);
          final importing = _activeImportingUrl == book.url ||
              (library.hasActiveLinkJob &&
                  library.linkJobPayload?['sourceUrl'] == book.url);
          return MobileDiscoveryBookRow(
            key: ValueKey('mobile-discovery-book-${book.url}'),
            book: book,
            ranked: controller.kind == 'rank',
            existing: existing != null,
            importing: importing,
            onPreview: () => _preview(book, site),
            onImport: existing != null
                ? () => _openBook(existing)
                : book.url.trim().isEmpty ||
                        _activeImportingUrl != null ||
                        library.hasActiveLinkJob
                    ? null
                    : () => _import(book, site),
          );
        },
      ),
      _pagination(controller),
    ];
  }

  Widget _pagination(DiscoveryController controller) {
    if (!controller.isPageable) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '该栏目不支持翻页，可刷新或切换栏目',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    final lastPage = controller.result != null &&
        controller.error == null &&
        const {LoadState.ready, LoadState.empty}
            .contains(controller.contentState) &&
        !controller.hasMore;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          children: [
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                MobileActionButton(
                  key: const ValueKey('mobile-discovery-previous'),
                  tonal: true,
                  onPressed: controller.canPreviousPage
                      ? controller.previousPage
                      : null,
                  child: const Text('上一页'),
                ),
                Text('第 ${controller.page} 页'),
                MobileActionButton(
                  key: const ValueKey('mobile-discovery-next'),
                  tonal: true,
                  onPressed:
                      controller.canNextPage ? controller.nextPage : null,
                  child: const Text('下一页'),
                ),
              ],
            ),
            if (lastPage) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text('已到最后一页',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
