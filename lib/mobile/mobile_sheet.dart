import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'mobile_surface.dart';
import 'mobile_tokens.dart';

Future<T?> showMobileSheet<T>({
  required BuildContext context,
  required String title,
  required Widget child,
  String? subtitle,
}) {
  final colors = MiuixTheme.of(context).colors;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    sheetAnimationStyle: AnimationStyle(
      duration: MobileTokens.duration(context),
      reverseDuration: MobileTokens.duration(context, true),
    ),
    backgroundColor: Colors.transparent,
    barrierColor: colors.windowDimming,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: MobileOverlaySurface(
          isDark: MiuixTheme.of(context).brightness == Brightness.dark,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10),
                  decoration: BoxDecoration(
                    color: colors.onBackground.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(100),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              title,
                              style: MiuixTheme.of(context)
                                  .textStyles
                                  .title4
                                  .copyWith(color: colors.onBackground),
                            ),
                            if (subtitle != null) ...<Widget>[
                              const SizedBox(height: 3),
                              Text(
                                subtitle,
                                style: MiuixTheme.of(context)
                                    .textStyles
                                    .footnote1
                                    .copyWith(
                                      color: colors.onSurfaceVariantSummary,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
