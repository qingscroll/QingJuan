import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../app/app_scope.dart';
import '../../core/models/book.dart';
import '../../core/models/reading_annotation.dart';
import '../../shared/desktop_subpage.dart';
import 'annotations_controller.dart';

Future<ReadingProgress?> showReadingAnnotations(f.BuildContext context,
        {required String bookId,
        required ReadingProgress position,
        bool mobile = false,
        String? selectedQuote}) =>
    f.Navigator.of(context).push<ReadingProgress>(f.PageRouteBuilder(
        pageBuilder: (_, __, ___) => AnnotationsPage(
            bookId: bookId,
            position: position,
            mobile: mobile,
            selectedQuote: selectedQuote)));

class AnnotationsPage extends f.StatefulWidget {
  const AnnotationsPage(
      {required this.bookId,
      required this.position,
      this.mobile = false,
      this.selectedQuote,
      super.key});
  final String bookId;
  final ReadingProgress position;
  final bool mobile;
  final String? selectedQuote;
  @override
  f.State<AnnotationsPage> createState() => _AnnotationsPageState();
}

class _AnnotationsPageState extends f.State<AnnotationsPage> {
  AnnotationsController? _controller;
  final _query = f.TextEditingController();
  bool _searchTab = false, _chapterOnly = false;
  bool _annotationsAvailable = false, _searchAvailable = false;
  late String _mode;
  AnnotationsController get controller => _controller!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final scope = AppScope.of(context);
    _annotationsAvailable =
        scope.backend.capabilities['readingAnnotations'] == true;
    _searchAvailable = scope.backend.capabilities['cachedTextSearch'] == true;
    _searchTab = !_annotationsAvailable;
    _mode = widget.position.contentMode ?? 'original';
    _controller = AnnotationsController(scope.api, scope.library, widget.bookId)
      ..addListener(_changed);
    f.WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (_annotationsAvailable) {
        unawaited(controller.load(
            filter: widget.selectedQuote == null ? 'bookmark' : 'note'));
      }
      if (_annotationsAvailable && widget.selectedQuote != null) {
        await _edit(kind: 'note', quote: widget.selectedQuote!);
      }
    });
  }

  void _changed() {
    if (!mounted) return;
    if (controller.invalidated) _query.clear();
    setState(() {});
  }

  Future<void> _edit(
      {ReadingAnnotation? item,
      String kind = 'bookmark',
      String quote = ''}) async {
    if (controller.invalidated || controller.saving) return;
    await f.Navigator.of(context).push<void>(f.PageRouteBuilder(
        pageBuilder: (_, __, ___) => _AnnotationEditor(
            controller: controller,
            mobile: widget.mobile,
            item: item,
            kind: item?.kind ?? kind,
            position: AnnotationPosition(widget.position),
            quote: quote)));
  }

  Future<bool> _confirm(String title, String message, String action) async {
    if (widget.mobile) {
      return await m.showDialog<bool>(
              context: context,
              builder: (context) => m.AlertDialog(
                      title: f.Text(title),
                      content: f.Text(message),
                      actions: [
                        m.TextButton(
                            onPressed: () => f.Navigator.pop(context, false),
                            child: const f.Text('返回')),
                        m.TextButton(
                            onPressed: () => f.Navigator.pop(context, true),
                            child: f.Text(action))
                      ])) ??
          false;
    }
    return await f.showDialog<bool>(
            context: context,
            builder: (context) => f.ContentDialog(
                    title: f.Text(title),
                    content: f.Text(message),
                    actions: [
                      f.Button(
                          onPressed: () => f.Navigator.pop(context, false),
                          child: const f.Text('返回')),
                      f.FilledButton(
                          onPressed: () => f.Navigator.pop(context, true),
                          child: f.Text(action))
                    ])) ??
        false;
  }

  Future<void> _jump(ReadingAnnotation item) async {
    if (item.contentChanged &&
        !await _confirm('正文已变化', '保存后章节正文发生变化，原位置可能已偏移。请结合摘录核对内容。', '仍然跳转')) {
      return;
    }
    if (mounted && !controller.invalidated) {
      f.Navigator.pop(context, item.position.progress);
    }
  }

  Future<void> _delete(ReadingAnnotation item) async {
    final name = item.label.isEmpty
        ? '第 ${item.position.progress.chapterIndex} 章的记录'
        : item.label;
    if (await _confirm('删除记录', '删除“$name”？', '删除') &&
        mounted &&
        !controller.invalidated) {
      await controller.delete(item);
    }
  }

  f.Widget _button(String label, f.VoidCallback? action,
          {bool primary = false}) =>
      _actionButton(widget.mobile, label, action, primary: primary);

  f.Widget _record(ReadingAnnotation item) => _card(
      widget.mobile,
      f.Column(crossAxisAlignment: f.CrossAxisAlignment.start, children: [
        f.Text(
            item.label.isEmpty
                ? '第 ${item.position.progress.chapterIndex} 章'
                : item.label,
            style: const f.TextStyle(fontWeight: f.FontWeight.bold)),
        f.Text(
            '第 ${item.position.progress.chapterIndex} 章 · ${item.position.progress.contentMode == 'translated' ? '译文' : '原文'}'),
        if (item.quote.isNotEmpty)
          f.Padding(
              padding: const f.EdgeInsets.only(top: 8),
              child: f.Text('“${item.quote}”')),
        if (item.note.isNotEmpty)
          f.Padding(
              padding: const f.EdgeInsets.only(top: 8),
              child: f.Text(item.note)),
        if (item.contentChanged) const f.Text('正文已变化，跳转前请核对摘录'),
        const f.SizedBox(height: 8),
        f.Wrap(spacing: 8, runSpacing: 8, children: [
          _button('跳转', () => unawaited(_jump(item))),
          _button('编辑',
              controller.saving ? null : () => unawaited(_edit(item: item))),
          _button(
              '删除', controller.saving ? null : () => unawaited(_delete(item))),
        ])
      ]));

  void _search() {
    f.FocusScope.of(context).unfocus();
    unawaited(controller.search(
        query: _query.text,
        mode: _mode,
        chapterIndex: _chapterOnly ? widget.position.chapterIndex : null));
  }

  List<f.Widget> _searchChildren() => [
        const f.Text('只搜索服务端已缓存的正文；未缓存章节不会自动下载。'),
        const f.SizedBox(height: 12),
        _textField(widget.mobile, _query, '关键词',
            key: const f.ValueKey('cached-text-query'),
            maxLength: 120,
            onSubmitted: (_) => _search()),
        const f.SizedBox(height: 8),
        if (widget.mobile) ...[
          m.CheckboxListTile(
              contentPadding: f.EdgeInsets.zero,
              title: const f.Text('仅当前章节'),
              value: _chapterOnly,
              onChanged: (value) =>
                  setState(() => _chapterOnly = value ?? false)),
          m.SwitchListTile(
              contentPadding: f.EdgeInsets.zero,
              title: const f.Text('搜索译文'),
              value: _mode == 'translated',
              onChanged: (value) =>
                  setState(() => _mode = value ? 'translated' : 'original')),
        ] else
          f.Wrap(spacing: 16, runSpacing: 12, children: [
            f.Checkbox(
                content: const f.Text('仅当前章节'),
                checked: _chapterOnly,
                onChanged: (value) =>
                    setState(() => _chapterOnly = value ?? false)),
            f.ToggleSwitch(
                content: const f.Text('搜索译文'),
                checked: _mode == 'translated',
                onChanged: (value) =>
                    setState(() => _mode = value ? 'translated' : 'original'))
          ]),
        const f.SizedBox(height: 12),
        _button('搜索正文', _search, primary: true),
        if (controller.searching)
          const f.Padding(
              padding: f.EdgeInsets.all(12), child: f.Text('正在搜索…')),
        if (controller.searchError != null) f.Text(controller.searchError!),
        if (controller.hasSearched &&
            !controller.searching &&
            controller.searchError == null)
          f.Text(
              '找到 ${controller.hits.length} 处 · 扫描 ${controller.scannedChapters} 章 · 未缓存 ${controller.uncachedChapters} 章 · 跳过 ${controller.skippedChapters} 章'),
        if (controller.searchTruncated && controller.nextCursor == null)
          const f.Text('部分章节超出大小或编码限制，未参与搜索。'),
        for (final hit in controller.hits)
          _card(
              widget.mobile,
              f.Column(
                  crossAxisAlignment: f.CrossAxisAlignment.start,
                  children: [
                    f.Text(hit.chapterTitle,
                        style:
                            const f.TextStyle(fontWeight: f.FontWeight.bold)),
                    f.Text(hit.snippet),
                    const f.SizedBox(height: 8),
                    _button('阅读此处',
                        () => f.Navigator.pop(context, hit.position.progress))
                  ])),
        if (controller.nextCursor != null)
          _button(
              '继续搜索',
              controller.searching
                  ? null
                  : () => unawaited(controller.search(more: true))),
      ];

  @override
  f.Widget build(f.BuildContext context) {
    final children = <f.Widget>[
      if (controller.invalidated)
        const f.Text('账号或服务已切换，请返回阅读器重新打开。')
      else if (!_annotationsAvailable && !_searchAvailable)
        const f.Text('当前服务尚不支持书签、笔记和正文搜索，请更新后端后重试。')
      else ...[
        f.Wrap(spacing: 8, runSpacing: 8, children: [
          if (_annotationsAvailable) ...[
            _button('书签', () {
              setState(() => _searchTab = false);
              unawaited(controller.load(filter: 'bookmark'));
            }, primary: !_searchTab && controller.kind == 'bookmark'),
            _button('笔记', () {
              setState(() => _searchTab = false);
              unawaited(controller.load(filter: 'note'));
            }, primary: !_searchTab && controller.kind == 'note'),
          ],
          if (_searchAvailable)
            _button('正文搜索', () => setState(() => _searchTab = true),
                primary: _searchTab),
        ]),
        const f.SizedBox(height: 20),
        if (_searchTab && _searchAvailable)
          ..._searchChildren()
        else if (_annotationsAvailable) ...[
          f.Wrap(spacing: 8, runSpacing: 8, children: [
            _button(
                controller.kind == 'bookmark' ? '添加当前书签' : '添加当前位置笔记',
                controller.saving
                    ? null
                    : () => unawaited(_edit(kind: controller.kind)),
                primary: true),
            _button(
                '刷新记录',
                controller.loading || controller.saving
                    ? null
                    : () => unawaited(controller.load())),
          ]),
          if (controller.error != null)
            f.Padding(
                padding: const f.EdgeInsets.symmetric(vertical: 12),
                child: f.Text(controller.error!)),
          if (controller.loading)
            const f.Padding(
                padding: f.EdgeInsets.all(12), child: f.Text('正在加载…')),
          if (!controller.loading && controller.items.isEmpty)
            const f.Padding(
                padding: f.EdgeInsets.all(12), child: f.Text('还没有记录')),
          ...controller.items.map(_record),
          if (controller.hasMore)
            _button(
                '加载更多记录',
                controller.loading
                    ? null
                    : () => unawaited(controller.load(more: true))),
        ]
      ]
    ];
    return _page(widget.mobile, '书签、笔记与搜索',
        f.ListView(padding: const f.EdgeInsets.all(20), children: children));
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    _controller?.dispose();
    _query.dispose();
    super.dispose();
  }
}

