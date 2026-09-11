import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/models/book.dart';
import '../core/models/book_import_source.dart';
import 'mobile_action_button.dart';
import 'mobile_import_progress.dart';
import 'mobile_preferences.dart';
import 'mobile_sheet.dart';

Future<Book?> showMobileImportSheet(BuildContext context) async {
  final mode = await showMobileSheet<String>(
    context: context,
    title: '导入作品',
    child: Column(children: <Widget>[
      ListTile(
          leading: const Icon(Icons.link_rounded),
          title: const Text('作品链接'),
          subtitle: const Text('粘贴作品地址，也支持禁漫本子号'),
          minVerticalPadding: 16,
          onTap: () => Navigator.pop(context, 'link')),
      const Divider(height: 1),
      ListTile(
          leading: const Icon(Icons.numbers_rounded),
          title: const Text('禁漫本子号'),
          subtitle: const Text('输入编号，获取章节和漫画图片'),
          minVerticalPadding: 16,
          onTap: () => Navigator.pop(context, 'comic18')),
      const Divider(height: 1),
      ListTile(
          leading: const Icon(Icons.upload_file_outlined),
          title: const Text('本地文件'),
          subtitle: const Text('TXT、DOCX、EPUB、PDF'),
          minVerticalPadding: 16,
          onTap: () => Navigator.pop(context, 'local')),
    ]),
  );
  if (!context.mounted || mode == null) return null;
  return Navigator.of(context).push<Book>(MaterialPageRoute<Book>(
      builder: (_) => MobileImportPage(
          local: mode == 'local', comic18: mode == 'comic18')));
}

/// Complex import options have their own route, so keyboard and back navigation
/// remain predictable while the lightweight entry chooser stays short.
class MobileImportPage extends StatefulWidget {
  const MobileImportPage({this.local = false, this.comic18 = false, super.key});
  final bool local;
  final bool comic18;
  @override
  State<MobileImportPage> createState() => _MobileImportPageState();
}

class _MobileImportPageState extends State<MobileImportPage> {
  final _urlController = TextEditingController();
  final _titleController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  XFile? _file;
  String _kind = '长小说';
  String _language = '中文';
  String _downloadMode = 'on_demand';
  bool _translate = false;
  bool _busy = false;
  bool _submitted = false;
  bool _selectingFile = false;
  String? _error;

  bool get _isComic18 =>
      !widget.local && (widget.comic18 || isComic18Source(_urlController.text));

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  bool get _isFanqie {
    if (_kind == '漫画') return false;
    final host = Uri.tryParse(_urlController.text.trim())?.host.toLowerCase();
    return host == 'fanqienovel.com' ||
        host?.endsWith('.fanqienovel.com') == true;
  }

