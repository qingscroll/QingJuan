import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_scope.dart';
import '../../core/models/book.dart';
import '../../shared/motion.dart';
import 'editor/manga_text_editor_page.dart';
import 'manga_bookshelf_import.dart';
import 'manga_translation_controller.dart';
import 'manga_translation_coordinator.dart';
import 'manga_translation_models.dart';
import 'widgets/manga_file_list.dart';
import 'widgets/manga_translation_task_card.dart';

class MangaTranslationPage extends StatefulWidget {
  const MangaTranslationPage({
    this.controller,
    this.workspaceIdentity,
    super.key,
  });

  final MangaTranslationController? controller;
  final String? workspaceIdentity;

  @override
  State<MangaTranslationPage> createState() => _MangaTranslationPageState();
}

class _MangaTranslationPageState extends State<MangaTranslationPage> {
  static const _imageTypes = XTypeGroup(
    label: '漫画图片',
    extensions: <String>[
      'png',
      'jpg',
      'jpeg',
      'jfif',
      'webp',
      'avif',
      'bmp',
      'tiff',
      'tif',
      'heic',
      'heif',
    ],
  );

  MangaTranslationController? _controller;
  MangaTranslationCoordinator? _coordinator;
  bool _ownsController = false;
  bool _dragging = false;
  bool _loadingBookshelf = false;
  String _workspaceIdentity = 'local';
  final _outputController = TextEditingController();

  MangaTranslationController get controller => _controller!;

