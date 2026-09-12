import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

class QualityControls {
  const QualityControls(this.mobile);
  final bool mobile;

  f.Widget button(String label, f.VoidCallback? action,
          {bool primary = false, f.Key? key}) =>
      mobile
          ? (primary
              ? m.FilledButton(
                  key: key, onPressed: action, child: f.Text(label))
              : m.OutlinedButton(
                  key: key, onPressed: action, child: f.Text(label)))
          : (primary
              ? f.FilledButton(
                  key: key, onPressed: action, child: f.Text(label))
              : f.Button(key: key, onPressed: action, child: f.Text(label)));

  f.Widget field(String label, f.TextEditingController controller,
      {bool readOnly = false,
      bool enabled = true,
      int minLines = 1,
      int maxLines = 1,
      f.ValueChanged<String>? onChanged,
      f.Key? key}) {
    final input = mobile
        ? m.TextField(
            key: key,
            controller: controller,
            readOnly: readOnly,
            enabled: enabled,
            minLines: minLines,
            maxLines: maxLines,
            onChanged: onChanged,
            decoration: m.InputDecoration(
                labelText: label, border: const m.OutlineInputBorder()))
        : f.InfoLabel(
            label: label,
            child: f.TextBox(
                key: key,
                controller: controller,
                readOnly: readOnly,
                enabled: enabled,
                minLines: minLines,
                maxLines: maxLines,
                onChanged: onChanged));
    return f.Padding(
        padding: const f.EdgeInsets.only(bottom: 12), child: input);
  }

  f.Widget notice(String text, {bool error = false}) => mobile
      ? m.Card(
          child: f.Padding(
              padding: const f.EdgeInsets.all(12), child: f.Text(text)))
      : f.InfoBar(
          title: f.Text(text),
          severity: error ? f.InfoBarSeverity.error : f.InfoBarSeverity.info);

  Future<bool> confirm(f.BuildContext context, String title, String content,
          {required bool Function() current,
          required f.Listenable listenable}) async =>
      (await (mobile ? m.showDialog<bool> : f.showDialog<bool>)(
          context: context,
          builder: (context) => f.ListenableBuilder(
              listenable: listenable,
              builder: (context, _) {
                final valid = current();
                final actions = [
                  button('取消', () => f.Navigator.of(context).pop(false)),
                  button('确认',
                      valid ? () => f.Navigator.of(context).pop(true) : null,
                      primary: true, key: const f.ValueKey('quality-confirm')),
                ];
                final text = f.SingleChildScrollView(
                    child: f.Text(valid ? content : '账号、后端或版本已变化，请取消并重新加载。'));
                return mobile
                    ? m.AlertDialog(
                        title: f.Text(title), content: text, actions: actions)
                    : f.ContentDialog(
                        title: f.Text(title), content: text, actions: actions);
              }))) ??
      false;
}
