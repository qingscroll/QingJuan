import 'package:fluent_ui/fluent_ui.dart';

/// Matches book details: a small window-level app bar and a content heading.
class DesktopSubpage extends StatelessWidget {
  const DesktopSubpage({
    required this.title,
    required this.child,
    this.maxContentWidth = 1120,
    this.horizontalPadding = 20,
    this.showContentTitle = true,
    this.onBack,
    this.backEnabled = true,
    this.backLabel = '返回',
    this.backKey,
    super.key,
  });

  final String title;
  final Widget child;
  final double maxContentWidth;
  final double horizontalPadding;
  final bool showContentTitle;
  final VoidCallback? onBack;
  final bool backEnabled;
  final String backLabel;
  final Key? backKey;

  @override
  Widget build(BuildContext context) => NavigationView(
        appBar: NavigationAppBar(
          automaticallyImplyLeading: false,
          backgroundColor: FluentTheme.of(context).micaBackgroundColor,
          leading: Tooltip(
            message: backLabel,
            child: IconButton(
              key: backKey,
              icon: Icon(FluentIcons.back, semanticLabel: backLabel),
              onPressed: !backEnabled
                  ? null
                  : onBack ?? () => Navigator.of(context).maybePop(),
            ),
          ),
          title: Text(title,
              key: const ValueKey('desktop-subpage-navigation-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        content: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxContentWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showContentTitle)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        horizontalPadding, 28, horizontalPadding, 8),
                    child: Text(
                      title,
                      key: const ValueKey('desktop-subpage-content-title'),
                      style: FluentTheme.of(context).typography.title,
                    ),
                  ),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      );
}
