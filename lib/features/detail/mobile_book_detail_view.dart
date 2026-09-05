import 'package:fluent_ui/fluent_ui.dart';

import '../../core/models/book.dart';
import '../../shared/mobile_sheet.dart';
import '../../mobile/mobile_book_cover.dart';
import '../../mobile/mobile_action_button.dart';

/// A reading-first detail surface. All mutations remain in BookDetailPage.
class MobileBookDetailView extends StatefulWidget {
  const MobileBookDetailView({
    required this.detail,
    required this.selected,
    required this.busy,
    required this.onRead,
    required this.onListen,
    required this.onDownload,
    required this.onTranslate,
    required this.onExport,
    required this.onExportChapter,
    required this.onDelete,
    required this.onSelectionChanged,
    required this.onRefresh,
    this.exportProgress,
    super.key,
  });

  final BookDetail detail;
  final Set<int> selected;
  final bool busy;
  final double? exportProgress;
  final ValueChanged<int?> onRead;
  final VoidCallback? onListen;
  final VoidCallback onDownload;
  final VoidCallback onTranslate;
  final VoidCallback onExport;
  final ValueChanged<Chapter> onExportChapter;
  final VoidCallback onDelete;
  final ValueChanged<Set<int>> onSelectionChanged;
  final VoidCallback onRefresh;

  @override
  State<MobileBookDetailView> createState() => _MobileBookDetailViewState();
}

class _MobileBookDetailViewState extends State<MobileBookDetailView> {
  final _scroll = ScrollController();
  bool _selecting = false;
  bool _expanded = false;
  String _query = '';

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toggleChapter(int index) {
    final selection = {...widget.selected};
    if (!selection.add(index)) selection.remove(index);
    widget.onSelectionChanged(selection);
  }

