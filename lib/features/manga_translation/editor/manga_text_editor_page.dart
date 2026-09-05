import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';

import '../manga_translation_controller.dart';
import '../manga_translation_models.dart';
import 'manga_text_editor_models.dart';

/// 漫画翻译后的人工校对工作台。
///
/// 工程仍由 [MangaTranslationController] 负责落盘和重新渲染；本页面只修改
/// 文本区域数据，因此保存不会额外调用 OCR 或翻译模型。
class MangaTextEditorPage extends StatefulWidget {
  const MangaTextEditorPage({
    required this.controller,
    required this.files,
    required this.initialFile,
    super.key,
  });

  final MangaTranslationController controller;
  final List<MangaTranslationFile> files;
  final MangaTranslationFile initialFile;

  @override
  State<MangaTextEditorPage> createState() => _MangaTextEditorPageState();
}

enum _CompactPane { pages, canvas, regions }

class _MangaTextEditorPageState extends State<MangaTextEditorPage> {
  late final List<MangaTranslationFile> _files;
  late int _fileIndex;
  MangaTextEditorProject? _project;
  MangaTextEditorRegion? _selectedRegion;
  Size _imageSize = const Size(1, 1);
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _showUntranslatedOnly = false;
  bool _showRendered = false;
  bool _addRegionMode = false;
  _CompactPane _compactPane = _CompactPane.canvas;
  String? _renderedPath;
  String? _error;
  String? _notice;
  InfoBarSeverity _noticeSeverity = InfoBarSeverity.info;

  MangaTranslationFile get _file => _files[_fileIndex];

  List<MangaTextEditorRegion> get _visibleRegions {
    final regions = _project?.regions ?? const <MangaTextEditorRegion>[];
    if (!_showUntranslatedOnly) return regions;
    return regions.where((region) => region.isUntranslated).toList();
  }

  String get _displayImagePath {
    if (_showRendered) {
      final candidate =
          _renderedPath ?? MangaWorkspacePaths.forSource(_file.path).resultPath;
      if (File(candidate).existsSync()) return candidate;
    }
    return _file.path;
  }

  @override
  void initState() {
    super.initState();
    _files = List<MangaTranslationFile>.of(widget.files);
    if (_files.isEmpty) _files.add(widget.initialFile);
    _fileIndex = _files.indexWhere(
      (candidate) => candidate.path == widget.initialFile.path,
    );
    if (_fileIndex < 0) {
      _files.insert(0, widget.initialFile);
      _fileIndex = 0;
    }
    unawaited(_loadFile(_fileIndex, saveCurrent: false));
  }

