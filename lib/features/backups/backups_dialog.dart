import 'dart:async';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_state.dart';
import '../../core/api/api_client.dart';
import '../../core/backend/backend_connection_manager.dart';
import 'backups_controller.dart';
import 'backups_panel.dart';

class BackupsDialog extends StatefulWidget {
  const BackupsDialog({
    required this.api,
    required this.appState,
    required this.backend,
    required this.onRestored,
    super.key,
  });

  final ApiClient api;
  final AppState appState;
  final BackendConnectionManager backend;
  final Future<void> Function() onRestored;

  @override
  State<BackupsDialog> createState() => _BackupsDialogState();
}

class _BackupsDialogState extends State<BackupsDialog> {
  late final BackupsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = BackupsController(widget.api, onRestored: widget.onRestored);
    widget.appState.addListener(_updateContext);
    widget.backend.addListener(_updateContext);
    _updateContext();
  }

  void _updateContext() {
    final generation = _controller.contextGeneration;
    _controller.setContext(
      revision: widget.appState.backendConnectionRevision,
      enabled: widget.appState.localBackendSupported &&
          widget.appState.connectionMode == BackendConnectionMode.local &&
          widget.backend.status == BackendStatus.ready &&
          widget.backend.capabilities['backups'] == true,
    );
    if (generation != _controller.contextGeneration && _controller.enabled) {
      unawaited(_controller.load());
    }
  }

  @override
  void dispose() {
    widget.appState.removeListener(_updateContext);
    widget.backend.removeListener(_updateContext);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => ContentDialog(
          constraints: const BoxConstraints(maxWidth: 760),
          title: const Text('本机备份与恢复'),
          content: SizedBox(
            width: 700,
            height: math.min(620, MediaQuery.sizeOf(context).height * .62),
            child: SingleChildScrollView(
              child: BackupsPanel(controller: _controller),
            ),
          ),
          actions: [
            Button(
              onPressed:
                  _controller.busy ? null : () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
}
