import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;

import '../../core/models/book.dart';
import '../../mobile/mobile_security_controls.dart';
import '../../shared/responsive.dart';
import 'reader_progress_writer.dart';

class ReaderProgressNotice extends StatelessWidget {
  const ReaderProgressNotice(
      {required this.writer, required this.onUseServer, super.key});
  final ReaderProgressWriter writer;
  final Future<void> Function(ReadingProgress position) onUseServer;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: writer,
      builder: (context, child) {
        if (!writer.isCurrentContext) return const SizedBox.shrink();
        final remote = writer.conflict;
        final error = writer.syncError;
        if (remote == null && error == null) return const SizedBox.shrink();
        final mobile = usesMobileUi(context);
        final body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(remote == null ? '阅读进度待同步' : '阅读进度发生冲突',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(remote == null
                  ? error!
                  : '本机${_label(writer.localPosition)}；服务端${_label(remote)}。请选择要继续使用的位置。'),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 6, children: [
                if (remote == null)
                  mobileSecurityAction(context,
                      mobile: mobile,
                      key: const ValueKey('reader-progress-retry'),
                      onPressed: () => unawaited(writer.flush()),
                      child: const Text('重试同步')),
                if (remote != null) ...[
                  mobileSecurityAction(context,
                      mobile: mobile,
                      key: const ValueKey('reader-progress-keep-local'),
                      onPressed: writer.resolving || !writer.canSynchronize
                          ? null
                          : () => unawaited(writer.keepLocal()),
                      child: const Text('保留本机位置')),
                  mobileSecurityAction(context,
                      mobile: mobile,
                      key: const ValueKey('reader-progress-use-server'),
                      onPressed: writer.resolving || !writer.canSynchronize
                          ? null
                          : () => unawaited(_useServer()),
                      child: const Text('采用服务端位置')),
                ],
              ]),
            ]);
        final padded = SafeArea(
            top: false,
            child: Padding(padding: const EdgeInsets.all(12), child: body));
        return mobile
            ? material.Material(
                color: material.Theme.of(context).colorScheme.surfaceContainer,
                child: padded)
            : ColoredBox(
                color: FluentTheme.of(context).micaBackgroundColor,
                child: padded);
      });

  Future<void> _useServer() async {
    final position = await writer.useServer();
    if (position != null) await onUseServer(position);
  }

  String _label(ReadingProgress? value) => value == null
      ? '没有待提交位置'
      : '第 ${value.chapterIndex} 章${value.pageIndex == null ? '' : ' · 第 ${value.pageIndex! + 1} 页'}';
}
