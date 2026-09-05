import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart';
import 'mobile_tokens.dart';

class MobilePage extends StatelessWidget {
  const MobilePage({
    required this.title,
    this.subtitle = '',
    required this.child,
    this.actions = const <Widget>[],
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: MobileTokens.contentWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: theme.textStyles.title1.copyWith(
                          color: theme.colors.onBackground,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  ),
                  if (actions.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 12),
                    Row(mainAxisSize: MainAxisSize.min, children: actions),
                  ],
                ],
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: theme.textStyles.footnote1.copyWith(
                    color: theme.colors.onBackgroundVariant,
                  ),
                ),
              const SizedBox(height: 12),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
