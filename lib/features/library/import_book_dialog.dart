import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_scope.dart';
import '../../app/app_state.dart';
import '../../core/models/book.dart';
import '../../core/models/book_import_source.dart';
import '../../core/models/link_job.dart';
import '../../shared/app_surface.dart';
import '../../shared/mobile_sheet.dart';
import '../../shared/responsive.dart';
import 'library_controller.dart';

const _localNovelFiles = XTypeGroup(
  label: '小说文档',
  extensions: <String>['txt', 'text', 'docx', 'epub'],
);
const _localMangaFiles = XTypeGroup(
  label: 'PDF 漫画',
  extensions: <String>['pdf'],
);

Future<Book?> showImportBookDialog(BuildContext context) {
  final scope = AppScope.of(context);
  final controller = scope.library;
  final usesLinuxBackend =
      scope.appState.connectionMode == BackendConnectionMode.remote;
  if (usesMobileUi(context)) {
    return showMobileSheet<Book>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ImportBookDialog(
        controller: controller,
        usesLinuxBackend: usesLinuxBackend,
      ),
    );
  }
  return showDialog<Book>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ImportBookDialog(
      controller: controller,
      usesLinuxBackend: usesLinuxBackend,
    ),
  );
}

class _ImportBookDialog extends StatefulWidget {
  const _ImportBookDialog({
    required this.controller,
    required this.usesLinuxBackend,
  });

  final LibraryController controller;
  final bool usesLinuxBackend;

  @override
  State<_ImportBookDialog> createState() => _ImportBookDialogState();
}

