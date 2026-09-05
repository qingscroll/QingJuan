import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/models/book.dart';
import 'mobile_action_button.dart';
import 'mobile_sheet.dart';

/// One truthful view of the server-owned import, shared by shelf and discovery.
/// Link imports have no cancellation API; dismissing this view keeps them alive.
class MobileImportProgress extends StatelessWidget {
  const MobileImportProgress({this.onOpenBook, super.key});

  final ValueChanged<Book>? onOpenBook;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final job = library.linkJob;
        if (job == null) return const SizedBox.shrink();
        final theme = MiuixTheme.of(context);
        final disconnected = library.linkJobConnectionError != null;
        final title = library.linkJobPayload?['title'] as String?;
        final message = disconnected
            ? '进度连接已中断，服务端任务可能仍在继续。'
            : job.isFailed
                ? job.error ?? job.message
                : job.message;
        return Semantics(
          liveRegion: true,
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            decoration: BoxDecoration(
              color: theme.colors.surfaceContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(children: <Widget>[
                  Icon(
                    disconnected
                        ? Icons.cloud_off_outlined
                        : job.isFailed
                            ? Icons.error_outline_rounded
                            : job.isCompleted
                                ? Icons.check_circle_outline_rounded
                                : Icons.downloading_outlined,
                    size: 20,
                    color: job.isFailed
                        ? theme.colors.error
                        : theme.colors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      job.isFailed
                          ? '导入未完成'
                          : job.isCompleted
                              ? '已加入书库'
                              : title?.isNotEmpty == true
                                  ? '正在导入 · $title'
                                  : '正在导入作品',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textStyles.body2.copyWith(
                        color: theme.colors.onBackground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => showMobileSheet<void>(
                      context: context,
                      title: '导入进度',
                      child: _ImportProgressDetail(onOpenBook: onOpenBook),
                    ),
                    child: const Text('查看'),
                  ),
                ]),
                if (job.isActive && !disconnected) ...<Widget>[
                  LinearProgressIndicator(
                    value: (job.progress / 100).clamp(0, 1),
                    color: theme.colors.primary,
                    backgroundColor: theme.colors.secondaryContainer,
                    minHeight: 3,
                  ),
                  const SizedBox(height: 8),
                ],
                if (message.isNotEmpty)
                  Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textStyles.footnote1.copyWith(
                      color: theme.colors.onBackgroundVariant,
                      height: 1.45,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ImportProgressDetail extends StatefulWidget {
  const _ImportProgressDetail({this.onOpenBook});
  final ValueChanged<Book>? onOpenBook;

  @override
  State<_ImportProgressDetail> createState() => _ImportProgressDetailState();
}

class _ImportProgressDetailState extends State<_ImportProgressDetail> {
  bool _retrying = false;
  bool _refreshing = false;
  String? _error;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await AppScope.of(context).library.refreshLinkJob();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _retry() async {
    final library = AppScope.of(context).library;
    final payload = library.linkJobPayload;
    if (payload == null || _retrying) return;
    setState(() {
      _retrying = true;
      _error = null;
    });
    try {
      await library.startLinkJob('import', payload);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    final theme = MiuixTheme.of(context);
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final job = library.linkJob;
        if (job == null) return const Text('没有正在处理的导入');
        final requestedTitle = library.linkJobPayload?['title'] as String?;
        final title = job.book?.title ??
            (requestedTitle?.trim().isNotEmpty == true
                ? requestedTitle!.trim()
                : '正在解析的作品');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(title, style: theme.textStyles.subtitle),
            const SizedBox(height: 12),
            if (job.isActive)
              LinearProgressIndicator(value: (job.progress / 100).clamp(0, 1)),
            const SizedBox(height: 12),
            Text(
              library.linkJobConnectionError ?? job.error ?? job.message,
              style: theme.textStyles.body2.copyWith(height: 1.55),
            ),
            if (job.isActive)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('可以返回继续使用。收起页面不会停止服务端导入；进度也可在任务页查看。',
                    style: theme.textStyles.footnote1
                        .copyWith(color: theme.colors.onBackgroundVariant)),
              ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colors.error)),
            if (job.logs.isNotEmpty) ...<Widget>[
              const SizedBox(height: 20),
              Text('最近进度', style: theme.textStyles.footnote1),
              for (final log in job.logs.reversed.take(5))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(log.message,
                      style: theme.textStyles.footnote1.copyWith(height: 1.5)),
                ),
            ],
            const SizedBox(height: 18),
            if (library.linkJobConnectionError != null) ...<Widget>[
              MobileActionButton(
                  onPressed: _refreshing ? null : _refresh,
                  busy: _refreshing,
                  tonal: true,
                  icon: Icons.refresh_rounded,
                  child: const Text('重新获取进度')),
              const SizedBox(height: 8),
            ],
            if (job.isFailed)
              MobileActionButton(
                  onPressed: _retrying ? null : _retry,
                  busy: _retrying,
                  icon: Icons.refresh_rounded,
                  child: Text(_retrying ? '正在重试' : '重新导入')),
            if (job.isCompleted &&
                job.book != null &&
                widget.onOpenBook != null)
              MobileActionButton(
                onPressed: () {
                  final book = job.book!;
                  Navigator.pop(context);
                  widget.onOpenBook!(book);
                },
                icon: Icons.auto_stories_outlined,
                child: const Text('打开作品'),
              ),
            if (!job.isActive)
              TextButton(
                  onPressed: () {
                    library.clearLinkJob();
                    Navigator.pop(context);
                  },
                  child: const Text('收起这条记录')),
          ],
        );
      },
    );
  }
}