class _AnnotationEditor extends f.StatefulWidget {
  const _AnnotationEditor(
      {required this.controller,
      required this.mobile,
      required this.kind,
      required this.position,
      required this.quote,
      this.item});
  final AnnotationsController controller;
  final bool mobile;
  final String kind, quote;
  final AnnotationPosition position;
  final ReadingAnnotation? item;
  @override
  f.State<_AnnotationEditor> createState() => _AnnotationEditorState();
}

class _AnnotationEditorState extends f.State<_AnnotationEditor> {
  final _label = f.TextEditingController(), _note = f.TextEditingController();
  ReadingAnnotation? _item;
  String? _draft, _clientKey, _message;
  AnnotationsController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    _item = widget.item;
    _label.text =
        _item?.label ?? '第 ${widget.position.progress.chapterIndex} 章';
    _note.text = _item?.note ?? '';
    controller.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    if (controller.invalidated) {
      _label.clear();
      _note.clear();
      _draft = _clientKey = null;
    }
    setState(() {});
  }

  Future<void> _save() async {
    if (controller.saving || controller.invalidated) return;
    f.FocusScope.of(context).unfocus();
    final label = _label.text.trim(), note = _note.text.trim();
    if (label.length > 120 || note.length > 20000) {
      setState(() => _message = '标题最多 120 字，笔记最多 20000 字');
      return;
    }
    bool success;
    if (_item != null) {
      success = await controller.update(_item!, label: label, note: note);
    } else {
      final draft = jsonEncode([label, note, widget.quote]);
      if (_draft != draft) {
        _draft = draft;
        _clientKey =
            'note-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      }
      success = await controller.create(
          clientKey: _clientKey!,
          kind: widget.kind,
          label: label,
          note: note,
          quote: widget.quote,
          position: widget.position);
    }
    if (mounted && success) f.Navigator.pop(context);
  }

  Future<void> _reload() async {
    await controller.load(filter: widget.kind);
    while (!controller.invalidated &&
        controller.error == null &&
        !controller.items.any((item) => item.id == _item?.id) &&
        controller.hasMore) {
      await controller.load(more: true);
    }
    if (!mounted || controller.invalidated) return;
    final latest =
        controller.items.where((item) => item.id == _item?.id).firstOrNull;
    if (latest == null) {
      setState(() => _message = '记录已被删除，当前草稿仍保留。');
      return;
    }
    setState(() {
      _item = latest;
      _label.text = latest.label;
      _note.text = latest.note;
      _message = null;
    });
  }

  @override
  f.Widget build(f.BuildContext context) => _page(
      widget.mobile,
      widget.kind == 'bookmark' ? '编辑书签' : '编辑笔记',
      f.ListView(padding: const f.EdgeInsets.all(20), children: [
        if (controller.invalidated)
          const f.Text('账号或服务已切换，请返回阅读器重新打开。')
        else ...[
          f.Text(
              '第 ${(_item?.position ?? widget.position).progress.chapterIndex} 章'),
          const f.SizedBox(height: 12),
          _textField(widget.mobile, _label, '标题',
              maxLength: 120,
              enabled: !controller.saving,
              key: const f.ValueKey('annotation-label')),
          if ((_item?.quote ?? widget.quote).isNotEmpty)
            f.Padding(
                padding: const f.EdgeInsets.symmetric(vertical: 12),
                child: f.Text('摘录：${_item?.quote ?? widget.quote}')),
          const f.SizedBox(height: 12),
          _textField(widget.mobile, _note, '笔记内容',
              maxLength: 20000,
              maxLines: 8,
              enabled: !controller.saving,
              key: const f.ValueKey('annotation-note')),
          const f.SizedBox(height: 16),
          if (_message != null || controller.error != null)
            f.Text(_message ?? controller.error!),
          f.Wrap(spacing: 8, runSpacing: 8, children: [
            _actionButton(widget.mobile, controller.saving ? '正在保存…' : '保存记录',
                controller.saving ? null : () => unawaited(_save()),
                primary: true),
            if (_item != null)
              _actionButton(
                  widget.mobile,
                  '放弃草稿并重新加载',
                  controller.saving || controller.loading
                      ? null
                      : () => unawaited(_reload())),
          ]),
        ]
      ]));
  @override
  void dispose() {
    controller.removeListener(_changed);
    _label.dispose();
    _note.dispose();
    super.dispose();
  }
}

