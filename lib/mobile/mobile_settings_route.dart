import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// Full routes keep multi-step forms usable with the keyboard and large type.
Future<T?> showMobileSettingsPage<T>(
        {required BuildContext context,
        required String title,
        required Widget child}) =>
    Navigator.of(context).push<T>(MaterialPageRoute<T>(
        builder: (_) => MobileSettingsPage(title: title, child: child)));

class MobileSettingsPage extends StatelessWidget {
  const MobileSettingsPage(
      {required this.title,
      required this.child,
      this.canClose = true,
      this.onClose,
      super.key});
  final String title;
  final Widget child;
  final bool canClose;
  final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
          title: Text(title),
          leading: IconButton(
              tooltip: '返回',
              onPressed: canClose
                  ? (onClose ?? () => Navigator.of(context).maybePop())
                  : null,
              icon: const Icon(Icons.arrow_back_rounded)),
          backgroundColor: colors.background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0),
      body: SafeArea(
          top: false,
          child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                    child: child,
                  )))),
    );
  }
}

class MobileSettingsNotice extends StatelessWidget {
  const MobileSettingsNotice(
      {required this.title,
      required this.message,
      this.error = false,
      this.action,
      super.key});
  final String title;
  final String message;
  final bool error;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final color = error ? theme.colors.error : theme.colors.primary;
    return Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: theme.colors.surfaceContainer,
              borderRadius: BorderRadius.circular(16)),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                          error
                              ? Icons.error_outline_rounded
                              : Icons.info_outline_rounded,
                          size: 20,
                          color: color),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(title,
                              style: theme.textStyles.body2.copyWith(
                                  fontWeight: FontWeight.w600, color: color))),
                    ]),
                if (message.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(message,
                      style: theme.textStyles.footnote1.copyWith(
                          color: theme.colors.onBackgroundVariant,
                          height: 1.55))
                ],
                if (action != null) ...<Widget>[
                  const SizedBox(height: 12),
                  action!
                ],
              ]),
        ));
  }
}
