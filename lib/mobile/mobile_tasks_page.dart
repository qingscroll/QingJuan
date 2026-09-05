import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/models/task.dart';
import '../core/state/load_state.dart';
import '../features/tasks/tasks_controller.dart';
import '../features/detail/book_detail_page.dart';
import 'mobile_import_progress.dart';
import 'mobile_action_button.dart';
import 'mobile_page.dart';
import 'mobile_sheet.dart';
import 'mobile_state.dart';
import 'mobile_widgets.dart';

class MobileTasksPage extends StatefulWidget {
  const MobileTasksPage({super.key});
  @override
  State<MobileTasksPage> createState() => _MobileTasksPageState();
}

class _MobileTasksPageState extends State<MobileTasksPage> {
  int _filter = 0;
  final Set<String> _retrying = <String>{};

  Future<void> _retry(TasksController tasks, BookTask task) async {
    if (!_retrying.add(task.id)) return;
    setState(() {});
    try {
      await tasks.retry(task.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重试失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _retrying.remove(task.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final tasks = scope.tasks;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[tasks, scope.library]),
      builder: (context, _) {
        final filtered = tasks.tasks
            .where((task) => switch (_filter) {
                  1 => task.status == 'running' || task.status == 'queued',
                  2 => task.status == 'failed',
                  3 => task.status == 'completed',
                  _ => true,
                })
            .toList();
        return MobilePage(
          title: '任务',
          actions: <Widget>[
            IconButton(
                tooltip: '刷新任务',
                onPressed: tasks.state == LoadState.loading
                    ? null
                    : () => tasks.load(silent: tasks.tasks.isNotEmpty),
                icon: const Icon(Icons.refresh_rounded)),
          ],
          child: Column(children: <Widget>[
            MobileImportProgress(
                onOpenBook: (book) => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                        builder: (_) => BookDetailPage(bookId: book.id)))),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: <Widget>[
                for (final entry
                    in const <String>['全部', '进行中', '需处理', '已完成'].indexed)
                  Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                          label: Text(entry.$2),
                          selected: _filter == entry.$1,
                          onSelected: (_) =>
                              setState(() => _filter = entry.$1))),
              ]),
            ),
            if (tasks.error != null && tasks.tasks.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(Icons.sync_problem_rounded,
                            size: 20,
                            color: MiuixTheme.of(context).colors.error),
                        const SizedBox(width: 8),
                        Expanded(child: Text('进度更新中断，以下为上次结果。${tasks.error}')),
                        TextButton(
                            onPressed: () => tasks.load(silent: true),
                            child: const Text('重连')),
                      ])),
            const SizedBox(height: 8),
            Expanded(child: _content(tasks, filtered)),
          ]),
        );
      },
    );
  }

  Widget _content(TasksController tasks, List<BookTask> filtered) {
    if (tasks.tasks.isEmpty &&
        (tasks.state == LoadState.idle || tasks.state == LoadState.loading)) {
      return const MobileLoadingView('正在加载任务');
    }
    if (tasks.tasks.isEmpty && tasks.state == LoadState.error) {
      return MobileEmptyView(
          icon: const Icon(Icons.cloud_off_outlined),
          title: '任务暂时无法更新',
          message: tasks.error ?? '请检查服务连接后重试。',
          action: MobileActionButton(
              icon: Icons.refresh_rounded,
              onPressed: () => tasks.load(),
              child: const Text('重新加载')));
    }
    if (filtered.isEmpty) {
      return MobileEmptyView(
          icon: const Icon(Icons.task_alt_outlined),
          title: tasks.tasks.isEmpty
              ? '还没有任务'
              : _filter == 2
                  ? '暂时没有需要处理的任务'
                  : '暂无此类任务',
          message: '在作品详情中下载或翻译章节后，可在这里查看进度。');
    }
    final books = AppScope.of(context).library.books;
    final titles = {for (final book in books) book.id: book.title};
    return RefreshIndicator(
      onRefresh: () => tasks.load(silent: true),
      child: ListView.separated(
        key: PageStorageKey<String>('mobile-tasks-$_filter'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: mobileNavigationClearance(context)),
        itemCount: filtered.length,
        separatorBuilder: (_, index) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final task = filtered[index];
          return _TaskRow(
              task: task,
              title: titles[task.bookId] ?? '作品任务',
              retrying: _retrying.contains(task.id),
              onRetry: () => _retry(tasks, task),
              onDetails: () => showMobileSheet<void>(
                    context: context,
                    title: titles[task.bookId] ?? '任务详情',
                    child: AnimatedBuilder(
                        animation: tasks,
                        builder: (context, _) {
                          final current = tasks.tasks
                                  .where((item) => item.id == task.id)
                                  .firstOrNull ??
                              task;
                          return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Text(
                                    '${_taskType(current.type)} · ${_taskStatus(current.status)}'),
                                const SizedBox(height: 12),
                                Text(current.totalCount > 0
                                    ? '已完成 ${current.completedCount} / ${current.totalCount} 章'
                                    : '等待服务端报告章节进度'),
                                if (current.message.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 12),
                                  SelectableText(current.message)
                                ],
                                if (current.error?.isNotEmpty ==
                                    true) ...<Widget>[
                                  const SizedBox(height: 12),
                                  SelectableText(current.error!)
                                ],
                                if (current.status == 'failed') ...<Widget>[
                                  const SizedBox(height: 12),
                                  const Text(
                                      '请先根据错误检查书源、网络或翻译服务，再重试任务；已完成的章节仍会保留。')
                                ],
                                if (current.updatedAt.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 16),
                                  Text(
                                      '更新于 ${current.updatedAt.replaceFirst('T', ' ')}')
                                ],
                              ]);
                        }),
                  ));
        },
      ),
    );
  }
}

