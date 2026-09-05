import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/api_client.dart';
import '../../core/models/book.dart';
import '../../core/models/manga_workflow.dart';
import 'manga_bookshelf_import.dart';
import 'manga_translation_models.dart';

typedef MangaWorkflowInvoker = Future<MangaWorkflowResult> Function({
  required String filePath,
  required String mode,
  String language,
  String title,
  Object? project,
  Object? companion,
  String? translatedFilePath,
  int upscaleFactor,
  Future<void>? abortTrigger,
});

typedef MangaBookshelfTranslationPersister = Future<void> Function({
  required String bookId,
  required int chapterIndex,
  required String targetLanguage,
  required List<Map<String, dynamic>> pages,
});

class MangaTranslationController extends ChangeNotifier {
  MangaTranslationController(
    ApiClient api, {
    SharedPreferences? preferences,
    MangaWorkflowInvoker? invokeWorkflow,
    MangaBookshelfImportInvoker? importBookshelfBook,
    MangaBookshelfTranslationPersister? persistBookshelfTranslation,
    Future<List<Book>> Function()? loadBookshelfBooks,
  })  : _preferences = preferences,
        _invokeWorkflow = invokeWorkflow ?? api.runImageWorkflow,
        _importBookshelfBook =
            importBookshelfBook ?? MangaBookshelfImporter(api).importBook,
        _persistBookshelfTranslation =
            persistBookshelfTranslation ?? api.saveMangaBookshelfTranslation,
        _loadBookshelfBooks = loadBookshelfBooks ?? api.fetchBooks;

