import 'package:fluent_ui/fluent_ui.dart' as f;

import '../../core/models/translation_quality.dart';
import 'quality_controls.dart';
import 'translation_quality_controller.dart';

class QualityHistory extends f.StatelessWidget {
  const QualityHistory(
      {required this.controller,
      required this.ui,
      required this.restore,
      super.key});
  final TranslationQualityController controller;
  final QualityControls ui;
  final f.ValueChanged<TranslationRevision> restore;

  @override
  f.Widget build(f.BuildContext context) =>
      f.Column(crossAxisAlignment: f.CrossAxisAlignment.start, children: [
        const f.Text('保留本章最近 100 个译文版本。查看不会修改当前译文；恢复会创建一个新版本。'),
        const f.SizedBox(height: 12),
        if (controller.chapter?.history.isEmpty ?? true)
          const f.Text('本章尚无校对历史。'),
        for (final item
            in controller.chapter?.history ?? <TranslationHistoryItem>[])
          f.Padding(
              padding: const f.EdgeInsets.only(bottom: 8),
              child: ui.button(
                  '版本 ${item.revision} · ${item.kindLabel} · ${item.createdAt}',
                  controller.busy ? null : () => controller.viewHistory(item))),
        if (controller.historical case final version?) ...[
          const f.SizedBox(height: 12),
          f.Text('历史译文 · 版本 ${version.revision}'),
          const f.SizedBox(height: 8),
          f.ConstrainedBox(
              constraints: const f.BoxConstraints(maxHeight: 320),
              child: f.SingleChildScrollView(
                  child: f.SelectableText(version.text))),
          const f.SizedBox(height: 12),
          if (version.sourceHash != controller.chapter?.sourceHash)
            ui.notice('此版本对应的原文已变化，请复制需要的文字到校对草稿。'),
          ui.button(
              '恢复此版本',
              controller.busy ||
                      version.sourceHash != controller.chapter?.sourceHash
                  ? null
                  : () => restore(version),
              primary: true,
              key: const f.ValueKey('quality-restore')),
        ],
      ]);
}

class QualityUsage extends f.StatelessWidget {
  const QualityUsage({required this.records, super.key});
  final List<TranslationUsage> records;

  @override
  f.Widget build(f.BuildContext context) =>
      f.Column(crossAxisAlignment: f.CrossAxisAlignment.start, children: [
        const f.Text('当前小说最近 100 次模型请求。Token 数量取自服务商响应，未报告时留空；此处不估算金额。'),
        const f.SizedBox(height: 12),
        if (records.isEmpty) const f.Text('尚无模型用量记录。'),
        for (final record in records)
          f.Padding(
              padding: const f.EdgeInsets.only(bottom: 16),
              child: f.Column(
                  crossAxisAlignment: f.CrossAxisAlignment.start,
                  children: [
                    f.Text(
                        '第 ${record.chapterIndex} 章 · ${record.operation == 'retranslate' ? '选段重译' : '章节翻译'} · ${record.model}'),
                    f.Text(
                        '输入 ${record.inputTokens?.toString() ?? '未报告'} / 输出 ${record.outputTokens?.toString() ?? '未报告'} / 合计 ${record.totalTokens?.toString() ?? '未报告'} Token'),
                    f.Text('${switch (record.status) {
                      'completed' => '完成',
                      'cancelled' => '已取消',
                      _ => '失败'
                    }} · ${record.durationMs} 毫秒 · ${record.createdAt}'),
                  ])),
      ]);
}
