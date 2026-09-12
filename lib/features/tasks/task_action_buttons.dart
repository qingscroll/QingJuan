import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart' as material;

import '../../app/app_scope.dart';
import '../../core/models/task.dart';
import '../../mobile/mobile_action_button.dart';

class TaskActionButtons extends fluent.StatefulWidget {
  const TaskActionButtons({required this.task, this.mobile = false, super.key});
  final BookTask task;
  final bool mobile;

  @override
  fluent.State<TaskActionButtons> createState() => _TaskActionButtonsState();
}

class _TaskActionButtonsState extends fluent.State<TaskActionButtons> {
  String? _error;
  String? _action;

  Future<void> _control(String action) async {
    final controller = AppScope.of(context).tasks;
    final generation = controller.contextGeneration;
    setState(() {
      _error = null;
      _action = action;
    });
    try {
      if (action == 'retry') {
        await controller.retry(widget.task.id);
      } else {
        await controller.control(widget.task.id, action);
      }
    } catch (error) {
      if (mounted && generation == controller.contextGeneration) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == controller.contextGeneration) {
        setState(() => _action = null);
      }
    }
  }

  @override
  void didUpdateWidget(covariant TaskActionButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id ||
        oldWidget.task.status != widget.task.status) {
      _error = null;
    }
  }

  @override
  fluent.Widget build(fluent.BuildContext context) {
    final controlEnabled =
        AppScope.of(context).backend.capabilities['taskControl'] == true;
    final task = widget.task;
    final busy = AppScope.of(context).tasks.isControlling(task.id);
    final actions = <String, String>{
      if (controlEnabled && task.canPause) 'pause': '暂停',
      if (controlEnabled && task.canResume) 'resume': '继续',
      if (controlEnabled && task.canCancel) 'cancel': '取消任务',
      if (task.status == 'failed') 'retry': '重试任务',
    };
    return fluent.Column(
      crossAxisAlignment: fluent.CrossAxisAlignment.start,
      children: [
        fluent.Wrap(spacing: 8, runSpacing: 8, children: [
          for (final entry in actions.entries)
            if (widget.mobile && entry.key == 'retry')
              MobileActionButton(
                icon: material.Icons.refresh_rounded,
                tonal: true,
                busy: busy && _action == 'retry',
                onPressed: busy ? null : () => _control(entry.key),
                child: material.Text(
                    busy && _action == 'retry' ? '正在重试' : entry.value),
              )
            else if (widget.mobile)
              material.TextButton(
                style: material.TextButton.styleFrom(
                  minimumSize: const material.Size(64, 48),
                ),
                onPressed: busy ? null : () => _control(entry.key),
                child: material.Text(entry.value),
              )
            else
              fluent.Button(
                onPressed: busy ? null : () => _control(entry.key),
                child: fluent.Text(entry.value),
              ),
        ]),
        if (_error != null)
          fluent.Semantics(
              liveRegion: true, child: fluent.Text('任务操作失败：$_error')),
      ],
    );
  }
}
