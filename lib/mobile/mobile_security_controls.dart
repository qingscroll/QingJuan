import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'mobile_action_button.dart';
import 'mobile_settings_route.dart';

/// Security workflows share behavior while retaining platform-native controls.
Widget mobileSecurityAction(
  BuildContext context, {
  required bool mobile,
  Key? key,
  required Widget child,
  VoidCallback? onPressed,
  bool primary = false,
}) {
  if (mobile) {
    return primary
        ? MobileActionButton(key: key, onPressed: onPressed, child: child)
        : OutlinedButton(key: key, onPressed: onPressed, child: child);
  }
  return primary
      ? fluent.FilledButton(key: key, onPressed: onPressed, child: child)
      : fluent.Button(key: key, onPressed: onPressed, child: child);
}

Widget mobileSecurityInput(
  BuildContext context, {
  required bool mobile,
  Key? key,
  required TextEditingController controller,
  bool obscureText = false,
  bool autocorrect = true,
  bool enableSuggestions = true,
  TextInputType? keyboardType,
  int? maxLength,
  ValueChanged<String>? onSubmitted,
}) {
  if (mobile) {
    return TextField(
      key: key,
      controller: controller,
      obscureText: obscureText,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      keyboardType: keyboardType,
      maxLength: maxLength,
      onSubmitted: onSubmitted,
    );
  }
  return fluent.TextBox(
    key: key,
    controller: controller,
    obscureText: obscureText,
    autocorrect: autocorrect,
    enableSuggestions: enableSuggestions,
    keyboardType: keyboardType,
    maxLength: maxLength,
    onSubmitted: onSubmitted,
  );
}

Widget mobileSecurityNotice(BuildContext context,
    {required bool mobile,
    Key? key,
    required Text title,
    required Text content,
    fluent.InfoBarSeverity severity = fluent.InfoBarSeverity.info}) {
  if (mobile) {
    return MobileSettingsNotice(
        key: key,
        title: title.data ?? '',
        message: content.data ?? '',
        error: severity == fluent.InfoBarSeverity.error);
  }
  return fluent.InfoBar(
      key: key, title: title, content: content, severity: severity);
}
