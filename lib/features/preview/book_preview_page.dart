import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../app/app_scope.dart';
import '../../core/models/book.dart';
import '../../core/models/book_preview_chapter.dart';
import '../../shared/responsive.dart';
import '../../shared/smooth_scroll.dart';
import 'book_preview_controller.dart';
import 'preview_chapter_page.dart';
import 'preview_controls.dart';

final _openPreviewRoutes = Expando<bool>('active-book-preview');

Future<void> showBookPreview(f.BuildContext context,
    {required JsonMap payload, Book? existingBook}) async {
  final navigator = f.Navigator.of(context);
  if (_openPreviewRoutes[navigator] == true) return;
  _openPreviewRoutes[navigator] = true;
  final scope = AppScope.of(context);
  final generation = scope.library.contextGeneration;
  final apiCurrent = scope.api.captureContextGuard();
  final instance = scope.backend.instanceId;
  final identity = scope.auth.workspaceIdentity;
  final platform = UiPlatformScope.of(context);
  final page = UiPlatformScope(
      platform: platform,
      child: BookPreviewPage(
          payload: payload,
          existingBook: existingBook,
          isCurrentContext: () =>
              apiCurrent() &&
              generation == scope.library.contextGeneration &&
              instance == scope.backend.instanceId &&
              identity == scope.auth.workspaceIdentity));
  try {
    await navigator.push<void>(usesMobileUi(context)
        ? m.MaterialPageRoute(builder: (_) => page)
        : f.FluentPageRoute(builder: (_) => page));
  } finally {
    _openPreviewRoutes[navigator] = null;
  }
}

class BookPreviewPage extends f.StatefulWidget {
  const BookPreviewPage(
      {required this.payload,
      this.existingBook,
      this.isCurrentContext,
      super.key});
  final JsonMap payload;
  final Book? existingBook;
  final bool Function()? isCurrentContext;
  @override
  f.State<BookPreviewPage> createState() => _BookPreviewPageState();
}

