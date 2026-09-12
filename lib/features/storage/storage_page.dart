import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../app/app_scope.dart';
import '../../core/models/storage.dart';
import '../../shared/desktop_subpage.dart';
import 'storage_controller.dart';

Future<void> showBookStorage(f.BuildContext context,
        {required String bookId, bool mobile = false}) =>
    f.Navigator.of(context).push<void>(f.PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) =>
            BookStoragePage(bookId: bookId, mobile: mobile)));

class BookStoragePage extends f.StatefulWidget {
  const BookStoragePage({required this.bookId, this.mobile = false, super.key});
  final String bookId;
  final bool mobile;
  @override
  f.State<BookStoragePage> createState() => _BookStoragePageState();
}

class _BookStoragePageState extends f.State<BookStoragePage> {
  BookStorageController? _controller;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _controller = BookStorageController(AppScope.of(context).library,
        bookId: widget.bookId)
      ..addListener(_changed);
    f.WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_controller!.load());
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  f.Widget _button(String label, f.VoidCallback? action,
          {bool primary = false, String? id}) =>
      widget.mobile
          ? (primary
              ? m.FilledButton(
                  key: id == null ? null : f.ValueKey<String>(id),
                  onPressed: action,
                  child: f.Text(label))
              : m.OutlinedButton(
                  key: id == null ? null : f.ValueKey<String>(id),
                  onPressed: action,
                  child: f.Text(label)))
          : (primary
              ? f.FilledButton(
                  key: id == null ? null : f.ValueKey<String>(id),
                  onPressed: action,
                  child: f.Text(label))
              : f.Button(
                  key: id == null ? null : f.ValueKey<String>(id),
                  onPressed: action,
                  child: f.Text(label)));

  Future<void> _confirm(StorageCleanupPreview preview) async {
    final controller = _controller!;
    final confirmed =
        await (widget.mobile ? m.showDialog<bool> : f.showDialog<bool>)(
            context: context,
            builder: (context) => f.ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final valid = controller.usable &&
                      !controller.busy &&
                      identical(controller.preview, preview);
                  final content = f.SingleChildScrollView(
                      child: f.Text(valid
                          ? '将删除 ${preview.fileCount} 个导出临时文件，释放 ${formatStorageBytes(preview.totalBytes)}。\n\n已有下载链接将失效，可从原书重新导出。原文、译文、图片、笔记和阅读进度均保留。'
                          : '账号、后端或预览已变化，请取消后重新预览。'));
                  final actions = [
                    _button('取消', () => f.Navigator.of(context).pop(false)),
                    _button('确认清理',
                        valid ? () => f.Navigator.of(context).pop(true) : null,
                        primary: true, id: 'storage-confirm'),
                  ];
                  return widget.mobile
                      ? m.AlertDialog(
                          title: const f.Text('清理导出临时文件？'),
                          content: content,
                          actions: actions)
                      : f.ContentDialog(
                          title: const f.Text('清理导出临时文件？'),
                          content: content,
                          actions: actions);
                }));
    if (confirmed == true && mounted) await controller.cleanup(preview);
  }

  f.Widget _content() {
    final controller = _controller!;
    return f.ListView(
        key: const f.ValueKey('storage-scroll'),
        padding: const f.EdgeInsets.all(20),
        children: [
          if (controller.busy)
            widget.mobile
                ? const m.LinearProgressIndicator()
                : const f.ProgressBar(),
          if (controller.error case final error?)
            f.Padding(
                padding: const f.EdgeInsets.only(bottom: 12),
                child: f.Text(error, key: const f.ValueKey('storage-error'))),
          if (controller.message case final message?)
            f.Padding(
                padding: const f.EdgeInsets.only(bottom: 12),
                child:
                    f.Text(message, key: const f.ValueKey('storage-result'))),
          if (!controller.invalidated) ...[
            f.Wrap(spacing: 8, runSpacing: 8, children: [
              _button('重新统计', controller.busy ? null : controller.load,
                  id: 'storage-reload'),
              _button(
                  '预览可清理文件',
                  controller.busy || controller.report == null
                      ? null
                      : controller.inspect,
                  id: 'storage-preview'),
            ]),
            const f.SizedBox(height: 16),
            if (controller.report case final report?) ...[
              f.Text(
                  '书籍文件 ${formatStorageBytes(report.totalBytes)} · ${report.fileCount} 个文件'),
              f.Text(
                  '可清理 ${formatStorageBytes(report.reclaimableBytes)} · 保留 ${formatStorageBytes(report.protectedBytes)}'),
              const f.SizedBox(height: 12),
              const f.Text('统计此书正文、图片及导出产物的文件大小；共享数据库和其他书籍不计入本页。'),
              for (final category in report.categories)
                f.Padding(
                    padding: const f.EdgeInsets.symmetric(vertical: 10),
                    child: f.Column(
                        crossAxisAlignment: f.CrossAxisAlignment.start,
                        children: [
                          f.Text(
                              '${category.label} · ${formatStorageBytes(category.bytes)} · ${category.fileCount} 个'),
                          f.Text(category.description),
                        ])),
              for (final warning in report.warnings)
                f.Padding(
                    padding: const f.EdgeInsets.only(bottom: 8),
                    child: f.Text(warning)),
            ],
            if (controller.preview case final preview?) ...[
              const f.SizedBox(height: 16),
              f.Text(
                  '清理预览 · ${preview.fileCount} 个导出文件 · ${formatStorageBytes(preview.totalBytes)}'),
              for (final warning in preview.warnings) f.Text(warning),
              if (preview.fileCount == 0)
                const f.Text('当前没有可清理的导出文件。')
              else ...[
                const f.SizedBox(height: 8),
                f.SizedBox(
                    height: 240,
                    child: f.ListView.builder(
                        itemCount: preview.artifacts.length,
                        itemBuilder: (context, index) {
                          final item = preview.artifacts[index];
                          return f.Padding(
                              padding:
                                  const f.EdgeInsets.symmetric(vertical: 8),
                              child: f.Column(
                                  crossAxisAlignment:
                                      f.CrossAxisAlignment.start,
                                  children: [
                                    f.Text(
                                        '${item.format.toUpperCase()} · ${formatStorageBytes(item.sizeBytes)}'),
                                    f.Text(item.id),
                                    f.Text(item.createdAt),
                                  ]));
                        })),
                const f.SizedBox(height: 12),
                f.Align(
                    alignment: f.Alignment.centerLeft,
                    child: _button('清理这些导出文件',
                        controller.busy ? null : () => _confirm(preview),
                        primary: true, id: 'storage-cleanup')),
              ],
            ],
          ],
        ]);
  }

  @override
  f.Widget build(f.BuildContext context) => widget.mobile
      ? m.Scaffold(
          appBar: m.AppBar(title: const f.Text('书籍空间')), body: _content())
      : DesktopSubpage(title: '书籍空间', maxContentWidth: 1000, child: _content());

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    _controller?.dispose();
    super.dispose();
  }
}
