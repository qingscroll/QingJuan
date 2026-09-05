import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/manga_workflow.dart';
import 'package:qingjuan/features/manga_translation/manga_bookshelf_import.dart';
import 'package:qingjuan/features/manga_translation/manga_translation_controller.dart';
import 'package:qingjuan/features/manga_translation/manga_translation_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('folder scan skips work directory and uses natural image order',
      () async {
    final temporary = await Directory.systemTemp.createTemp('qingjuan-scan-');
    addTearDown(() => temporary.delete(recursive: true));
    await File('${temporary.path}${Platform.pathSeparator}page10.jpg')
        .writeAsBytes(<int>[1]);
    final translatedSource =
        File('${temporary.path}${Platform.pathSeparator}page2.jpg');
    await translatedSource.writeAsBytes(<int>[1]);
    await File(MangaWorkspacePaths.forSource(translatedSource.path)
            .legacyProjectPath)
        .writeAsString('{"regions":[]}');
    await File('${temporary.path}${Platform.pathSeparator}ignored.gif')
        .writeAsBytes(<int>[1]);
    final generated = File(
      '${temporary.path}${Platform.pathSeparator}manga_translator_work'
      '${Platform.pathSeparator}result${Platform.pathSeparator}page1.png',
    );
    await generated.parent.create(recursive: true);
    await generated.writeAsBytes(<int>[1]);

    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(api);
    addTearDown(controller.dispose);

    expect(await controller.addFolder(temporary.path), 2);
    expect(
      controller.files.map((file) => file.name),
      <String>['page2.jpg', 'page10.jpg'],
    );
    expect(controller.files.first.hasProject, isTrue);
    expect(controller.files.last.hasProject, isFalse);
  });

  test('batch continues after failure and writes upstream-compatible project',
      () async {
    final temporary = await Directory.systemTemp.createTemp('qingjuan-run-');
    addTearDown(() => temporary.delete(recursive: true));
    final page2 = File('${temporary.path}${Platform.pathSeparator}page2.jpg');
    final page10 = File('${temporary.path}${Platform.pathSeparator}page10.jpg');
    await page2.writeAsBytes(<int>[1]);
    await page10.writeAsBytes(<int>[2]);
    final calls = <String>[];
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async {
        calls.add(title);
        if (title == 'page10') throw StateError('模拟失败');
        return MangaWorkflowResult(
          mode: mode,
          imageKey: 'backend-upload.jpg',
          mimeType: 'image/png',
          outputImageBase64: base64Encode(<int>[9, 8, 7]),
          inpaintedImageBase64: base64Encode(<int>[6, 5]),
          projectDocument: <String, dynamic>{
            'backend-upload.jpg': <String, dynamic>{
              'regions': <dynamic>[],
              'original_width': 320,
              'original_height': 480,
            },
          },
          original: const <String, dynamic>{'0': '原文'},
          translated: const <String, dynamic>{'0': '译文'},
        );
      },
    );
    addTearDown(controller.dispose);
    final selectedOutput = Directory(
      '${temporary.path}${Platform.pathSeparator}selected-output',
    );
    controller.setOutputDirectory(selectedOutput.path);
    await controller.addFiles(<String>[page10.path, page2.path]);

    await controller.run();

    expect(calls, <String>['page2', 'page10']);
    expect(controller.runState, MangaTranslationRunState.partialFailure);
    expect(controller.succeededCount, 1);
    expect(controller.failedCount, 1);
    final paths = MangaWorkspacePaths.forSource(page2.path);
    for (final directory in paths.directories) {
      expect(await Directory(directory).exists(), isTrue, reason: directory);
    }
    expect(await File(paths.resultPath).readAsBytes(), <int>[9, 8, 7]);
    expect(
      await File('${selectedOutput.path}${Platform.pathSeparator}page2.png')
          .readAsBytes(),
      <int>[9, 8, 7],
    );
    final document = jsonDecode(await File(paths.projectPath).readAsString())
        as Map<String, dynamic>;
    final sourceKey = page2.absolute.path;
    expect(document.keys, <String>[sourceKey]);
    expect(
      (document[sourceKey] as Map<String, dynamic>)['original_width'],
      320,
    );
    expect(await File(paths.originalPath).exists(), isFalse);
    expect(await File(paths.translatedPath).exists(), isFalse);
  });

  test('colorize and upscale do not create empty text sidecars', () async {
    final temporary = await Directory.systemTemp.createTemp('qingjuan-image-');
    addTearDown(() => temporary.delete(recursive: true));
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final preferences = await SharedPreferences.getInstance();

    for (final mode in <MangaWorkflowMode>[
      MangaWorkflowMode.colorizeOnly,
      MangaWorkflowMode.upscaleOnly,
    ]) {
      final source = File(
        '${temporary.path}${Platform.pathSeparator}${mode.apiValue}.jpg',
      );
      await source.writeAsBytes(<int>[1]);
      final controller = MangaTranslationController(
        api,
        preferences: preferences,
        invokeWorkflow: ({
          required String filePath,
          required String mode,
          String language = '中文',
          String title = '',
          Object? project,
          Object? companion,
          String? translatedFilePath,
          int upscaleFactor = 2,
          Future<void>? abortTrigger,
        }) async =>
            MangaWorkflowResult(
          mode: mode,
          imageKey: title,
          mimeType: 'image/png',
          project: const <String, dynamic>{},
          projectDocument: const <String, dynamic>{},
          original: const <String, dynamic>{},
          translated: const <String, dynamic>{},
          diagnostics: const <String, dynamic>{
            'shouldPersistProject': false,
          },
        ),
      );
      await controller.initialize();
      await controller.selectMode(mode);
      await controller.addFiles(<String>[source.path]);
      await controller.run();

      final paths = MangaWorkspacePaths.forSource(source.path);
      expect(await File(paths.originalPath).exists(), isFalse);
      expect(await File(paths.translatedPath).exists(), isFalse);
      expect(await File(paths.projectPath).exists(), isFalse);
      controller.dispose();
    }
  });

  test('selected output preserves folder hierarchy for duplicate names',
      () async {
    final temporary = await Directory.systemTemp.createTemp('qingjuan-tree-');
    addTearDown(() => temporary.delete(recursive: true));
    for (final folder in <String>['chapter-a', 'chapter-b']) {
      final source = File(
        '${temporary.path}${Platform.pathSeparator}$folder'
        '${Platform.pathSeparator}page.jpg',
      );
      await source.parent.create(recursive: true);
      await source.writeAsBytes(<int>[1]);
    }
    final output = Directory(
      '${temporary.path}${Platform.pathSeparator}selected-output',
    );
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async =>
          MangaWorkflowResult(
        mode: mode,
        imageKey: title,
        mimeType: 'image/png',
        outputImageBase64: base64Encode(<int>[9]),
      ),
    );
    addTearDown(controller.dispose);
    controller.setOutputDirectory(output.path);
    await controller.addFolder(temporary.path);
    await controller.run();
    final inputRootName = temporary.path.split(Platform.pathSeparator).last;

    expect(
      await File(
        '${output.path}${Platform.pathSeparator}$inputRootName'
        '${Platform.pathSeparator}chapter-a'
        '${Platform.pathSeparator}page.png',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${output.path}${Platform.pathSeparator}$inputRootName'
        '${Platform.pathSeparator}chapter-b'
        '${Platform.pathSeparator}page.png',
      ).exists(),
      isTrue,
    );
  });

  test('replace translation finds a same-stem image across extensions',
      () async {
    final temporary = await Directory.systemTemp.createTemp('qingjuan-pair-');
    addTearDown(() => temporary.delete(recursive: true));
    final source = File('${temporary.path}${Platform.pathSeparator}page.jpg');
    await source.writeAsBytes(<int>[1]);
    final paths = MangaWorkspacePaths.forSource(source.path);
    final translated = File(
      '${paths.translatedImagesDirectory}${Platform.pathSeparator}page.png',
    );
    await translated.parent.create(recursive: true);
    await translated.writeAsBytes(<int>[2]);
    String? receivedTranslatedFile;
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async {
        receivedTranslatedFile = translatedFilePath;
        return MangaWorkflowResult(
          mode: mode,
          imageKey: title,
          mimeType: 'image/png',
        );
      },
    );
    addTearDown(controller.dispose);
    await controller.selectMode(MangaWorkflowMode.replaceTranslation);
    await controller.addFiles(<String>[source.path]);

    await controller.run();

    expect(receivedTranslatedFile, translated.path);
  });

  test('JSON-only loads legacy project, removes original, and persists mode',
      () async {
    final temporary = await Directory.systemTemp.createTemp('qingjuan-json-');
    addTearDown(() => temporary.delete(recursive: true));
    final source = File('${temporary.path}${Platform.pathSeparator}page.png');
    await source.writeAsBytes(<int>[1]);
    final paths = MangaWorkspacePaths.forSource(source.path);
    await File(paths.legacyProjectPath).writeAsString(
      jsonEncode(<String, dynamic>{
        source.absolute.path: <String, dynamic>{
          'regions': <dynamic>[],
          'original_width': 12,
          'original_height': 34,
        },
      }),
    );
    await File(paths.originalPath).parent.create(recursive: true);
    await File(paths.originalPath).writeAsString('{"0":"原文"}');
    Object? receivedProject;
    final preferences = await SharedPreferences.getInstance();
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      preferences: preferences,
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async {
        receivedProject = project;
        return MangaWorkflowResult(
          mode: mode,
          imageKey: title,
          mimeType: 'image/png',
          project: <String, dynamic>{
            'regions': <dynamic>[],
            'original_width': 12,
            'original_height': 34,
          },
        );
      },
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectMode(MangaWorkflowMode.translateJsonOnly);
    await controller.addFiles(<String>[source.path]);

    await controller.run();

    expect(receivedProject, isA<Map<String, dynamic>>());
    expect(await File(paths.projectPath).exists(), isTrue);
    expect(await File(paths.originalPath).exists(), isFalse);
    final restored = MangaTranslationController(
      api,
      preferences: preferences,
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async =>
          throw UnimplementedError(),
    );
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.mode, MangaWorkflowMode.translateJsonOnly);
  });

  test('stop aborts the in-flight request and skips remaining work', () async {
    final temporary = await Directory.systemTemp.createTemp('qingjuan-stop-');
    addTearDown(() => temporary.delete(recursive: true));
    final first = File('${temporary.path}${Platform.pathSeparator}page1.jpg');
    final second = File('${temporary.path}${Platform.pathSeparator}page2.jpg');
    await first.writeAsBytes(<int>[1]);
    await second.writeAsBytes(<int>[2]);
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async {
        await abortTrigger;
        throw StateError('request aborted');
      },
    );
    addTearDown(controller.dispose);
    await controller.addFiles(<String>[first.path, second.path]);

    final run = controller.run();
    await Future<void>.delayed(Duration.zero);
    controller.stop();
    expect(controller.runState, MangaTranslationRunState.stopping);
    await run;

    expect(controller.runState, MangaTranslationRunState.stopped);
    expect(controller.files.first.status, MangaTranslationFileStatus.stopped);
    expect(controller.files.last.status, MangaTranslationFileStatus.stopped);
  });

  test('bookshelf list contains only manga and is sorted by title', () async {
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      loadBookshelfBooks: () async => <Book>[
        _book(id: 'novel', title: '小说', kind: '长小说'),
        _book(id: 'manga-a', title: '甲漫画'),
        _book(id: 'manga-b', title: '乙漫画'),
      ],
    );
    addTearDown(controller.dispose);

    final books = await controller.loadBookshelfMangaBooks();

    expect(books.map((book) => book.id), <String>['manga-b', 'manga-a']);
    expect(books.every((book) => book.kind == '漫画'), isTrue);
  });

  test('bookshelf import reports progress and replaces the current file list',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-bookshelf-import-');
    addTearDown(() => temporary.delete(recursive: true));
    final previous = File(
      '${temporary.path}${Platform.pathSeparator}previous.jpg',
    );
    final first = File(
      '${temporary.path}${Platform.pathSeparator}chapter-1'
      '${Platform.pathSeparator}page-0001.jpg',
    );
    final second = File(
      '${temporary.path}${Platform.pathSeparator}chapter-1'
      '${Platform.pathSeparator}page-0002.jpg',
    );
    await previous.writeAsBytes(<int>[1]);
    await first.parent.create(recursive: true);
    await first.writeAsBytes(<int>[2]);
    await second.writeAsBytes(<int>[3]);
    final progressReported = Completer<void>();
    final finishImport = Completer<void>();
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      importBookshelfBook: (
        request, {
        onProgress,
        abortTrigger,
      }) async {
        onProgress?.call(
          const MangaBookshelfImportProgress(
            message: '正在导入第 1/2 页',
            completedPages: 1,
            totalPages: 2,
          ),
        );
        progressReported.complete();
        await finishImport.future;
        return MangaBookshelfImportResult(
          bookId: request.bookId,
          bookTitle: request.bookTitle,
          sourceRoot: temporary.path,
          filePaths: <String>[first.path, second.path],
          chapterCount: 1,
        );
      },
    );
    addTearDown(controller.dispose);
    await controller.addFiles(<String>[previous.path]);

    controller.enqueueBookshelfImport(
      MangaBookshelfImportRequest.fromBook(
        _book(id: 'manga-1', title: '测试漫画'),
        workspaceIdentity: 'remote:user-1',
      ),
    );
    await progressReported.future;

    expect(controller.runState, MangaTranslationRunState.importing);
    expect(controller.current, 1);
    expect(controller.total, 2);
    expect(controller.progress, 50);
    expect(controller.message, '正在导入第 1/2 页');
    expect(controller.files.single.path, previous.absolute.path);

    finishImport.complete();
    await _waitUntil(
      () =>
          controller.runState == MangaTranslationRunState.ready &&
          controller.selectedBookId == 'manga-1',
    );

    expect(
      controller.files.map((file) => file.path),
      <String>[first.absolute.path, second.absolute.path],
    );
    expect(
      controller.files.any((file) => file.path == previous.absolute.path),
      isFalse,
    );
    expect(controller.selectedBookId, 'manga-1');
    expect(controller.selectedBookTitle, '测试漫画');
    expect(controller.current, 2);
    expect(controller.total, 2);
    expect(controller.message, contains('已从《测试漫画》导入 1 章、2 张图片'));

    controller.removeFile(first.path);
    expect(controller.selectedBookTitle, '测试漫画');
    controller.removeFile(second.path);
    expect(controller.selectedBookId, isNull);
    expect(controller.selectedBookTitle, isNull);
  });

  test('duplicate active bookshelf import is ignored', () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-bookshelf-dedup-');
    addTearDown(() => temporary.delete(recursive: true));
    final page = File('${temporary.path}${Platform.pathSeparator}page.jpg');
    await page.writeAsBytes(<int>[1]);
    final finishImport = Completer<void>();
    var importCalls = 0;
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      importBookshelfBook: (
        request, {
        onProgress,
        abortTrigger,
      }) async {
        importCalls += 1;
        await finishImport.future;
        return MangaBookshelfImportResult(
          bookId: request.bookId,
          bookTitle: request.bookTitle,
          sourceRoot: temporary.path,
          filePaths: <String>[page.path],
          chapterCount: 1,
        );
      },
    );
    addTearDown(controller.dispose);
    final request = MangaBookshelfImportRequest.fromBook(
      _book(id: 'manga-1', title: '测试漫画'),
      workspaceIdentity: 'local:user-1',
      chapterIndexes: const <int>[2, 1, 2],
    );

    controller.enqueueBookshelfImport(request);
    await _waitUntil(
      () => controller.runState == MangaTranslationRunState.importing,
    );
    controller.enqueueBookshelfImport(
      MangaBookshelfImportRequest.fromBook(
        _book(id: 'manga-1', title: '测试漫画'),
        workspaceIdentity: 'local:user-1',
        chapterIndexes: const <int>[1, 2],
      ),
    );

    expect(importCalls, 1);
    expect(controller.pendingBookImportCount, 0);
    expect(controller.message, '《测试漫画》已在导入队列中');

    finishImport.complete();
    await _waitUntil(() => controller.selectedBookId == 'manga-1');
    expect(importCalls, 1);
  });

  test('invalid bookshelf result does not clear the current file list',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-bookshelf-invalid-');
    addTearDown(() => temporary.delete(recursive: true));
    final previous = File(
      '${temporary.path}${Platform.pathSeparator}previous.jpg',
    );
    await previous.writeAsBytes(<int>[1]);
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      importBookshelfBook: (
        request, {
        onProgress,
        abortTrigger,
      }) async {
        return MangaBookshelfImportResult(
          bookId: request.bookId,
          bookTitle: request.bookTitle,
          sourceRoot: temporary.path,
          filePaths: <String>[
            '${temporary.path}${Platform.pathSeparator}missing.jpg',
          ],
          chapterCount: 1,
        );
      },
    );
    addTearDown(controller.dispose);
    await controller.addFiles(<String>[previous.path]);

    controller.enqueueBookshelfImport(
      MangaBookshelfImportRequest.fromBook(
        _book(id: 'broken-manga', title: '失效漫画'),
        workspaceIdentity: 'local:user-1',
      ),
    );
    await _waitUntil(
      () => controller.runState == MangaTranslationRunState.failed,
    );

    expect(controller.files.single.path, previous.absolute.path);
    expect(controller.selectedBookId, isNull);
    expect(controller.message, contains('没有可加入工作台的文件'));
  });

  test('stopping bookshelf import keeps the current file list', () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-bookshelf-stop-');
    addTearDown(() => temporary.delete(recursive: true));
    final previous = File(
      '${temporary.path}${Platform.pathSeparator}previous.jpg',
    );
    final imported = File(
      '${temporary.path}${Platform.pathSeparator}imported.jpg',
    );
    await previous.writeAsBytes(<int>[1]);
    await imported.writeAsBytes(<int>[2]);
    final importStarted = Completer<void>();
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      importBookshelfBook: (
        request, {
        onProgress,
        abortTrigger,
      }) async {
        importStarted.complete();
        await abortTrigger;
        return MangaBookshelfImportResult(
          bookId: request.bookId,
          bookTitle: request.bookTitle,
          sourceRoot: temporary.path,
          filePaths: <String>[imported.path],
          chapterCount: 1,
        );
      },
    );
    addTearDown(controller.dispose);
    await controller.addFiles(<String>[previous.path]);
    controller.enqueueBookshelfImport(
      MangaBookshelfImportRequest.fromBook(
        _book(id: 'manga-1', title: '测试漫画'),
        workspaceIdentity: 'local:user-1',
      ),
    );
    await importStarted.future;

    controller.stop();
    expect(controller.runState, MangaTranslationRunState.stopping);
    await _waitUntil(
      () => controller.runState == MangaTranslationRunState.stopped,
    );

    expect(controller.files.single.path, previous.absolute.path);
    expect(controller.selectedBookId, isNull);
    expect(controller.pendingBookImportCount, 0);
    expect(controller.message, '已停止导入《测试漫画》');
  });

  test('bookshelf run writes only complete chapters once in page order',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-bookshelf-writeback-');
    addTearDown(() => temporary.delete(recursive: true));
    final chapterOnePageOne = File(
      '${temporary.path}${Platform.pathSeparator}chapter-1'
      '${Platform.pathSeparator}page-0001.jpg',
    );
    final chapterOnePageTwo = File(
      '${temporary.path}${Platform.pathSeparator}chapter-1'
      '${Platform.pathSeparator}page-0002.jpg',
    );
    final chapterTwoPageOne = File(
      '${temporary.path}${Platform.pathSeparator}chapter-2'
      '${Platform.pathSeparator}page-0001.jpg',
    );
    final chapterTwoPageTwo = File(
      '${temporary.path}${Platform.pathSeparator}chapter-2'
      '${Platform.pathSeparator}page-0002.jpg',
    );
    for (final file in <File>[
      chapterOnePageOne,
      chapterOnePageTwo,
      chapterTwoPageOne,
      chapterTwoPageTwo,
    ]) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(<int>[1]);
    }
    final persistedChapters = <int>[];
    final persistedPages = <List<Map<String, dynamic>>>[];
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      importBookshelfBook: (
        request, {
        onProgress,
        abortTrigger,
      }) async {
        final files = <File>[
          chapterOnePageOne,
          chapterOnePageTwo,
          chapterTwoPageTwo,
          chapterTwoPageOne,
        ];
        return MangaBookshelfImportResult(
          bookId: request.bookId,
          bookTitle: request.bookTitle,
          sourceRoot: temporary.path,
          filePaths: files.map((file) => file.path).toList(),
          chapterCount: 2,
          pageTargets: <String, MangaBookshelfPageTarget>{
            chapterOnePageOne.path: const MangaBookshelfPageTarget(
              bookId: 'manga-1',
              chapterIndex: 1,
              pageNumber: 1,
            ),
            chapterOnePageTwo.path: const MangaBookshelfPageTarget(
              bookId: 'manga-1',
              chapterIndex: 1,
              pageNumber: 2,
            ),
            chapterTwoPageOne.path: const MangaBookshelfPageTarget(
              bookId: 'manga-1',
              chapterIndex: 2,
              pageNumber: 1,
            ),
            chapterTwoPageTwo.path: const MangaBookshelfPageTarget(
              bookId: 'manga-1',
              chapterIndex: 2,
              pageNumber: 2,
            ),
          },
        );
      },
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async {
        if (filePath == chapterOnePageTwo.absolute.path) {
          throw StateError('第二页翻译失败');
        }
        return MangaWorkflowResult(
          mode: mode,
          imageKey: title,
          mimeType: 'image/png',
          outputImageBase64: base64Encode(<int>[9]),
          project: <String, dynamic>{
            'regions': <dynamic>[],
            'original_width': 100,
            'original_height': 200,
          },
          pageTranslation: '译文-$title',
        );
      },
      persistBookshelfTranslation: ({
        required String bookId,
        required int chapterIndex,
        required String targetLanguage,
        required List<Map<String, dynamic>> pages,
      }) async {
        expect(bookId, 'manga-1');
        expect(targetLanguage, '中文');
        persistedChapters.add(chapterIndex);
        persistedPages.add(pages);
      },
    );
    addTearDown(controller.dispose);
    controller.enqueueBookshelfImport(
      MangaBookshelfImportRequest.fromBook(
        _book(id: 'manga-1', title: '测试漫画'),
        workspaceIdentity: 'local:user-1',
      ),
    );
    await _waitUntil(() => controller.selectedBookId == 'manga-1');

    await controller.run();

    expect(persistedChapters, <int>[2]);
    expect(
      persistedPages.single.map((page) => page['pageNumber']),
      <int>[1, 2],
    );
    expect(controller.runState, MangaTranslationRunState.partialFailure);
    expect(controller.message, contains('已写入书架译文 1 章'));
    expect(
      controller.files
          .where((file) => file.path.contains('chapter-2'))
          .map((file) => file.message),
      everyElement('已完成并写入书架译文'),
    );
  });

  test('bookshelf writeback failure marks the chapter as failed', () async {
    final temporary = await Directory.systemTemp
        .createTemp('qingjuan-bookshelf-writeback-failure-');
    addTearDown(() => temporary.delete(recursive: true));
    final page = File('${temporary.path}${Platform.pathSeparator}page.jpg');
    await page.writeAsBytes(<int>[1]);
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      importBookshelfBook: (
        request, {
        onProgress,
        abortTrigger,
      }) async =>
          MangaBookshelfImportResult(
        bookId: request.bookId,
        bookTitle: request.bookTitle,
        sourceRoot: temporary.path,
        filePaths: <String>[page.path],
        chapterCount: 1,
        pageTargets: <String, MangaBookshelfPageTarget>{
          page.path: const MangaBookshelfPageTarget(
            bookId: 'manga-1',
            chapterIndex: 4,
            pageNumber: 1,
          ),
        },
      ),
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async =>
          MangaWorkflowResult(
        mode: mode,
        imageKey: title,
        mimeType: 'image/png',
        outputImageBase64: base64Encode(<int>[9]),
        project: const <String, dynamic>{'regions': <dynamic>[]},
        pageTranslation: '译文',
      ),
      persistBookshelfTranslation: ({
        required String bookId,
        required int chapterIndex,
        required String targetLanguage,
        required List<Map<String, dynamic>> pages,
      }) async {
        throw StateError('后端拒绝保存');
      },
    );
    addTearDown(controller.dispose);
    controller.enqueueBookshelfImport(
      MangaBookshelfImportRequest.fromBook(
        _book(id: 'manga-1', title: '测试漫画'),
        workspaceIdentity: 'local:user-1',
      ),
    );
    await _waitUntil(() => controller.selectedBookId == 'manga-1');

    await controller.run();

    expect(controller.runState, MangaTranslationRunState.failed);
    expect(controller.files.single.status, MangaTranslationFileStatus.failed);
    expect(controller.files.single.message, contains('写入书架译文失败'));
    expect(controller.files.single.message, contains('后端拒绝保存'));
    expect(controller.message, isNot(contains('已写入书架译文')));
  });

  test('text editor loads and atomically saves a complete project document',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-text-editor-save-');
    addTearDown(() => temporary.delete(recursive: true));
    final source = File('${temporary.path}${Platform.pathSeparator}page.jpg');
    await source.writeAsBytes(<int>[1, 2, 3]);
    final sourceKey = source.absolute.path;
    final paths = MangaWorkspacePaths.forSource(source.path);
    await File(paths.projectPath).parent.create(recursive: true);
    await File(paths.projectPath).writeAsString(
      jsonEncode(<String, dynamic>{
        '_metadata': <String, dynamic>{'custom': 'keep-root'},
        sourceKey: <String, dynamic>{
          'original_width': 100,
          'original_height': 200,
          'custom_page': 'keep-page',
          'regions': <Map<String, dynamic>>[
            <String, dynamic>{
              'order': 1,
              'translation': '旧译',
              'custom_region': 'keep-region',
            },
          ],
        },
      }),
    );
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async {
        throw StateError('已有工程不应重新识别');
      },
    );
    addTearDown(controller.dispose);
    await controller.addFiles(<String>[source.path]);

    final project = await controller.loadTextEditorProject(
      controller.files.single,
    );
    final page = project[sourceKey] as Map<String, dynamic>;
    final region = (page['regions'] as List).single as Map<String, dynamic>;
    region['translation'] = '人工改译';
    await controller.saveTextEditorProject(controller.files.single, project);

    final saved = jsonDecode(await File(paths.projectPath).readAsString())
        as Map<String, dynamic>;
    expect((saved['_metadata'] as Map<String, dynamic>)['custom'], 'keep-root');
    final savedPage = saved[sourceKey] as Map<String, dynamic>;
    expect(savedPage['custom_page'], 'keep-page');
    final savedRegion =
        (savedPage['regions'] as List).single as Map<String, dynamic>;
    expect(savedRegion['translation'], '人工改译');
    expect(savedRegion['custom_region'], 'keep-region');
    expect(await File(paths.editorBasePath).readAsBytes(), <int>[1, 2, 3]);
    expect(controller.files.single.hasProject, isTrue);
    expect(controller.files.single.message, contains('等待重新渲染'));
  });

  test('text editor creates a project with export original when none exists',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-text-editor-create-');
    addTearDown(() => temporary.delete(recursive: true));
    final source = File('${temporary.path}${Platform.pathSeparator}page.jpg');
    await source.writeAsBytes(<int>[1]);
    final modes = <String>[];
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async {
        modes.add(mode);
        expect(project, isNull);
        return MangaWorkflowResult(
          mode: mode,
          imageKey: 'upload.jpg',
          mimeType: 'image/png',
          projectDocument: <String, dynamic>{
            'upload.jpg': <String, dynamic>{
              'regions': <Map<String, dynamic>>[
                <String, dynamic>{
                  'order': 1,
                  'text': '原文',
                  'custom_region': 'keep',
                },
              ],
              'original_width': 320,
              'original_height': 480,
              'custom_page': 'keep',
            },
          },
          original: const <String, dynamic>{'0': '原文'},
        );
      },
    );
    addTearDown(controller.dispose);
    await controller.addFiles(<String>[source.path]);

    final project = await controller.loadTextEditorProject(
      controller.files.single,
    );

    expect(modes, <String>['export_original']);
    expect(project.keys, <String>[source.absolute.path]);
    expect(
      (project[source.absolute.path] as Map<String, dynamic>)['custom_page'],
      'keep',
    );
    final paths = MangaWorkspacePaths.forSource(source.path);
    expect(await File(paths.projectPath).exists(), isTrue);
    expect(await File(paths.originalPath).exists(), isTrue);
    expect(controller.files.single.status, MangaTranslationFileStatus.ready);
    expect(controller.files.single.hasProject, isTrue);
  });

  test('text editor rerenders without replacing manually saved project fields',
      () async {
    final temporary =
        await Directory.systemTemp.createTemp('qingjuan-text-editor-render-');
    addTearDown(() => temporary.delete(recursive: true));
    final source = File('${temporary.path}${Platform.pathSeparator}page.jpg');
    await source.writeAsBytes(<int>[1]);
    final sourceKey = source.absolute.path;
    final project = <String, dynamic>{
      '_metadata': <String, dynamic>{'custom': 'keep-root'},
      sourceKey: <String, dynamic>{
        'regions': <Map<String, dynamic>>[
          <String, dynamic>{
            'order': 1,
            'translation': '人工译文',
            'custom_region': 'keep-region',
          },
        ],
        'custom_page': 'keep-page',
      },
    };
    Object? receivedProject;
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async {
        expect(mode, 'import_translation_render');
        expect(companion, isNull);
        receivedProject = project;
        return MangaWorkflowResult(
          mode: mode,
          imageKey: 'upload.jpg',
          mimeType: 'image/png',
          outputImageBase64: base64Encode(<int>[9, 8, 7]),
          inpaintedImageBase64: base64Encode(<int>[6, 5]),
          projectDocument: const <String, dynamic>{
            'upload.jpg': <String, dynamic>{'regions': <dynamic>[]},
          },
        );
      },
    );
    addTearDown(controller.dispose);
    await controller.addFiles(<String>[source.path]);

    final result = await controller.renderTextEditorProject(
      controller.files.single,
      project,
    );

    expect(identical(receivedProject, project), isTrue);
    final paths = MangaWorkspacePaths.forSource(source.path);
    expect(result.resultPath, paths.resultPath);
    expect(result.bookshelfBound, isFalse);
    expect(result.message, '已保存并重新渲染');
    expect(await File(paths.resultPath).readAsBytes(), <int>[9, 8, 7]);
    final saved = jsonDecode(await File(paths.projectPath).readAsString())
        as Map<String, dynamic>;
    expect((saved['_metadata'] as Map<String, dynamic>)['custom'], 'keep-root');
    expect(
      (saved[sourceKey] as Map<String, dynamic>)['custom_page'],
      'keep-page',
    );
    expect(
        controller.files.single.status, MangaTranslationFileStatus.succeeded);
  });

  test('text editor writes a complete bookshelf chapter in page order',
      () async {
    final temporary = await Directory.systemTemp
        .createTemp('qingjuan-text-editor-bookshelf-');
    addTearDown(() => temporary.delete(recursive: true));
    final pageOne = File(
      '${temporary.path}${Platform.pathSeparator}chapter'
      '${Platform.pathSeparator}page-0001.jpg',
    );
    final pageTwo = File(
      '${temporary.path}${Platform.pathSeparator}chapter'
      '${Platform.pathSeparator}page-0002.jpg',
    );
    for (final file in <File>[pageOne, pageTwo]) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(<int>[1]);
    }
    final persisted = <List<Map<String, dynamic>>>[];
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      importBookshelfBook: (
        request, {
        onProgress,
        abortTrigger,
      }) async =>
          MangaBookshelfImportResult(
        bookId: request.bookId,
        bookTitle: request.bookTitle,
        sourceRoot: temporary.path,
        filePaths: <String>[pageTwo.path, pageOne.path],
        chapterCount: 1,
        pageTargets: <String, MangaBookshelfPageTarget>{
          pageOne.path: const MangaBookshelfPageTarget(
            bookId: 'manga-1',
            chapterIndex: 3,
            pageNumber: 1,
          ),
          pageTwo.path: const MangaBookshelfPageTarget(
            bookId: 'manga-1',
            chapterIndex: 3,
            pageNumber: 2,
          ),
        },
      ),
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async =>
          MangaWorkflowResult(
        mode: mode,
        imageKey: title,
        mimeType: 'image/png',
        outputImageBase64: base64Encode(<int>[9]),
      ),
      persistBookshelfTranslation: ({
        required String bookId,
        required int chapterIndex,
        required String targetLanguage,
        required List<Map<String, dynamic>> pages,
      }) async {
        expect(bookId, 'manga-1');
        expect(chapterIndex, 3);
        persisted.add(pages);
      },
    );
    addTearDown(controller.dispose);
    controller.enqueueBookshelfImport(
      MangaBookshelfImportRequest.fromBook(
        _book(id: 'manga-1', title: '测试漫画'),
        workspaceIdentity: 'local:user-1',
      ),
    );
    await _waitUntil(() => controller.selectedBookId == 'manga-1');
    final pageTwoPaths = MangaWorkspacePaths.forSource(pageTwo.path);
    await File(pageTwoPaths.resultPath).parent.create(recursive: true);
    await File(pageTwoPaths.resultPath).writeAsBytes(<int>[2]);
    await File(pageTwoPaths.projectPath).parent.create(recursive: true);
    await File(pageTwoPaths.projectPath).writeAsString(
      jsonEncode(<String, dynamic>{
        pageTwo.absolute.path: <String, dynamic>{
          'regions': <Map<String, dynamic>>[
            <String, dynamic>{'translation': '第二页'},
          ],
        },
      }),
    );
    final pageOneProject = <String, dynamic>{
      pageOne.absolute.path: <String, dynamic>{
        'regions': <Map<String, dynamic>>[
          <String, dynamic>{
            'translation': '',
            'translation_raw': '第一页[BR]第二行',
          },
        ],
      },
    };

    final outcome = await controller.renderTextEditorProject(
      controller.files.firstWhere(
        (file) => file.path == pageOne.absolute.path,
      ),
      pageOneProject,
    );

    expect(outcome.bookshelfBound, isTrue);
    expect(outcome.bookshelfWritten, isTrue);
    expect(outcome.missingBookshelfPages, 0);
    expect(persisted, hasLength(1));
    expect(
      persisted.single.map((page) => page['pageNumber']),
      <int>[1, 2],
    );
    expect(persisted.single[0]['pageTranslation'], '第一页\n第二行');
    expect(persisted.single[1]['pageTranslation'], '第二页');
    expect(
      base64Decode(persisted.single[1]['outputImageBase64'] as String),
      <int>[2],
    );
  });

  test('text editor keeps local result when a bookshelf chapter has gaps',
      () async {
    final temporary = await Directory.systemTemp
        .createTemp('qingjuan-text-editor-bookshelf-gap-');
    addTearDown(() => temporary.delete(recursive: true));
    final pageOne = File('${temporary.path}${Platform.pathSeparator}page1.jpg');
    final pageTwo = File('${temporary.path}${Platform.pathSeparator}page2.jpg');
    await pageOne.writeAsBytes(<int>[1]);
    await pageTwo.writeAsBytes(<int>[2]);
    var persistCount = 0;
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    addTearDown(api.close);
    final controller = MangaTranslationController(
      api,
      importBookshelfBook: (
        request, {
        onProgress,
        abortTrigger,
      }) async =>
          MangaBookshelfImportResult(
        bookId: request.bookId,
        bookTitle: request.bookTitle,
        sourceRoot: temporary.path,
        filePaths: <String>[pageOne.path, pageTwo.path],
        chapterCount: 1,
        pageTargets: <String, MangaBookshelfPageTarget>{
          pageOne.path: const MangaBookshelfPageTarget(
            bookId: 'manga-1',
            chapterIndex: 1,
            pageNumber: 1,
          ),
          pageTwo.path: const MangaBookshelfPageTarget(
            bookId: 'manga-1',
            chapterIndex: 1,
            pageNumber: 2,
          ),
        },
      ),
      invokeWorkflow: ({
        required String filePath,
        required String mode,
        String language = '中文',
        String title = '',
        Object? project,
        Object? companion,
        String? translatedFilePath,
        int upscaleFactor = 2,
        Future<void>? abortTrigger,
      }) async =>
          MangaWorkflowResult(
        mode: mode,
        imageKey: title,
        mimeType: 'image/png',
        outputImageBase64: base64Encode(<int>[9]),
      ),
      persistBookshelfTranslation: ({
        required String bookId,
        required int chapterIndex,
        required String targetLanguage,
        required List<Map<String, dynamic>> pages,
      }) async {
        persistCount += 1;
      },
    );
    addTearDown(controller.dispose);
    controller.enqueueBookshelfImport(
      MangaBookshelfImportRequest.fromBook(
        _book(id: 'manga-1', title: '测试漫画'),
        workspaceIdentity: 'local:user-1',
      ),
    );
    await _waitUntil(() => controller.selectedBookId == 'manga-1');
    final project = <String, dynamic>{
      pageOne.absolute.path: <String, dynamic>{
        'regions': <Map<String, dynamic>>[
          <String, dynamic>{'translation': '第一页'},
        ],
      },
    };

    final outcome = await controller.renderTextEditorProject(
      controller.files.firstWhere(
        (file) => file.path == pageOne.absolute.path,
      ),
      project,
    );

    expect(outcome.bookshelfBound, isTrue);
    expect(outcome.bookshelfWritten, isFalse);
    expect(outcome.missingBookshelfPages, 1);
    expect(outcome.message, contains('本章还有 1 页未生成'));
    expect(persistCount, 0);
    expect(
      await File(MangaWorkspacePaths.forSource(pageOne.path).resultPath)
          .readAsBytes(),
      <int>[9],
    );
    expect(controller.files.first.status, MangaTranslationFileStatus.succeeded);
  });
}

Book _book({
  required String id,
  required String title,
  String kind = '漫画',
}) {
  return Book(
    id: id,
    title: title,
    sourceUrl: 'https://example.com/$id',
    kind: kind,
    language: '日文',
    status: '已导入',
    chapterCount: 2,
    translated: false,
    synopsis: '',
    lastReadChapterIndex: 1,
  );
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TestFailure('Timed out waiting for controller state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
