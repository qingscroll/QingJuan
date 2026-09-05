import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// A single-line search field whose icon and hint share the input's layout.
class MobileSearchField extends StatelessWidget {
  const MobileSearchField({
    required this.controller,
    required this.hintText,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    super.key,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final colors = theme.colors;
    final style = theme.textStyles.body2.copyWith(color: colors.onBackground);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    );
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        autofocus: autofocus,
        maxLines: 1,
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        cursorColor: colors.primary,
        style: style,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          hintText: hintText,
          hintMaxLines: 1,
          hintStyle: style.copyWith(color: colors.onBackgroundVariant),
          filled: true,
          fillColor: colors.surfaceContainer,
          isDense: true,
          contentPadding: const EdgeInsetsDirectional.fromSTEB(0, 12, 18, 12),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: BorderSide(color: colors.primary.withValues(alpha: .4)),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 46, minHeight: 48),
          prefixIcon: Padding(
            padding: const EdgeInsetsDirectional.only(start: 16, end: 10),
            child: Icon(Icons.search_rounded,
                size: 20, color: colors.onBackgroundVariant),
          ),
          suffixIconConstraints:
              const BoxConstraints(minWidth: 48, minHeight: 48),
          suffixIcon: value.text.isEmpty
              ? null
              : MiuixPressable(
                  semanticLabel: '清除搜索',
                  borderRadius: BorderRadius.circular(100),
                  onPressed: () {
                    controller.clear();
                    onChanged?.call('');
                  },
                  child: Icon(Icons.cancel_outlined,
                      size: 18, color: colors.onBackgroundVariant),
                ),
        ),
      ),
    );
  }
}
