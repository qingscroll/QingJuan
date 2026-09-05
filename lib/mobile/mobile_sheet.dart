import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

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
    backgroundColor: Colors.transparent,
    barrierColor: colors.windowDimming,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
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
                    MiuixIconButton(
                      onPressed: () => Navigator.pop(context),
                      child: MiuixIcon(
                        vector: MiuixIcons.extended.byName('close')!,
                        size: 20,
                        contentDescription: '关闭',
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
