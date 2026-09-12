import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../app/app_scope.dart';
import '../../core/models/translation_quality.dart';
import '../../shared/desktop_subpage.dart';
import 'quality_controls.dart';
import 'quality_glossary.dart';
import 'quality_records.dart';
import 'quality_text_editor.dart';
import 'translation_quality_controller.dart';

Future<bool?> showTranslationQualityEditor(f.BuildContext context,
        {required String bookId,
        required int chapterIndex,
        bool mobile = false}) =>
    f.Navigator.of(context).push<bool>(f.PageRouteBuilder<bool>(
        pageBuilder: (_, __, ___) => TranslationQualityPage(
            bookId: bookId, chapterIndex: chapterIndex, mobile: mobile)));

Future<bool?> showBookGlossaryEditor(f.BuildContext context,
        {required String bookId, bool mobile = false}) =>
    f.Navigator.of(context).push<bool>(f.PageRouteBuilder<bool>(
        pageBuilder: (_, __, ___) =>
            TranslationQualityPage.glossary(bookId: bookId, mobile: mobile)));

class TranslationQualityPage extends f.StatefulWidget {
  const TranslationQualityPage(
      {required this.bookId,
      required this.chapterIndex,
      this.mobile = false,
      super.key});
  const TranslationQualityPage.glossary(
      {required this.bookId, this.mobile = false, super.key})
      : chapterIndex = null;
  final String bookId;
  final int? chapterIndex;
  final bool mobile;
  @override
  f.State<TranslationQualityPage> createState() =>
      _TranslationQualityPageState();
}

