import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../../core/models/link_job.dart';
import 'import_history_controls.dart';

class ImportHistoryRecordCard extends f.StatefulWidget {
  const ImportHistoryRecordCard({
    required this.job,
    required this.mobile,
    required this.retrying,
    required this.onRetry,
    required this.onOpenBook,
    super.key,
  });

  final LinkJob job;
  final bool mobile;
  final bool retrying;
  final f.VoidCallback onRetry;
  final f.VoidCallback onOpenBook;

  @override
  f.State<ImportHistoryRecordCard> createState() =>
      _ImportHistoryRecordCardState();
}

class _ImportHistoryRecordCardState extends f.State<ImportHistoryRecordCard> {
  bool _logsExpanded = false;

  @override
  f.Widget build(f.BuildContext context) {
    final job = widget.job;
    final mobile = widget.mobile;
    final secondary = importHistorySecondaryStyle(context, mobile);
    final dark = mobile
        ? m.Theme.of(context).brightness == f.Brightness.dark
        : f.FluentTheme.of(context).brightness == f.Brightness.dark;
    final accent = mobile
        ? m.Theme.of(context).colorScheme.primary
        : f.FluentTheme.of(context).accentColor.defaultBrushFor(
              f.FluentTheme.of(context).brightness,
            );
    final statusColor = job.isFailed
        ? (dark ? const f.Color(0xFFFF99A4) : const f.Color(0xFFB42318))
        : job.isCompleted
            ? (dark ? const f.Color(0xFF6CCB5F) : const f.Color(0xFF107C41))
            : accent;
    final status = switch (job.status) {
      'queued' => '等待中',
      'running' => '进行中',
      'completed' => '已完成',
      'failed' => '导入失败',
      _ => '状态未知',
    };
    final icon = job.isFailed
        ? (mobile ? m.Icons.error_outline : f.FluentIcons.error_badge)
        : job.isCompleted
            ? (mobile ? m.Icons.check_circle_outline : f.FluentIcons.completed)
            : (mobile ? m.Icons.schedule : f.FluentIcons.clock);
    final badge = f.Container(
      padding: const f.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: f.BoxDecoration(
        color: statusColor.withAlpha(dark ? 34 : 16),
        borderRadius: f.BorderRadius.circular(6),
      ),
      child: f.Row(mainAxisSize: f.MainAxisSize.min, children: [
        f.Icon(icon, size: 14, color: statusColor),
        const f.SizedBox(width: 6),
        f.Flexible(
          child: f.Text(status,
              style: f.TextStyle(color: statusColor, fontSize: 12)),
        ),
      ]),
    );
    final title = f.Text(
      job.book?.title ?? job.preview?.title ?? '链接导入',
      maxLines: 3,
      overflow: f.TextOverflow.ellipsis,
      style: (mobile
              ? m.Theme.of(context).textTheme.titleMedium
              : f.FluentTheme.of(context).typography.bodyStrong)
          ?.copyWith(fontWeight: f.FontWeight.w600, fontSize: 16),
    );
    final chapterCount = job.book?.chapterCount ?? job.preview?.chapterCount;
    final detail = [
      job.mode == 'preview' ? '作品预览' : '作品导入',
      if (chapterCount != null) '$chapterCount 章',
      if (job.book != null) job.book!.language,
      if (job.isFailed && job.progress > 0)
        '已处理 ${job.progress.clamp(0, 100).round()}%',
    ].join(' · ');
    final message = job.error?.trim().isNotEmpty == true
        ? job.error!.trim()
        : job.message.trim();
    // A completed badge already conveys generic completion messages. The full
    // server log remains available below, without repeating it in the card.
    final showMessage = message.isNotEmpty &&
        !{status, '已完成', '导入完成', '作品导入完成', '导入成功', '完成'}.contains(message);
    return ImportHistorySurface(
      mobile: mobile,
      padding: f.EdgeInsets.all(mobile ? 16 : 20),
      child: f.Column(
        crossAxisAlignment: f.CrossAxisAlignment.start,
        children: [
          f.LayoutBuilder(builder: (context, constraints) {
            final stacked = constraints.maxWidth <
                480 * f.MediaQuery.textScalerOf(context).scale(1);
            if (stacked) {
              return f.Column(
                crossAxisAlignment: f.CrossAxisAlignment.start,
                children: [badge, const f.SizedBox(height: 10), title],
              );
            }
            return f.Row(
                crossAxisAlignment: f.CrossAxisAlignment.start,
                children: [
                  f.Expanded(child: title),
                  const f.SizedBox(width: 16),
                  badge,
                ]);
          }),
          const f.SizedBox(height: 6),
          f.Text(detail, style: secondary),
          if (job.book == null &&
              job.preview == null &&
              job.sourceUrl.isNotEmpty)
            f.Text(job.sourceUrl,
                style: secondary,
                maxLines: 2,
                overflow: f.TextOverflow.ellipsis),
          if (job.isActive) ...[
            const f.SizedBox(height: 14),
            f.Semantics(
              label: '导入进度',
              value: '${job.progress.clamp(0, 100).round()}%',
              child: f.Column(
                crossAxisAlignment: f.CrossAxisAlignment.start,
                children: [
                  f.Text('${job.progress.clamp(0, 100).round()}%',
                      style: secondary),
                  const f.SizedBox(height: 6),
                  if (mobile)
                    m.LinearProgressIndicator(
                        value: job.progress.clamp(0, 100) / 100)
                  else
                    f.SizedBox(
                        width: double.infinity,
                        child:
                            f.ProgressBar(value: job.progress.clamp(0, 100))),
                ],
              ),
            ),
          ],
          if (showMessage) ...[
            const f.SizedBox(height: 12),
            f.Text(message,
                style: job.isFailed ? f.TextStyle(color: statusColor) : null),
          ],
          const f.SizedBox(height: 12),
          f.Text('更新于 ${importHistoryLocalTime(job.updatedAt)} · 本地时间',
              style: secondary),
          if (job.isFailed || job.book != null || job.logs.isNotEmpty) ...[
            const f.SizedBox(height: 12),
            f.Wrap(spacing: 8, runSpacing: 8, children: [
              if (job.isFailed)
                ImportHistoryAction(
                  label: widget.retrying ? '正在重试…' : '重试导入',
                  mobile: mobile,
                  icon: mobile ? m.Icons.refresh : f.FluentIcons.refresh,
                  onPressed: widget.retrying ? null : widget.onRetry,
                ),
              if (job.book != null)
                ImportHistoryAction(
                  label: '打开作品',
                  mobile: mobile,
                  onPressed: widget.onOpenBook,
                ),
              if (job.logs.isNotEmpty)
                ImportHistoryAction(
                  label: _logsExpanded ? '收起日志' : '查看日志 (${job.logs.length})',
                  mobile: mobile,
                  subtle: true,
                  onPressed: () =>
                      setState(() => _logsExpanded = !_logsExpanded),
                ),
            ]),
          ],
          if (_logsExpanded && job.logs.isNotEmpty) ...[
            const f.SizedBox(height: 12),
            f.Container(
              width: double.infinity,
              padding: const f.EdgeInsets.only(left: 12),
              decoration: f.BoxDecoration(
                border: f.Border(
                    left: f.BorderSide(color: accent.withAlpha(85), width: 2)),
              ),
              child: f.Column(
                crossAxisAlignment: f.CrossAxisAlignment.start,
                children: [
                  for (final log in job.logs)
                    f.Padding(
                      padding: const f.EdgeInsets.symmetric(vertical: 6),
                      child: f.Column(
                        crossAxisAlignment: f.CrossAxisAlignment.start,
                        children: [
                          f.Text(importHistoryLocalTime(log.createdAt),
                              style: secondary),
                          f.SelectableText(log.message),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
