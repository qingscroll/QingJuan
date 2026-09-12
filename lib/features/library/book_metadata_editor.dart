import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../app/app_scope.dart';
import '../../core/models/book.dart';
import '../../core/models/book_metadata.dart';
import '../../shared/desktop_subpage.dart';
import 'book_metadata_controller.dart';

Future<bool?> showBookMetadataEditor(f.BuildContext context,
        {required String bookId, bool mobile = false}) =>
    f.Navigator.of(context).push<bool>(f.PageRouteBuilder<bool>(
        pageBuilder: (_, __, ___) =>
            BookMetadataEditor(bookId: bookId, mobile: mobile)));

class BookMetadataEditor extends f.StatefulWidget {
  const BookMetadataEditor(
      {required this.bookId, this.mobile = false, super.key});
  final String bookId;
  final bool mobile;
  @override
  f.State<BookMetadataEditor> createState() => _BookMetadataEditorState();
}

class _BookMetadataEditorState extends f.State<BookMetadataEditor> {
  BookMetadataController? _controller;
  BookMetadata? _original;
  final _title = f.TextEditingController();
  final _author = f.TextEditingController();
  final _synopsis = f.TextEditingController();
  final _group = f.TextEditingController();
  final _tags = f.TextEditingController();
  final _reset = <String>{};
  String _readingState = 'unread';
  bool _pinned = false;
  String? _validation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _controller =
        BookMetadataController(AppScope.of(context).library, widget.bookId)
          ..addListener(_changed);
    f.WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_controller!.load());
    });
  }

  void _changed() {
    if (!mounted) return;
    final next = _controller!.metadata;
    if (_controller!.invalidated) {
      for (final field in [_title, _author, _synopsis, _group, _tags]) {
        field.clear();
      }
      _original = null;
      _reset.clear();
    } else if (next != null && next != _original && !_controller!.saving) {
      _original = next;
      _title.text = next.title;
      _author.text = next.author;
      _synopsis.text = next.synopsis;
      _group.text = next.groupName ?? '';
      _tags.text = next.tags.join('，');
      _pinned = next.pinned;
      _readingState = readingStateLabels.containsKey(next.readingState)
          ? next.readingState
          : 'unread';
      _reset.clear();
      _validation = null;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    _controller?.dispose();
    for (final field in [_title, _author, _synopsis, _group, _tags]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    f.FocusScope.of(context).unfocus();
    final original = _original;
    if (original == null) return;
    final tags = _tags.text
        .split(RegExp('[,，\\n]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    String? validation;
    if (!_reset.contains('title') && _title.text.trim().isEmpty) {
      validation = '请输入书名';
    }
    if (_title.text.trim().length > 300 || _author.text.trim().length > 300) {
      validation = '书名和作者最多 300 字';
    }
    if (_synopsis.text.trim().length > 20000) validation = '简介最多 20000 字';
    if (_group.text.trim().length > 80) validation = '分组名称最多 80 字';
    if (tags.length > 20 || tags.any((tag) => tag.length > 80)) {
      validation = '最多 20 个标签，每个最多 80 字';
    }
    setState(() => _validation = validation);
    if (validation != null) return;
    final JsonMap changes = {};
    void textChange(String name, String value, String previous) {
      if (_reset.contains(name)) {
        changes[name] = null;
      } else if (value.trim() != previous) {
        changes[name] = value.trim();
      }
    }

    textChange('title', _title.text, original.title);
    textChange('author', _author.text, original.author);
    textChange('synopsis', _synopsis.text, original.synopsis);
    final group = _group.text.trim();
    if (group != (original.groupName ?? '')) {
      changes['groupName'] = group.isEmpty ? null : group;
    }
    if (tags.join('\u0000') != original.tags.join('\u0000')) {
      changes['tags'] = tags;
    }
    if (_pinned != original.pinned) changes['pinned'] = _pinned;
    if (_readingState != original.readingState) {
      changes['readingState'] = _readingState;
    }
    if (changes.isEmpty) {
      f.Navigator.pop(context, false);
      return;
    }
    final saved = await _controller!.save(changes);
    if (mounted && saved) f.Navigator.pop(context, true);
  }

  f.Widget _button(String label, f.VoidCallback? onPressed,
      {bool primary = false}) {
    if (widget.mobile) {
      return primary
          ? m.FilledButton(onPressed: onPressed, child: m.Text(label))
          : m.TextButton(onPressed: onPressed, child: m.Text(label));
    }
    return primary
        ? f.FilledButton(onPressed: onPressed, child: f.Text(label))
        : f.Button(onPressed: onPressed, child: f.Text(label));
  }

  f.Widget _field(String name, String label, f.TextEditingController text,
      {int lines = 1, String? hint}) {
    final enabled = !_controller!.saving && !_reset.contains(name);
    final field = widget.mobile
        ? m.TextField(
            key: f.ValueKey('metadata-$name'),
            controller: text,
            enabled: enabled,
            maxLines: lines,
            magnifierConfiguration: m.TextMagnifierConfiguration.disabled,
            decoration: m.InputDecoration(
                labelText: label,
                hintText: hint,
                border: const m.OutlineInputBorder()))
        : f.InfoLabel(
            label: label,
            child: f.TextBox(
                key: f.ValueKey('metadata-$name'),
                controller: text,
                enabled: enabled,
                maxLines: lines,
                placeholder: hint));
    return f.Padding(
        padding: const f.EdgeInsets.only(bottom: 16),
        child:
            f.Column(crossAxisAlignment: f.CrossAxisAlignment.start, children: [
          field,
          if (_original!.overriddenFields.contains(name))
            _button(
                _reset.contains(name) ? '已选择恢复来源 · 撤销' : '恢复来源$label',
                _controller!.saving
                    ? null
                    : () => setState(() {
                          if (!_reset.add(name)) _reset.remove(name);
                        })),
        ]));
  }

  f.Widget _form() {
    final busy = _controller!.saving;
    return f
        .Column(crossAxisAlignment: f.CrossAxisAlignment.stretch, children: [
      const f.Text('分组、标签和阅读状态保存在当前账号，可在其他设备继续使用。'),
      const f.SizedBox(height: 20),
      _field('title', '书名', _title),
      _field('author', '作者', _author),
      _field('synopsis', '简介', _synopsis, lines: 5),
      _field('groupName', '分组', _group, hint: '例如：待读、收藏；留空为未分组'),
      _field('tags', '标签', _tags, hint: '以逗号或换行分隔', lines: 2),
      const f.Text('阅读状态'),
      const f.SizedBox(height: 6),
      if (widget.mobile)
        m.DropdownButtonFormField<String>(
            key: f.ValueKey('metadata-reading-state-$_readingState'),
            initialValue: _readingState,
            items: [
              for (final entry in readingStateLabels.entries)
                m.DropdownMenuItem(value: entry.key, child: m.Text(entry.value))
            ],
            onChanged:
                busy ? null : (value) => setState(() => _readingState = value!),
            decoration: const m.InputDecoration(border: m.OutlineInputBorder()))
      else
        f.ComboBox<String>(
            value: _readingState,
            items: [
              for (final entry in readingStateLabels.entries)
                f.ComboBoxItem(value: entry.key, child: f.Text(entry.value))
            ],
            onChanged: busy
                ? null
                : (value) => setState(() => _readingState = value!)),
      const f.SizedBox(height: 16),
      if (widget.mobile)
        m.SwitchListTile.adaptive(
            contentPadding: f.EdgeInsets.zero,
            title: const m.Text('置顶作品'),
            value: _pinned,
            onChanged: busy ? null : (value) => setState(() => _pinned = value))
      else
        f.ToggleSwitch(
            checked: _pinned,
            content: const f.Text('置顶作品'),
            onChanged:
                busy ? null : (value) => setState(() => _pinned = value)),
      const f.SizedBox(height: 16),
      if (_validation ?? _controller!.error case final String error) ...[
        f.Semantics(liveRegion: true, child: f.Text(error)),
        if (_controller!.error != null)
          _button('重新加载最新信息（会清除编辑内容）', busy ? null : _controller!.load),
        const f.SizedBox(height: 12),
      ],
      f.Wrap(spacing: 12, runSpacing: 8, children: [
        _button(busy ? '正在保存' : '保存修改', busy ? null : _save, primary: true),
        _button('取消', busy ? null : () => f.Navigator.pop(context, false)),
      ]),
    ]);
  }

  @override
  f.Widget build(f.BuildContext context) {
    final controller = _controller!;
    final content = f.SafeArea(
        child: f.Align(
            alignment: f.Alignment.topCenter,
            child: f.ConstrainedBox(
                constraints: const f.BoxConstraints(maxWidth: 720),
                child: f.SingleChildScrollView(
                    keyboardDismissBehavior:
                        f.ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const f.EdgeInsets.all(20),
                    child: controller.invalidated
                        ? f.Text(controller.error!)
                        : controller.loading
                            ? (widget.mobile
                                ? const m.Center(
                                    child: m.CircularProgressIndicator())
                                : const f.Center(child: f.ProgressRing()))
                            : _original == null
                                ? f.Column(children: [
                                    f.Text(controller.error ?? '正在加载作品信息'),
                                    _button('重新加载', controller.load)
                                  ])
                                : _form()))));
    if (widget.mobile) {
      return m.Scaffold(
          appBar: m.AppBar(title: const m.Text('编辑作品信息')), body: content);
    }
    return DesktopSubpage(
        title: '编辑作品信息',
        maxContentWidth: 720,
        backLabel: '返回书库',
        onBack: () => f.Navigator.pop(context, false),
        child: content);
  }
}