class _ImportBookDialogState extends State<_ImportBookDialog> {
  final _urlController = TextEditingController();
  final _titleController = TextEditingController();
  final _logScrollController = ScrollController();
  String _kind = '长小说';
  String _language = '中文';
  String _downloadMode = 'on_demand';
  bool _translate = false;
  bool _loading = false;
  bool _restoredPayload = false;
  int _visibleLogCount = 0;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredPayload) return;
    _restoredPayload = true;
    final payload = widget.controller.linkJobPayload;
    if (payload == null) return;
    _urlController.text =
        payload['albumId'] as String? ?? payload['sourceUrl'] as String? ?? '';
    _titleController.text = payload['title'] as String? ?? '';
    _kind = payload['bookKind'] as String? ?? _kind;
    _language = payload['language'] as String? ?? _language;
    _downloadMode = payload['downloadMode'] as String? ?? _downloadMode;
    _translate = payload['needTranslation'] as bool? ?? _translate;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  bool get _isFanqieNovel {
    if (_kind == '漫画') return false;
    final uri = Uri.tryParse(_urlController.text.trim());
    final host = uri?.host.toLowerCase() ?? '';
    return host == 'fanqienovel.com' || host.endsWith('.fanqienovel.com');
  }

  JsonMap get _payload => <String, dynamic>{
        ...bookImportSourcePayload(_urlController.text, _kind),
        'title': _titleController.text.trim(),
        'language': _language,
        'needTranslation': _translate,
        'downloadMode': _isFanqieNovel ? _downloadMode : 'all',
      };

  Future<void> _previewRemote() async {
    final error = bookImportSourceError(_urlController.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    await _run(() async {
      await widget.controller.startLinkJob('preview', _payload);
    });
  }

  Future<void> _importRemote() async {
    final error = bookImportSourceError(_urlController.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    await _run(() async {
      await widget.controller.startLinkJob('import', _payload);
    });
  }

  Future<void> _importLocal() async {
    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[
        _localNovelFiles,
        _localMangaFiles,
      ],
    );
    if (file == null) return;
    final suffix = file.name.split('.').last.toLowerCase();
    final importKind = suffix == 'pdf'
        ? '漫画'
        : _kind == '漫画'
            ? '长小说'
            : _kind;
    await _run(() async {
      final book = await widget.controller.importLocal(
        filePath: file.path,
        kind: importKind,
        language: _language,
        translate: _translate,
        title: _titleController.text,
      );
      if (mounted) _close(book);
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final job = controller.linkJob;
        final busy = _loading || (job?.isActive ?? false);
        final preview = job?.preview;
        final importedBook = job?.book;
        _scrollLogsAfterBuild(job?.logs.length ?? 0);
        final content = SingleChildScrollView(
          padding: usesMobileUi(context)
              ? const EdgeInsets.fromLTRB(16, 14, 16, 18)
              : EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const FeatureHero(
                icon: FluentIcons.library,
                title: '把新作品放进书架',
                message: '支持网页地址、禁漫本子号、TXT、DOCX、EPUB 小说与 PDF 漫画；远程解析任务收起后仍会继续。',
              ),
              if (controller.importProgress case final progress?) ...<Widget>[
                const SizedBox(height: 12),
                ProgressBar(value: (progress * 100).clamp(0, 100)),
                const SizedBox(height: 4),
                Text(
                    '正在上传 ${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%'),
              ],
              const SizedBox(height: 18),
              InfoLabel(
                label: '作品地址 / 禁漫本子号',
                child: TextBox(
                  key: const ValueKey('import-book-url'),
                  controller: _urlController,
                  magnifierConfiguration:
                      textInputMagnifierConfiguration(context),
                  placeholder: 'https://... 或纯数字本子号',
                  enabled: !busy,
                  onChanged: busy ? null : (_) => setState(() {}),
                ),
              ),
              if (isComic18Source(_urlController.text)) ...<Widget>[
                const SizedBox(height: 6),
                const Text('已识别为禁漫作品，将获取章节和图片并加入漫画书架。'),
              ],
              const SizedBox(height: 12),
              InfoLabel(
                label: '自定义标题（可选）',
                child: TextBox(
                  controller: _titleController,
                  magnifierConfiguration:
                      textInputMagnifierConfiguration(context),
                  enabled: !busy,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: InfoLabel(
                      label: '类型',
                      child: ComboBox<String>(
                        value:
                            isComic18Source(_urlController.text) ? '漫画' : _kind,
                        isExpanded: true,
                        items: const <ComboBoxItem<String>>[
                          ComboBoxItem(value: '长小说', child: Text('长小说')),
                          ComboBoxItem(value: '轻小说', child: Text('轻小说')),
                          ComboBoxItem(value: '漫画', child: Text('漫画')),
                        ],
                        onChanged: busy || isComic18Source(_urlController.text)
                            ? null
                            : (value) => setState(() => _kind = value ?? _kind),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InfoLabel(
                      label: '语言',
                      child: ComboBox<String>(
                        value: _language,
                        isExpanded: true,
                        items: const <ComboBoxItem<String>>[
                          ComboBoxItem(value: '中文', child: Text('中文')),
                          ComboBoxItem(value: '英文', child: Text('英文')),
                          ComboBoxItem(value: '日文', child: Text('日文')),
                        ],
                        onChanged: busy
                            ? null
                            : (value) =>
                                setState(() => _language = value ?? _language),
                      ),
                    ),
                  ),
                ],
              ),
              if (_isFanqieNovel) ...<Widget>[
                const SizedBox(height: 14),
                InfoLabel(
                  label: '番茄正文获取方式',
                  child: ComboBox<String>(
                    value: _downloadMode,
                    isExpanded: true,
                    items: const <ComboBoxItem<String>>[
                      ComboBoxItem(
                        value: 'on_demand',
                        child: Text('边看边下（默认）'),
                      ),
                      ComboBoxItem(
                        value: 'all',
                        child: Text('立即下载全部正文'),
                      ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(
                              () => _downloadMode = value ?? _downloadMode,
                            ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _downloadMode == 'on_demand'
                      ? widget.usesLinuxBackend
                          ? '快速加入书架；所选章节会立即优先获取并准备下一章，Linux 服务器退出客户端后仍会继续缓存全书。'
                          : '快速加入书架；打开章节时下载当前章，并在后台预取后续 20 章。'
                      : '导入时下载全部正文；长篇小说耗时较久，但完成后可完整离线阅读。',
                  style: FluentTheme.of(context).typography.caption,
                ),
              ],
              const SizedBox(height: 14),
              ToggleSwitch(
                checked: _translate,
                onChanged:
                    busy ? null : (value) => setState(() => _translate = value),
                content: const Text('导入后启用翻译'),
              ),
              const SizedBox(height: 16),
              AppSurface(
                tone: AppSurfaceTone.muted,
                padding: const EdgeInsets.all(10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    Button(
                      onPressed: busy ? null : _importLocal,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(FluentIcons.folder_open, size: 15),
                          SizedBox(width: 7),
                          Text('导入本地文件'),
                        ],
                      ),
                    ),
                    Button(
                      onPressed: busy ? null : _previewRemote,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(FluentIcons.view, size: 15),
                          SizedBox(width: 7),
                          Text('预览'),
                        ],
                      ),
                    ),
                    if (job != null && !job.isActive)
                      Button(
                        onPressed: controller.clearLinkJob,
                        child: const Text('新建任务'),
                      ),
                  ],
                ),
              ),
              if (job != null) ...<Widget>[
                const SizedBox(height: 18),
                _LinkJobProgress(
                    job: job, scrollController: _logScrollController),
              ],
              if (preview != null) ...<Widget>[
                const SizedBox(height: 14),
                InfoBar(
                  title: Text(preview.title),
                  content:
                      Text('${preview.author} · ${preview.chapterCount} 章'),
                  severity: InfoBarSeverity.success,
                ),
              ],
              if (importedBook != null) ...<Widget>[
                const SizedBox(height: 14),
                InfoBar(
                  title: const Text('导入完成'),
                  content: Text('《${importedBook.title}》已经加入书架。'),
                  severity: InfoBarSeverity.success,
                ),
              ],
              if (_error != null || controller.linkJobConnectionError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: InfoBar(
                    title: const Text('操作失败'),
                    content:
                        Text(_error ?? controller.linkJobConnectionError ?? ''),
                    severity: InfoBarSeverity.error,
                  ),
                ),
            ],
          ),
        );
        final actions = <Widget>[
          Button(
            onPressed: _loading ? null : _close,
            child: Text(job?.isActive ?? false ? '收起' : '取消'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : importedBook != null
                    ? () => _close(importedBook)
                    : _importRemote,
            child: Text(importedBook != null ? '打开书籍' : '导入'),
          ),
        ];
        if (usesMobileUi(context)) {
          return MobileSheet(
            title: '添加书籍',
            subtitle: '网页地址、禁漫本子号或本地文件',
            trailing: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: ProgressRing(strokeWidth: 2.5),
                  )
                : null,
            onClose: _loading ? null : _close,
            actions: actions,
            child: content,
          );
        }
        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 660),
          title: Row(
            children: <Widget>[
              const Expanded(child: Text('添加书籍')),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: ProgressRing(strokeWidth: 3, value: null),
                ),
            ],
          ),
          content: content,
          actions: actions,
        );
      },
    );
  }

  void _scrollLogsAfterBuild(int count) {
    if (count == _visibleLogCount) return;
    _visibleLogCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScrollController.hasClients) return;
      _logScrollController.jumpTo(
        _logScrollController.position.maxScrollExtent,
      );
    });
  }

  void _close([Book? book]) {
    Navigator.of(context, rootNavigator: true).pop(book);
  }
}

class _LinkJobProgress extends StatelessWidget {
  const _LinkJobProgress({required this.job, required this.scrollController});

  final LinkJob job;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final failed = job.isFailed;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.resources.subtleFillColorSecondary,
        border: Border.all(color: theme.resources.cardStrokeColorDefault),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(failed ? FluentIcons.error : FluentIcons.processing),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  failed ? '链接任务失败' : job.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${job.progress.round()}%'),
            ],
          ),
          const SizedBox(height: 10),
          ProgressBar(value: job.progress.clamp(0, 100)),
          const SizedBox(height: 14),
          Text('实时日志', style: theme.typography.bodyStrong),
          const SizedBox(height: 8),
          SizedBox(
            height: 150,
            child: job.logs.isEmpty
                ? const Center(child: Text('等待后端返回进度…'))
                : ListView.builder(
                    controller: scrollController,
                    itemCount: job.logs.length,
                    itemBuilder: (context, index) {
                      final log = job.logs[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '${log.createdAt}  ${log.message}',
                          style: theme.typography.caption,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
