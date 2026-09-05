import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

class MobilePreferenceGroup extends StatelessWidget {
  const MobilePreferenceGroup({required this.children, this.title, super.key});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(left: 3, bottom: 8),
            child: Text(
              title!,
              style: theme.textStyles.footnote1.copyWith(
                color: theme.colors.onSurfaceVariantSummary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        MiuixCard(
          cornerRadius: 20,
          colors: MiuixCardColors(
            color: theme.colors.surfaceContainer,
            contentColor: theme.colors.onSurfaceContainer,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var index = 0; index < children.length; index++) ...<Widget>[
                if (index > 0)
                  Container(
                    height: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    color: theme.colors.dividerLine,
                  ),
                children[index],
              ],
            ],
          ),
        ),
      ],
    );
  }
}
