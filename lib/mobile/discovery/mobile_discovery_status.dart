import 'package:flutter/material.dart';

import '../mobile_action_button.dart';

class MobileDiscoveryNotice extends StatelessWidget {
  const MobileDiscoveryNotice({required this.message, this.onRetry, super.key});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (onRetry != null)
                TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      );
}

class MobileDiscoveryStatus extends StatelessWidget {
  const MobileDiscoveryStatus(
      {required this.icon,
      required this.title,
      required this.message,
      this.onRetry,
      super.key});

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 36),
          child: Column(
            children: [
              Icon(icon,
                  size: 36,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                MobileActionButton(
                    onPressed: onRetry,
                    icon: Icons.refresh_rounded,
                    child: const Text('重试')),
              ],
            ],
          ),
        ),
      );
}