  @override
  void initState() {
    super.initState();
    _workspaceIdentity = widget.workspaceIdentity ?? 'local';
    if (widget.controller != null) {
      _attachController(widget.controller!, ownsController: false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null) {
      final scope = AppScope.of(context);
      _workspaceIdentity =
          widget.workspaceIdentity ?? scope.auth.workspaceIdentity ?? 'local';
      final coordinator = scope.mangaTranslation;
      if (coordinator != null) {
        _attachCoordinator(coordinator);
      } else {
        _attachController(
          MangaTranslationController(scope.api),
          ownsController: true,
        );
      }
    }
  }

  void _attachCoordinator(MangaTranslationCoordinator value) {
    if (identical(_coordinator, value)) return;
    _coordinator?.removeListener(_handleCoordinatorChanged);
    _coordinator = value;
    value.addListener(_handleCoordinatorChanged);
    _attachController(value.controller, ownsController: false);
  }

  void _handleCoordinatorChanged() {
    final coordinator = _coordinator;
    if (coordinator == null || !mounted) return;
    _attachController(coordinator.controller, ownsController: false);
    setState(() {});
  }

  void _attachController(
    MangaTranslationController value, {
    required bool ownsController,
  }) {
    if (identical(_controller, value)) return;
    _controller?.removeListener(_handleControllerChanged);
    if (_ownsController) _controller?.dispose();
    _controller = value;
    _ownsController = ownsController;
    value.addListener(_handleControllerChanged);
    unawaited(value.initialize());
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    if (!_outputController.selection.isValid &&
        _outputController.text != controller.outputDirectory) {
      _outputController.text = controller.outputDirectory;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _coordinator?.removeListener(_handleCoordinatorChanged);
    _controller?.removeListener(_handleControllerChanged);
    if (_ownsController) _controller?.dispose();
    _outputController.dispose();
    super.dispose();
  }

  Future<void> _addFiles() async {
    final selected = await openFiles(
      acceptedTypeGroups: const <XTypeGroup>[_imageTypes],
    );
    if (selected.isEmpty) return;
    await controller.addFiles(selected.map((file) => file.path));
  }

  Future<void> _addFolder() async {
    final selected = await getDirectoryPath();
    if (selected == null || selected.isEmpty) return;
    await controller.addFolder(selected);
  }

  Future<void> _selectBookshelfBook() async {
    if (controller.isBusy || _loadingBookshelf) return;
    setState(() => _loadingBookshelf = true);
    try {
      final books = await controller.loadBookshelfMangaBooks();
      if (!mounted) return;
      if (books.isEmpty) {
        await displayInfoBar(
          context,
          builder: (_, __) => const InfoBar(
            title: Text('书架中没有漫画'),
            content: Text('请先把漫画加入书架，再从这里选择。'),
            severity: InfoBarSeverity.info,
          ),
        );
        return;
      }
      final selected = await showDialog<Book>(
        context: context,
        builder: (dialogContext) => _MangaBookshelfPickerDialog(books: books),
      );
      if (selected == null || !mounted) return;
      controller.enqueueBookshelfImport(
        MangaBookshelfImportRequest.fromBook(
          selected,
          workspaceIdentity: widget.controller == null
              ? (AppScope.of(context).auth.workspaceIdentity ?? 'local')
              : _workspaceIdentity,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      await displayInfoBar(
        context,
        builder: (_, __) => InfoBar(
          title: const Text('读取书架失败'),
          content: Text('$error'),
          severity: InfoBarSeverity.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _loadingBookshelf = false);
    }
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    if (controller.isBusy) return;
    final files = <String>[];
    for (final item in details.files) {
      final itemPath = item.path.trim();
      if (itemPath.isEmpty) continue;
      final type = await FileSystemEntity.type(itemPath, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await controller.addFolder(itemPath);
      } else if (type == FileSystemEntityType.file) {
        files.add(itemPath);
      }
    }
    if (files.isNotEmpty) await controller.addFiles(files);
  }

  void _setDragging(bool value) {
    if (!mounted || _dragging == value) return;
    setState(() => _dragging = value);
  }

  Future<void> _browseOutput() async {
    final selected = await getDirectoryPath(
      initialDirectory: controller.outputDirectory.isEmpty
          ? null
          : controller.outputDirectory,
    );
    if (selected == null || selected.isEmpty) return;
    controller.setOutputDirectory(selected);
    _outputController.text = selected;
  }

  Future<void> _openOutput() async {
    final directory = controller.outputDirectory.isNotEmpty
        ? controller.outputDirectory
        : controller.files.isNotEmpty
            ? MangaWorkspacePaths.forSource(controller.files.first.path)
                .resultDirectory
            : '';
    if (directory.isEmpty) return;
    await Directory(directory).create(recursive: true);
    if (Platform.isWindows) {
      await Process.start('explorer.exe', <String>[directory]);
    }
  }

  Future<void> _openTextEditor(MangaTranslationFile file) async {
    if (controller.isBusy) return;
    await Navigator.of(context).push<void>(
      qjPageRoute<void>(
        context: context,
        builder: (_) => MangaTextEditorPage(
          controller: controller,
          files: List<MangaTranslationFile>.of(controller.files),
          initialFile: file,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final current = controller;
    return Padding(
      key: const ValueKey('manga-translation-page'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Card(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  current.mode.label,
                  key: const ValueKey('manga-workflow-title'),
                  style: theme.typography.title,
                ),
                if (current.selectedBookTitle
                    case final bookTitle?) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    '已载入书架漫画：《$bookTitle》',
                    key: const ValueKey('manga-selected-bookshelf-book'),
                    style: theme.typography.caption?.copyWith(
                      color: theme.accentColor,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  current.mode.description,
                  key: const ValueKey('manga-workflow-description'),
                  style: theme.typography.body?.copyWith(
                    color: theme.resources.textFillColorSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      Button(
                        key: const ValueKey('select-manga-bookshelf-book'),
                        onPressed: current.isBusy || _loadingBookshelf
                            ? null
                            : _selectBookshelfBook,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (_loadingBookshelf)
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: ProgressRing(strokeWidth: 2.5),
                              )
                            else
                              const Icon(FluentIcons.library, size: 14),
                            const SizedBox(width: 6),
                            const Text('从书架选择'),
                          ],
                        ),
                      ),
                      Button(
                        key: const ValueKey('add-manga-files'),
                        onPressed: current.isBusy ? null : _addFiles,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(FluentIcons.add, size: 14),
                            SizedBox(width: 6),
                            Text('添加文件'),
                          ],
                        ),
                      ),
                      Button(
                        key: const ValueKey('add-manga-folder'),
                        onPressed: current.isBusy ? null : _addFolder,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(FluentIcons.folder_open, size: 14),
                            SizedBox(width: 6),
                            Text('添加文件夹'),
                          ],
                        ),
                      ),
                      Button(
                        key: const ValueKey('clear-manga-files'),
                        onPressed: current.isBusy || current.files.isEmpty
                            ? null
                            : current.clearFiles,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(FluentIcons.delete, size: 14),
                            SizedBox(width: 6),
                            Text('清空列表'),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: DropTarget(
                      enable: !current.isBusy,
                      onDragEntered: (_) => _setDragging(true),
                      onDragExited: (_) => _setDragging(false),
                      onDragDone: (details) {
                        _setDragging(false);
                        unawaited(_handleDrop(details));
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                            color: _dragging
                                ? theme.accentColor
                                : const Color(0x00000000),
                            width: _dragging ? 2 : 1,
                          ),
                        ),
                        padding: const EdgeInsets.all(1),
                        child: MangaFileList(
                          files: current.files,
                          removeEnabled: !current.isBusy,
                          onRemove: current.removeFile,
                          editEnabled: !current.isBusy,
                          onEdit: (file) => unawaited(_openTextEditor(file)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          MangaTranslationTaskCard(
            controller: current,
            outputController: _outputController,
            onBrowseOutput: _browseOutput,
            onOpenOutput: _openOutput,
          ),
          const SizedBox(height: 10),
          MangaTranslationProgressCard(controller: current),
        ],
      ),
    );
  }
}

class _MangaBookshelfPickerDialog extends StatefulWidget {
  const _MangaBookshelfPickerDialog({required this.books});

  final List<Book> books;

  @override
  State<_MangaBookshelfPickerDialog> createState() =>
      _MangaBookshelfPickerDialogState();
}

class _MangaBookshelfPickerDialogState
    extends State<_MangaBookshelfPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final needle = _query.trim().toLowerCase();
    final books = needle.isEmpty
        ? widget.books
        : widget.books
            .where((book) => book.title.toLowerCase().contains(needle))
            .toList();
    return ContentDialog(
      title: const Text('从书架选择漫画'),
      content: SizedBox(
        width: 500,
        height: 410,
        child: Column(
          children: <Widget>[
            TextBox(
              key: const ValueKey('manga-bookshelf-search'),
              placeholder: '搜索漫画书名',
              prefix: const Padding(
                padding: EdgeInsets.only(left: 10),
                child: Icon(FluentIcons.search, size: 15),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: books.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的漫画',
                        style: theme.typography.body?.copyWith(
                          color: theme.resources.textFillColorSecondary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: books.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final book = books[index];
                        return Button(
                          key: ValueKey('manga-bookshelf-book-${book.id}'),
                          onPressed: () => Navigator.pop(context, book),
                          child: SizedBox(
                            height: 54,
                            child: Row(
                              children: <Widget>[
                                const Icon(FluentIcons.photo_collection),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        book.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.typography.bodyStrong,
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${book.chapterCount} 章 · ${book.status}',
                                        style:
                                            theme.typography.caption?.copyWith(
                                          color: theme
                                              .resources.textFillColorSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(FluentIcons.chevron_right, size: 12),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        Button(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