f.Widget _actionButton(bool mobile, String label, f.VoidCallback? action,
        {bool primary = false}) =>
    mobile
        ? (primary
            ? m.FilledButton(
                onPressed: action,
                style:
                    m.FilledButton.styleFrom(minimumSize: const f.Size(48, 48)),
                child: f.Text(label))
            : m.OutlinedButton(
                onPressed: action,
                style: m.OutlinedButton.styleFrom(
                    minimumSize: const f.Size(48, 48)),
                child: f.Text(label)))
        : (primary
            ? f.FilledButton(onPressed: action, child: f.Text(label))
            : f.Button(onPressed: action, child: f.Text(label)));

f.Widget _textField(
        bool mobile, f.TextEditingController controller, String label,
        {f.Key? key,
        int maxLength = 120,
        int maxLines = 1,
        bool enabled = true,
        f.ValueChanged<String>? onSubmitted}) =>
    mobile
        ? m.TextField(
            key: key,
            controller: controller,
            enabled: enabled,
            maxLength: maxLength,
            maxLines: maxLines,
            decoration: m.InputDecoration(
                labelText: label, border: const m.OutlineInputBorder()),
            onSubmitted: onSubmitted)
        : f.InfoLabel(
            label: label,
            child: f.TextBox(
                key: key,
                controller: controller,
                enabled: enabled,
                maxLength: maxLength,
                maxLines: maxLines,
                onSubmitted: onSubmitted));

f.Widget _card(bool mobile, f.Widget child) => f.Padding(
    padding: const f.EdgeInsets.symmetric(vertical: 8),
    child: mobile
        ? m.Card(
            child: f.Padding(padding: const f.EdgeInsets.all(16), child: child))
        : f.Card(child: child));

f.Widget _page(bool mobile, String title, f.Widget body) => mobile
    ? m.Scaffold(
        appBar: m.AppBar(title: f.Text(title)), body: m.SafeArea(child: body))
    : DesktopSubpage(title: title, child: body);