  Future<void> _chooseFile() async {
    if (_busy || _selectingFile) return;
    setState(() => _selectingFile = true);
    try {
      final file = await openFile(acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
            label: '小说和漫画文档',
            extensions: <String>['txt', 'text', 'docx', 'epub', 'pdf']),
      ]);
      if (!mounted || file == null) return;
      setState(() {
        _file = file;
        if (file.name.toLowerCase().endsWith('.pdf')) _kind = '漫画';
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '无法读取文件，请重新选择：$error');
    } finally {
      if (mounted) setState(() => _selectingFile = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    if (widget.local && _file == null) {
      setState(() => _error = '请先选择要导入的文件。');
      return;
    }
    final scope = AppScope.of(context);
    if (!widget.local && scope.library.hasActiveLinkJob) {
      setState(() => _error = '已有作品正在导入，请在下方查看进度，完成后再添加。');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.local) {
        final file = _file!;
        final book = await scope.library.importLocal(
            filePath: file.path,
            kind: _kind,
            language: _language,
            translate: _translate &&
                scope.backend.translationModelCheck?.available == true,
            title: _titleController.text.trim().isEmpty
                ? file.name
                : _titleController.text.trim());
        if (mounted) Navigator.pop(context, book);
      } else {
        await scope.library.startLinkJob('import', <String, dynamic>{
          ...bookImportSourcePayload(_urlController.text, _kind),
          'title': _titleController.text.trim(),
          'language': _language,
          'needTranslation': _translate &&
              scope.backend.translationModelCheck?.available == true,
          'downloadMode': _isComic18 ? 'all' : _downloadMode,
        });
        if (mounted) setState(() => _submitted = true);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '导入未完成：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final theme = MiuixTheme.of(context);
    return Scaffold(
      backgroundColor: theme.colors.background,
      appBar: AppBar(
          title: Text(widget.local
              ? '导入文件'
              : widget.comic18
                  ? '禁漫本子号'
                  : '导入链接'),
          backgroundColor: theme.colors.background,
          foregroundColor: theme.colors.onBackground,
          elevation: 0,
          scrolledUnderElevation: 0),
      body: SafeArea(
          top: false,
          child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: AnimatedBuilder(
                    animation: Listenable.merge(
                        <Listenable>[scope.library, scope.backend]),
                    builder: (context, _) {
                      final canTranslate =
                          scope.backend.translationModelCheck?.available ==
                              true;
                      final progress = scope.library.importProgress;
                      return Form(
                          key: _formKey,
                          child: SingleChildScrollView(
                              padding:
                                  const EdgeInsets.fromLTRB(20, 12, 20, 32),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  Text(
                                      widget.local
                                          ? '把设备上的作品加入个人书库。'
                                          : _isComic18
                                              ? '输入本子号，青卷会获取作品目录和漫画图片。导入任务收起后仍会继续。'
                                              : '填写作品地址或禁漫本子号，青卷会在服务端解析目录。',
                                      style: theme.textStyles.body2.copyWith(
                                          color:
                                              theme.colors.onBackgroundVariant,
                                          height: 1.5)),
                                  const SizedBox(height: 20),
                                  if (!_submitted) ...<Widget>[
                                    if (widget.local)
                                      MobilePreferenceGroup(children: <Widget>[
                                        ListTile(
                                            leading: const Icon(
                                                Icons.description_outlined),
                                            title: Text(
                                                _file?.name ?? '选择小说或漫画文件'),
                                            subtitle: Text(_file == null
                                                ? 'TXT、DOCX、EPUB、PDF'
                                                : '文件会上传到当前服务'),
                                            minVerticalPadding: 16,
                                            onTap: _busy || _selectingFile
                                                ? null
                                                : _chooseFile,
                                            trailing: const Icon(
                                                Icons.chevron_right_rounded)),
                                      ])
                                    else
                                      TextFormField(
                                        key:
                                            const ValueKey('mobile-import-url'),
                                        controller: _urlController,
                                        enabled: !_busy,
                                        keyboardType: widget.comic18
                                            ? TextInputType.number
                                            : TextInputType.url,
                                        textInputAction: TextInputAction.next,
                                        autocorrect: false,
                                        maxLines: 2,
                                        minLines: 1,
                                        decoration: InputDecoration(
                                            labelText: widget.comic18
                                                ? '本子号'
                                                : '作品地址 / 禁漫本子号',
                                            hintText: widget.comic18
                                                ? '输入纯数字编号'
                                                : 'https://... 或纯数字本子号',
                                            helperText: widget.comic18
                                                ? '输入专辑编号，不是章节编号'
                                                : '使用作品主页、目录地址，或纯数字本子号'),
                                        onChanged: (_) => setState(() {}),
                                        validator: (value) =>
                                            bookImportSourceError(value,
                                                albumOnly: widget.comic18),
                                      ),
                                    const SizedBox(height: 20),
                                    TextFormField(
                                        controller: _titleController,
                                        enabled: !_busy,
                                        textInputAction: TextInputAction.done,
                                        decoration: const InputDecoration(
                                            labelText: '作品标题（可选）',
                                            helperText: '留空时使用解析得到的标题')),
                                    const SizedBox(height: 24),
                                    MobilePreferenceGroup(
                                        title: '作品信息',
                                        children: <Widget>[
                                          _choice(
                                              '内容类型',
                                              const <String>[
                                                '长小说',
                                                '轻小说',
                                                '漫画'
                                              ],
                                              _isComic18 ? '漫画' : _kind,
                                              (value) =>
                                                  setState(() => _kind = value),
                                              enabled: !_isComic18),
                                          _choice(
                                              '原文语言',
                                              const <String>['中文', '英文', '日文'],
                                              _language,
                                              (value) => setState(
                                                  () => _language = value)),
                                          if (_isFanqie && !widget.local)
                                            _choice(
                                                '正文下载',
                                                const <String>[
                                                  'on_demand',
                                                  'all'
                                                ],
                                                _downloadMode,
                                                (value) => setState(() =>
                                                    _downloadMode = value),
                                                labels: const <String>[
                                                  '阅读时下载',
                                                  '下载全部章节'
                                                ]),
                                        ]),
                                    const SizedBox(height: 24),
                                    MobilePreferenceGroup(
                                        title: '翻译',
                                        children: <Widget>[
                                          SwitchListTile.adaptive(
                                              title: const Text('导入后翻译'),
                                              subtitle: Text(canTranslate
                                                  ? '使用当前服务的翻译模型'
                                                  : scope
                                                          .backend
                                                          .translationModelCheck
                                                          ?.message ??
                                                      '翻译服务尚未验证，可先导入阅读原文'),
                                              value: _translate && canTranslate,
                                              onChanged: _busy || !canTranslate
                                                  ? null
                                                  : (value) => setState(() =>
                                                      _translate = value)),
                                        ]),
                                  ],
                                  if (_busy && widget.local) ...<Widget>[
                                    const SizedBox(height: 24),
                                    Semantics(
                                        liveRegion: true,
                                        child: Text(progress != null &&
                                                progress < 1
                                            ? '正在上传 ${((progress) * 100).round()}%'
                                            : '上传完成，正在解析文件…')),
                                    const SizedBox(height: 8),
                                    LinearProgressIndicator(
                                        value: progress != null && progress < 1
                                            ? progress
                                            : null),
                                    const SizedBox(height: 8),
                                    Text('文件上传期间请保持应用开启。',
                                        style: theme.textStyles.footnote1
                                            .copyWith(
                                                color: theme.colors
                                                    .onBackgroundVariant)),
                                  ],
                                  if (_error != null) ...<Widget>[
                                    const SizedBox(height: 20),
                                    Semantics(
                                        liveRegion: true,
                                        child: Text(_error!,
                                            style: TextStyle(
                                                color: theme.colors.error,
                                                height: 1.5))),
                                  ],
                                  const SizedBox(height: 24),
                                  if (scope.library.linkJob != null &&
                                      !widget.local)
                                    MobileImportProgress(
                                        onOpenBook: (book) =>
                                            Navigator.pop(context, book)),
                                  if (_submitted)
                                    MobileActionButton(
                                        onPressed: () => Navigator.pop(context),
                                        icon: Icons.auto_stories_outlined,
                                        child: const Text('返回书库'))
                                  else
                                    MobileActionButton(
                                        key: const ValueKey(
                                            'mobile-import-submit'),
                                        onPressed: _busy ? null : _submit,
                                        busy: _busy,
                                        icon: Icons.library_add_outlined,
                                        child: Text(_busy ? '正在提交' : '加入书库')),
                                ],
                              )));
                    }),
              ))),
    );
  }

  Widget _choice(String label, List<String> values, String value,
          ValueChanged<String> onChanged,
          {List<String>? labels, bool enabled = true}) =>
      MiuixOverlayDropdownPreference(
        title: label,
        items: labels ?? values,
        selectedIndex: values.indexOf(value).clamp(0, values.length - 1),
        onSelectedIndexChange: (index) => onChanged(values[index]),
        enabled: !_busy && enabled,
      );
}
