import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../app/app_scope.dart';
import '../../core/models/book_update.dart';
import '../../mobile/mobile_action_button.dart';
import '../../shared/desktop_subpage.dart';
import 'book_updates_controller.dart';

String _formatTime(String? value) {
  final date = DateTime.tryParse(value ?? '')?.toLocal();
  if (date == null) return '尚未检查';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}

Future<void> showBookUpdates(f.BuildContext context,
        {required String bookId, bool mobile = false}) =>
    f.Navigator.of(context).push<void>(f.PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) =>
            BookUpdatesPage(bookId: bookId, mobile: mobile)));

class BookUpdatesPage extends f.StatefulWidget {
  const BookUpdatesPage({required this.bookId, this.mobile = false, super.key});
  final String bookId;
  final bool mobile;
  @override
  f.State<BookUpdatesPage> createState() => _BookUpdatesPageState();
}

class _BookUpdatesPageState extends f.State<BookUpdatesPage> {
  BookUpdatesController? _controller;
  final _interval = f.TextEditingController(text: '6');
  int _generation = 0;
  int _revision = 0;
  bool _autoDownload = false;
  bool _loading = true;
  bool _invalidated = false;
  String? _error;
  BookUpdate? get _record => _controller!.records[widget.bookId];
  bool get _busy => _loading || _controller!.isPending(widget.bookId);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final scope = AppScope.of(context);
    _controller = scope.library.serials;
    _controller!.enabled = scope.backend.capabilities['bookUpdates'] == true;
    _generation = _controller!.contextGeneration;
    _controller!.addListener(_changed);
    f.WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  void _changed() {
    if (!mounted) return;
    if (_generation != _controller!.contextGeneration) {
      _invalidated = true;
      _interval.clear();
      _autoDownload = false;
      _error = null;
    }
    setState(() {});
  }

  void _fill(BookUpdate value) {
    _autoDownload = value.autoDownload;
    _interval.text = '${value.intervalHours}';
    _revision = value.revision;
  }

