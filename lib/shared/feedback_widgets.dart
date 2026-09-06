import 'package:fluent_ui/fluent_ui.dart';

import 'responsive.dart';

class LoadingView extends StatelessWidget {
  const LoadingView({this.label = '正在加载', super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    if (usesMobileUi(context)) {
      return Semantics(
        label: label,
        liveRegion: true,
        child: const ExcludeSemantics(
          child: Center(
            child: SizedBox.square(
              dimension: 28,
              child: ProgressRing(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const ProgressRing(),
            const SizedBox(height: 14),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final compact = usesMobileUi(context);
    if (!compact) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 34, color: theme.accentColor),
                const SizedBox(height: 16),
                Text(title, style: theme.typography.subtitle),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                if (action != null) ...<Widget>[
                  const SizedBox(height: 18),
                  action!,
                ],
              ],
            ),
          ),
        ),
      );
    }
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: compact ? 68 : 48,
          height: compact ? 68 : 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.accentColor.withAlpha(
              theme.brightness == Brightness.dark ? 54 : 24,
            ),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: compact ? 28 : 24,
            color: theme.accentColor,
          ),
        ),
        SizedBox(height: compact ? 22 : 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.typography.subtitle?.copyWith(
            fontSize: compact ? 20 : null,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.typography.body?.copyWith(
            height: 1.6,
            color: theme.resources.textFillColorSecondary,
          ),
        ),
        if (action != null) ...<Widget>[
          const SizedBox(height: 22),
          action!,
        ],
      ],
    );
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: compact ? 24 : 64,
          horizontal: compact ? 0 : 24,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: content,
        ),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({
    required this.message,
    required this.onRetry,
    this.additionalActions = const <Widget>[],
    super.key,
  });

  final String message;
  final VoidCallback? onRetry;
  final List<Widget> additionalActions;

  @override
  Widget build(BuildContext context) {
    return EmptyView(
      icon: FluentIcons.error,
      title: '暂时无法加载',
      message: message,
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 10,
        children: <Widget>[
          Button(onPressed: onRetry, child: const Text('重试')),
          ...additionalActions,
        ],
      ),
    );
  }
}
