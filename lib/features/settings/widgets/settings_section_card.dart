import 'package:fluent_ui/fluent_ui.dart';

import '../../../shared/app_surface.dart';
import '../../../shared/responsive.dart';

class SettingsSectionCard extends StatelessWidget {
  const SettingsSectionCard({
    required this.icon,
    required this.child,
    super.key,
  });

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      tone: AppSurfaceTone.elevated,
      borderRadius: usesMobileUi(context) ? 16 : 8,
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(builder: (context, constraints) {
        if (!usesMobileUi(context) && constraints.maxWidth < 500) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [AccentIcon(icon), const SizedBox(height: 12), child],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AccentIcon(icon),
            const SizedBox(width: 16),
            Expanded(child: child),
          ],
        );
      }),
    );
  }
}
