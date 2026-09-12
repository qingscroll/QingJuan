import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/models/book.dart';
import 'offline_library_page.dart';
import 'offline_reading_controller.dart';

class OfflineSavePage extends StatefulWidget {
  const OfflineSavePage(
      {required this.controller, required this.detail, super.key});
  final OfflineReadingController controller;
  final BookDetail detail;
  @override
  State<OfflineSavePage> createState() => _OfflineSavePageState();
}

class _OfflineSavePageState extends State<OfflineSavePage> {
  final Set<int> _selected = {};
  String _mode = 'original';
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return Scaffold(
            appBar: AppBar(title: const Text('保存到本机')),
            body: SafeArea(
                child: Column(children: [
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(widget.detail.book.title,
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text(
                            '${offlineSize(controller.bytesUsed)} / ${offlineSize(controller.limitBytes)} · 选定章节的正文和全部图片保存成功后才可离线阅读'),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final mode in const ['original', 'translated'])
                            ChoiceChip(
                                label: Text(mode == 'original' ? '原文' : '译文'),
                                selected: _mode == mode,
                                onSelected: controller.downloading
                                    ? null
                                    : (_) => setState(() => _mode = mode)),
                          TextButton(
                              onPressed: controller.downloading
                                  ? null
                                  : () => setState(() {
                                        if (_selected.length ==
                                            widget.detail.chapters.length) {
                                          _selected.clear();
                                        } else {
                                          _selected.addAll(widget
                                              .detail.chapters
                                              .map((c) => c.index));
                                        }
                                      }),
                              child: const Text('全选 / 清空')),
                        ]),
                        if (controller.error != null)
                          Text(controller.error!,
                              key: const ValueKey('offline-save-error')),
                        if (controller.downloading)
                          Text(
                              '已保存 ${controller.completed} / ${controller.total} 章'),
                      ])),
              Expanded(
                  child: ListView.builder(
                      itemCount: widget.detail.chapters.length,
                      itemBuilder: (context, index) {
                        final chapter = widget.detail.chapters[index];
                        return CheckboxListTile(
                            value: _selected.contains(chapter.index),
                            title: Text(chapter.title),
                            subtitle: Text(
                                '第 ${chapter.index} 章${_mode == 'translated' && !chapter.translated ? ' · 译文尚未就绪' : ''}'),
                            onChanged: controller.downloading
                                ? null
                                : (value) => setState(() {
                                      if (value == true) {
                                        _selected.add(chapter.index);
                                      } else {
                                        _selected.remove(chapter.index);
                                      }
                                    }));
                      })),
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton(
                        onPressed: _selected.isEmpty || controller.downloading
                            ? null
                            : () => unawaited(controller.download(
                                widget.detail, Set.of(_selected), _mode)),
                        child: Text('保存所选 ${_selected.length} 章')),
                    if (controller.downloading)
                      OutlinedButton(
                          onPressed: controller.cancelDownload,
                          child: const Text('停止保存')),
                  ])),
            ])));
      });
}
