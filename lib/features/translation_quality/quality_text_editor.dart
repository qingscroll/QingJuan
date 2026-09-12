import 'package:fluent_ui/fluent_ui.dart' as f;

import 'quality_controls.dart';
import 'translation_quality_controller.dart';

int unicodeOffset(String text, int utf16Offset) {
  if (utf16Offset < 0 || utf16Offset > text.length) throw RangeError('文本选区无效');
  if (utf16Offset > 0 &&
      utf16Offset < text.length &&
      text.codeUnitAt(utf16Offset) >= 0xdc00 &&
      text.codeUnitAt(utf16Offset) <= 0xdfff &&
      text.codeUnitAt(utf16Offset - 1) >= 0xd800 &&
      text.codeUnitAt(utf16Offset - 1) <= 0xdbff) {
    throw ArgumentError('选区不能截断字符');
  }
  return text.substring(0, utf16Offset).runes.length;
}

class QualityTextEditor extends f.StatelessWidget {
  const QualityTextEditor(
      {required this.controller,
      required this.ui,
      required this.source,
      required this.draft,
      required this.onDraftChanged,
      required this.save,
      required this.retranslate,
      required this.applySuggestion,
      required this.dirty,
      super.key});
  final TranslationQualityController controller;
  final QualityControls ui;
  final f.TextEditingController source;
  final f.TextEditingController draft;
  final f.ValueChanged<String> onDraftChanged;
  final f.VoidCallback save;
  final f.VoidCallback retranslate;
  final f.VoidCallback applySuggestion;
  final bool dirty;

  @override
  f.Widget build(f.BuildContext context) =>
      f.Column(crossAxisAlignment: f.CrossAxisAlignment.start, children: [
        const f.Text('校对在保存后生效。原文只读；也可以选择原文和对应译文范围，生成替换候选。'),
        const f.SizedBox(height: 12),
        f.LayoutBuilder(builder: (context, constraints) {
          final original = ui.field('原文（可选中）', source,
              readOnly: true,
              enabled: !controller.busy,
              minLines: 6,
              maxLines: 12,
              key: const f.ValueKey('quality-source'));
          final translated = ui.field('译文草稿', draft,
              enabled: !controller.busy,
              minLines: 6,
              maxLines: 12,
              onChanged: onDraftChanged,
              key: const f.ValueKey('quality-draft'));
          return constraints.maxWidth >= 900
              ? f.Row(
                  crossAxisAlignment: f.CrossAxisAlignment.start,
                  children: [
                      f.Expanded(child: original),
                      const f.SizedBox(width: 16),
                      f.Expanded(child: translated)
                    ])
              : f.Column(children: [original, translated]);
        }),
        f.Wrap(spacing: 8, runSpacing: 8, children: [
          ui.button(
              dirty ? '保存校对' : '已保存', controller.busy || !dirty ? null : save,
              primary: true, key: const f.ValueKey('quality-save')),
          ui.button('选段重译（调用模型）', controller.busy ? null : retranslate,
              key: const f.ValueKey('quality-retranslate')),
        ]),
        const f.SizedBox(height: 12),
        const f.Text(
            '选段重译可能产生模型费用，每次最多 4000 个原文字符，最长等待 60 秒。请求失败不会自动重试，候选译文不会自动保存。'),
        if (controller.suggestion case final suggestion?) ...[
          const f.SizedBox(height: 16),
          const f.Text('候选译文'),
          const f.SizedBox(height: 8),
          f.ConstrainedBox(
              constraints: const f.BoxConstraints(maxHeight: 280),
              child: f.SingleChildScrollView(
                  child: f.SelectableText(suggestion.text))),
          const f.SizedBox(height: 8),
          ui.button('替换所选译文到草稿', controller.busy ? null : applySuggestion,
              primary: true, key: const f.ValueKey('quality-apply-suggestion')),
        ],
      ]);
}