  Future<void> _load() async {
    if (_invalidated) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await _controller!.refresh(widget.bookId);
      if (mounted && !_invalidated && value != null) _fill(value);
    } catch (error) {
      if (mounted && !_invalidated) _error = '$error';
    } finally {
      if (mounted && !_invalidated) setState(() => _loading = false);
    }
  }

  Future<void> _perform(Future<BookUpdate?> Function() operation,
      {bool fill = false}) async {
    if (_busy || _invalidated) return;
    f.FocusScope.of(context).unfocus();
    setState(() => _error = null);
    try {
      final value = await operation();
      if (mounted && !_invalidated && value != null && fill) {
        setState(() => _fill(value));
      }
    } catch (error) {
      if (mounted && !_invalidated) setState(() => _error = '$error');
    }
  }

  void _save() {
    if (_record?.automatic != true) return;
    final hours = int.tryParse(_interval.text.trim());
    if (hours == null || hours < 1 || hours > 168) {
      setState(() => _error = '检查间隔应为 1 到 168 小时');
      return;
    }
    unawaited(_perform(
        () => _controller!.configure(widget.bookId,
            expectedRevision: _revision,
            intervalHours: hours,
            autoDownload: _autoDownload),
        fill: true));
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    _interval.dispose();
    super.dispose();
  }

  f.Widget _button(String label, f.VoidCallback? action,
          {bool primary = false}) =>
      widget.mobile
          ? (primary
              ? MobileActionButton(onPressed: action, child: m.Text(label))
              : m.OutlinedButton(onPressed: action, child: m.Text(label)))
          : (primary
              ? f.FilledButton(onPressed: action, child: f.Text(label))
              : f.Button(onPressed: action, child: f.Text(label)));

  f.Widget _toggle(String label, bool value, f.ValueChanged<bool> change) =>
      widget.mobile
          ? m.SwitchListTile.adaptive(
              contentPadding: f.EdgeInsets.zero,
              title: m.Text(label),
              value: value,
              onChanged: _busy || _record?.automatic != true ? null : change)
          : f.ToggleSwitch(
              checked: value,
              content: f.Text(label),
              onChanged: _busy || _record?.automatic != true ? null : change);

  f.Widget _body() {
    if (_invalidated) return const f.Text('账号或服务已切换，请返回书库重新打开作品。');
    if (!_controller!.enabled) return const f.Text('当前服务尚不支持连载追更，请更新后端后重试。');
    if (_loading) {
      return widget.mobile
          ? const m.CircularProgressIndicator()
          : const f.ProgressRing();
    }
    final record = _record;
    if (record == null) {
      return f.Column(
          children: [f.Text(_error ?? '无法读取追更状态'), _button('重新加载', _load)]);
    }
    return f
        .Column(crossAxisAlignment: f.CrossAxisAlignment.stretch, children: [
      f.Text(record.sourceStatusLabel,
          key: const f.ValueKey('book-source-status'),
          style:
              const f.TextStyle(fontSize: 22, fontWeight: f.FontWeight.w600)),
      const f.SizedBox(height: 8),
      f.Text(!record.supported
          ? (record.unsupportedReason ?? '该来源暂不支持检查更新。')
          : !record.automatic
              ? '当前服务未提供自动连载判断，仍可手动检查目录更新。'
              : record.sourceStatus == 'completed'
                  ? '来源已确认完结，后端已停止定时检查。'
                  : record.sourceStatus == 'unknown'
                      ? '来源尚未明确连载状态，后端会低频复查，确认完结后停止。'
                      : '后端根据来源状态自动判断并定时检查，确认完结后停止。'),
      if (record.sourceStatusCheckedAt != null) ...[
        const f.SizedBox(height: 8),
        f.Text('状态确认：${_formatTime(record.sourceStatusCheckedAt)}'),
      ],
      const f.SizedBox(height: 20),
      f.Text(
          record.newChapterCount > 0
              ? '发现 ${record.newChapterCount} 章更新'
              : '暂无未确认的新章节',
          style:
              const f.TextStyle(fontSize: 18, fontWeight: f.FontWeight.w600)),
      const f.SizedBox(height: 12),
      f.Text('上次检查：${_formatTime(record.lastCheckedAt)}'),
      if (record.enabled && record.nextCheckAt != null)
        f.Text('下次检查：${_formatTime(record.nextCheckAt)}'),
      const f.SizedBox(height: 16),
      f.Wrap(spacing: 10, runSpacing: 10, children: [
        _button(
            _controller!.isPending(widget.bookId) || record.checking
                ? '正在处理'
                : '立即检查更新',
            _busy || !record.supported
                ? null
                : () => _perform(() => _controller!.check(widget.bookId)),
            primary: true),
        if (record.newChapterCount > 0)
          _button(
              '标记更新已看',
              _busy
                  ? null
                  : () => _perform(() => _controller!
                      .acknowledge(widget.bookId, record.latestChapterIndex))),
      ]),
      const f.SizedBox(height: 24),
      if (widget.mobile)
        m.TextField(
            key: const f.ValueKey('book-update-interval'),
            controller: _interval,
            keyboardType: m.TextInputType.number,
            enabled: !_busy && record.automatic,
            magnifierConfiguration: m.TextMagnifierConfiguration.disabled,
            decoration: const m.InputDecoration(
                labelText: '检查间隔（小时）',
                helperText: '1 到 168 小时',
                border: m.OutlineInputBorder()))
      else
        f.InfoLabel(
            label: '检查间隔（小时，1 到 168）',
            child: f.TextBox(
                key: const f.ValueKey('book-update-interval'),
                controller: _interval,
                enabled: !_busy && record.automatic,
                keyboardType: f.TextInputType.number)),
      const f.SizedBox(height: 16),
      _toggle('自动下载未确认的新章节', _autoDownload,
          (value) => setState(() => _autoDownload = value)),
      const f.SizedBox(height: 12),
      const f.Text('检查间隔和自动下载是阅读偏好，连载状态由后端判断。自动下载会使用网络流量；作品正在下载或翻译时，请稍后检查。'),
      if (!record.automatic) ...[
        const f.SizedBox(height: 10),
        const f.Text('更新后端后，可配置自动检查间隔与下载偏好。'),
      ],
      const f.SizedBox(height: 16),
      if (_error ?? record.lastError case final String error) ...[
        f.Semantics(liveRegion: true, child: f.Text(error)),
        const f.SizedBox(height: 10),
        _button('重新加载状态与设置', _busy ? null : _load),
        const f.SizedBox(height: 10),
      ],
      _button('保存追更设置', _busy || !record.automatic ? null : _save,
          primary: true),
    ]);
  }

  @override
  f.Widget build(f.BuildContext context) {
    final body = f.SafeArea(
        child: f.Align(
            alignment: f.Alignment.topCenter,
            child: f.ConstrainedBox(
                constraints: const f.BoxConstraints(maxWidth: 680),
                child: f.SingleChildScrollView(
                    keyboardDismissBehavior:
                        f.ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const f.EdgeInsets.all(20),
                    child: _body()))));
    return widget.mobile
        ? m.Scaffold(appBar: m.AppBar(title: const m.Text('连载追更')), body: body)
        : DesktopSubpage(
            title: '连载追更',
            maxContentWidth: 680,
            backLabel: '返回作品',
            child: body);
  }
}