  Future<void> _actions() => showMobileSheet<void>(
        context: context,
        builder: (sheetContext) => MobileSheet(
          title: widget.selected.isEmpty
              ? '作品操作'
              : '已选 ${widget.selected.length} 章',
          subtitle: widget.detail.book.title,
          onClose: () => Navigator.pop(sheetContext),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _actionRow(
                  sheetContext,
                  FluentIcons.download,
                  widget.selected.isEmpty ? '下载全部章节' : '下载所选章节',
                  '将章节内容缓存到服务端',
                  widget.onDownload,
                ),
                _actionRow(
                  sheetContext,
                  FluentIcons.locale_language,
                  widget.selected.isEmpty ? '翻译全部章节' : '翻译所选章节',
                  '使用当前服务的翻译能力',
                  widget.onTranslate,
                ),
                _actionRow(
                  sheetContext,
                  FluentIcons.share,
                  widget.selected.isEmpty ? '导出全部章节' : '导出所选章节',
                  '保存已有内容到此设备',
                  widget.onExport,
                ),
                if (!_selecting) ...[
                  _actionRow(
                    sheetContext,
                    FluentIcons.refresh,
                    '刷新作品',
                    '更新目录、下载与翻译状态',
                    widget.onRefresh,
                  ),
                  _actionRow(
                    sheetContext,
                    FluentIcons.delete,
                    '删除作品',
                    '删除章节、译文及阅读进度',
                    widget.onDelete,
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  Widget _actionRow(
    BuildContext sheetContext,
    IconData icon,
    String title,
    String subtitle,
    VoidCallback action,
  ) =>
      HyperlinkButton(
        onPressed: widget.busy
            ? null
            : () {
                Navigator.pop(sheetContext);
                action();
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: FluentTheme.of(context).typography.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _overview() {
    final detail = widget.detail;
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 88,
                height: 124,
                child: MobileBookCover(
                  title: detail.book.title,
                  cover: detail.book.cover,
                  borderRadius: 8,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.book.title,
                      style: theme.typography.subtitle?.copyWith(
                        fontSize: 22,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      detail.author?.trim().isNotEmpty == true
                          ? detail.author!
                          : '作者未提供',
                      style: theme.typography.body,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${detail.book.kind} · ${detail.book.language}',
                      style: theme.typography.caption,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${detail.chapters.length} 章${detail.totalWords > 0 ? ' · ${detail.totalWords} 字' : ''}',
                      style: theme.typography.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            detail.synopsis.trim().isEmpty ? '暂无作品简介。' : detail.synopsis,
            key: const ValueKey('book-mobile-synopsis'),
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: theme.typography.body?.copyWith(height: 1.6),
          ),
          if (detail.synopsis.trim().isNotEmpty)
            HyperlinkButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? '收起简介' : '展开简介'),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              _status(
                FluentIcons.download,
                '原文 ${detail.downloadedCount}/${detail.chapters.length} 章',
              ),
              _status(
                FluentIcons.locale_language,
                '译文 ${detail.translatedCount}/${detail.chapters.length} 章',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _status(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: FluentTheme.of(context).accentColor),
          const SizedBox(width: 6),
          Text(text, style: FluentTheme.of(context).typography.caption),
        ],
      );

  Widget _chapterHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _selecting ? '已选 ${widget.selected.length} 章' : '章节目录',
                    style: FluentTheme.of(context).typography.bodyStrong,
                  ),
                ),
                if (_selecting)
                  HyperlinkButton(
                    onPressed: () => widget.onSelectionChanged(
                      widget.selected.length == widget.detail.chapters.length
                          ? <int>{}
                          : widget.detail.chapters.map((e) => e.index).toSet(),
                    ),
                    child: Text(
                      widget.selected.length == widget.detail.chapters.length
                          ? '取消全选'
                          : '全选',
                    ),
                  ),
                HyperlinkButton(
                  onPressed: () {
                    setState(() => _selecting = !_selecting);
                    if (!_selecting) widget.onSelectionChanged(<int>{});
                  },
                  child: Text(_selecting ? '完成' : '选择'),
                ),
              ],
            ),
            if (widget.detail.chapters.length > 20)
              Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 8),
                child: TextBox(
                  placeholder: '查找章节名称或序号',
                  prefix: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(FluentIcons.search, size: 16),
                  ),
                  onChanged: (value) => setState(() => _query = value.trim()),
                ),
              ),
          ],
        ),
      );

  Widget _chapter(Chapter chapter) {
    final theme = FluentTheme.of(context);
    final selected = widget.selected.contains(chapter.index);
    final current = widget.detail.book.lastReadAt != null &&
        chapter.index == widget.detail.progress.chapterIndex;
    final status = [
      if (current) '上次读到',
      chapter.downloaded ? '原文已下载' : '待下载',
      if (chapter.translated) '已有译文',
    ].join(' · ');
    return Semantics(
      key: ValueKey('mobile-chapter-${chapter.index}'),
      button: true,
      selected: _selecting ? selected : current,
      label: '${chapter.index}，${chapter.title}，$status',
      child: HoverButton(
        onPressed: () => _selecting
            ? _toggleChapter(chapter.index)
            : widget.onRead(chapter.index),
        builder: (context, states) => Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
          decoration: BoxDecoration(
            color: selected || states.isPressed
                ? theme.resources.subtleFillColorSecondary
                : null,
            border: Border(
              bottom: BorderSide(
                color: theme.resources.dividerStrokeColorDefault,
              ),
            ),
          ),
          child: Row(
            children: [
              if (_selecting) ...[
                Icon(
                  selected
                      ? FluentIcons.checkbox_composite
                      : FluentIcons.checkbox,
                  size: 22,
                  color: theme.accentColor,
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${chapter.index}. ${chapter.title}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.body?.copyWith(
                        fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(status, style: theme.typography.caption),
                  ],
                ),
              ),
              if (!_selecting) ...[
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Tooltip(
                    message: chapter.downloaded ? '导出本章到设备' : '下载后可导出本章',
                    child: IconButton(
                      key: ValueKey<String>('chapter-export-${chapter.index}'),
                      onPressed: chapter.downloaded && !widget.busy
                          ? () => widget.onExportChapter(chapter)
                          : null,
                      icon: const Icon(
                        FluentIcons.share,
                        size: 17,
                        semanticLabel: '导出本章',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  current
                      ? FluentIcons.reading_mode
                      : FluentIcons.chevron_right,
                  size: 16,
                  color: current
                      ? theme.accentColor
                      : theme.resources.textFillColorSecondary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(bool tablet) {
    final chapters = widget.detail.chapters
        .where(
          (chapter) =>
              _query.isEmpty ||
              chapter.title.contains(_query) ||
              '${chapter.index}'.contains(_query),
        )
        .toList();
    return CustomScrollView(
      key: const PageStorageKey('mobile-book-directory'),
      controller: _scroll,
      slivers: [
        if (!tablet) SliverToBoxAdapter(child: _overview()),
        SliverToBoxAdapter(child: _chapterHeader()),
        if (chapters.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Text(_query.isEmpty ? '暂无章节，请刷新目录后重试。' : '没有匹配的章节。'),
            ),
          ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _chapter(chapters[index]),
            childCount: chapters.length,
            addAutomaticKeepAlives: false,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              key: const ValueKey('detail-mobile-header'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      icon: const Icon(FluentIcons.back, semanticLabel: '返回书库'),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '作品详情',
                      style: theme.typography.bodyStrong?.copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      icon: const Icon(
                        FluentIcons.more,
                        semanticLabel: '更多作品操作',
                      ),
                      onPressed: widget.busy ? null : _actions,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final tablet = constraints.maxWidth >= 760;
                  return tablet
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 320,
                              child: SingleChildScrollView(child: _overview()),
                            ),
                            Container(
                              width: 1,
                              color: theme.resources.dividerStrokeColorDefault,
                            ),
                            Expanded(child: _content(true)),
                          ],
                        )
                      : _content(false);
                },
              ),
            ),
            if (widget.exportProgress case final progress?) ...[
              ProgressBar(value: progress * 100),
              Text(
                '正在保存到设备 ${(progress * 100).round()}%',
                style: theme.typography.caption,
              ),
            ],
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              decoration: BoxDecoration(
                color: theme.cardColor,
                border: Border(
                  top: BorderSide(
                    color: theme.resources.dividerStrokeColorDefault,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: MobileActionButton(
                        onPressed: widget.busy || widget.detail.chapters.isEmpty
                            ? null
                            : _selecting
                                ? (widget.selected.isEmpty ? null : _actions)
                                : () => widget.onRead(null),
                        child: Text(
                          _selecting
                              ? '管理所选章节'
                              : widget.detail.book.lastReadAt != null
                                  ? '继续阅读'
                                  : '开始阅读',
                        ),
                      ),
                    ),
                  ),
                  if (!_selecting && widget.onListen != null) ...[
                    const SizedBox(width: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: MobileActionButton(
                        tonal: true,
                        onPressed: widget.onListen,
                        child: const Text('听小说'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
