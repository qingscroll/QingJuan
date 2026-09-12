import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../core/models/translation_quality.dart';
import 'quality_controls.dart';
import 'translation_quality_controller.dart';

class QualityGlossary extends f.StatelessWidget {
  const QualityGlossary(
      {required this.controller, required this.ui, super.key});
  final TranslationQualityController controller;
  final QualityControls ui;

  Future<void> _edit(
          f.BuildContext context, BookGlossary glossary, int? index) =>
      (ui.mobile ? m.showDialog<void> : f.showDialog<void>)(
          context: context,
          builder: (_) => _GlossaryDialog(
              controller: controller,
              ui: ui,
              original: glossary,
              index: index));

  @override
  f.Widget build(f.BuildContext context) {
    final glossary = controller.glossary;
    if (glossary == null) return const f.SizedBox.shrink();
    return f.Column(crossAxisAlignment: f.CrossAxisAlignment.start, children: [
      const f.Text('每本小说最多 100 条术语和人名映射。保存后用于后续翻译，不会改写已有译文。'),
      const f.SizedBox(height: 12),
      ui.button(
          '添加术语或人名',
          controller.busy || glossary.entries.length >= 100
              ? null
              : () => _edit(context, glossary, null),
          primary: true,
          key: const f.ValueKey('quality-add-term')),
      if (glossary.entries.isEmpty)
        const f.Padding(
            padding: f.EdgeInsets.symmetric(vertical: 16),
            child: f.Text('尚未添加术语。')),
      for (var index = 0; index < glossary.entries.length; index++)
        f.Padding(
            padding: const f.EdgeInsets.symmetric(vertical: 10),
            child: f.Column(
                crossAxisAlignment: f.CrossAxisAlignment.start,
                children: [
                  f.Text(
                      '${glossary.entries[index].source} → ${glossary.entries[index].target}'),
                  f.Text(
                      '${glossary.entries[index].kind == 'name' ? '人名' : '术语'} · ${glossary.entries[index].note}'),
                  f.Wrap(spacing: 8, runSpacing: 8, children: [
                    ui.button(
                        '编辑',
                        controller.busy
                            ? null
                            : () => _edit(context, glossary, index)),
                    ui.button(
                        '移除',
                        controller.busy
                            ? null
                            : () => controller.saveGlossary([
                                  for (var item = 0;
                                      item < glossary.entries.length;
                                      item++)
                                    if (item != index) glossary.entries[item]
                                ])),
                  ]),
                ])),
    ]);
  }
}

class _GlossaryDialog extends f.StatefulWidget {
  const _GlossaryDialog(
      {required this.controller,
      required this.ui,
      required this.original,
      this.index});
  final TranslationQualityController controller;
  final QualityControls ui;
  final BookGlossary original;
  final int? index;
  @override
  f.State<_GlossaryDialog> createState() => _GlossaryDialogState();
}

class _GlossaryDialogState extends f.State<_GlossaryDialog> {
  late final _source = f.TextEditingController(text: _entry?.source ?? '');
  late final _target = f.TextEditingController(text: _entry?.target ?? '');
  late final _note = f.TextEditingController(text: _entry?.note ?? '');
  late String _kind = _entry?.kind ?? 'term';
  String? _validation;
  GlossaryEntry? get _entry =>
      widget.index == null ? null : widget.original.entries[widget.index!];
  bool get _current =>
      widget.controller.usable &&
      identical(widget.controller.glossary, widget.original);

  Future<void> _save() async {
    if (!_current || widget.controller.busy) return;
    if (_source.text.trim().isEmpty ||
        _target.text.trim().isEmpty ||
        _source.text.runes.length > 100 ||
        _target.text.runes.length > 100 ||
        _note.text.runes.length > 200) {
      setState(() => _validation = '原文和译名各需 1–100 字符，备注最多 200 字符。');
      return;
    }
    final entries = [...widget.original.entries];
    final entry = GlossaryEntry(
        source: _source.text.trim(),
        target: _target.text.trim(),
        kind: _kind,
        note: _note.text.trim());
    if (widget.index == null) {
      entries.add(entry);
    } else {
      entries[widget.index!] = entry;
    }
    await widget.controller.saveGlossary(entries);
    if (mounted &&
        widget.controller.usable &&
        widget.controller.error == null) {
      f.Navigator.of(context).pop();
    }
  }

  @override
  f.Widget build(f.BuildContext context) => f.ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final enabled = _current && !widget.controller.busy;
        final content = f.SingleChildScrollView(
            child: _current
                ? f.Column(
                    mainAxisSize: f.MainAxisSize.min,
                    crossAxisAlignment: f.CrossAxisAlignment.start,
                    children: [
                        widget.ui.field('原文', _source,
                            enabled: enabled,
                            key: const f.ValueKey('quality-term-source')),
                        widget.ui.field('统一译名', _target,
                            enabled: enabled,
                            key: const f.ValueKey('quality-term-target')),
                        widget.ui.field('备注（可选）', _note, enabled: enabled),
                        f.Wrap(spacing: 8, runSpacing: 8, children: [
                          widget.ui.button(
                              _kind == 'term' ? '✓ 术语' : '术语',
                              enabled
                                  ? () => setState(() => _kind = 'term')
                                  : null),
                          widget.ui.button(
                              _kind == 'name' ? '✓ 人名' : '人名',
                              enabled
                                  ? () => setState(() => _kind = 'name')
                                  : null),
                        ]),
                        if (_validation ?? widget.controller.error
                            case final error?)
                          widget.ui.notice(error, error: true),
                      ])
                : const f.Text('账号、后端或术语表已变化，请关闭后重新打开。'));
        final actions = [
          widget.ui.button(
              '取消',
              widget.controller.busy
                  ? null
                  : () => f.Navigator.of(context).pop()),
          widget.ui.button('保存术语', enabled ? _save : null, primary: true),
        ];
        return f.PopScope(
            canPop: !widget.controller.busy,
            child: widget.ui.mobile
                ? m.AlertDialog(
                    title: const f.Text('术语与人名映射'),
                    content: content,
                    actions: actions)
                : f.ContentDialog(
                    title: const f.Text('术语与人名映射'),
                    content: content,
                    actions: actions));
      });

  @override
  void dispose() {
    _source.dispose();
    _target.dispose();
    _note.dispose();
    super.dispose();
  }
}
