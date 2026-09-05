import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart';

class MobilePage extends StatelessWidget {
  const MobilePage({
    required this.title,
    required this.subtitle,
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
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          style: theme.textStyles.title1.copyWith(
                            color: theme.colors.onBackground,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          subtitle,
                          style: theme.textStyles.body2.copyWith(
                            color: theme.colors.onBackgroundVariant,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (actions.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 12),
                    Row(mainAxisSize: MainAxisSize.min, children: actions),
                  ],
                ],
              ),
              const SizedBox(height: 22),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
