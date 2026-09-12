import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/models/book.dart';
import '../../core/models/offline_cache.dart';
import '../reader/reader_page.dart';
import '../reader/reader_progress_writer.dart';
import 'offline_reading_controller.dart';
import 'offline_codec.dart';

class OfflineReaderRoute extends StatefulWidget {
  const OfflineReaderRoute(
      {required this.controller,
      required this.book,
      required this.initialChapterIndex,
      required this.mode,
      super.key});
  final OfflineReadingController controller;
  final OfflineBook book;
  final int initialChapterIndex;
  final String mode;
  @override
  State<OfflineReaderRoute> createState() => _OfflineReaderRouteState();
}

class _OfflineReaderRouteState extends State<OfflineReaderRoute> {
  late final ReaderProgressWriter _writer =
      widget.controller.writerFor(widget.book.detail);
  final Map<String, ImageProvider<Object>> _images = {};
  ImageProvider<Object> _image(String source) => _images.putIfAbsent(
      source, () => FileImage(File(widget.controller.localImagePath(source))));
  Future<ChapterContent> _load(String bookId, int chapterIndex,
      {String mode = 'translated', bool prefetch = false}) async {
    final content = await widget.controller
        .loadChapter(bookId, chapterIndex, mode: mode, prefetch: prefetch);
    for (final source in content.imageSources) {
      _image(source);
    }
    return content;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => _writer.isCurrentContext
          ? ReaderPage(
              detail: offlineWithProgress(
                  widget.book.detail,
                  _writer.localPosition ??
                      _writer.confirmedPosition ??
                      widget.book.detail.progress),
              initialChapterIndex: widget.initialChapterIndex,
              initialMode: widget.mode,
              chapterLoader: _load,
              progressWriter: _writer,
              imageProvider: _image)
          : Scaffold(
              appBar: AppBar(title: const Text('离线阅读')),
              body: const Center(child: Text('已退出账号或切换后端，请返回重新打开离线书库'))));
}
