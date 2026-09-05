import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_scope.dart';
import '../../core/models/task.dart';
import '../../core/state/load_state.dart';
import '../../shared/app_surface.dart';
import '../../shared/feedback_widgets.dart';
import '../../shared/page_frame.dart';
import '../../shared/responsive.dart';
import '../../shared/smooth_scroll.dart';

enum _TaskFilter { all, active, failed, completed }

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  _TaskFilter _filter = _TaskFilter.all;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context).tasks;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => PageFrame(
        title: '任务',
        subtitle: '查看下载、翻译与失败重试进度。',
        scrollable: false,
        compactHeader: ReadingPageHeader(
          title: '任务',
          subtitle: '下载与翻译进度',
          actions: <Widget>[
            Tooltip(
              message: '刷新任务',
              child: IconButton(
                icon: const Icon(
                  FluentIcons.refresh,
                  semanticLabel: '刷新任务',
                ),
                onPressed: controller.load,
              ),
            ),
          ],
        ),
        command: Tooltip(
          message: '刷新任务',
          child: IconButton(
            icon: const Icon(FluentIcons.refresh, semanticLabel: '刷新任务'),
            onPressed: controller.load,
          ),
        ),
        child: Expanded(
          child: switch (controller.state) {
            LoadState.idle ||
            LoadState.loading =>
              const LoadingView(label: '正在同步任务'),
            LoadState.error => ErrorView(
                message: controller.error ?? '未知错误',
                onRetry: controller.load,
              ),
            LoadState.empty => usesMobileUi(context)
                ? ListView(
                    children: const <Widget>[
                      FeatureHero(
                        icon: FluentIcons.processing,
                        title: '任务概览',
                        message: '下载、翻译和漫画逐页识别状态会自动同步。',
                        child: Row(
                          children: <Widget>[
                            Expanded(
                                child: AppMetric(value: '0', label: '进行中')),
                            Expanded(
                                child: AppMetric(value: '0', label: '等待中')),
                            Expanded(child: AppMetric(value: '0', label: '失败')),
                          ],
                        ),
                      ),
                      SizedBox(height: 20),
                      AppSurface(
                        tone: AppSurfaceTone.muted,
                        padding: EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 24,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            AccentIcon(FluentIcons.history, size: 46),
                            SizedBox(width: 15),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '暂无任务',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                  SizedBox(height: 6),
                                  Text('从作品详情页创建下载或翻译任务后，实时进度会显示在这里。'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : const EmptyView(
                    icon: FluentIcons.history,
                    title: '暂无任务',
                    message: '从作品详情页创建下载或翻译任务后，进度会显示在这里。',
                  ),
            _ => _TaskList(
                tasks: controller.tasks,
                filter: _filter,
                onFilterChanged: (filter) => setState(() => _filter = filter),
              ),
          },
        ),
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({
    required this.tasks,
    required this.filter,
    required this.onFilterChanged,
  });

  final List<BookTask> tasks;
  final _TaskFilter filter;
  final ValueChanged<_TaskFilter> onFilterChanged;

  @override
  Widget build(BuildContext context) {
    final filteredTasks = tasks
        .where((task) => switch (filter) {
              _TaskFilter.all => true,
              _TaskFilter.active =>
                task.status == 'queued' || task.status == 'running',
              _TaskFilter.failed => task.status == 'failed',
              _TaskFilter.completed => task.status == 'completed',
            })
        .toList(growable: false);

    int count(_TaskFilter target) => tasks
        .where((task) => switch (target) {
              _TaskFilter.all => true,
              _TaskFilter.active =>
                task.status == 'queued' || task.status == 'running',
              _TaskFilter.failed => task.status == 'failed',
              _TaskFilter.completed => task.status == 'completed',
            })
        .length;

    return QjScrollControllerBuilder(
      debugLabel: 'tasks',
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        scrollCacheExtent: const ScrollCacheExtent.pixels(360),
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _TaskSummary(
                key: const ValueKey('task-summary-all'),
                label: '全部',
                count: count(_TaskFilter.all),
                icon: FluentIcons.list,
                selected: filter == _TaskFilter.all,
                onPressed: () => onFilterChanged(_TaskFilter.all),
              ),
              _TaskSummary(
                key: const ValueKey('task-summary-active'),
                label: '进行中',
                count: count(_TaskFilter.active),
                icon: FluentIcons.sync,
                selected: filter == _TaskFilter.active,
                onPressed: () => onFilterChanged(_TaskFilter.active),
              ),
              _TaskSummary(
                key: const ValueKey('task-summary-failed'),
                label: '失败',
                count: count(_TaskFilter.failed),
                icon: FluentIcons.error_badge,
                selected: filter == _TaskFilter.failed,
                onPressed: () => onFilterChanged(_TaskFilter.failed),
              ),
              _TaskSummary(
                key: const ValueKey('task-summary-completed'),
                label: '已完成',
                count: count(_TaskFilter.completed),
                icon: FluentIcons.completed,
                selected: filter == _TaskFilter.completed,
                onPressed: () => onFilterChanged(_TaskFilter.completed),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (filteredTasks.isEmpty)
            EmptyView(
              icon: FluentIcons.filter,
              title: '该分类暂无任务',
              message: '可以选择“全部”查看其他任务。',
              action: Button(
                onPressed: () => onFilterChanged(_TaskFilter.all),
                child: const Text('查看全部'),
              ),
            )
          else
            for (final task in filteredTasks)
              _TaskTile(
                key: ValueKey('task-tile-${task.id}'),
                task: task,
              ),
        ],
      ),
    );
  }
}

class _TaskSummary extends StatelessWidget {
  const _TaskSummary({
    required this.label,
    required this.count,
    required this.icon,
    required this.selected,
    required this.onPressed,
    super.key,
  });

  final String label;
  final int count;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return SizedBox(
      width: 78,
      height: 70 + 18 * (textScale - 1).clamp(0, 1),
      child: Semantics(
        button: true,
        selected: selected,
        label: '$label，$count 个任务',
        child: AppSurface(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          tone: selected ? AppSurfaceTone.accent : AppSurfaceTone.muted,
          selected: selected,
          onPressed: onPressed,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    icon,
                    size: 15,
                    color: selected
                        ? theme.accentColor
                        : theme.resources.textFillColorSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$count',
                    style: theme.typography.bodyStrong?.copyWith(
                      color: selected ? theme.accentColor : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                style: theme.typography.caption?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : null,
                  color: selected ? theme.accentColor : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, super.key});

  final BookTask task;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final controller = AppScope.of(context).tasks;
    final failed = task.status == 'failed';
    final statusLabel = switch (task.status) {
      'queued' => '等待中',
      'running' => '进行中',
      'completed' => '已完成',
      'failed' => '失败',
      _ => task.status,
    };
    final updatedAt = _formatTimestamp(task.updatedAt);
    final pageResults = controller
        .pageResultsForTask(task.id)
        .where((result) => result.displayText.isNotEmpty)
        .toList(growable: false);
    return AppSurface(
      margin: const EdgeInsets.only(bottom: 10),
      tone: AppSurfaceTone.elevated,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AccentIcon(
            task.type == 'translate'
                ? FluentIcons.locale_language
                : FluentIcons.download,
            enabled: !failed,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  task.type == 'translate' ? '翻译任务' : '下载任务',
                  style: theme.typography.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    _TaskStatusPill(
                      statusLabel,
                      status: task.status,
                    ),
                    Text(
                      '${task.completedCount} / ${task.totalCount}',
                      style: theme.typography.caption,
                    ),
                    if (updatedAt.isNotEmpty)
                      Text(updatedAt, style: theme.typography.caption),
                    Text(
                      '尝试 ${task.attempts} 次',
                      style: theme.typography.caption,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ProgressBar(value: (task.progress * 100).clamp(0, 100)),
                const SizedBox(height: 8),
                Text(
                  task.error ?? task.message,
                  style: theme.typography.caption?.copyWith(
                    color: failed
                        ? (theme.brightness == Brightness.dark
                            ? const Color(0xFFFF99A4)
                            : const Color(0xFFC42B1C))
                        : theme.resources.textFillColorSecondary,
                    fontWeight: failed ? FontWeight.w600 : null,
                  ),
                ),
                if (pageResults.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Expander(
                    key: ValueKey('task-page-text-${task.id}'),
                    leading: const Icon(FluentIcons.text_document),
                    header: Text('逐页识别结果（${pageResults.length} 页）'),
                    initiallyExpanded: task.status == 'running',
                    contentPadding: const EdgeInsets.all(10),
                    content: SizedBox(
                      height: (pageResults.length * 96.0).clamp(80.0, 260.0),
                      child: ListView.separated(
                        reverse: true,
                        itemCount: pageResults.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, index) {
                          final result =
                              pageResults[pageResults.length - 1 - index];
                          return Semantics(
                            label: '漫画逐页识别结果',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  '${result.chapterTitle} · '
                                  '第 ${result.pageNumber}/${result.totalPages} 页',
                                  style: theme.typography.caption?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                SelectableText(
                                  result.displayText,
                                  style: theme.typography.caption?.copyWith(
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
                if (failed) ...<Widget>[
                  const SizedBox(height: 12),
                  Button(
                    onPressed: () => controller.retry(task.id),
                    child: const Text('重试'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskStatusPill extends StatelessWidget {
  const _TaskStatusPill(this.label, {required this.status});

  final String label;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final failed = status == 'failed';
    final active = status == 'running';
    final color = failed
        ? (theme.brightness == Brightness.dark
            ? const Color(0xFFFF99A4)
            : const Color(0xFFC42B1C))
        : active
            ? theme.accentColor.defaultBrushFor(theme.brightness)
            : theme.resources.textFillColorSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(theme.brightness == Brightness.dark ? 46 : 22),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.typography.caption?.copyWith(color: color),
      ),
    );
  }
}

String _formatTimestamp(String value) {
  final timestamp = DateTime.tryParse(value)?.toLocal();
  if (timestamp == null) return '';
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${twoDigits(timestamp.month)}-${twoDigits(timestamp.day)} '
      '${twoDigits(timestamp.hour)}:${twoDigits(timestamp.minute)}';
}
