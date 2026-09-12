import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../app/app_scope.dart';
import '../../shared/responsive.dart';
import '../../shared/smooth_scroll.dart';
import '../reader/reader_theme.dart';
import 'book_preview_controller.dart';
import 'preview_controls.dart';

/// Read-only source content. This page never opens a bookshelf progress writer,
/// annotation controller, offline cache, or translation task.
class PreviewChapterPage extends f.StatefulWidget {
  const PreviewChapterPage(
      {required this.controller, required this.index, super.key});
  final BookPreviewController controller;
  final int index;
  @override
  f.State<PreviewChapterPage> createState() => _PreviewChapterPageState();
}

class _PreviewChapterPageState extends f.State<PreviewChapterPage> {
  final _scroll = QjScrollController(debugLabel: 'preview-chapter');
  int _chapterLoad = 0;

  @override
  void initState() {
    super.initState();
    f.WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(widget.index));
    });
  }

  Future<void> _load(int index) async {
    final operation = ++_chapterLoad;
    await widget.controller.loadChapter(index);
    if (!mounted || !widget.controller.isCurrent || operation != _chapterLoad) {
      return;
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  f.Widget _mangaImage(String url, int index) {
    final controller = widget.controller;
    return f.Padding(
      padding: const f.EdgeInsets.only(bottom: 12),
      child: f.Semantics(
        image: true,
        label: '试读漫画第 ${index + 1} 张，可双指缩放',
        child: f.InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: f.Image.network(
            url,
            key: f.ValueKey('preview-image-$index-$url'),
            headers: controller.api.headersForUrl(url),
            width: double.infinity,
            fit: f.BoxFit.contain,
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : f.SizedBox(
                    height: 320,
                    child: f.Center(child: previewProgress(context))),
            errorBuilder: (_, error, __) => f.Container(
              padding: const f.EdgeInsets.all(20),
              color: usesMobileUi(context)
                  ? m.Theme.of(context).colorScheme.surface
                  : f.FluentTheme.of(context).inactiveBackgroundColor,
              child: f.Column(mainAxisSize: f.MainAxisSize.min, children: [
                f.Text('第 ${index + 1} 张图片暂时无法读取'),
                const f.SizedBox(height: 10),
                f.Text('试读图片链接可能已过期，请检查连接后重新加载本章。',
                    style: previewCaption(context)),
                const f.SizedBox(height: 12),
                previewButton(
                    context,
                    '重新加载本章',
                    !controller.isCurrent || controller.chapterLoading
                        ? null
                        : () => unawaited(_load(controller.chapterIndex!))),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  f.Widget build(f.BuildContext context) => f.AnimatedBuilder(
        animation: f.Listenable.merge(
            [widget.controller, AppScope.of(context).appState]),
        builder: (context, _) {
          final controller = widget.controller;
          final app = AppScope.of(context).appState;
          final mobile = usesMobileUi(context);
          final paragraphStyle = (mobile
                  ? m.Theme.of(context).textTheme.bodyMedium
                  : f.FluentTheme.of(context).typography.body)
              ?.copyWith(
                  fontSize: app.readerFontSize,
                  height: app.readerLineSpacing.height);
          final content = controller.chapter;
          final index = controller.chapterIndex ?? widget.index;
          final chapters = controller.preview?.chapters ?? const [];
          final position =
              chapters.indexWhere((chapter) => chapter.index == index);
          final previous = position > 0 ? chapters[position - 1] : null;
          final next = position >= 0 && position + 1 < chapters.length
              ? chapters[position + 1]
              : null;
          final title = content?.chapter.title ??
              (position < 0 ? '第 $index 章' : chapters[position].title);
          final paragraphs = content == null
              ? const <String>[]
              : content.paragraphs.isNotEmpty
                  ? content.paragraphs
                  : content.content.trim().isEmpty
                      ? const <String>[]
                      : content.content.split('\n');
          return PreviewFrame(
            title: '试读 · $title',
            maxContentWidth: 1000,
            horizontalPadding: 32,
            child: !controller.isCurrent
                ? const PreviewContextExpired()
                : f.Center(
                    child: f.ConstrainedBox(
                      constraints: const f.BoxConstraints(maxWidth: 1000),
                      child: PreviewScrollbar(
                        controller: _scroll,
                        child: f.ListView(
                          key: const f.ValueKey('preview-chapter-content'),
                          controller: _scroll,
                          padding: f.EdgeInsets.all(mobile ? 18 : 32),
                          children: [
                            f.Text(title, style: previewHeading(context)),
                            const f.SizedBox(height: 12),
                            f.Text('原文试读 · 第 $index 章',
                                style: previewCaption(context)),
                            const f.SizedBox(height: 18),
                            f.Wrap(spacing: 10, runSpacing: 10, children: [
                              PreviewLibraryAction(controller: controller),
                              previewButton(
                                  context,
                                  '上一章',
                                  previous == null || controller.chapterLoading
                                      ? null
                                      : () => unawaited(_load(previous.index)),
                                  key: const f.ValueKey(
                                      'preview-previous-chapter')),
                              previewButton(
                                  context,
                                  '下一章',
                                  next == null || controller.chapterLoading
                                      ? null
                                      : () => unawaited(_load(next.index)),
                                  key:
                                      const f.ValueKey('preview-next-chapter')),
                              previewButton(
                                  context,
                                  '重新加载本章',
                                  controller.chapterLoading
                                      ? null
                                      : () => unawaited(_load(index)),
                                  key: const f.ValueKey(
                                      'preview-reload-chapter')),
                            ]),
                            if (controller.importError case final error?)
                              previewMessage(context, error, error: true),
                            if (controller.added &&
                                controller.existingBook != null)
                              previewMessage(context, '已加入书架，可以打开作品继续阅读。'),
                            if (controller.chapterError case final error?)
                              previewMessage(context, error, error: true),
                            const f.SizedBox(height: 28),
                            if (controller.chapterLoading)
                              f.Center(child: previewProgress(context)),
                            if (content != null) ...[
                              if (content.imageSources.isEmpty &&
                                  paragraphs.isEmpty)
                                const f.Text('书源没有返回本章正文，请重新加载或试读其他章节。'),
                              for (final paragraph in paragraphs)
                                f.Padding(
                                  padding: const f.EdgeInsets.only(bottom: 16),
                                  child: mobile
                                      ? m.SelectableText(paragraph,
                                          style: paragraphStyle)
                                      : f.SelectableText(paragraph,
                                          style: paragraphStyle),
                                ),
                              for (final (imageIndex, url)
                                  in content.imageSources.indexed)
                                _mangaImage(url, imageIndex),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
          );
        },
      );

  @override
  void dispose() {
    _chapterLoad++;
    _scroll.dispose();
    super.dispose();
  }
}