  Future<void> _loadFile(int index, {bool saveCurrent = true}) async {
    if (_saving || index < 0 || index >= _files.length) return;
    if (saveCurrent && _dirty) {
      final saved = await _saveProject(showNotice: false);
      if (!saved) return;
    }
    setState(() {
      _fileIndex = index;
      _loading = true;
      _error = null;
      _notice = null;
      _project = null;
      _selectedRegion = null;
      _showRendered = false;
      _renderedPath = null;
      _addRegionMode = false;
    });
    try {
      final document = await widget.controller.loadTextEditorProject(_file);
      final project = MangaTextEditorProject.fromDocument(
        document,
        sourcePath: _file.path,
      );
      final imageSize = await _resolveImageSize(
        _file.path,
        width: project.originalWidth,
        height: project.originalHeight,
      );
      if (!mounted || index != _fileIndex) return;
      final regions = project.regions;
      setState(() {
        _files[index] = _files[index].copyWith(
          hasProject: true,
          message: '文本工程已就绪',
        );
        _project = project;
        _imageSize = imageSize;
        _selectedRegion = regions.isEmpty ? null : regions.first;
        _dirty = false;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || index != _fileIndex) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<Size> _resolveImageSize(
    String filePath, {
    int? width,
    int? height,
  }) async {
    if (width != null && height != null && width > 0 && height > 0) {
      return Size(width.toDouble(), height.toDouble());
    }
    final bytes = await File(filePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        return Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  void _markDirty({bool refresh = true}) {
    if (!mounted) return;
    if (refresh) {
      setState(() {
        _dirty = true;
        _notice = null;
      });
    } else {
      _dirty = true;
      _notice = null;
    }
  }

  Future<bool> _saveProject({bool showNotice = true}) async {
    final project = _project;
    if (project == null || _saving) return false;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.saveTextEditorProject(
        _file,
        project.toDocument(),
      );
      if (!mounted) return true;
      setState(() {
        _files[_fileIndex] = _file.copyWith(
          hasProject: true,
          message: '文本修改已保存，等待重新渲染',
        );
        _saving = false;
        _dirty = false;
        if (showNotice) {
          _notice = '工程已保存。你可以继续修改，或重新渲染查看成图。';
          _noticeSeverity = InfoBarSeverity.success;
        }
      });
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() {
        _saving = false;
        _error = '保存失败：$error';
      });
      return false;
    }
  }

  Future<void> _renderProject() async {
    final project = _project;
    if (project == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _notice = '正在修复原文字并重新渲染译文……';
      _noticeSeverity = InfoBarSeverity.info;
    });
    try {
      final result = await widget.controller.renderTextEditorProject(
        _file,
        project.toDocument(),
      );
      if (!mounted) return;
      setState(() {
        _files[_fileIndex] = _file.copyWith(
          hasProject: true,
          outputPath: result.resultPath,
          message: result.message,
        );
        _saving = false;
        _dirty = false;
        _renderedPath = result.resultPath;
        _showRendered = true;
        _notice = result.message.isEmpty ? '已重新渲染译文。' : result.message;
        _noticeSeverity = result.bookshelfBound && !result.bookshelfWritten
            ? InfoBarSeverity.warning
            : InfoBarSeverity.success;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '重新渲染失败：$error';
        _notice = null;
      });
    }
  }

  Future<void> _close() async {
    if (_dirty && !await _saveProject(showNotice: false)) return;
    if (mounted) Navigator.of(context).pop();
  }

  void _selectRegion(MangaTextEditorRegion region) {
    setState(() {
      _selectedRegion = region;
      if (_compactPane == _CompactPane.canvas &&
          MediaQuery.sizeOf(context).width < 820) {
        _compactPane = _CompactPane.regions;
      }
    });
  }

  void _addRegion(MangaTextRegionBounds bounds) {
    final project = _project;
    if (project == null) return;
    final region = project.addRegion(bounds);
    setState(() {
      _selectedRegion = region;
      _addRegionMode = false;
      _dirty = true;
      _notice = '已新增空白文字区域，请在右侧填写译文。';
      _noticeSeverity = InfoBarSeverity.info;
      if (MediaQuery.sizeOf(context).width < 820) {
        _compactPane = _CompactPane.regions;
      }
    });
  }

  void _removeSelectedRegion() {
    final project = _project;
    final selected = _selectedRegion;
    if (project == null || selected == null) return;
    final currentRegions = project.regions;
    final index = currentRegions.indexWhere(
      (region) => identical(region.raw, selected.raw),
    );
    if (!project.removeRegion(selected)) return;
    final remainingRegions = project.regions;
    setState(() {
      if (remainingRegions.isEmpty) {
        _selectedRegion = null;
      } else {
        _selectedRegion = remainingRegions[
            math.min(math.max(index, 0), remainingRegions.length - 1)];
      }
      _dirty = true;
      _notice = '区域已删除；保存后写入工程。';
      _noticeSeverity = InfoBarSeverity.warning;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return ScaffoldPage(
      key: const ValueKey('manga-text-editor-page'),
      padding: EdgeInsets.zero,
      content: ColoredBox(
        color: theme.micaBackgroundColor,
        child: Column(
          children: <Widget>[
            _buildHeader(context),
            if (_error != null || _notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: InfoBar(
                  key: const ValueKey('manga-text-editor-message'),
                  title: Text(_error == null ? '文本工作台' : '操作未完成'),
                  content: Text(_error ?? _notice!),
                  severity:
                      _error == null ? _noticeSeverity : InfoBarSeverity.error,
                  onClose: () => setState(() {
                    _error = null;
                    _notice = null;
                  }),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: _loading
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            ProgressRing(),
                            SizedBox(height: 12),
                            Text('正在准备文本工程……'),
                          ],
                        ),
                      )
                    : _project == null
                        ? _buildLoadFailure(theme)
                        : LayoutBuilder(
                            builder: (context, constraints) =>
                                _buildWorkbench(constraints.maxWidth),
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = FluentTheme.of(context);
    final title = Row(
      children: <Widget>[
        IconButton(
          key: const ValueKey('close-manga-text-editor'),
          icon: const Icon(FluentIcons.back, size: 16),
          onPressed: _saving ? null : () => unawaited(_close()),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      '漫画文本工作台 · ${_file.name}',
                      key: const ValueKey('manga-text-editor-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.subtitle,
                    ),
                  ),
                  if (_dirty) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      '未保存',
                      style: theme.typography.caption?.copyWith(
                        color: const Color(0xFF9D5D00),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '点击文字框修改；OCR 漏字处可用“框选新增”人工补译。',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.caption?.copyWith(
                  color: theme.resources.textFillColorSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      children: <Widget>[
        ToggleButton(
          key: const ValueKey('toggle-untranslated-regions'),
          checked: _showUntranslatedOnly,
          onChanged: _project == null
              ? null
              : (checked) => setState(() => _showUntranslatedOnly = checked),
          child: Text(
            _project == null ? '只看未翻译' : '未翻译 ${_project!.untranslatedCount}',
          ),
        ),
        ToggleButton(
          key: const ValueKey('toggle-manga-region-draw'),
          checked: _addRegionMode,
          onChanged: _project == null || _saving
              ? null
              : (checked) => setState(() {
                    _addRegionMode = checked;
                    _compactPane = _CompactPane.canvas;
                  }),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(FluentIcons.add, size: 13),
              SizedBox(width: 6),
              Text('框选新增'),
            ],
          ),
        ),
        Button(
          key: const ValueKey('delete-manga-text-region'),
          onPressed:
              _selectedRegion == null || _saving ? null : _removeSelectedRegion,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(FluentIcons.delete, size: 13),
              SizedBox(width: 6),
              Text('删除区域'),
            ],
          ),
        ),
        Button(
          key: const ValueKey('save-manga-text-project'),
          onPressed: _project == null || _saving
              ? null
              : () => unawaited(_saveProject()),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(FluentIcons.save, size: 13),
              SizedBox(width: 6),
              Text('保存工程'),
            ],
          ),
        ),
        FilledButton(
          key: const ValueKey('render-manga-text-project'),
          onPressed: _project == null || _saving
              ? null
              : () => unawaited(_renderProject()),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_saving)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: ProgressRing(strokeWidth: 2.2),
                )
              else
                const Icon(FluentIcons.refresh, size: 13),
              const SizedBox(width: 6),
              const Text('保存并重渲染'),
            ],
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 900;
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    title,
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: actions,
                    ),
                  ],
                )
              : Row(
                  children: <Widget>[
                    Expanded(child: title),
                    const SizedBox(width: 12),
                    actions,
                  ],
                ),
        );
      },
    );
  }

  Widget _buildLoadFailure(FluentThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            FluentIcons.error,
            size: 34,
            color: theme.resources.textFillColorSecondary,
          ),
          const SizedBox(height: 12),
          const Text('无法打开文本工程'),
          const SizedBox(height: 10),
          Button(
            onPressed: () => unawaited(
              _loadFile(_fileIndex, saveCurrent: false),
            ),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkbench(double width) {
    if (width < 820) {
      return Column(
        children: <Widget>[
          _CompactPaneSwitcher(
            selected: _compactPane,
            onChanged: (value) => setState(() => _compactPane = value),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: switch (_compactPane) {
              _CompactPane.pages => _buildPagePanel(),
              _CompactPane.canvas => _buildCanvasPanel(),
              _CompactPane.regions => _buildRegionPanel(),
            },
          ),
        ],
      );
    }
    final sideWidth = width >= 1180 ? 248.0 : 205.0;
    final inspectorWidth = width >= 1180 ? 340.0 : 300.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(width: sideWidth, child: _buildPagePanel()),
        const SizedBox(width: 10),
        Expanded(child: _buildCanvasPanel()),
        const SizedBox(width: 10),
        SizedBox(width: inspectorWidth, child: _buildRegionPanel()),
      ],
    );
  }

  Widget _buildPagePanel() {
    final theme = FluentTheme.of(context);
    return Card(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(FluentIcons.page, size: 15),
              const SizedBox(width: 7),
              Text('页面', style: theme.typography.bodyStrong),
              const Spacer(),
              Text(
                '${_fileIndex + 1}/${_files.length}',
                style: theme.typography.caption,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.separated(
              key: const ValueKey('manga-text-editor-pages'),
              itemCount: _files.length,
              separatorBuilder: (_, __) => const SizedBox(height: 5),
              itemBuilder: (context, index) {
                final file = _files[index];
                final selected = index == _fileIndex;
                return _PageTile(
                  file: file,
                  selected: selected,
                  onPressed: _saving ? null : () => unawaited(_loadFile(index)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvasPanel() {
    final theme = FluentTheme.of(context);
    return Card(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(
              children: <Widget>[
                const Icon(FluentIcons.photo2, size: 15),
                const SizedBox(width: 7),
                Text('画布', style: theme.typography.bodyStrong),
                const Spacer(),
                ToggleButton(
                  key: const ValueKey('toggle-manga-render-preview'),
                  checked: _showRendered,
                  onChanged: (checked) => setState(() {
                    _showRendered = checked;
                    if (checked && _displayImagePath == _file.path) {
                      _notice = '尚无渲染结果，当前仍显示原图。';
                      _noticeSeverity = InfoBarSeverity.info;
                    }
                  }),
                  child: Text(_showRendered ? '译图' : '原图'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _RegionCanvas(
              imagePath: _displayImagePath,
              imageSize: _imageSize,
              regions: _visibleRegions,
              selectedRegion: _selectedRegion,
              addMode: _addRegionMode,
              onSelected: _selectRegion,
              onRegionAdded: _addRegion,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
            child: Text(
              _addRegionMode ? '在图片上拖动鼠标，框住未识别的原文区域。' : '滚轮缩放，拖动画布；点击方框即可编辑。',
              style: theme.typography.caption?.copyWith(
                color: _addRegionMode
                    ? theme.accentColor
                    : theme.resources.textFillColorSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRegionPanel() {
    final theme = FluentTheme.of(context);
    final project = _project!;
    return Card(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(FluentIcons.edit, size: 15),
              const SizedBox(width: 7),
              Text('文本区域', style: theme.typography.bodyStrong),
              const Spacer(),
              Text(
                _showUntranslatedOnly
                    ? '${_visibleRegions.length} 个待补'
                    : '${project.regions.length} 个',
                style: theme.typography.caption,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            flex: 4,
            child: _visibleRegions.isEmpty
                ? _EmptyRegions(showingFilter: _showUntranslatedOnly)
                : ListView.separated(
                    key: const ValueKey('manga-text-editor-regions'),
                    itemCount: _visibleRegions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (context, index) {
                      final region = _visibleRegions[index];
                      return _RegionTile(
                        region: region,
                        selected: _selectedRegion != null &&
                            identical(region.raw, _selectedRegion!.raw),
                        onPressed: () => _selectRegion(region),
                      );
                    },
                  ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 9),
            child: Divider(),
          ),
          Flexible(
            flex: 6,
            child: _selectedRegion == null
                ? const Center(child: Text('选择一个文字区域开始修改'))
                : _RegionInspector(
                    key: ObjectKey(_selectedRegion),
                    region: _selectedRegion!,
                    onChanged: () => _markDirty(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _CompactPaneSwitcher extends StatelessWidget {
  const _CompactPaneSwitcher({
    required this.selected,
    required this.onChanged,
  });

  final _CompactPane selected;
  final ValueChanged<_CompactPane> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (final pane in _CompactPane.values) ...<Widget>[
          Expanded(
            child: ToggleButton(
              key: ValueKey('manga-editor-pane-${pane.name}'),
              checked: selected == pane,
              onChanged: (_) => onChanged(pane),
              child: Text(switch (pane) {
                _CompactPane.pages => '页面',
                _CompactPane.canvas => '画布',
                _CompactPane.regions => '文本',
              }),
            ),
          ),
          if (pane != _CompactPane.regions) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _PageTile extends StatelessWidget {
  const _PageTile({
    required this.file,
    required this.selected,
    required this.onPressed,
  });

  final MangaTranslationFile file;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Button(
      key: ValueKey<String>('manga-editor-page-${file.path}'),
      onPressed: onPressed,
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (_) => selected
              ? theme.accentColor.withAlpha(28)
              : theme.resources.subtleFillColorSecondary,
        ),
      ),
      child: SizedBox(
        height: 48,
        child: Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                width: 36,
                height: 42,
                child: Image.file(
                  File(file.path),
                  fit: BoxFit.cover,
                  cacheWidth: 72,
                  errorBuilder: (_, __, ___) => const Center(
                    child: Icon(FluentIcons.photo2, size: 16),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: selected
                        ? theme.typography.bodyStrong?.copyWith(
                            color: theme.accentColor,
                          )
                        : theme.typography.bodyStrong,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    file.hasProject ? '已有文本工程' : '打开时自动识别',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.caption?.copyWith(
                      color: theme.resources.textFillColorSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RegionTile extends StatelessWidget {
  const _RegionTile({
    required this.region,
    required this.selected,
    required this.onPressed,
  });

  final MangaTextEditorRegion region;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final translation = region.translation.trim();
    return Button(
      key: ValueKey<String>('manga-text-region-${region.order}'),
      onPressed: onPressed,
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (_) => selected
              ? theme.accentColor.withAlpha(28)
              : theme.resources.subtleFillColorSecondary,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: region.isUntranslated
                    ? const Color(0xFFFFB900).withAlpha(35)
                    : const Color(0xFF107C10).withAlpha(28),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${region.order}',
                style: theme.typography.caption,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    region.sourceText.trim().isEmpty
                        ? '（人工新增区域）'
                        : region.sourceText.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.caption,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    translation.isEmpty ? '待填写译文' : translation,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.caption?.copyWith(
                      color: region.isUntranslated
                          ? const Color(0xFF9D5D00)
                          : theme.resources.textFillColorSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RegionInspector extends StatefulWidget {
  const _RegionInspector({
    required this.region,
    required this.onChanged,
    super.key,
  });

  final MangaTextEditorRegion region;
  final VoidCallback onChanged;

  @override
  State<_RegionInspector> createState() => _RegionInspectorState();
}

class _RegionInspectorState extends State<_RegionInspector> {
  late final TextEditingController _sourceController;
  late final TextEditingController _translationController;

  @override
  void initState() {
    super.initState();
    _sourceController = TextEditingController(text: widget.region.sourceText);
    _translationController = TextEditingController(
      text: widget.region.translation,
    );
  }

  @override
  void dispose() {
    _sourceController.dispose();
    _translationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final bounds = widget.region.bounds;
    return SingleChildScrollView(
      key: const ValueKey('manga-text-region-inspector'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '区域 ${widget.region.order}',
                style: theme.typography.bodyStrong,
              ),
              const Spacer(),
              Text(
                bounds == null
                    ? '位置数据缺失'
                    : '${bounds.left.round()}, ${bounds.top.round()} · '
                        '${bounds.width.round()}×${bounds.height.round()}',
                style: theme.typography.caption?.copyWith(
                  color: theme.resources.textFillColorSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text('识别原文'),
          const SizedBox(height: 5),
          TextBox(
            key: const ValueKey('manga-region-source-text'),
            controller: _sourceController,
            minLines: 2,
            maxLines: 4,
            placeholder: 'OCR 没识别到时可留空，直接填写译文',
            onChanged: (value) {
              widget.region.updateSourceText(value);
              widget.onChanged();
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              const Text('译文'),
              const Spacer(),
              if (widget.region.isUntranslated)
                Text(
                  '待补译',
                  style: theme.typography.caption?.copyWith(
                    color: const Color(0xFF9D5D00),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          TextBox(
            key: const ValueKey('manga-region-translation-text'),
            controller: _translationController,
            minLines: 3,
            maxLines: 7,
            placeholder: '输入最终显示在图片上的文字',
            onChanged: (value) {
              widget.region.updateTranslation(value);
              widget.onChanged();
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('文字排版'),
                    const SizedBox(height: 2),
                    Text(
                      widget.region.direction == MangaTextDirection.vertical
                          ? '纵向，从右向左排列'
                          : '横向，从左向右排列',
                      style: theme.typography.caption?.copyWith(
                        color: theme.resources.textFillColorSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              ToggleSwitch(
                key: const ValueKey('manga-region-direction'),
                checked: widget.region.direction == MangaTextDirection.vertical,
                onChanged: (vertical) {
                  widget.region.updateDirection(
                    vertical
                        ? MangaTextDirection.vertical
                        : MangaTextDirection.horizontal,
                  );
                  widget.onChanged();
                  setState(() {});
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyRegions extends StatelessWidget {
  const _EmptyRegions({required this.showingFilter});

  final bool showingFilter;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          showingFilter ? '当前没有待补译区域' : '没有识别到文字。点击“框选新增”，在画布上框住气泡后人工填写。',
          textAlign: TextAlign.center,
          style: theme.typography.caption?.copyWith(
            color: theme.resources.textFillColorSecondary,
          ),
        ),
      ),
    );
  }
}

class _RegionCanvas extends StatefulWidget {
  const _RegionCanvas({
    required this.imagePath,
    required this.imageSize,
    required this.regions,
    required this.selectedRegion,
    required this.addMode,
    required this.onSelected,
    required this.onRegionAdded,
  });

  final String imagePath;
  final Size imageSize;
  final List<MangaTextEditorRegion> regions;
  final MangaTextEditorRegion? selectedRegion;
  final bool addMode;
  final ValueChanged<MangaTextEditorRegion> onSelected;
  final ValueChanged<MangaTextRegionBounds> onRegionAdded;

  @override
  State<_RegionCanvas> createState() => _RegionCanvasState();
}

class _RegionCanvasState extends State<_RegionCanvas> {
  Offset? _dragStart;
  Offset? _dragEnd;

  @override
  void didUpdateWidget(_RegionCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.addMode && oldWidget.addMode) {
      _dragStart = null;
      _dragEnd = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return ColoredBox(
      color: theme.resources.layerFillColorDefault,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final imageWidth = math.max(widget.imageSize.width, 1.0);
          final imageHeight = math.max(widget.imageSize.height, 1.0);
          final availableWidth = math.max(constraints.maxWidth - 24, 1.0);
          final availableHeight = math.max(constraints.maxHeight - 24, 1.0);
          final scale = math.min(
            availableWidth / imageWidth,
            availableHeight / imageHeight,
          );
          final fittedSize = Size(
            imageWidth * math.max(scale, 0.01),
            imageHeight * math.max(scale, 0.01),
          );
          return ClipRect(
            child: InteractiveViewer(
              key: const ValueKey('manga-text-region-canvas'),
              minScale: 0.5,
              maxScale: 8,
              panEnabled: !widget.addMode,
              scaleEnabled: !widget.addMode,
              boundaryMargin: const EdgeInsets.all(80),
              child: Center(
                child: SizedBox.fromSize(
                  size: fittedSize,
                  child: MouseRegion(
                    cursor: widget.addMode
                        ? SystemMouseCursors.precise
                        : SystemMouseCursors.click,
                    child: GestureDetector(
                      key: const ValueKey('manga-text-region-gesture-surface'),
                      behavior: HitTestBehavior.opaque,
                      onTapUp: widget.addMode
                          ? null
                          : (details) => _handleTap(
                                details.localPosition,
                                fittedSize,
                              ),
                      onPanStart: widget.addMode
                          ? (details) => setState(() {
                                _dragStart = _clamp(
                                  details.localPosition,
                                  fittedSize,
                                );
                                _dragEnd = _dragStart;
                              })
                          : null,
                      onPanUpdate: widget.addMode
                          ? (details) => setState(() {
                                _dragEnd = _clamp(
                                  details.localPosition,
                                  fittedSize,
                                );
                              })
                          : null,
                      onPanCancel: widget.addMode
                          ? () => setState(() {
                                _dragStart = null;
                                _dragEnd = null;
                              })
                          : null,
                      onPanEnd: widget.addMode
                          ? (_) => _finishDrag(fittedSize)
                          : null,
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          Image.file(
                            File(widget.imagePath),
                            key: ValueKey<String>(widget.imagePath),
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.medium,
                            errorBuilder: (_, __, ___) => ColoredBox(
                              color: theme.resources.controlFillColorSecondary,
                              child: const Center(
                                child: Icon(FluentIcons.file_image, size: 30),
                              ),
                            ),
                          ),
                          IgnorePointer(
                            child: CustomPaint(
                              painter: _RegionOverlayPainter(
                                regions: widget.regions,
                                selectedRegion: widget.selectedRegion,
                                imageSize: widget.imageSize,
                                dragRect: _dragRect,
                                accentColor: theme.accentColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Rect? get _dragRect {
    if (_dragStart == null || _dragEnd == null) return null;
    return Rect.fromPoints(_dragStart!, _dragEnd!);
  }

  Offset _clamp(Offset point, Size size) => Offset(
        point.dx.clamp(0.0, size.width),
        point.dy.clamp(0.0, size.height),
      );

  void _handleTap(Offset point, Size fittedSize) {
    final imagePoint = Offset(
      point.dx * widget.imageSize.width / fittedSize.width,
      point.dy * widget.imageSize.height / fittedSize.height,
    );
    for (final region in widget.regions.reversed) {
      final bounds = region.bounds;
      if (bounds == null) continue;
      if (imagePoint.dx >= bounds.left &&
          imagePoint.dx <= bounds.right &&
          imagePoint.dy >= bounds.top &&
          imagePoint.dy <= bounds.bottom) {
        widget.onSelected(region);
        return;
      }
    }
  }

  void _finishDrag(Size fittedSize) {
    final rect = _dragRect;
    setState(() {
      _dragStart = null;
      _dragEnd = null;
    });
    if (rect == null || rect.width < 8 || rect.height < 8) return;
    widget.onRegionAdded(
      MangaTextRegionBounds.fromLTRB(
        rect.left * widget.imageSize.width / fittedSize.width,
        rect.top * widget.imageSize.height / fittedSize.height,
        rect.right * widget.imageSize.width / fittedSize.width,
        rect.bottom * widget.imageSize.height / fittedSize.height,
      ),
    );
  }
}

class _RegionOverlayPainter extends CustomPainter {
  const _RegionOverlayPainter({
    required this.regions,
    required this.selectedRegion,
    required this.imageSize,
    required this.dragRect,
    required this.accentColor,
  });

  final List<MangaTextEditorRegion> regions;
  final MangaTextEditorRegion? selectedRegion;
  final Size imageSize;
  final Rect? dragRect;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / math.max(imageSize.width, 1);
    final scaleY = size.height / math.max(imageSize.height, 1);
    for (final region in regions) {
      final bounds = region.bounds;
      if (bounds == null) continue;
      final rect = Rect.fromLTRB(
        bounds.left * scaleX,
        bounds.top * scaleY,
        bounds.right * scaleX,
        bounds.bottom * scaleY,
      );
      final selected =
          selectedRegion != null && identical(region.raw, selectedRegion!.raw);
      final color = selected
          ? accentColor
          : region.isUntranslated
              ? const Color(0xFFFF8C00)
              : const Color(0xFF107C10);
      canvas.drawRect(
        rect,
        Paint()
          ..color = color.withAlpha(selected ? 42 : 24)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 2.5 : 1.4,
      );
      final label = TextPainter(
        text: TextSpan(
          text: '${region.order}',
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelRect = Rect.fromLTWH(
        rect.left,
        math.max(0, rect.top - 16),
        label.width + 8,
        16,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(labelRect, const Radius.circular(3)),
        Paint()..color = color,
      );
      label.paint(canvas, Offset(labelRect.left + 4, labelRect.top + 2));
    }
    if (dragRect case final rect?) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = accentColor.withAlpha(35)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = accentColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_RegionOverlayPainter oldDelegate) =>
      !identical(regions, oldDelegate.regions) ||
      !identical(selectedRegion, oldDelegate.selectedRegion) ||
      dragRect != oldDelegate.dragRect ||
      imageSize != oldDelegate.imageSize ||
      accentColor != oldDelegate.accentColor;
}
