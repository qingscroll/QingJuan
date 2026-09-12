import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../app/app_scope.dart';
import '../../core/models/link_job.dart';
import '../../shared/desktop_subpage.dart';
import '../detail/book_detail_page.dart';
import 'link_history_controller.dart';
import 'widgets/import_history_controls.dart';
import 'widgets/import_history_form.dart';
import 'widgets/import_history_record_card.dart';

Future<void> openImportHistory(f.BuildContext context, {bool mobile = false}) =>
    f.Navigator.of(context).push<void>(f.PageRouteBuilder<void>(
      pageBuilder: (_, __, ___) => ImportHistoryPage(mobile: mobile),
    ));

class ImportHistoryPage extends f.StatefulWidget {
  const ImportHistoryPage({this.mobile = false, super.key});
  final bool mobile;
  @override
  f.State<ImportHistoryPage> createState() => _ImportHistoryPageState();
}

class _ImportHistoryPageState extends f.State<ImportHistoryPage> {
  final _links = f.TextEditingController();
  LinkHistoryController? _controller;
  bool _adding = false;
  String _kind = '长小说';
  String _language = '中文';
  String? _error;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _controller = AppScope.of(context).library.imports;
    _generation = _controller!.contextGeneration;
    _controller!.addListener(_clearOldContext);
    f.WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_controller!.load());
    });
  }

  @override
  void dispose() {
    _controller?.removeListener(_clearOldContext);
    _links.dispose();
    super.dispose();
  }

  void _clearOldContext() {
    final generation = _controller!.contextGeneration;
    if (_generation == generation || !mounted) return;
    setState(() {
      _generation = generation;
      _links.clear();
      _error = null;
      _adding = false;
    });
  }

  Future<void> _submit() async {
    final generation = _generation;
    setState(() => _error = null);
    try {
      await _controller!
          .enqueueLines(_links.text, kind: _kind, language: _language);
      if (mounted && generation == _generation) {
        setState(() {
          _links.clear();
          _adding = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    }
  }

  Future<void> _retry(LinkJob job) async {
    final generation = _generation;
    setState(() => _error = null);
    try {
      await _controller!.retry(job.id);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    }
  }

  Future<void> _retryFailed() async {
    final generation = _generation;
    setState(() => _error = null);
    try {
      await _controller!.retryFailed();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    }
  }

  f.Widget _action(String label, f.VoidCallback? action,
          {bool primary = false, bool subtle = false, f.IconData? icon}) =>
      ImportHistoryAction(
        label: label,
        mobile: widget.mobile,
        onPressed: action,
        primary: primary,
        subtle: subtle,
        icon: icon,
      );

  @override
  f.Widget build(f.BuildContext context) {
    final content = f.AnimatedBuilder(
      animation: _controller!,
      builder: (context, _) {
        final controller = _controller!;
        return f.Align(
          alignment: f.Alignment.topCenter,
          child: f.ConstrainedBox(
            constraints: const f.BoxConstraints(maxWidth: 1120),
            child: f.ListView.builder(
              key: f.ValueKey('import-history-$_generation'),
              padding: f.EdgeInsets.fromLTRB(
                widget.mobile ? 16 : 32,
                widget.mobile ? 16 : 24,
                widget.mobile ? 16 : 32,
                32,
              ),
              itemCount: controller.enabled ? controller.jobs.length + 2 : 1,
              itemBuilder: (context, index) {
                if (index == 0) return _header(controller);
                if (index <= controller.jobs.length) {
                  final job = controller.jobs[index - 1];
                  return f.Padding(
                    padding: const f.EdgeInsets.only(bottom: 12),
                    child: ImportHistoryRecordCard(
                      key: f.ValueKey(job.id),
                      job: job,
                      mobile: widget.mobile,
                      retrying: controller.retrying.contains(job.id),
                      onRetry: () => _retry(job),
                      onOpenBook: () {
                        if (job.book == null) return;
                        f.Navigator.of(context)
                            .push<void>(f.PageRouteBuilder<void>(
                          pageBuilder: (_, __, ___) =>
                              BookDetailPage(bookId: job.book!.id),
                        ));
                      },
                    ),
                  );
                }
                return controller.hasMore
                    ? f.Align(
                        alignment: f.Alignment.center,
                        child: _action(
                          controller.loading ? '正在加载…' : '加载更多记录',
                          controller.loading
                              ? null
                              : () => controller.load(more: true),
                        ),
                      )
                    : const f.SizedBox.shrink();
              },
            ),
          ),
        );
      },
    );
    return widget.mobile
        ? m.Scaffold(
            appBar: m.AppBar(title: const m.Text('导入记录')),
            body: m.SafeArea(top: false, child: content),
          )
        : DesktopSubpage(
            title: '导入记录', showContentTitle: false, child: content);
  }

  f.Widget _header(LinkHistoryController controller) {
    final mobile = widget.mobile;
    final secondary = importHistorySecondaryStyle(context, mobile);
    final heading = f.Column(
      crossAxisAlignment: f.CrossAxisAlignment.start,
      children: [
        if (!mobile) ...[
          f.Text('导入记录', style: f.FluentTheme.of(context).typography.title),
          const f.SizedBox(height: 6),
        ],
        f.Text('查看作品导入进度，继续处理未完成的导入。', style: secondary),
      ],
    );
    final actions = f.Wrap(spacing: 8, runSpacing: 8, children: [
      _action(
        _adding ? '收起表单' : '批量导入',
        controller.submitting ? null : () => setState(() => _adding = !_adding),
        primary: true,
        icon: mobile ? m.Icons.add : f.FluentIcons.add,
      ),
      _action(
        '刷新记录',
        controller.loading
            ? null
            : () {
                setState(() => _error = null);
                unawaited(controller.load());
              },
        icon: mobile ? m.Icons.refresh : f.FluentIcons.refresh,
      ),
    ]);
    return f.Column(
      crossAxisAlignment: f.CrossAxisAlignment.start,
      children: [
        f.LayoutBuilder(builder: (context, constraints) {
          if (!mobile &&
              constraints.maxWidth >=
                  760 * f.MediaQuery.textScalerOf(context).scale(1)) {
            return f.Row(
                crossAxisAlignment: f.CrossAxisAlignment.center,
                children: [
                  f.Expanded(child: heading),
                  if (controller.enabled) ...[
                    const f.SizedBox(width: 24),
                    actions
                  ],
                ]);
          }
          return f.Column(
              crossAxisAlignment: f.CrossAxisAlignment.start,
              children: [
                heading,
                if (controller.enabled) ...[
                  const f.SizedBox(height: 16),
                  actions
                ],
              ]);
        }),
        const f.SizedBox(height: 24),
        if (!controller.enabled)
          _notice('当前连接不可用或不支持导入记录，请连接支持此功能的后端后重试。')
        else ...[
          if (_adding) ...[
            ImportHistoryForm(
              mobile: mobile,
              links: _links,
              kind: _kind,
              language: _language,
              submitting: controller.submitting,
              onKindChanged: (value) => setState(() => _kind = value),
              onLanguageChanged: (value) => setState(() => _language = value),
              onSubmit: _submit,
              onCancel: () => setState(() => _adding = false),
            ),
            const f.SizedBox(height: 24),
          ],
          if (_error != null || controller.error != null) ...[
            _notice(_error ?? controller.error!, error: true),
            const f.SizedBox(height: 16),
          ],
          if (controller.loading && controller.jobs.isEmpty)
            _notice('正在加载导入记录…', loading: true),
          if (!controller.loading &&
              controller.jobs.isEmpty &&
              controller.error == null &&
              _error == null &&
              !_adding)
            _notice('还没有导入记录。点击“批量导入”，添加想读的作品链接。'),
          if (controller.jobs.isNotEmpty) ...[
            f.Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: f.WrapCrossAlignment.center,
              children: [
                f.Text('已加载 ${controller.jobs.length} 条',
                    style: const f.TextStyle(fontWeight: f.FontWeight.w600)),
                f.Text(
                    '进行中 ${controller.activeCount} 条 · 失败 ${controller.failedCount} 条',
                    style: secondary),
                if (controller.failedCount > 0)
                  _action(
                    controller.retryingFailed ? '正在重试…' : '重试已加载的失败项',
                    controller.retryingFailed ? null : _retryFailed,
                    subtle: true,
                  ),
                if (controller.loading) f.Text('正在刷新…', style: secondary),
              ],
            ),
            const f.SizedBox(height: 16),
          ],
        ],
      ],
    );
  }

  f.Widget _notice(String text, {bool error = false, bool loading = false}) {
    if (error && !widget.mobile) {
      return f.InfoBar(
        title: const f.Text('暂时无法完成操作'),
        content: f.Text(text),
        severity: f.InfoBarSeverity.error,
      );
    }
    return ImportHistorySurface(
      mobile: widget.mobile,
      child: f.Semantics(
        liveRegion: error || loading,
        child:
            f.Column(crossAxisAlignment: f.CrossAxisAlignment.start, children: [
          if (loading) ...[
            if (widget.mobile)
              const m.LinearProgressIndicator()
            else
              const f.ProgressBar(),
            const f.SizedBox(height: 16),
          ],
          if (error) ...[
            const f.Text('暂时无法完成操作',
                style: f.TextStyle(fontWeight: f.FontWeight.w600)),
            const f.SizedBox(height: 8),
          ],
          f.Text(text),
        ]),
      ),
    );
  }
}