class _BookPreviewPageState extends f.State<BookPreviewPage> {
  BookPreviewController? _controller;
  f.Listenable? _contextChanges;
  final _scroll = QjScrollController(debugLabel: 'book-preview-directory');
  bool _openingChapter = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final scope = AppScope.of(context);
    final instance = scope.backend.instanceId;
    final identity = scope.auth.workspaceIdentity;
    final controller = BookPreviewController(scope.library,
        payload: widget.payload,
        existingBook: widget.existingBook,
        supportsReading: () =>
            scope.backend.capabilities['previewReading'] == true,
        isCurrentContext: () =>
            (widget.isCurrentContext?.call() ?? true) &&
            instance == scope.backend.instanceId &&
            identity == scope.auth.workspaceIdentity);
    _controller = controller;
    _contextChanges =
        f.Listenable.merge([scope.appState, scope.backend, scope.auth]);
    _contextChanges!.addListener(controller.checkContext);
    f.WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(controller.load());
    });
  }

  Future<void> _openChapter(BookPreviewChapter chapter) async {
    final controller = _controller!;
    if (_openingChapter || !controller.canRead) {
      return;
    }
    _openingChapter = true;
    final platform = UiPlatformScope.of(context);
    final page = UiPlatformScope(
        platform: platform,
        child:
            PreviewChapterPage(controller: controller, index: chapter.index));
    try {
      await f.Navigator.of(context).push<void>(usesMobileUi(context)
          ? m.MaterialPageRoute(builder: (_) => page)
          : f.FluentPageRoute(builder: (_) => page));
    } finally {
      _openingChapter = false;
    }
  }

  f.Widget _introduction(BookPreviewController controller) {
    final preview = controller.preview;
    final title =
        preview?.title ?? widget.payload['title'] as String? ?? '作品预览';
    final author = preview?.author ?? widget.payload['author'] as String? ?? '';
    final synopsis = preview?.synopsis ?? '';
    final first = preview?.chapters.firstOrNull;
    return f.Column(crossAxisAlignment: f.CrossAxisAlignment.start, children: [
      f.Text(title, style: previewHeading(context)),
      if (author.isNotEmpty) ...[
        const f.SizedBox(height: 8),
        f.Text('作者：$author'),
      ],
      if (preview != null) ...[
        const f.SizedBox(height: 10),
        f.Text(
            '${preview.kind} · ${preview.chapterCount} 章 · ${preview.sourceStatusLabel}'),
      ],
      const f.SizedBox(height: 18),
      f.Wrap(spacing: 10, runSpacing: 10, children: [
        PreviewLibraryAction(controller: controller),
        if (first != null && controller.canRead)
          previewButton(context, '开始试读', () => _openChapter(first)),
        previewButton(context, '刷新目录',
            controller.loading ? null : () => unawaited(controller.load())),
      ]),
      const f.SizedBox(height: 12),
      const f.Text('查看与试读不会加入书架；喜欢这部作品时，再选择“加入书架”。'),
      if (!controller.canRead)
        previewMessage(context, '当前服务支持作品预览；升级后端后可直接试读章节。'),
      if (controller.added && controller.existingBook != null)
        previewMessage(context, '已加入书架，可以打开作品继续阅读。'),
      if (controller.importError case final error?)
        previewMessage(context, error, error: true),
      if (controller.error case final error?)
        previewMessage(context, error, error: true),
      if (controller.loading)
        f.Padding(
            padding: const f.EdgeInsets.symmetric(vertical: 20),
            child: previewProgress(context)),
      if (preview != null) ...[
        const f.SizedBox(height: 24),
        f.Text('作品简介', style: previewHeading(context)?.copyWith(fontSize: 20)),
        const f.SizedBox(height: 10),
        if (usesMobileUi(context))
          m.SelectableText(synopsis.trim().isEmpty ? '书源暂未提供简介。' : synopsis)
        else
          f.SelectableText(synopsis.trim().isEmpty ? '书源暂未提供简介。' : synopsis),
        const f.SizedBox(height: 28),
        f.Text('章节目录', style: previewHeading(context)?.copyWith(fontSize: 20)),
        const f.SizedBox(height: 10),
        if (preview.chapters.isEmpty) const f.Text('书源暂未提供可试读目录，可稍后刷新重试。'),
      ],
      const f.SizedBox(height: 12),
    ]);
  }

  f.Widget _chapterRow(BookPreviewChapter chapter) {
    final canRead = _controller!.canRead;
    final subtitle = !_controller!.canRead
        ? '升级后端后可试读'
        : chapter.pageCount > 0
            ? '${chapter.pageCount} 页 · 点击试读'
            : '点击试读';
    final key = f.ValueKey('preview-chapter-${chapter.index}');
    if (usesMobileUi(context)) {
      return m.ListTile(
        key: key,
        contentPadding: f.EdgeInsets.zero,
        title: f.Text('${chapter.index}. ${chapter.title}'),
        subtitle: f.Text(subtitle),
        trailing: const m.Icon(m.Icons.chevron_right),
        onTap: canRead ? () => _openChapter(chapter) : null,
      );
    }
    return f.Padding(
      padding: const f.EdgeInsets.only(bottom: 8),
      child: f.Button(
        key: key,
        onPressed: canRead ? () => _openChapter(chapter) : null,
        child: f.SizedBox(
          width: double.infinity,
          child: f.Padding(
            padding: const f.EdgeInsets.symmetric(vertical: 8),
            child: f.Column(
                crossAxisAlignment: f.CrossAxisAlignment.start,
                children: [
                  f.Text('${chapter.index}. ${chapter.title}'),
                  const f.SizedBox(height: 4),
                  f.Text(subtitle),
                ]),
          ),
        ),
      ),
    );
  }

  @override
  f.Widget build(f.BuildContext context) => f.AnimatedBuilder(
      animation: _controller!,
      builder: (context, _) {
        final controller = _controller!;
        return PreviewFrame(
          title: '作品预览',
          child: !controller.isCurrent
              ? const PreviewContextExpired()
              : f.Center(
                  child: f.ConstrainedBox(
                    constraints: const f.BoxConstraints(maxWidth: 1120),
                    child: PreviewScrollbar(
                      controller: _scroll,
                      child: f.CustomScrollView(controller: _scroll, slivers: [
                        f.SliverPadding(
                          padding:
                              f.EdgeInsets.all(usesMobileUi(context) ? 18 : 28),
                          sliver: f.SliverMainAxisGroup(slivers: [
                            f.SliverToBoxAdapter(
                                child: _introduction(controller)),
                            f.SliverList.builder(
                              itemCount:
                                  controller.preview?.chapters.length ?? 0,
                              itemBuilder: (_, index) => _chapterRow(
                                  controller.preview!.chapters[index]),
                            ),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ),
        );
      });

  @override
  void dispose() {
    _contextChanges?.removeListener(_controller!.checkContext);
    _controller?.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
