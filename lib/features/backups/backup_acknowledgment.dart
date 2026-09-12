import 'package:fluent_ui/fluent_ui.dart';

/// Keeps lengthy consent text readable under desktop text scaling.
class BackupAcknowledgment extends StatelessWidget {
  const BackupAcknowledgment({
    required this.checked,
    required this.onChanged,
    required this.label,
    required this.checkboxKey,
    super.key,
  });
  final bool checked;
  final ValueChanged<bool?>? onChanged;
  final String label;
  final Key checkboxKey;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(key: checkboxKey, checked: checked, onChanged: onChanged),
            const SizedBox(width: 8),
            Expanded(child: Text(label)),
          ],
        ),
      );
}