String _taskType(String type) => switch (type) {
      'translate' => '翻译',
      'download' => '下载',
      'import' => '导入',
      _ => type.isEmpty ? '处理' : type
    };
String _taskStatus(String status) => switch (status) {
      'running' => '进行中',
      'queued' => '等待中',
      'failed' => '需要处理',
      'completed' => '已完成',
      'cancelled' => '已取消',
      _ => status
    };

class _TaskRow extends StatelessWidget {
  const _TaskRow(
      {required this.task,
      required this.title,
      required this.retrying,
      required this.onRetry,
      required this.onDetails});
  final BookTask task;
  final String title;
  final bool retrying;
  final VoidCallback onRetry;
  final VoidCallback onDetails;
  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final active = task.status == 'running' || task.status == 'queued';
    final failed = task.status == 'failed';
    final statusColor = failed
        ? theme.colors.error
        : active
            ? theme.colors.primary
            : theme.colors.onBackgroundVariant;
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Icon(
                            task.type == 'translate'
                                ? Icons.translate_rounded
                                : Icons.download_outlined,
                            size: 24,
                            color: theme.colors.onBackgroundVariant)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                          Text(title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textStyles.body1
                                  .copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 5),
                          Wrap(spacing: 10, runSpacing: 4, children: <Widget>[
                            Text(_taskType(task.type),
                                style: theme.textStyles.footnote1),
                            Text(_taskStatus(task.status),
                                style: theme.textStyles.footnote1.copyWith(
                                    color: statusColor,
                                    fontWeight: FontWeight.w600)),
                            if (task.totalCount > 0)
                              Text(
                                  '${task.completedCount} / ${task.totalCount} 章',
                                  style: theme.textStyles.footnote1),
                          ]),
                        ])),
                    IconButton(
                        onPressed: onDetails,
                        tooltip: '查看任务详情',
                        icon: const Icon(Icons.more_horiz_rounded)),
                  ]),
              if (active) ...<Widget>[
                const SizedBox(height: 12),
                Semantics(
                    label: '任务进度',
                    value: task.totalCount > 0
                        ? '${task.progress.clamp(0, 100).round()}%'
                        : '等待进度',
                    child: LinearProgressIndicator(
                        value: task.totalCount > 0
                            ? (task.progress / 100).clamp(0, 1)
                            : null,
                        minHeight: 3,
                        borderRadius: BorderRadius.circular(3))),
              ],
              if (task.message.isNotEmpty ||
                  task.error?.isNotEmpty == true) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                    task.error?.isNotEmpty == true ? task.error! : task.message,
                    maxLines: failed ? 4 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textStyles.footnote1
                        .copyWith(color: theme.colors.onBackgroundVariant)),
              ],
              if (failed)
                Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: MobileActionButton(
                          icon: Icons.refresh_rounded,
                          tonal: true,
                          busy: retrying,
                          onPressed: retrying ? null : onRetry,
                          child: Text(retrying ? '正在重试' : '重试任务')),
                    )),
            ]));
  }
}
