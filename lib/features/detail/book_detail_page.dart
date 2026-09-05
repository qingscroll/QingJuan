import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../core/files/export_file_service.dart';
import '../../core/models/book.dart';
import '../../shared/app_surface.dart';
import '../../shared/feedback_widgets.dart';
import '../../shared/mobile_sheet.dart';
import '../../shared/motion.dart';
import '../../shared/page_frame.dart';
import '../../shared/responsive.dart';
import '../../shared/smooth_scroll.dart';
import '../audiobook/audiobook_page.dart';
import '../manga_translation/manga_bookshelf_import.dart';
import '../reader/reader_page.dart';
import '../reader/reader_progress.dart';
import 'mobile_book_detail_view.dart';

class BookDetailPage extends StatefulWidget {
  const BookDetailPage({
    required this.bookId,
    this.openReaderOnLoad = false,
    super.key,
  });

  final String bookId;
  final bool openReaderOnLoad;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  final ScrollController _chapterScrollController = QjScrollController(
    debugLabel: 'book-detail-chapters',
  );
  final ExportFileService _exportFiles = ExportFileService();
  late AppScope _scope;
  BookDetail? _detail;
  String? _error;
  bool _loading = true;
  bool _actionRunning = false;
  double? _exportProgress;
  bool _initialized = false;
  bool _openedReaderOnLoad = false;
  String? _deleteError;
  final Set<int> _selected = <int>{};
  final Set<int> _exportingChapters = <int>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = AppScope.of(context);
    if (!_initialized) {
      _initialized = true;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = _detail == null;
      _error = null;
      _deleteError = null;
    });
    try {
      final detail = await _scope.api.fetchBookDetail(widget.bookId);
      if (mounted) {
        setState(() => _detail = detail);
        if (widget.openReaderOnLoad &&
            !_openedReaderOnLoad &&
            detail.chapters.isNotEmpty) {
          _openedReaderOnLoad = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _openReader();
          });
        }
      }
    } catch (error) {
      if (mounted) {
        if (_detail != null && usesMobileUi(context)) {
          displayInfoBar(
            context,
            builder: (_, __) => InfoBar(
              title: const Text('未能刷新作品'),
              content: Text('$error。已保留当前目录，请检查连接后重试。'),
              severity: InfoBarSeverity.warning,
            ),
          );
        } else {
          setState(() => _error = '$error');
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enqueue(String action) async {
    final detail = _detail;
    if (detail == null) return;
    final chapters = _selected.isEmpty
        ? detail.chapters.map((chapter) => chapter.index).toList()
        : _selected.toList()
      ..sort();
    setState(() => _actionRunning = true);
    try {
      await _scope.tasks.enqueue(widget.bookId, action, chapters);
      if (mounted) {
        await displayInfoBar(
          context,
          builder: (_, __) => InfoBar(
            title: Text(action == 'download' ? '下载任务已创建' : '翻译任务已创建'),
            content: Text('共 ${chapters.length} 章，可在任务页面查看进度。'),
            severity: InfoBarSeverity.success,
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        await displayInfoBar(
          context,
          builder: (_, __) => InfoBar(
            title: const Text('任务创建失败'),
            content: Text('$error'),
            severity: InfoBarSeverity.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  bool _usesDedicatedMangaTranslation(BookDetail detail) {
    return detail.book.kind == '漫画' &&
        UiPlatformScope.of(context) == TargetPlatform.windows &&
        _scope.mangaTranslation != null;
  }

  String _translationActionLabel(BookDetail detail) {
    if (_usesDedicatedMangaTranslation(detail)) {
      return _selected.isEmpty ? '漫画翻译' : '翻译所选到工作台';
    }
    return _selected.isEmpty ? '翻译全部' : '翻译所选';
  }

  void _openDedicatedMangaTranslation(BookDetail detail) {
    final coordinator = _scope.mangaTranslation;
    if (coordinator == null) return;
    coordinator.controller.enqueueBookshelfImport(
      MangaBookshelfImportRequest.fromBook(
        detail.book,
        workspaceIdentity: _scope.auth.workspaceIdentity ?? 'local',
        chapterIndexes: _selected.isEmpty
            ? detail.chapters.map((chapter) => chapter.index)
            : _selected,
      ),
    );
    _scope.appState.selectSection(AppSection.translator);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _startTranslation(BookDetail detail) {
    if (usesMobileUi(context)) {
      final check = _scope.backend.translationModelCheck;
      if (check != null && !check.available) {
        displayInfoBar(
          context,
          builder: (_, __) => InfoBar(
            title: const Text('翻译服务暂不可用'),
            content: Text('${check.message}。请在连接设置重新检查，或联系服务管理员。'),
            severity: InfoBarSeverity.warning,
          ),
        );
        return;
      }
    }
    if (_usesDedicatedMangaTranslation(detail)) {
      _openDedicatedMangaTranslation(detail);
      return;
    }
    _enqueue('translate');
  }

  Future<void> _delete() async {
    if (_actionRunning) return;
    final Future<bool?> confirmation;
    if (usesMobileUi(context)) {
      confirmation = showMobileSheet<bool>(
        context: context,
        builder: (dialogContext) => MobileSheet(
          title: _detail == null ? '删除这本书？' : '删除《${_detail!.book.title}》？',
          onClose: () => Navigator.pop(dialogContext, false),
          actions: <Widget>[
            Button(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除'),
            ),
          ],
          child: const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 22),
            child: Text('此账号书库中的章节、翻译内容和阅读进度都将被删除，此操作无法撤销。'),
          ),
        ),
      );
    } else {
      confirmation = showDialog<bool>(
        context: context,
        builder: (context) => ContentDialog(
          title: const Text('删除这本书？'),
          content: const Text('本地章节、翻译内容和阅读进度都将被删除，此操作无法撤销。'),
          actions: <Widget>[
            Button(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
    }
    final confirmed = await confirmation;
    if (confirmed != true || !mounted) return;

    setState(() {
      _actionRunning = true;
      _deleteError = null;
    });
    try {
      await _scope.library.delete(widget.bookId);
      if (!mounted) return;
      setState(() => _actionRunning = false);
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actionRunning = false;
        _deleteError = '$error';
      });
    }
  }

  Widget _buildErrorPage() {
    final canDeleteMissingBook = _error!.contains('本地书籍目录不存在');
    final page = NavigationView(
      appBar: NavigationAppBar(
        automaticallyImplyLeading: false,
        backgroundColor: FluentTheme.of(context).micaBackgroundColor,
        leading: Tooltip(
          message: '返回',
          child: IconButton(
            icon: const Icon(FluentIcons.back, semanticLabel: '返回'),
            onPressed: () => Navigator.maybePop(context),
          ),
        ),
        title: const Text('作品详情'),
      ),
      content: Column(
        children: <Widget>[
          if (_deleteError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: InfoBar(
                title: const Text('删除失败'),
                content: Text(_deleteError!),
                severity: InfoBarSeverity.error,
                onClose: () => setState(() => _deleteError = null),
              ),
            ),
          Expanded(
            child: ErrorView(
              message: _error!,
              onRetry: _actionRunning ? null : _load,
              additionalActions: <Widget>[
                if (canDeleteMissingBook)
                  Button(
                    onPressed: _actionRunning ? null : _delete,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(FluentIcons.delete, size: 14),
                        SizedBox(width: 7),
                        Text('从书架删除'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    return _withMobileSafeArea(page);
  }

  Widget _withMobileSafeArea(Widget child) {
    if (!usesMobileUi(context)) return child;
    return ColoredBox(
      color: FluentTheme.of(context).micaBackgroundColor,
      child: SafeArea(child: child),
    );
  }

  Future<void> _openReader([int? chapterIndex]) async {
    final detail = _detail;
    if (detail == null || detail.chapters.isEmpty) return;
    final writer = ReaderProgressWriter(_scope.api, detail.book.id);
    final isCurrent = _scope.api.captureContextGuard();
    await Navigator.of(context).push<void>(
      qjPageRoute<void>(
        context: context,
        beginOffset: const Offset(0, 0.025),
        builder: (_) => ReaderPage(
          detail: detail,
          initialChapterIndex: chapterIndex ?? detail.progress.chapterIndex,
          progressWriter: writer,
        ),
      ),
    );
    // Route teardown submits the final position. Wait for that write before
    // fetching the detail again so Continue Reading cannot use stale progress.
    await writer.flush();
    writer.dispose();
    if (mounted && isCurrent()) {
      try {
        final updated = await _scope.api.fetchBookDetail(widget.bookId);
        if (mounted && isCurrent()) setState(() => _detail = updated);
        if (mounted && isCurrent()) await _scope.library.load(silent: true);
      } catch (_) {
        // Returning to the directory retains the loaded book when disconnected.
      }
    }
  }

  void _openAudiobook([int? chapterIndex]) {
    final detail = _detail;
    if (detail == null || detail.book.kind == '漫画') return;
    Navigator.of(context).push<void>(
      qjPageRoute<void>(
        context: context,
        beginOffset: const Offset(0, 0.025),
        builder: (_) => AudiobookPage(
          detail: detail,
          voice: _scope.appState.ttsVoice,
          style: _scope.appState.ttsSpeechStyle,
          onStyleChanged: _scope.appState.setTtsSpeechStyle,
          initialChapterIndex: chapterIndex ?? detail.progress.chapterIndex,
          loadChapter: (index, mode) =>
              _scope.api.fetchChapter(detail.book.id, index, mode: mode),
        ),
      ),
    );
  }

  Future<void> _exportChapter(Chapter chapter) async {
    final detail = _detail;
    if (detail == null || _exportingChapters.contains(chapter.index)) return;

    final option = await _showChapterExportFormatDialog(
      detail.book.kind,
      title: '导出本章',
    );
    if (option == null || !mounted) return;

    setState(() {
      _exportingChapters.add(chapter.index);
      _exportProgress = 0;
    });
    try {
      final saved = await _exportFiles.save<Map<String, dynamic>>(
        suggestedName: _chapterExportFileName(
          detail,
          chapter,
          option.extension,
        ),
        mimeType: option.mimeType,
        download: (targetPath) => _scope.api.exportChapter(
          bookId: widget.bookId,
          chapterIndex: chapter.index,
          format: option.format,
          targetPath: targetPath,
          onProgress: _updateExportProgress,
        ),
      );
      if (saved == null || !mounted) return;
      final result = saved.value;
      final fileCount = result['fileCount'] as int? ?? 1;
      await displayInfoBar(
        context,
        builder: (_, __) => InfoBar(
          title: const Text('章节导出完成'),
          content: Text(
            option.format == 'images'
                ? '已将 $fileCount 张图片打包保存为：${saved.fileName}'
                : '已保存为：${saved.fileName}',
          ),
          severity: InfoBarSeverity.success,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      await displayInfoBar(
        context,
        builder: (_, __) => InfoBar(
          title: const Text('章节导出失败'),
          content: Text('$error'),
          severity: InfoBarSeverity.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _exportingChapters.remove(chapter.index));
        setState(() => _exportProgress = null);
      }
    }
  }

  Future<void> _exportSelectedChapters() async {
    final detail = _detail;
    if (detail == null || _actionRunning) return;
    final chapters = _selected.isEmpty
        ? detail.chapters
        : detail.chapters
            .where((chapter) => _selected.contains(chapter.index))
            .toList();
    final unavailable =
        chapters.where((chapter) => !chapter.downloaded).toList();
    if (unavailable.isNotEmpty) {
      await displayInfoBar(
        context,
        builder: (_, __) => InfoBar(
          title: const Text('存在尚未下载的章节'),
          content: Text(
            '请先下载第 ${unavailable.map((chapter) => chapter.index).join('、')} 章。',
          ),
          severity: InfoBarSeverity.warning,
        ),
      );
      return;
    }

    final exportingAll = _selected.isEmpty;
    final option = await _showChapterExportFormatDialog(
      detail.book.kind,
      title: exportingAll ? '导出全部章节' : '导出所选章节',
    );
    if (option == null || !mounted) return;

    setState(() {
      _actionRunning = true;
      _exportProgress = 0;
    });
    try {
      final saved = await _exportFiles.save<Map<String, dynamic>>(
        suggestedName: _bookExportFileName(
          detail,
          option.extension,
          exportingAll: exportingAll,
          chapterCount: chapters.length,
        ),
        mimeType: option.mimeType,
        download: (targetPath) => _scope.api.exportBook(
          bookId: widget.bookId,
          chapterIndexes: chapters.map((chapter) => chapter.index).toList(),
          format: option.format,
          targetPath: targetPath,
          onProgress: _updateExportProgress,
        ),
      );
      if (saved == null || !mounted) return;
      final result = saved.value;
      final chapterCount = result['chapterCount'] as int? ?? chapters.length;
      final fileCount = result['fileCount'] as int? ?? 1;
      await displayInfoBar(
        context,
        builder: (_, __) => InfoBar(
          title: const Text('章节导出完成'),
          content: Text(
            option.format == 'images'
                ? '已将 $chapterCount 章、$fileCount 张图片打包保存为：${saved.fileName}'
                : '已将 $chapterCount 章保存为：${saved.fileName}',
          ),
          severity: InfoBarSeverity.success,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      await displayInfoBar(
        context,
        builder: (_, __) => InfoBar(
          title: const Text('章节导出失败'),
          content: Text('$error'),
          severity: InfoBarSeverity.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _actionRunning = false;
          _exportProgress = null;
        });
      }
    }
  }

  Future<_ChapterExportOption?> _showChapterExportFormatDialog(
    String bookKind, {
    required String title,
  }) {
    final options = bookKind == '漫画'
        ? _mangaChapterExportOptions
        : _novelChapterExportOptions;
    Widget content(BuildContext dialogContext) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('选择保存格式。优先导出已有译文或译图，否则导出原始内容。'),
            const SizedBox(height: 16),
            for (final option in options) ...<Widget>[
              SizedBox(
                width: double.infinity,
                child: Button(
                  onPressed: () => Navigator.pop(dialogContext, option),
                  child: SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(option.label),
                          const SizedBox(height: 3),
                          Text(
                            option.description,
                            style: FluentTheme.of(dialogContext)
                                .typography
                                .caption,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
        );
    if (usesMobileUi(context)) {
      return showMobileSheet<_ChapterExportOption>(
        context: context,
        builder: (dialogContext) => MobileSheet(
          title: title,
          subtitle: '优先导出已有译文或译图',
          onClose: () => Navigator.pop(dialogContext),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: content(dialogContext),
          ),
        ),
      );
    }
    return showDialog<_ChapterExportOption>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 360, maxWidth: 460),
          child: content(dialogContext),
        ),
        actions: <Widget>[
          Button(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  String _chapterExportFileName(
    BookDetail detail,
    Chapter chapter,
    String extension,
  ) {
    final rawName =
        '${detail.book.title}-${chapter.index.toString().padLeft(4, '0')}-${chapter.title}';
    final safeName = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    return '${safeName.isEmpty ? '章节' : safeName}.$extension';
  }

  String _bookExportFileName(
    BookDetail detail,
    String extension, {
    required bool exportingAll,
    required int chapterCount,
  }) {
    final scopeName = exportingAll ? '全部章节' : '所选$chapterCount章';
    final rawName = '${detail.book.title}-$scopeName';
    final safeName = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    return '${safeName.isEmpty ? '作品导出' : safeName}.$extension';
  }

  Widget _buildDesktopOverview(BookDetail detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppSurface(
          child: Flex(
            direction: Axis.horizontal,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _DesktopBookSummary(detail: detail),
              const SizedBox(width: 28),
              Expanded(child: _DesktopStats(detail: detail)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (_exportProgress case final progress?) ...<Widget>[
          ProgressBar(value: (progress * 100).clamp(0, 100)),
          const SizedBox(height: 6),
          Text(
            '正在接收导出文件 '
            '${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            FilledButton(
              onPressed: () => _openReader(),
              child: const Text('继续阅读'),
            ),
            if (detail.book.kind != '漫画' && detail.chapters.isNotEmpty)
              Button(
                onPressed: () => _openAudiobook(),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(FluentIcons.headset, size: 16),
                    SizedBox(width: 8),
                    Text('听小说'),
                  ],
                ),
              ),
            Button(
              onPressed: _actionRunning ? null : _exportSelectedChapters,
              child: Text(_selected.isEmpty ? '下载全部' : '下载所选'),
            ),
            Button(
              onPressed:
                  _actionRunning ? null : () => _startTranslation(detail),
              child: Text(_translationActionLabel(detail)),
            ),
            Button(
              onPressed: () {
                setState(() {
                  if (_selected.length == detail.chapters.length) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(detail.chapters.map((chapter) => chapter.index));
                  }
                });
              },
              child: Text(
                _selected.length == detail.chapters.length ? '取消全选' : '全选章节',
              ),
            ),
          ],
        ),
        const SizedBox(height: 30),
        SectionTitle('章节', trailing: Text('已选择 ${_selected.length} 章')),
      ],
    );
  }

  void _updateExportProgress(int receivedBytes, int totalBytes) {
    if (!mounted || totalBytes <= 0) return;
    setState(() => _exportProgress = receivedBytes / totalBytes);
  }

  @override
  void dispose() {
    _chapterScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      const loading = NavigationView(content: LoadingView(label: '正在加载作品详情'));
      return _withMobileSafeArea(loading);
    }
    if (_error != null) {
      return _buildErrorPage();
    }
    final detail = _detail!;
    if (usesMobileUi(context)) {
      return MobileBookDetailView(
        detail: detail,
        selected: _selected,
        busy: _actionRunning,
        exportProgress: _exportProgress,
        onRead: _openReader,
        onListen: detail.book.kind != '漫画' && detail.chapters.isNotEmpty
            ? () => _openAudiobook()
            : null,
        onDownload: () => _enqueue('download'),
        onTranslate: () => _startTranslation(detail),
        onExport: _exportSelectedChapters,
        onExportChapter: _exportChapter,
        onDelete: _delete,
        onRefresh: _load,
        onSelectionChanged: (selection) => setState(() {
          _selected
            ..clear()
            ..addAll(selection);
        }),
      );
    }
    final page = NavigationView(
      appBar: NavigationAppBar(
        automaticallyImplyLeading: false,
        backgroundColor: FluentTheme.of(context).micaBackgroundColor,
        leading: Tooltip(
          message: '返回',
          child: IconButton(
            icon: const Icon(FluentIcons.back, semanticLabel: '返回'),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        title: Text(detail.book.title),
      ),
      content: PageFrame(
        title: detail.book.title,
        subtitle: [
          if (detail.author?.trim().isNotEmpty == true) detail.author!,
          detail.book.kind,
          detail.book.language,
          '${detail.chapters.length} 章',
        ].join(' · '),
        command: Button(onPressed: _delete, child: const Text('删除')),
        scrollable: false,
        child: Expanded(
          child: Scrollbar(
            controller: _chapterScrollController,
            child: CustomScrollView(
              controller: _chapterScrollController,
              scrollCacheExtent: const ScrollCacheExtent.pixels(600),
              slivers: <Widget>[
                SliverToBoxAdapter(child: _buildDesktopOverview(detail)),
                SliverFixedExtentList(
                  itemExtent: 48,
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final chapter = detail.chapters[index];
                      return _ChapterRow(
                        chapter: chapter,
                        selected: _selected.contains(chapter.index),
                        exporting: _exportingChapters.contains(chapter.index),
                        onSelected: (value) => setState(() {
                          if (value) {
                            _selected.add(chapter.index);
                          } else {
                            _selected.remove(chapter.index);
                          }
                        }),
                        onOpen: () => _openReader(chapter.index),
                        onExport: chapter.downloaded
                            ? () => _exportChapter(chapter)
                            : null,
                      );
                    },
                    childCount: detail.chapters.length,
                    addAutomaticKeepAlives: false,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          ),
        ),
      ),
    );
    return _withMobileSafeArea(page);
  }
}

class _DesktopBookSummary extends StatelessWidget {
  const _DesktopBookSummary({required this.detail});

  final BookDetail detail;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Text(
        detail.synopsis.trim().isEmpty ? '暂无简介。' : detail.synopsis,
        style: FluentTheme.of(
          context,
        ).typography.bodyLarge?.copyWith(height: 1.65),
      ),
    );
  }
}

class _DesktopStats extends StatelessWidget {
  const _DesktopStats({required this.detail});

  final BookDetail detail;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 20,
      runSpacing: 12,
      children: <Widget>[
        _DesktopMetric(label: '总字数', value: '${detail.totalWords}'),
        _DesktopMetric(label: '已下载', value: '${detail.downloadedCount}'),
        _DesktopMetric(label: '已翻译', value: '${detail.translatedCount}'),
      ],
    );
  }
}

class _DesktopMetric extends StatelessWidget {
  const _DesktopMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(value, style: FluentTheme.of(context).typography.subtitle),
          const SizedBox(height: 3),
          Text(label, style: FluentTheme.of(context).typography.caption),
        ],
      ),
    );
  }
}

class _ScrollableSynopsis extends StatefulWidget {
  const _ScrollableSynopsis({required this.text, required this.maxHeight});

  final String text;
  final double maxHeight;

  @override
  State<_ScrollableSynopsis> createState() => _ScrollableSynopsisState();
}

class _ScrollableSynopsisState extends State<_ScrollableSynopsis> {
  final ScrollController _controller = QjScrollController(
    debugLabel: 'book-synopsis',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return ConstrainedBox(
      key: const ValueKey('book-synopsis-scroll'),
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          controller: _controller,
          thumbVisibility: true,
          interactive: true,
          style: const ScrollbarThemeData(
            thickness: 2,
            hoveringThickness: 4,
            crossAxisMargin: 1,
            hoveringCrossAxisMargin: 1,
          ),
          child: SingleChildScrollView(
            controller: _controller,
            primary: false,
            padding: const EdgeInsetsDirectional.only(end: 10),
            child: Text(
              widget.text,
              style: theme.typography.body?.copyWith(height: 1.55),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.chapter,
    required this.selected,
    required this.exporting,
    required this.onSelected,
    required this.onOpen,
    required this.onExport,
  });

  final Chapter chapter;
  final bool selected;
  final bool exporting;
  final ValueChanged<bool> onSelected;
  final VoidCallback onOpen;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: <Widget>[
          Checkbox(
            checked: selected,
            onChanged: (value) => onSelected(value ?? false),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: usesMobileUi(context)
                ? HoverButton(
                    onPressed: onOpen,
                    builder: (context, states) => Container(
                      alignment: AlignmentDirectional.centerStart,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: states.isPressed
                            ? FluentTheme.of(
                                context,
                              ).resources.subtleFillColorSecondary
                            : states.isHovered
                                ? FluentTheme.of(
                                    context,
                                  ).resources.subtleFillColorTertiary
                                : const Color(0x00000000),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Text(
                        '${chapter.index}. ${chapter.title}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                : Button(
                    onPressed: onOpen,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        '${chapter.index}. ${chapter.title}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 10),
          Tooltip(
            message: chapter.downloaded ? '导出本章' : '请先下载本章',
            child: IconButton(
              key: ValueKey<String>('chapter-export-${chapter.index}'),
              onPressed: exporting ? null : onExport,
              icon: exporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: ProgressRing(strokeWidth: 2),
                    )
                  : const Icon(FluentIcons.download, size: 14),
            ),
          ),
          if (chapter.translated) ...<Widget>[
            const SizedBox(width: 8),
            const Icon(FluentIcons.locale_language, size: 14),
          ],
        ],
      ),
    );
  }
}

class _ChapterExportOption {
  const _ChapterExportOption({
    required this.format,
    required this.label,
    required this.description,
    required this.extension,
  });

  final String format;
  final String label;
  final String description;
  final String extension;

  String get mimeType => switch (extension) {
        'txt' || 'text' => 'text/plain',
        'docx' =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'epub' => 'application/epub+zip',
        'pdf' => 'application/pdf',
        'zip' => 'application/zip',
        _ => 'application/octet-stream',
      };
}

const _novelChapterExportOptions = <_ChapterExportOption>[
  _ChapterExportOption(
    format: 'txt',
    label: 'TXT',
    description: '通用 UTF-8 纯文本，可重新导入青卷。',
    extension: 'txt',
  ),
  _ChapterExportOption(
    format: 'text',
    label: 'TEXT',
    description: '使用 .text 扩展名的 UTF-8 纯文本。',
    extension: 'text',
  ),
  _ChapterExportOption(
    format: 'docx',
    label: 'DOCX',
    description: 'Microsoft Word 文档，可重新导入青卷。',
    extension: 'docx',
  ),
  _ChapterExportOption(
    format: 'epub',
    label: 'EPUB',
    description: '标准电子书格式，可重新导入青卷。',
    extension: 'epub',
  ),
];

const _mangaChapterExportOptions = <_ChapterExportOption>[
  _ChapterExportOption(
    format: 'images',
    label: '图片 ZIP',
    description: '按章节建立目录并打包，页面按 001、002……顺序命名。',
    extension: 'zip',
  ),
  _ChapterExportOption(
    format: 'pdf',
    label: 'PDF',
    description: '将所选章节页面依次合并为可重新导入青卷的 PDF。',
    extension: 'pdf',
  ),
];
