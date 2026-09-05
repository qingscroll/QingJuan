import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/models/task.dart';
import '../core/state/load_state.dart';
import '../features/tasks/tasks_controller.dart';
import 'mobile_page.dart';
import 'mobile_state.dart';
import 'mobile_widgets.dart';

class MobileTasksPage extends StatefulWidget {
  const MobileTasksPage({super.key});

  @override
  State<MobileTasksPage> createState() => _MobileTasksPageState();
}

class _MobileTasksPageState extends State<MobileTasksPage> {
  int _filter = 0;

  @override
  Widget build(BuildContext context) {
    final tasks = AppScope.of(context).tasks;
    return AnimatedBuilder(
      animation: tasks,
      builder: (context, _) {
        final filtered = tasks.tasks.where((task) => switch (_filter) {
              1 => task.status == 'running' || task.status == 'queued',
              2 => task.status == 'failed',
              3 => task.status == 'completed',
              _ => true,
            }).toList();
        return MobilePage(
          title: '任务',
          subtitle: '下载、翻译和失败重试进度。',
          actions: <Widget>[
            MiuixIconButton(
              onPressed: () => tasks.load(),
              child: MiuixIcon(
                vector: MiuixIcons.extended.byName('refresh')!,
                contentDescription: '刷新任务',
              ),
            ),
          ],
          child: Column(
            children: <Widget>[
              MobileCard(
                color: MiuixTheme.of(context).colors.tertiaryContainer,
                child: Row(
                  children: <Widget>[
                    _metric('${tasks.activeCount}', '进行中'),
                    _metric(
                      '${tasks.tasks.where((t) => t.status == 'queued').length}',
                      '等待中',
                    ),
                    _metric(
                      '${tasks.tasks.where((t) => t.status == 'failed').length}',
                      '失败',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              MiuixTabRow(
                tabs: const <String>['全部', '进行中', '失败', '已完成'],
                selectedTabIndex: _filter,
                onTabSelected: (index) => setState(() => _filter = index),
              ),
              const SizedBox(height: 14),
              Expanded(child: _buildContent(tasks, filtered)),
            ],
          ),
        );
      },
    );
  }

  Widget _metric(String value, String label) {
    final theme = MiuixTheme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(value, style: theme.textStyles.title3),
          const SizedBox(height: 3),
          Text(
            label,
            style: theme.textStyles.footnote1.copyWith(
              color: theme.colors.onSurfaceVariantSummary,
            ),
          ),
        ],
      ),
    );
  }
}