class _TranslationQualityPageState extends f.State<TranslationQualityPage> {
  TranslationQualityController? _controller;
  ChapterTranslation? _loaded;
  final _source = f.TextEditingController();
  final _draft = f.TextEditingController();
  int _tab = 0;
  bool _permitExit = false;
  String? _validation;
  String? _suggestionDraft;
  f.TextSelection? _replacement;
  QualityControls get _ui => QualityControls(widget.mobile);
  bool get _dirty => _loaded != null && _draft.text != _loaded!.translatedText;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _controller = TranslationQualityController(AppScope.of(context).library,
        bookId: widget.bookId, chapterIndex: widget.chapterIndex)
      ..addListener(_changed);
    f.WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_controller!.load());
    });
  }

  void _changed() {
    if (!mounted) return;
    final controller = _controller!;
    if (controller.invalidated) {
      _source.clear();
      _draft.clear();
      _loaded = null;
      _suggestionDraft = null;
      _replacement = null;
      _validation = null;
    } else if (controller.chapter case final chapter?) {
      if (!identical(chapter, _loaded)) {
        _loaded = chapter;
        _source.text = chapter.sourceText;
        _draft.text = chapter.translatedText;
        _suggestionDraft = null;
        _replacement = null;
        _validation = null;
      }
    }
    setState(() {});
  }

  Future<void> _leave() async {
    final controller = _controller!;
    if (controller.busy) return;
    if (_dirty &&
        !await _ui.confirm(context, '放弃未保存的校对？', '本次草稿尚未保存到后端。确认后将放弃草稿并返回。',
            current: () => controller.usable, listenable: controller)) {
      return;
    }
    if (!mounted) return;
    setState(() => _permitExit = true);
    await f.WidgetsBinding.instance.endOfFrame;
    if (mounted) f.Navigator.of(context).pop(controller.changed);
  }

  Future<void> _reload() async {
    final controller = _controller!;
    if (_dirty &&
        !await _ui.confirm(context, '重新加载译文？', '重新加载将放弃当前草稿，并读取后端最新版本。',
            current: () => controller.usable, listenable: controller)) {
      return;
    }
    await controller.load();
  }

  Future<void> _retranslate() async {
    final selected = _source.selection;
    final replacement = _draft.selection;
    if (!selected.isValid || selected.isCollapsed || !replacement.isValid) {
      setState(() => _validation = '请选中一段原文，并在译文中选择替换范围或放置插入光标。');
      return;
    }
    int start, end;
    try {
      start = unicodeOffset(_source.text, selected.start);
      end = unicodeOffset(_source.text, selected.end);
      unicodeOffset(_draft.text, replacement.start);
      unicodeOffset(_draft.text, replacement.end);
    } on ArgumentError {
      setState(() => _validation = '文本选区无效，请重新选择。');
      return;
    }
    _suggestionDraft = _draft.text;
    _replacement = replacement;
    setState(() => _validation = null);
    await _controller!.retranslate(start, end);
  }

  void _applySuggestion() {
    final suggestion = _controller!.suggestion;
    final replacement = _replacement;
    if (suggestion == null ||
        replacement == null ||
        _suggestionDraft != _draft.text) {
      setState(() => _validation = '草稿已变化，请重新选择文本并生成候选。');
      return;
    }
    _draft.value = f.TextEditingValue(
        text: _draft.text
            .replaceRange(replacement.start, replacement.end, suggestion.text),
        selection: f.TextSelection.collapsed(
            offset: replacement.start + suggestion.text.length));
    _controller!.discardSuggestion();
    setState(() => _validation = null);
  }

  Future<void> _restore(TranslationRevision version) async {
    final controller = _controller!;
    final chapter = controller.chapter;
    if (!await _ui.confirm(
        context, '恢复历史译文？', '将恢复版本 ${version.revision}，并创建一个新版本。当前未保存草稿会被替换。',
        current: () =>
            controller.usable &&
            identical(controller.chapter, chapter) &&
            identical(controller.historical, version),
        listenable: controller)) {
      return;
    }
    await controller.restore(version);
  }

  f.Widget _content() {
    final controller = _controller!;
    return f.ListView(
        key: const f.ValueKey('translation-quality-scroll'),
        padding: const f.EdgeInsets.all(20),
        children: [
          f.Align(
              alignment: f.Alignment.topCenter,
              child: f.ConstrainedBox(
                  constraints: const f.BoxConstraints(maxWidth: 1200),
                  child: f.Column(
                      crossAxisAlignment: f.CrossAxisAlignment.start,
                      children: [
                        if (controller.busy)
                          widget.mobile
                              ? const m.LinearProgressIndicator()
                              : const f.ProgressBar(),
                        if (_validation ?? controller.error case final error?)
                          f.Padding(
                              padding: const f.EdgeInsets.only(bottom: 12),
                              child: _ui.notice(error, error: true)),
                        if (controller.message case final message?)
                          f.Padding(
                              padding: const f.EdgeInsets.only(bottom: 12),
                              child: _ui.notice(message)),
                        if (!controller.invalidated) ...[
                          _ui.button('重新加载', controller.busy ? null : _reload,
                              key: const f.ValueKey('quality-reload')),
                          if (widget.chapterIndex == null) ...[
                            const f.SizedBox(height: 20),
                            QualityGlossary(controller: controller, ui: _ui),
                          ] else if (controller.chapter
                              case final chapter?) ...[
                            const f.SizedBox(height: 12),
                            f.Text('${chapter.title} · 版本 ${chapter.revision}'),
                            const f.SizedBox(height: 12),
                            f.Wrap(spacing: 8, runSpacing: 8, children: [
                              for (final (index, label) in const [
                                '译文校对',
                                '术语表',
                                '历史版本',
                                '模型用量'
                              ].indexed)
                                _ui.button(
                                    label, () => setState(() => _tab = index),
                                    primary: _tab == index),
                            ]),
                            const f.SizedBox(height: 20),
                            switch (_tab) {
                              1 => QualityGlossary(
                                  controller: controller, ui: _ui),
                              2 => QualityHistory(
                                  controller: controller,
                                  ui: _ui,
                                  restore: _restore),
                              3 => QualityUsage(records: controller.usage),
                              _ => QualityTextEditor(
                                  controller: controller,
                                  ui: _ui,
                                  source: _source,
                                  draft: _draft,
                                  dirty: _dirty,
                                  onDraftChanged: (_) {
                                    _controller!.discardSuggestion();
                                    setState(() => _validation = null);
                                  },
                                  save: () => controller.save(_draft.text),
                                  retranslate: _retranslate,
                                  applySuggestion: _applySuggestion),
                            },
                          ] else if (!controller.busy &&
                              controller.error == null)
                            const f.Text('请选择已下载的小说章节。'),
                        ],
                      ]))),
        ]);
  }

  @override
  f.Widget build(f.BuildContext context) {
    final controller = _controller!;
    final title = widget.chapterIndex == null ? '术语与人名' : '译文质量';
    final page = widget.mobile
        ? m.Scaffold(
            appBar: m.AppBar(
                title: f.Text(title),
                leading: m.IconButton(
                    onPressed: controller.busy ? null : _leave,
                    tooltip: '返回',
                    icon: const m.Icon(m.Icons.arrow_back))),
            body: _content())
        : DesktopSubpage(
            title: title,
            maxContentWidth: 1240,
            backEnabled: !controller.busy,
            onBack: _leave,
            child: _content());
    return f.PopScope(
        canPop: _permitExit,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !controller.busy) unawaited(_leave());
        },
        child: page);
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    _controller?.dispose();
    _source.dispose();
    _draft.dispose();
    super.dispose();
  }
}
