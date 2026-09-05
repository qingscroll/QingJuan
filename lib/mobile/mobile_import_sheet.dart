import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/models/book.dart';
import 'mobile_sheet.dart';
import 'mobile_widgets.dart';

Future<Book?> showMobileImportSheet(BuildContext context) {
  return showMobileSheet<Book>(
    context: context,
    title: '添加书籍',
    subtitle: '网页地址或本地文件',
    child: const _ImportBookForm(),
  );
}

class _ImportBookForm extends StatefulWidget {
  const _ImportBookForm();

  @override
  State<_ImportBookForm> createState() => _ImportBookFormState();
}

class _ImportBookFormState extends State<_ImportBookForm> {
  final _urlController = TextEditingController();
  final _titleController = TextEditingController();
  String _kind = '长小说';
  String _language = '中文';
  String _downloadMode = 'on_demand';
  bool _translate = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _payload => <String, dynamic>{
        'sourceUrl': _urlController.text.trim(),
        'bookKind': _kind,
        'title': _titleController.text.trim(),
        'language': _language,
        'needTranslation': _translate,
        'downloadMode': _downloadMode,
      };

  bool get _isFanqie {
    if (_kind == '漫画') return false;
    final host = Uri.tryParse(_urlController.text.trim())?.host.toLowerCase();
    return host == 'fanqienovel.com' || host?.endsWith('.fanqienovel.com') == true;
  }

  Future<void> _importUrl() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final book = await AppScope.of(context).library.importFromSearch(_payload);
      if (mounted) Navigator.pop(context, book);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importLocal() async {
    if (_busy) return;
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: '小说和漫画文档',
          extensions: <String>['txt', 'text', 'docx', 'epub', 'pdf'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    final extension = file.name.split('.').last.toLowerCase();
    final kind = extension == 'pdf' ? '漫画' : _kind;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final book = await AppScope.of(context).library.importLocal(
        filePath: file.path,
        kind: kind,
        language: _language,
        translate: _translate,
        title: _titleController.text.trim().isEmpty
            ? file.name
            : _titleController.text.trim(),
      );
      if (mounted) Navigator.pop(context, book);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MobileCard(
          color: colors.tertiaryContainer,
          child: Text(
            '支持 TXT、DOCX、EPUB、PDF 和网页作品；远程解析任务在客户端收起后仍会继续。',
            style: MiuixTheme.of(context).textStyles.body2.copyWith(
                  color: colors.onTertiaryContainer,
                  height: 1.45,
                ),
          ),
        ),
        const SizedBox(height: 14),
        MiuixTextField(
          controller: _urlController,
          label: '作品地址',
          useLabelAsPlaceholder: true,
          singleLine: true,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        MiuixTextField(
          controller: _titleController,
          label: '自定义标题（可选）',
          useLabelAsPlaceholder: true,
          singleLine: true,
          enabled: !_busy,
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: _choice('类型', const <String>['长小说', '轻小说', '漫画'],
                  _kind, (value) => setState(() => _kind = value)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _choice('语言', const <String>['中文', '英文', '日文'],
                  _language, (value) => setState(() => _language = value)),
            ),
          ],
        ),
        if (_isFanqie) ...<Widget>[
          const SizedBox(height: 12),
          _choice(
            '番茄正文获取方式',
            const <String>['on_demand', 'all'],
            _downloadMode,
            (value) => setState(() => _downloadMode = value),
            labels: const <String>['边看边下', '下载全部'],
          ),
        ],
        MiuixSwitchPreference(
          title: '导入后启用翻译',
          summary: '使用当前后端已配置的翻译服务',
          value: _translate,
          enabled: !_busy,
          onChanged: (value) => setState(() => _translate = value),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: MiuixTheme.of(context).textStyles.footnote1.copyWith(
                  color: colors.error,
                  height: 1.4,
                ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: MiuixButton(
                onPressed: _busy ? null : _importLocal,
                child: const MiuixText('本地文件'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: MiuixButton(
                onPressed: _busy || _urlController.text.trim().isEmpty
                    ? null
                    : _importUrl,
                colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                child: MiuixText(_busy ? '正在导入' : '导入'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _choice(
    String label,
    List<String> values,
    String value,
    ValueChanged<String> onChanged, {
    List<String>? labels,
  }) {
    return MiuixOverlayDropdownPreference(
      title: label,
      items: labels ?? values,
      selectedIndex: values.indexOf(value).clamp(0, values.length - 1),
      onSelectedIndexChange: (index) => onChanged(values[index]),
      enabled: !_busy,
    );
  }
}