  static const _workflowModePreference = 'qingjuan.mangaTranslation.mode';
  static const _outputDirectoryPreference =
      'qingjuan.mangaTranslation.outputDirectory';
  static const supportedImageExtensions = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.jfif',
    '.webp',
    '.avif',
    '.bmp',
    '.tif',
    '.tiff',
    '.heic',
    '.heif',
  };

  SharedPreferences? _preferences;
  final MangaWorkflowInvoker _invokeWorkflow;
  final MangaBookshelfImportInvoker _importBookshelfBook;
  final MangaBookshelfTranslationPersister _persistBookshelfTranslation;
  final Future<List<Book>> Function() _loadBookshelfBooks;
  final List<MangaTranslationFile> _files = <MangaTranslationFile>[];
  final Queue<MangaBookshelfImportRequest> _pendingBookImports =
      Queue<MangaBookshelfImportRequest>();
  MangaWorkflowMode _mode = MangaWorkflowMode.normal;
  MangaTranslationRunState _runState = MangaTranslationRunState.ready;
  String _outputDirectory = '';
  String _message = '';
  int _current = 0;
  int _total = 0;
  bool _stopRequested = false;
  bool _disposed = false;
  bool _modeEdited = false;
  bool _outputEdited = false;
  int _inputGeneration = 0;
  Completer<void>? _activeAbort;
  bool _importWorkerRunning = false;
  String? _activeBookImportKey;
  String? _selectedBookId;
  String? _selectedBookTitle;
  final Map<String, MangaBookshelfPageTarget> _bookshelfPageTargets =
      <String, MangaBookshelfPageTarget>{};
  final Map<_BookshelfChapterKey, Set<int>> _bookshelfExpectedPages =
      <_BookshelfChapterKey, Set<int>>{};

  List<MangaTranslationFile> get files =>
      List<MangaTranslationFile>.unmodifiable(_files);
  MangaWorkflowMode get mode => _mode;
  MangaTranslationRunState get runState => _runState;
  String get outputDirectory => _outputDirectory;
  String get message => _message;
  int get current => _current;
  int get total => _total;
  String? get selectedBookId => _selectedBookId;
  String? get selectedBookTitle => _selectedBookTitle;
  int get pendingBookImportCount => _pendingBookImports.length;
  bool get isBusy =>
      _runState == MangaTranslationRunState.importing ||
      _runState == MangaTranslationRunState.starting ||
      _runState == MangaTranslationRunState.running ||
      _runState == MangaTranslationRunState.stopping;
  int get succeededCount => _files
      .where((file) => file.status == MangaTranslationFileStatus.succeeded)
      .length;
  int get failedCount => _files
      .where((file) => file.status == MangaTranslationFileStatus.failed)
      .length;
  double get progress => _total == 0 ? 0 : (_current / _total) * 100;

  Future<List<Book>> loadBookshelfMangaBooks() async {
    final books = await _loadBookshelfBooks();
    return books.where((book) => book.kind == '漫画').toList()
      ..sort((left, right) => left.title.compareTo(right.title));
  }

  void enqueueBookshelfImport(MangaBookshelfImportRequest request) {
    if (_disposed) return;
    final duplicate = _activeBookImportKey == request.deduplicationKey ||
        _pendingBookImports.any(
          (pending) => pending.deduplicationKey == request.deduplicationKey,
        );
    if (duplicate) {
      if (!_isWorkflowBusy) {
        _message = '《${request.bookTitle}》已在导入队列中';
        _notify();
      }
      return;
    }
    _pendingBookImports.add(request);
    if (_isWorkflowBusy) return;
    unawaited(_drainBookImportQueue());
  }

  Future<void> _drainBookImportQueue() async {
    if (_disposed || _importWorkerRunning || _isWorkflowBusy) return;
    _importWorkerRunning = true;
    try {
      while (!_disposed && !_isWorkflowBusy && _pendingBookImports.isNotEmpty) {
        final request = _pendingBookImports.removeFirst();
        await _importBook(request);
      }
    } finally {
      _importWorkerRunning = false;
    }
  }

  Future<void> _importBook(MangaBookshelfImportRequest request) async {
    final generation = ++_inputGeneration;
    _stopRequested = false;
    _runState = MangaTranslationRunState.importing;
    _activeBookImportKey = request.deduplicationKey;
    _current = 0;
    _total = 0;
    _message = '正在从书架导入《${request.bookTitle}》…';
    final abort = Completer<void>();
    _activeAbort = abort;
    _notify();
    try {
      final result = await _importBookshelfBook(
        request,
        abortTrigger: abort.future,
        onProgress: (progress) {
          if (_disposed || generation != _inputGeneration) return;
          _current = progress.completedPages;
          _total = progress.totalPages;
          _message = progress.message;
          _notify();
        },
      );
      if (_disposed || generation != _inputGeneration) return;
      if (_stopRequested) throw const MangaBookshelfImportCancelled();
      final added = await _replaceFilesForGeneration(
        result.filePaths,
        sourceRoot: result.sourceRoot,
        generation: generation,
      );
      if (_disposed || generation != _inputGeneration) return;
      if (_stopRequested) throw const MangaBookshelfImportCancelled();
      if (added == 0) {
        throw StateError('书籍图片下载完成，但没有可加入工作台的文件');
      }
      _selectedBookId = result.bookId;
      _selectedBookTitle = result.bookTitle;
      _bindBookshelfPageTargets(result);
      _current = added;
      _total = added;
      _runState = MangaTranslationRunState.ready;
      _message =
          '已从《${result.bookTitle}》导入 ${result.chapterCount} 章、$added 张图片';
    } catch (error) {
      if (_disposed || generation != _inputGeneration) return;
      if (_stopRequested || error is MangaBookshelfImportCancelled) {
        _runState = MangaTranslationRunState.stopped;
        _message = '已停止导入《${request.bookTitle}》';
      } else {
        _runState = MangaTranslationRunState.failed;
        _message = '导入《${request.bookTitle}》失败：${_friendlyError(error)}';
      }
    } finally {
      if (identical(_activeAbort, abort)) _activeAbort = null;
      if (_activeBookImportKey == request.deduplicationKey) {
        _activeBookImportKey = null;
      }
      if (!_disposed && generation == _inputGeneration) _notify();
    }
  }

  bool get _isWorkflowBusy =>
      _runState == MangaTranslationRunState.starting ||
      _runState == MangaTranslationRunState.running ||
      _runState == MangaTranslationRunState.stopping;

  Future<void> initialize() async {
    _preferences ??= await SharedPreferences.getInstance();
    if (!_modeEdited) {
      _mode = MangaWorkflowMode.fromApiValue(
        _preferences?.getString(_workflowModePreference),
      );
    }
    if (!_outputEdited) {
      _outputDirectory =
          _preferences?.getString(_outputDirectoryPreference)?.trim() ?? '';
    }
    _notify();
  }

  Future<void> selectMode(MangaWorkflowMode value) async {
    if (isBusy || value == _mode) return;
    _modeEdited = true;
    _mode = value;
    _notify();
    await _preferences?.setString(_workflowModePreference, value.apiValue);
  }

  void setOutputDirectory(String value) {
    if (isBusy) return;
    final normalized = value.trim();
    if (_outputDirectory == normalized) return;
    _outputEdited = true;
    _outputDirectory = normalized;
    unawaited(
      _preferences?.setString(_outputDirectoryPreference, normalized),
    );
    _notify();
  }

  Future<int> addFiles(
    Iterable<String> inputPaths, {
    String? sourceRoot,
  }) async {
    if (isBusy) return 0;
    _clearBookshelfBinding();
    final generation = ++_inputGeneration;
    return _addFilesForGeneration(
      inputPaths,
      sourceRoot: sourceRoot,
      generation: generation,
    );
  }

  Future<int> _addFilesForGeneration(
    Iterable<String> inputPaths, {
    required int generation,
    String? sourceRoot,
  }) async {
    final existing = _files.map((file) => _pathKey(file.path)).toSet();
    final additions = await _resolveInputFiles(
      inputPaths,
      sourceRoot: sourceRoot,
      existing: existing,
    );
    if (generation != _inputGeneration) return 0;
    final added = additions.length;
    if (added > 0) {
      _files.addAll(additions);
      _sortFiles();
      _prepareForChangedInput();
      _message = '已添加 $added 张图片';
      _notify();
    }
    return added;
  }

  Future<int> _replaceFilesForGeneration(
    Iterable<String> inputPaths, {
    required int generation,
    String? sourceRoot,
  }) async {
    final replacements = await _resolveInputFiles(
      inputPaths,
      sourceRoot: sourceRoot,
      existing: <String>{},
    );
    if (generation != _inputGeneration ||
        _stopRequested ||
        replacements.isEmpty) {
      return 0;
    }
    _files
      ..clear()
      ..addAll(replacements);
    _sortFiles();
    _prepareForChangedInput();
    return replacements.length;
  }

  Future<List<MangaTranslationFile>> _resolveInputFiles(
    Iterable<String> inputPaths, {
    required Set<String> existing,
    String? sourceRoot,
  }) async {
    final additions = <MangaTranslationFile>[];
    for (final input in inputPaths) {
      final file = File(input).absolute;
      if (!_isSupportedImage(file.path) || _isWorkPath(file.path)) continue;
      if (!await file.exists()) continue;
      final key = _pathKey(file.path);
      if (!existing.add(key)) continue;
      final workspace = MangaWorkspacePaths.forSource(file.path);
      final projectExists = await File(workspace.projectPath).exists() ||
          await File(workspace.legacyProjectPath).exists();
      final root = Directory(sourceRoot ?? file.parent.path).absolute.path;
      final relative = path.relative(file.path, from: root);
      additions.add(
        MangaTranslationFile(
          path: file.path,
          sourceRoot: root,
          relativePath: relative.startsWith('..')
              ? path.basename(file.path)
              : path.normalize(relative),
          hasProject: projectExists,
        ),
      );
    }
    return additions;
  }

  Future<int> addFolder(String folderPath) async {
    if (isBusy) return 0;
    _clearBookshelfBinding();
    final generation = ++_inputGeneration;
    final root = Directory(folderPath).absolute;
    if (!await root.exists() || _isWorkPath(root.path)) return 0;
    _message = '正在扫描 ${path.basename(root.path)}…';
    _notify();
    final discovered = <String>[];
    await _scanDirectory(root, discovered);
    if (generation != _inputGeneration) return 0;
    final added = await _addFilesForGeneration(
      discovered,
      sourceRoot: root.parent.path,
      generation: generation,
    );
    if (generation == _inputGeneration && added == 0) {
      _message = '所选文件夹中没有可添加的图片';
      _notify();
    }
    return added;
  }

  void removeFile(String filePath) {
    if (isBusy) return;
    _inputGeneration += 1;
    final key = _pathKey(filePath);
    _files.removeWhere((file) => _pathKey(file.path) == key);
    _bookshelfPageTargets.remove(key);
    if (_files.isEmpty) {
      _clearBookshelfBinding();
    }
    _prepareForChangedInput();
    _message = _files.isEmpty ? '' : '已从列表移除图片';
    _notify();
  }

  void clearFiles() {
    if (isBusy || _files.isEmpty) return;
    _inputGeneration += 1;
    _files.clear();
    _clearBookshelfBinding();
    _prepareForChangedInput();
    _message = '';
    _notify();
  }

  Future<Map<String, dynamic>> loadTextEditorProject(
    MangaTranslationFile item,
  ) async {
    _ensureTextEditorAvailable(item);
    final paths = MangaWorkspacePaths.forSource(item.path);
    await _ensureWorkspace(paths);
    await _ensureEditorBase(paths, force: true);
    final existing = await _readProject(paths);
    if (existing != null) {
      final document = _jsonDocument(existing);
      if (!await File(paths.projectPath).exists()) {
        await _writeJson(paths.projectPath, document);
      }
      _updateFile(
        item.path,
        (current) => current.copyWith(
          hasProject: true,
          message: current.message,
        ),
      );
      _notify();
      return document;
    }

    _updateFile(
      item.path,
      (current) => current.copyWith(
        status: MangaTranslationFileStatus.running,
        message: '正在识别原文并生成文本工程',
      ),
    );
    _notify();
    try {
      final result = await _invokeWorkflow(
        filePath: item.path,
        mode: MangaWorkflowMode.exportOriginal.apiValue,
        language: '中文',
        title: paths.stem,
        project: null,
        companion: null,
        translatedFilePath: null,
        upscaleFactor: 2,
      );
      await _persistResult(
        paths,
        result,
        item,
        effectiveMode: MangaWorkflowMode.exportOriginal,
      );
      final generated = await _readJson(paths.projectPath);
      if (generated == null) {
        throw StateError('原文识别完成，但未生成可编辑的区域工程');
      }
      final document = _jsonDocument(generated);
      _updateFile(
        item.path,
        (current) => current.copyWith(
          status: MangaTranslationFileStatus.ready,
          hasProject: true,
          message: '文本工程已就绪',
        ),
      );
      _notify();
      return document;
    } catch (error) {
      _updateFile(
        item.path,
        (current) => current.copyWith(
          status: MangaTranslationFileStatus.failed,
          message: '生成文本工程失败：${_friendlyError(error)}',
        ),
      );
      _notify();
      rethrow;
    }
  }

  Future<void> saveTextEditorProject(
    MangaTranslationFile item,
    Map<String, dynamic> project,
  ) async {
    _ensureTextEditorAvailable(item);
    final paths = MangaWorkspacePaths.forSource(item.path);
    await _ensureWorkspace(paths);
    await _ensureEditorBase(paths, force: true);
    await _writeJson(paths.projectPath, project);
    _updateFile(
      item.path,
      (current) => current.copyWith(
        status: MangaTranslationFileStatus.ready,
        hasProject: true,
        message: '文本修改已保存，等待重新渲染',
      ),
    );
    _notify();
  }

  Future<MangaTextEditorRenderResult> renderTextEditorProject(
    MangaTranslationFile item,
    Map<String, dynamic> project,
  ) async {
    _ensureTextEditorAvailable(item);
    final paths = MangaWorkspacePaths.forSource(item.path);
    await _ensureWorkspace(paths);
    await _ensureEditorBase(paths, force: true);
    // Save first so manual edits remain recoverable even when rendering or
    // bookshelf publication subsequently fails.
    await _writeJson(paths.projectPath, project);
    _updateFile(
      item.path,
      (current) => current.copyWith(
        status: MangaTranslationFileStatus.running,
        hasProject: true,
        message: '正在重新渲染文本',
      ),
    );
    _notify();

    try {
      final result = await _invokeWorkflow(
        filePath: item.path,
        mode: MangaWorkflowMode.importTranslationRender.apiValue,
        language: '中文',
        title: paths.stem,
        project: project,
        companion: null,
        translatedFilePath: null,
        upscaleFactor: 2,
      );
      final outputPath = await _persistResult(
        paths,
        result,
        item,
        effectiveMode: MangaWorkflowMode.importTranslationRender,
        persistProject: false,
      );
      if (outputPath == null || !await File(paths.resultPath).exists()) {
        throw StateError('重新渲染未返回结果图片');
      }

      final writeback = await _writeTextEditorBookshelfChapter(item);
      _updateFile(
        item.path,
        (current) => current.copyWith(
          status: writeback.failed
              ? MangaTranslationFileStatus.failed
              : MangaTranslationFileStatus.succeeded,
          hasProject: true,
          outputPath: outputPath,
          message: writeback.message,
        ),
      );
      _notify();
      return MangaTextEditorRenderResult(
        resultPath: paths.resultPath,
        bookshelfBound: writeback.bound,
        bookshelfWritten: writeback.written,
        missingBookshelfPages: writeback.missingPages,
        message: writeback.message,
      );
    } catch (error) {
      _updateFile(
        item.path,
        (current) => current.copyWith(
          status: MangaTranslationFileStatus.failed,
          hasProject: true,
          message: '重新渲染失败：${_friendlyError(error)}',
        ),
      );
      _notify();
      rethrow;
    }
  }

  Future<void> run() async {
    if (isBusy) return;
    _inputGeneration += 1;
    if (_files.isEmpty) {
      _message = '请先添加需要处理的漫画图片';
      _notify();
      return;
    }
    _stopRequested = false;
    _runState = MangaTranslationRunState.starting;
    _current = 0;
    _total = _files.length;
    for (var index = 0; index < _files.length; index++) {
      _files[index] = _files[index].copyWith(
        status: MangaTranslationFileStatus.ready,
        message: '',
        outputPath: '',
      );
    }
    _message = '正在启动翻译任务…';
    _notify();
    await Future<void>.delayed(Duration.zero);
    if (_stopRequested) {
      _markRemainingStopped(0);
      _runState = MangaTranslationRunState.stopped;
      _message = '任务已停止';
      _notify();
      return;
    }
    _runState = MangaTranslationRunState.running;
    _notify();

    final bookshelfWritebacks = _createBookshelfWritebacks();

    for (var index = 0; index < _files.length; index++) {
      if (_stopRequested) {
        _markRemainingStopped(index);
        break;
      }
      final item = _files[index];
      _files[index] = item.copyWith(
        status: MangaTranslationFileStatus.running,
        message: '处理中',
      );
      _message = '正在处理 ${index + 1}/$_total：${item.name}';
      _notify();
      try {
        final paths = MangaWorkspacePaths.forSource(item.path);
        await _ensureWorkspace(paths);
        await _ensureEditorBase(paths);
        final project = await _readProject(paths);
        final companion = await _companionForMode(paths);
        final translatedFilePath = _mode == MangaWorkflowMode.replaceTranslation
            ? await _findTranslatedImage(paths)
            : null;
        if (_stopRequested) throw StateError('request cancelled');
        final abort = Completer<void>();
        _activeAbort = abort;
        final MangaWorkflowResult result;
        try {
          result = await _invokeWorkflow(
            filePath: item.path,
            mode: _mode.apiValue,
            language: '中文',
            title: paths.stem,
            project: project,
            companion: companion,
            translatedFilePath: translatedFilePath,
            upscaleFactor: 2,
            abortTrigger: abort.future,
          );
        } finally {
          if (identical(_activeAbort, abort)) _activeAbort = null;
        }
        final outputPath = await _persistResult(paths, result, item);
        _recordBookshelfWriteback(
          bookshelfWritebacks,
          item,
          result,
        );
        _files[index] = item.copyWith(
          status: MangaTranslationFileStatus.succeeded,
          message: '已完成',
          outputPath: outputPath ?? '',
          hasProject: await File(paths.projectPath).exists(),
        );
      } catch (error) {
        _files[index] = item.copyWith(
          status: _stopRequested
              ? MangaTranslationFileStatus.stopped
              : MangaTranslationFileStatus.failed,
          message: _stopRequested ? '已停止' : _friendlyError(error),
        );
      }
      _current = index + 1;
      _notify();
    }

    var writtenBackChapterCount = 0;
    if (!_stopRequested && bookshelfWritebacks.isNotEmpty) {
      writtenBackChapterCount =
          await _writeCompletedBookshelfChapters(bookshelfWritebacks);
    }

    if (_stopRequested) {
      _runState = MangaTranslationRunState.stopped;
      _message = '任务已停止，已处理 $_current/$_total';
    } else if (failedCount == _total) {
      _runState = MangaTranslationRunState.failed;
      _message = '处理失败：$_total 张图片均未完成';
    } else if (failedCount > 0) {
      _runState = MangaTranslationRunState.partialFailure;
      _message = '处理完成：成功 $succeededCount，失败 $failedCount'
          '${writtenBackChapterCount > 0 ? '；已写入书架译文 $writtenBackChapterCount 章' : ''}';
    } else {
      _runState = MangaTranslationRunState.completed;
      _message = '全部 $_total 张图片处理完成'
          '${writtenBackChapterCount > 0 ? '，已写入书架译文（$writtenBackChapterCount 章）' : ''}';
    }
    _notify();
    unawaited(_drainBookImportQueue());
  }

  void stop() {
    if (_runState != MangaTranslationRunState.importing &&
        _runState != MangaTranslationRunState.starting &&
        _runState != MangaTranslationRunState.running) {
      return;
    }
    _stopRequested = true;
    _pendingBookImports.clear();
    _runState = MangaTranslationRunState.stopping;
    _message = _activeBookImportKey == null ? '正在停止当前请求…' : '正在停止书籍导入…';
    final abort = _activeAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRequested = true;
    _pendingBookImports.clear();
    final abort = _activeAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    super.dispose();
  }

  Future<void> _scanDirectory(
    Directory directory,
    List<String> discovered,
  ) async {
    if (_outputDirectory.isNotEmpty &&
        _pathKey(directory.path) == _pathKey(_outputDirectory)) {
      return;
    }
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is Directory) {
        if (path.basename(entity.path).toLowerCase() ==
            MangaWorkspacePaths.workDirectoryName) {
          continue;
        }
        await _scanDirectory(entity, discovered);
      } else if (entity is File && _isSupportedImage(entity.path)) {
        discovered.add(entity.path);
      }
    }
  }

  Future<dynamic> _companionForMode(MangaWorkspacePaths paths) async {
    if (_mode != MangaWorkflowMode.importTranslationRender) return null;
    final original = await _readJson(paths.originalPath);
    if (original != null) return original;
    return _readJson(paths.translatedPath);
  }

  Future<dynamic> _readProject(MangaWorkspacePaths paths) async {
    final current = await _readJson(paths.projectPath);
    if (current != null) return current;
    return _readJson(paths.legacyProjectPath);
  }

  Future<String?> _findTranslatedImage(MangaWorkspacePaths paths) async {
    final exact = File(paths.translatedImagePath);
    if (await exact.exists()) return exact.path;
    final directory = Directory(paths.translatedImagesDirectory);
    if (!await directory.exists()) return null;
    final candidates = <String>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !_isSupportedImage(entity.path)) continue;
      if (path.basenameWithoutExtension(entity.path).toLowerCase() ==
          paths.stem.toLowerCase()) {
        candidates.add(entity.path);
      }
    }
    candidates.sort(_naturalCompare);
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<String?> _persistResult(
    MangaWorkspacePaths paths,
    MangaWorkflowResult result,
    MangaTranslationFile item, {
    MangaWorkflowMode? effectiveMode,
    bool persistProject = true,
  }) async {
    final resultMode = effectiveMode ?? _mode;
    if (persistProject) {
      final projectDocument =
          _projectDocumentForSource(paths.sourcePath, result);
      if (projectDocument != null) {
        await _writeJson(paths.projectPath, projectDocument);
      }
    }
    if (resultMode == MangaWorkflowMode.exportOriginal &&
        result.original != null) {
      await _writeJson(paths.originalPath, result.original);
    }
    if (resultMode == MangaWorkflowMode.exportTranslation &&
        result.translated != null) {
      await _writeJson(paths.translatedPath, result.translated);
    }
    if (resultMode == MangaWorkflowMode.translateJsonOnly) {
      final original = File(paths.originalPath);
      if (await original.exists()) await original.delete();
    }

    if (result.inpaintedImageBase64 != null) {
      await _writeBytes(
        paths.inpaintedPath,
        base64Decode(result.inpaintedImageBase64!),
      );
    }
    if (result.outputImageBase64 == null) return null;
    final bytes = base64Decode(result.outputImageBase64!);
    await _writeBytes(paths.resultPath, bytes);
    if (_outputDirectory.isEmpty) return paths.resultPath;
    final selectedOutput = path.join(
      _outputDirectory,
      _collisionSafeRelativeOutput(item),
    );
    if (_pathKey(selectedOutput) != _pathKey(paths.resultPath)) {
      await _writeBytes(selectedOutput, bytes);
    }
    return selectedOutput;
  }

  void _bindBookshelfPageTargets(MangaBookshelfImportResult result) {
    _bookshelfPageTargets.clear();
    _bookshelfExpectedPages.clear();
    final normalizedTargets = <String, MangaBookshelfPageTarget>{
      for (final entry in result.pageTargets.entries)
        _pathKey(entry.key): entry.value,
    };
    for (final target in normalizedTargets.values) {
      if (target.bookId != result.bookId) continue;
      final chapterKey = _BookshelfChapterKey(
        bookId: target.bookId,
        chapterIndex: target.chapterIndex,
      );
      _bookshelfExpectedPages
          .putIfAbsent(chapterKey, () => <int>{})
          .add(target.pageNumber);
    }
    for (final file in _files) {
      final key = _pathKey(file.path);
      final target = normalizedTargets[key];
      if (target == null || target.bookId != result.bookId) continue;
      _bookshelfPageTargets[key] = target;
    }
  }

  void _clearBookshelfBinding() {
    _selectedBookId = null;
    _selectedBookTitle = null;
    _bookshelfPageTargets.clear();
    _bookshelfExpectedPages.clear();
  }

  Map<_BookshelfChapterKey, _BookshelfChapterWriteback>
      _createBookshelfWritebacks() {
    if (!_modeWritesBookshelfTranslation || _bookshelfPageTargets.isEmpty) {
      return <_BookshelfChapterKey, _BookshelfChapterWriteback>{};
    }
    return <_BookshelfChapterKey, _BookshelfChapterWriteback>{
      for (final entry in _bookshelfExpectedPages.entries)
        entry.key: _BookshelfChapterWriteback(
          key: entry.key,
          expectedPageNumbers: Set<int>.from(entry.value),
        ),
    };
  }

  bool get _modeWritesBookshelfTranslation =>
      _mode == MangaWorkflowMode.normal ||
      _mode == MangaWorkflowMode.importTranslationRender ||
      _mode == MangaWorkflowMode.replaceTranslation;

  void _recordBookshelfWriteback(
    Map<_BookshelfChapterKey, _BookshelfChapterWriteback> writebacks,
    MangaTranslationFile item,
    MangaWorkflowResult result,
  ) {
    final target = _bookshelfPageTargets[_pathKey(item.path)];
    if (target == null || writebacks.isEmpty) return;
    final key = _BookshelfChapterKey(
      bookId: target.bookId,
      chapterIndex: target.chapterIndex,
    );
    final writeback = writebacks[key];
    if (writeback == null) return;
    final outputImageBase64 = result.outputImageBase64?.trim() ?? '';
    final project = result.project ?? result.projectDocument;
    if (outputImageBase64.isEmpty) {
      throw StateError('翻译结果缺少渲染图片，无法写入书架译文');
    }
    if (project == null) {
      throw StateError('翻译结果缺少区域工程数据，无法写入书架译文');
    }
    writeback.pages[target.pageNumber] = <String, dynamic>{
      'pageNumber': target.pageNumber,
      'outputImageBase64': outputImageBase64,
      'project': project,
      'pageTranslation': result.pageTranslation,
    };
  }

  Future<int> _writeCompletedBookshelfChapters(
    Map<_BookshelfChapterKey, _BookshelfChapterWriteback> writebacks,
  ) async {
    var completed = 0;
    final ordered = writebacks.values.toList()
      ..sort((left, right) {
        final bookComparison = left.key.bookId.compareTo(right.key.bookId);
        return bookComparison != 0
            ? bookComparison
            : left.key.chapterIndex.compareTo(right.key.chapterIndex);
      });
    for (final writeback in ordered) {
      if (!writeback.isComplete) continue;
      try {
        await _persistBookshelfTranslation(
          bookId: writeback.key.bookId,
          chapterIndex: writeback.key.chapterIndex,
          targetLanguage: '中文',
          pages: writeback.orderedPages,
        );
        completed += 1;
        _updateBookshelfChapterFiles(
          writeback.key,
          status: MangaTranslationFileStatus.succeeded,
          message: '已完成并写入书架译文',
        );
      } catch (error) {
        _updateBookshelfChapterFiles(
          writeback.key,
          status: MangaTranslationFileStatus.failed,
          message: '写入书架译文失败：${_friendlyError(error)}',
        );
      }
      _notify();
    }
    return completed;
  }

  void _updateBookshelfChapterFiles(
    _BookshelfChapterKey key, {
    required MangaTranslationFileStatus status,
    required String message,
  }) {
    for (var index = 0; index < _files.length; index++) {
      final target = _bookshelfPageTargets[_pathKey(_files[index].path)];
      if (target == null ||
          target.bookId != key.bookId ||
          target.chapterIndex != key.chapterIndex) {
        continue;
      }
      _files[index] = _files[index].copyWith(
        status: status,
        message: message,
      );
    }
  }

  Future<_TextEditorBookshelfWriteback> _writeTextEditorBookshelfChapter(
    MangaTranslationFile editedItem,
  ) async {
    final editedTarget = _bookshelfPageTargets[_pathKey(editedItem.path)];
    if (editedTarget == null) {
      return const _TextEditorBookshelfWriteback(
        bound: false,
        written: false,
        missingPages: 0,
        failed: false,
        message: '已保存并重新渲染',
      );
    }
    final key = _BookshelfChapterKey(
      bookId: editedTarget.bookId,
      chapterIndex: editedTarget.chapterIndex,
    );
    final expected = Set<int>.from(
      _bookshelfExpectedPages[key] ?? <int>{editedTarget.pageNumber},
    );
    final chapterFiles = <int, MangaTranslationFile>{};
    for (final file in _files) {
      final target = _bookshelfPageTargets[_pathKey(file.path)];
      if (target == null ||
          target.bookId != key.bookId ||
          target.chapterIndex != key.chapterIndex) {
        continue;
      }
      chapterFiles[target.pageNumber] = file;
    }

    final pages = <Map<String, dynamic>>[];
    final orderedPageNumbers = expected.toList()..sort();
    for (final pageNumber in orderedPageNumbers) {
      final file = chapterFiles[pageNumber];
      if (file == null) continue;
      final paths = MangaWorkspacePaths.forSource(file.path);
      final image = File(paths.resultPath);
      final projectFile = File(paths.projectPath);
      if (!await image.exists() || !await projectFile.exists()) continue;
      try {
        final project = _jsonDocument(await _readJson(paths.projectPath));
        pages.add(<String, dynamic>{
          'pageNumber': pageNumber,
          'outputImageBase64': base64Encode(await image.readAsBytes()),
          'project': project,
          'pageTranslation': _pageTranslation(file.path, project),
        });
      } catch (_) {
        // A corrupt or partially written peer page must not prevent the
        // edited page from being saved locally. Treat it as not generated.
      }
    }
    final missingPages = expected.length - pages.length;
    if (missingPages > 0) {
      return _TextEditorBookshelfWriteback(
        bound: true,
        written: false,
        missingPages: missingPages,
        failed: false,
        message: '已保存并重新渲染；本章还有 $missingPages 页未生成，暂未写入书架译文',
      );
    }

    try {
      await _persistBookshelfTranslation(
        bookId: key.bookId,
        chapterIndex: key.chapterIndex,
        targetLanguage: '中文',
        pages: pages,
      );
      _updateBookshelfChapterFiles(
        key,
        status: MangaTranslationFileStatus.succeeded,
        message: '已完成并写入书架译文',
      );
      return const _TextEditorBookshelfWriteback(
        bound: true,
        written: true,
        missingPages: 0,
        failed: false,
        message: '已保存、重新渲染并写入书架译文',
      );
    } catch (error) {
      final message = '重新渲染已完成，但写入书架译文失败：${_friendlyError(error)}';
      _updateBookshelfChapterFiles(
        key,
        status: MangaTranslationFileStatus.failed,
        message: message,
      );
      return _TextEditorBookshelfWriteback(
        bound: true,
        written: false,
        missingPages: 0,
        failed: true,
        message: message,
      );
    }
  }

  String _pageTranslation(
    String sourcePath,
    Map<String, dynamic> project,
  ) {
    dynamic page = project[File(sourcePath).absolute.path];
    if (page is! Map && project['regions'] is List) page = project;
    if (page is! Map) {
      for (final value in project.values) {
        if (value is Map && value['regions'] is List) {
          page = value;
          break;
        }
      }
    }
    if (page is! Map || page['regions'] is! List) return '';
    final translated = <String>[];
    for (final raw in page['regions'] as List) {
      if (raw is! Map) continue;
      var value = raw['translation'];
      if (value == null || '$value'.trim().isEmpty) {
        value = raw['translation_raw'];
      }
      final text = '${value ?? ''}'.trim().replaceAll('[BR]', '\n');
      if (text.isNotEmpty) translated.add(text);
    }
    return translated.join('\n');
  }

  Map<String, dynamic>? _projectDocumentForSource(
    String sourcePath,
    MangaWorkflowResult result,
  ) {
    if (result.diagnostics['shouldPersistProject'] == false) return null;
    final sourceKey = File(sourcePath).absolute.path;
    dynamic page;
    for (final candidate in <Map<String, dynamic>?>[
      result.projectDocument,
      result.project,
    ]) {
      if (candidate == null) continue;
      if (candidate[sourceKey] is Map) {
        page = candidate[sourceKey];
      } else if (result.imageKey.isNotEmpty &&
          candidate[result.imageKey] is Map) {
        page = candidate[result.imageKey];
      } else if (candidate['regions'] is List) {
        page = candidate;
      } else {
        for (final value in candidate.values) {
          if (value is Map && value['regions'] is List) {
            page = value;
            break;
          }
        }
      }
      if (page is Map) break;
    }
    if (page is! Map) return null;
    final normalized = Map<String, dynamic>.from(page);
    normalized['regions'] = normalized['regions'] is List
        ? normalized['regions']
        : const <dynamic>[];
    normalized['original_width'] =
        normalized['original_width'] ?? normalized['originalWidth'] ?? 0;
    normalized['original_height'] =
        normalized['original_height'] ?? normalized['originalHeight'] ?? 0;
    return <String, dynamic>{sourceKey: normalized};
  }

  Future<void> _ensureWorkspace(MangaWorkspacePaths paths) async {
    for (final directory in paths.directories) {
      await Directory(directory).create(recursive: true);
    }
  }

  Future<void> _ensureEditorBase(
    MangaWorkspacePaths paths, {
    bool force = false,
  }) async {
    if (!force &&
        _mode != MangaWorkflowMode.normal &&
        _mode != MangaWorkflowMode.importTranslationRender &&
        _mode != MangaWorkflowMode.replaceTranslation) {
      return;
    }
    final target = File(paths.editorBasePath);
    if (await target.exists()) return;
    await _writeBytes(
        paths.editorBasePath, await File(paths.sourcePath).readAsBytes());
  }

  Future<dynamic> _readJson(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString());
  }

  Future<void> _writeJson(String targetPath, dynamic value) async {
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(value),
    );
    await _writeBytes(targetPath, Uint8List.fromList(bytes));
  }

  Future<void> _writeBytes(String targetPath, Uint8List bytes) async {
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final temporary = File('$targetPath.qingjuan-part');
    final backup = File('$targetPath.qingjuan-backup');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await backup.exists()) {
      if (!await target.exists()) {
        await backup.rename(target.path);
      } else {
        await backup.delete();
      }
    }
    var movedExisting = false;
    try {
      if (await target.exists()) {
        await target.rename(backup.path);
        movedExisting = true;
      }
      await temporary.rename(target.path);
      if (movedExisting && await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // The new file is already durable; stale backup cleanup can retry
          // during the next write without turning a successful result into a
          // failed task.
        }
      }
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      if (movedExisting && await backup.exists() && !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }

  void _ensureTextEditorAvailable(MangaTranslationFile item) {
    if (isBusy) throw StateError('当前任务运行中，暂时无法编辑文本');
    if (_files.every((file) => _pathKey(file.path) != _pathKey(item.path))) {
      throw StateError('该图片已从漫画翻译列表移除');
    }
  }

  Map<String, dynamic> _jsonDocument(dynamic value) {
    if (value is! Map) throw const FormatException('文本工程必须是 JSON 对象');
    return Map<String, dynamic>.from(value);
  }

  void _updateFile(
    String filePath,
    MangaTranslationFile Function(MangaTranslationFile current) update,
  ) {
    final key = _pathKey(filePath);
    final index = _files.indexWhere((file) => _pathKey(file.path) == key);
    if (index >= 0) _files[index] = update(_files[index]);
  }

  void _markRemainingStopped(int start) {
    for (var index = start; index < _files.length; index++) {
      _files[index] = _files[index].copyWith(
        status: MangaTranslationFileStatus.stopped,
        message: '已停止',
      );
    }
  }

  void _prepareForChangedInput() {
    _current = 0;
    _total = _files.length;
    _runState = MangaTranslationRunState.ready;
  }

  void _sortFiles() {
    _files.sort(
      (left, right) => _naturalCompare(left.path, right.path),
    );
  }

  String _collisionSafeRelativeOutput(MangaTranslationFile item) {
    final outputRelative = path.setExtension(item.relativePath, '.png');
    final relativeKey = _relativePathKey(outputRelative);
    final collisions = _files
        .where(
          (file) =>
              _relativePathKey(path.setExtension(file.relativePath, '.png')) ==
              relativeKey,
        )
        .length;
    if (collisions <= 1) return outputRelative;
    final parent = path.dirname(item.path);
    final parentName = path.basename(parent);
    final hash = _stablePathHash(_pathKey(parent)).toRadixString(16);
    return path.join('${parentName}_$hash',
        '${path.basenameWithoutExtension(item.path)}.png');
  }

  String _relativePathKey(String value) {
    final normalized = path.normalize(value);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  int _stablePathHash(String value) {
    var hash = 0x811C9DC5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  int _naturalCompare(String left, String right) {
    final matcher = RegExp(r'\d+|\D+');
    final leftParts = matcher
        .allMatches(left.toLowerCase())
        .map((match) => match.group(0)!)
        .toList();
    final rightParts = matcher
        .allMatches(right.toLowerCase())
        .map((match) => match.group(0)!)
        .toList();
    final commonLength = leftParts.length < rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var index = 0; index < commonLength; index++) {
      final leftPart = leftParts[index];
      final rightPart = rightParts[index];
      final leftNumber = int.tryParse(leftPart);
      final rightNumber = int.tryParse(rightPart);
      final comparison = leftNumber != null && rightNumber != null
          ? leftNumber.compareTo(rightNumber)
          : leftPart.compareTo(rightPart);
      if (comparison != 0) return comparison;
    }
    return leftParts.length.compareTo(rightParts.length);
  }

  bool _isSupportedImage(String value) =>
      supportedImageExtensions.contains(path.extension(value).toLowerCase());

  bool _isWorkPath(String value) => path.split(path.normalize(value)).any(
      (part) => part.toLowerCase() == MangaWorkspacePaths.workDirectoryName);

  String _pathKey(String value) {
    final normalized = path.normalize(File(value).absolute.path);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  String _friendlyError(Object error) {
    final text = '$error'.trim();
    return text.isEmpty ? '处理失败' : text;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

class _BookshelfChapterKey {
  const _BookshelfChapterKey({
    required this.bookId,
    required this.chapterIndex,
  });

  final String bookId;
  final int chapterIndex;

  @override
  bool operator ==(Object other) =>
      other is _BookshelfChapterKey &&
      other.bookId == bookId &&
      other.chapterIndex == chapterIndex;

  @override
  int get hashCode => Object.hash(bookId, chapterIndex);
}

class _BookshelfChapterWriteback {
  _BookshelfChapterWriteback({
    required this.key,
    required this.expectedPageNumbers,
  });

  final _BookshelfChapterKey key;
  final Set<int> expectedPageNumbers;
  final Map<int, Map<String, dynamic>> pages = <int, Map<String, dynamic>>{};

  bool get isComplete =>
      pages.length == expectedPageNumbers.length &&
      expectedPageNumbers.every(pages.containsKey);

  List<Map<String, dynamic>> get orderedPages {
    final pageNumbers = pages.keys.toList()..sort();
    return pageNumbers.map((pageNumber) => pages[pageNumber]!).toList();
  }
}

class _TextEditorBookshelfWriteback {
  const _TextEditorBookshelfWriteback({
    required this.bound,
    required this.written,
    required this.missingPages,
    required this.failed,
    required this.message,
  });

  final bool bound;
  final bool written;
  final int missingPages;
  final bool failed;
  final String message;
}
