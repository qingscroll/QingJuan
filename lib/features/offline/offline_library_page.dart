import 'dart:async';
import 'package:flutter/material.dart';
import '../reader/reader_progress_notice.dart';
import 'offline_book_page.dart';
import 'offline_reading_controller.dart';

String offlineSize(int value) =>
    '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';

class OfflineLibraryPage extends StatelessWidget {
  const OfflineLibraryPage({required this.controller, super.key});
  final OfflineReadingController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
          appBar: AppBar(title: const Text('离线书库'), actions: [
            IconButton(
                tooltip: '刷新离线书库',
                onPressed: () => unawaited(controller.refresh()),
                icon: const Icon(Icons.refresh))
          ]),
          body: SafeArea(
              child: controller.identity == null
                  ? const Center(child: Text('当前离线身份已退出，请返回并重新登录'))
                  : ListView(padding: const EdgeInsets.all(16), children: [
                      Text(controller.identity!.displayName,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                          '本机 ${offlineSize(controller.bytesUsed)} / ${offlineSize(controller.limitBytes)}'),
                      const SizedBox(height: 8),
                      const Text('这里仅显示明确保存到本机的章节。书籍内容与阅读进度仍以原后端为准。'),
                      Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                              onPressed: () => unawaited(controller.clear()),
                              child: const Text('清理本身份全部缓存'))),
                      if (controller.error != null)
                        Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(controller.error!)),
                      if (controller.online)
                        Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton(
                                onPressed: () =>
                                    unawaited(controller.replayPending()),
                                child: const Text('补交待同步进度'))),
                      for (final entry in controller.replayErrors.entries)
                        Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                                '待同步 · ${_title(entry.key)}\n${entry.value}')),
                      for (final entry
                          in controller.pendingWriters.entries) ...[
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text('待同步 · ${_title(entry.key)}')),
                        ReaderProgressNotice(
                            writer: entry.value, onUseServer: (_) async {}),
                      ],
                      if (controller.books.isEmpty)
                        const Padding(
                            padding: EdgeInsets.symmetric(vertical: 32),
                            child: Text('尚无离线章节。联网后，在书籍详情中选择“保存到本机”。')),
                      for (final book in controller.books)
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(book.detail.book.title),
                            subtitle: Text(
                                '${book.chapters.length} 份章节 · ${offlineSize(book.bytes)}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                    builder: (_) => OfflineBookPage(
                                        controller: controller,
                                        bookId: book.detail.book.id)))),
                    ]))));
  String _title(String bookId) {
    for (final book in controller.books) {
      if (book.detail.book.id == bookId) return book.detail.book.title;
    }
    return '阅读记录';
  }
}
