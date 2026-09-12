import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import 'import_history_controls.dart';

class ImportHistoryForm extends f.StatelessWidget {
  const ImportHistoryForm({
    required this.mobile,
    required this.links,
    required this.kind,
    required this.language,
    required this.submitting,
    required this.onKindChanged,
    required this.onLanguageChanged,
    required this.onSubmit,
    required this.onCancel,
    super.key,
  });

  final bool mobile;
  final f.TextEditingController links;
  final String kind;
  final String language;
  final bool submitting;
  final f.ValueChanged<String> onKindChanged;
  final f.ValueChanged<String> onLanguageChanged;
  final f.VoidCallback onSubmit;
  final f.VoidCallback onCancel;

  f.Widget _selector(String label, String value, List<String> values,
      f.ValueChanged<String> changed) {
    void onChanged(String? item) {
      if (item != null) changed(item);
    }

    return f.Column(
      crossAxisAlignment: f.CrossAxisAlignment.start,
      mainAxisSize: f.MainAxisSize.min,
      children: [
        f.Text(label),
        const f.SizedBox(height: 6),
        f.Semantics(
          label: label,
          child: mobile
              ? m.DropdownButton<String>(
                  value: value,
                  items: [
                    for (final item in values)
                      m.DropdownMenuItem(value: item, child: m.Text(item)),
                  ],
                  onChanged: submitting ? null : onChanged,
                )
              : f.ComboBox<String>(
                  value: value,
                  items: [
                    for (final item in values)
                      f.ComboBoxItem(value: item, child: f.Text(item)),
                  ],
                  onChanged: submitting ? null : onChanged,
                ),
        ),
      ],
    );
  }

  @override
  f.Widget build(f.BuildContext context) => ImportHistorySurface(
        mobile: mobile,
        padding: f.EdgeInsets.all(mobile ? 16 : 20),
        child: f.Column(
          crossAxisAlignment: f.CrossAxisAlignment.start,
          children: [
            const f.Text('添加作品链接',
                style: f.TextStyle(fontWeight: f.FontWeight.w600)),
            const f.SizedBox(height: 8),
            f.Text('每行一个作品链接，最多 50 个。支持按需下载的站点先导入目录，其余站点会下载全书。',
                style: importHistorySecondaryStyle(context, mobile)),
            const f.SizedBox(height: 16),
            if (mobile)
              m.TextField(
                magnifierConfiguration: m.TextMagnifierConfiguration.disabled,
                controller: links,
                minLines: 3,
                maxLines: 6,
                enabled: !submitting,
                decoration: const m.InputDecoration(
                    labelText: '作品链接', border: m.OutlineInputBorder()),
              )
            else
              f.InfoLabel(
                label: '作品链接',
                child: f.TextBox(
                  controller: links,
                  minLines: 3,
                  maxLines: 6,
                  enabled: !submitting,
                  placeholder: '每行一个作品链接',
                ),
              ),
            const f.SizedBox(height: 16),
            f.Wrap(spacing: 24, runSpacing: 12, children: [
              _selector(
                  '作品类型', kind, const ['长小说', '轻小说', '漫画'], onKindChanged),
              _selector('作品语言', language, const ['中文', '英文', '日文'],
                  onLanguageChanged),
            ]),
            const f.SizedBox(height: 20),
            f.Wrap(spacing: 8, runSpacing: 8, children: [
              ImportHistoryAction(
                label: submitting ? '正在提交…' : '加入导入队列',
                mobile: mobile,
                primary: true,
                onPressed: submitting ? null : onSubmit,
              ),
              ImportHistoryAction(
                label: '取消',
                mobile: mobile,
                onPressed: submitting ? null : onCancel,
              ),
            ]),
          ],
        ),
      );
}
