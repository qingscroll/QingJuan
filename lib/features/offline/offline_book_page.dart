import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/models/offline_cache.dart';
import 'offline_reader_route.dart';
import 'offline_reading_controller.dart';

class OfflineBookPage extends StatefulWidget {
  const OfflineBookPage(
      {required this.controller, required this.bookId, super.key});
  final OfflineReadingController controller;
  final String bookId;
  @override
  State<OfflineBookPage> createState() => _OfflineBookPageState();
}

class _OfflineBookPageState extends State<OfflineBookPage> {
  final Set<int> _selected = {};
  String _mode = 'original';
  bool _opening = false;
  @override
  void initState() {
    super.initState();
    final books = widget.controller.books
        .where((book) => book.detail.book.id == widget.bookId);
    if (books.isNotEmpty && books.first.indices('original').isEmpty) {
      _mode = 'translated';
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final books = widget.controller.books
            .where((book) => book.detail.book.id == widget.bookId);
        if (books.isEmpty) {
          return Scaffold(
              appBar: AppBar(title: const Text('离线章节')),
              body: const Center(child: Text('本机章节已清理，或当前身份已切换')));
        }
        final book = books.first;
        final indices = book.indices(_mode);
        return Scaffold(
            appBar: AppBar(title: Text(book.detail.book.title)),
            body: SafeArea(
                child: Column(children: [
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    ChoiceChip(
                        label: const Text('原文'),
                        selected: _mode == 'original',
                        onSelected: (_) => setState(() {
                              _mode = 'original';
                              _selected.clear();
                            })),
                    FilledButton(
                        onPressed: indices.isEmpty
                            ? null
                            : () => unawaited(_read(book, null)),
                        child: const Text('继续离线阅读')),
                    ChoiceChip(
                        label: const Text('译文'),
                        selected: _mode == 'translated',
                        onSelected: (_) => setState(() {
                              _mode = 'translated';
                              _selected.clear();
                            })),
                    OutlinedButton(
                        onPressed: _selected.isEmpty
                            ? null
                            : () async {
                                await widget.controller.remove(widget.bookId,
                                    indices: Set.of(_selected), mode: _mode);
                                if (mounted) setState(_selected.clear);
                              },
                        child: const Text('清理所选章节')),
                    TextButton(
                        onPressed: () =>
                            unawaited(widget.controller.remove(widget.bookId)),
                        child: const Text('清理本机整本')),
                  ])),
              if (indices.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('此模式尚未保存章节，请联网后选章保存')),
              Expanded(
                  child: ListView.builder(
                      itemCount: indices.length,
                      itemBuilder: (context, index) {
                        final number = indices[index];
                        final chapter = book.detail.chapters
                            .firstWhere((c) => c.index == number);
                        return ListTile(
                            leading: Checkbox(
                                value: _selected.contains(number),
                                onChanged: (value) => setState(() {
                                      if (value == true) {
                                        _selected.add(number);
                                      } else {
                                        _selected.remove(number);
                                      }
                                    })),
                            title: Text(chapter.title),
                            subtitle: Text('第 $number 章 · 已保存到本机'),
                            trailing: const Icon(Icons.menu_book_outlined),
                            onTap: () => _read(book, number));
                      })),
            ])));
      });

  Future<void> _read(OfflineBook book, int? index) async {
    if (_opening) return;
    _opening = true;
    final controller = widget.controller;
    final writer = controller.writerFor(book.detail);
    try {
      await writer.ready;
      if (!mounted || !writer.isCurrentContext) return;
      final chapter = writer.localPosition?.chapterIndex ??
          writer.confirmedPosition?.chapterIndex ??
          book.detail.progress.chapterIndex;
      final indices = book.indices(_mode);
      final start =
          index ?? (indices.contains(chapter) ? chapter : indices.first);
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => OfflineReaderRoute(
              controller: controller,
              book: book,
              initialChapterIndex: start,
              mode: _mode)));
      if (mounted) await controller.refresh();
    } finally {
      _opening = false;
    }
  }
}
