import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'mobile_widgets.dart';

class MobileLoadingView extends StatelessWidget {
  const MobileLoadingView(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      liveRegion: true,
      child: const ExcludeSemantics(
        child: Center(
          child: SizedBox.square(
            dimension: 28,
            child: MiuixInfiniteProgressIndicator(),
          ),
        ),
      ),
    );
  }
}

class MobileEmptyView extends StatelessWidget {
  const MobileEmptyView({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final Widget icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding:
            EdgeInsets.fromLTRB(28, 36, 28, mobileNavigationClearance(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 58,
              height: 58,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colors.secondaryContainer,
                borderRadius: BorderRadius.circular(18),
              ),
              child: IconTheme.merge(
                data: IconThemeData(
                  size: 27,
                  color: theme.colors.onSecondaryContainer,
                ),
                child: icon,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textStyles.subtitle.copyWith(
                color: theme.colors.onBackground,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textStyles.body2.copyWith(
                color: theme.colors.onSurfaceVariantSummary,
                height: 1.55,
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 18),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
