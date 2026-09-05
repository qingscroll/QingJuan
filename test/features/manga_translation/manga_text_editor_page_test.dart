import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/features/manga_translation/editor/manga_text_editor_page.dart';
import 'package:qingjuan/features/manga_translation/manga_translation_controller.dart';
import 'package:qingjuan/features/manga_translation/manga_translation_models.dart';
import 'package:qingjuan/features/manga_translation/manga_translation_page.dart';

void main() {
  testWidgets('file editor opens workbench and saves manually corrected text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixturePath = path.join('fixtures', 'page-0001.png');
    final file = MangaTranslationFile(
      path: fixturePath,
      sourceRoot: path.dirname(fixturePath),
      relativePath: 'page-0001.png',
      hasProject: true,
    );
    final controller = _FakeTextEditorController(
      file: file,
      document: <String, dynamic>{
        file.path: <String, dynamic>{
          'original_width': 100,
          'original_height': 140,
          'regions': <Map<String, dynamic>>[
            <String, dynamic>{
              'order': 1,
              'bbox': <int>[10, 15, 70, 110],
              'text': 'ねー',
              'texts': <String>['ねー'],
              'translation': '',
              'translation_raw': '',
              'translation_rich': <String, dynamic>{'stale': true},
              'direction': 'v',
            },
          ],
        },
      },
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      FluentApp(
        theme: buildQingJuanTheme(
          Brightness.light,
          platform: TargetPlatform.windows,
        ),
        home: MangaTranslationPage(controller: controller),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final editButton = find.byKey(
      ValueKey<String>('edit-manga-file-${file.path}'),
    );
    expect(editButton, findsOneWidget);
    await tester.tap(editButton);
    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey('manga-text-region-inspector')),
    );

    expect(
        find.byKey(const ValueKey('manga-text-editor-page')), findsOneWidget);
    expect(find.textContaining('漫画文本工作台 · page-0001.png'), findsOneWidget);
    expect(find.text('页面'), findsOneWidget);
    expect(find.text('画布'), findsOneWidget);
    expect(find.text('文本区域'), findsOneWidget);
    expect(find.text('未翻译 1'), findsOneWidget);
    expect(find.text('ねー'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('manga-region-translation-text')),
      '喂——',
    );
    await tester.tap(
      find.byKey(const ValueKey('save-manga-text-project')),
    );
    await _pumpUntilFound(tester, find.textContaining('工程已保存'));

    final saved = controller.savedDocument!;
    final page = saved[file.path] as Map<String, dynamic>;
    final region = (page['regions'] as List).single as Map<String, dynamic>;
    expect(region['translation'], '喂——');
    expect(region['translation_raw'], '喂——');
    expect(region.containsKey('translation_rich'), isFalse);

    await tester.tap(
      find.byKey(const ValueKey('toggle-manga-region-draw')),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      tester
          .widget<ToggleButton>(
            find.byKey(const ValueKey('toggle-manga-region-draw')),
          )
          .checked,
      isTrue,
    );
    final surface = find.byKey(
      const ValueKey('manga-text-region-gesture-surface'),
    );
    final surfaceRect = tester.getRect(surface);
    final gesture = await tester.startGesture(
      surfaceRect.center - const Offset(45, 55),
    );
    await gesture.moveBy(const Offset(25, 30));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(50, 60));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.textContaining('已新增空白文字区域'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('manga-region-translation-text')),
      '人工补译',
    );
    await tester.tap(
      find.byKey(const ValueKey('save-manga-text-project')),
    );
    await _pumpUntilFound(tester, find.textContaining('工程已保存'));
    final addedPage =
        controller.savedDocument![file.path] as Map<String, dynamic>;
    final regions = addedPage['regions'] as List;
    expect(regions, hasLength(2));
    expect((regions.last as Map<String, dynamic>)['translation'], '人工补译');
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('narrow workbench switches between canvas and text panels',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const file = MangaTranslationFile(
      path: r'C:\fixtures\compact.png',
      sourceRoot: r'C:\fixtures',
      relativePath: 'compact.png',
      hasProject: true,
    );
    final controller = _FakeTextEditorController(
      file: file,
      document: <String, dynamic>{
        file.path: <String, dynamic>{
          'original_width': 120,
          'original_height': 180,
          'regions': <Map<String, dynamic>>[
            <String, dynamic>{
              'order': 1,
              'bbox': <int>[10, 20, 80, 140],
              'text': 'はい',
              'translation': '好的',
              'direction': 'v',
            },
          ],
        },
      },
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      FluentApp(
        theme: buildQingJuanTheme(
          Brightness.light,
          platform: TargetPlatform.windows,
        ),
        home: MangaTextEditorPage(
          controller: controller,
          files: const <MangaTranslationFile>[file],
          initialFile: file,
        ),
      ),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey('manga-editor-pane-canvas')),
    );

    expect(
        find.byKey(const ValueKey('manga-editor-pane-pages')), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-editor-pane-regions')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('manga-text-region-canvas')), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-text-region-inspector')),
        findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('manga-editor-pane-regions')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const ValueKey('manga-text-region-inspector')),
        findsOneWidget);
    expect(find.text('识别原文'), findsOneWidget);
    expect(find.text('译文'), findsOneWidget);
  });

  testWidgets('saving locks focused text, direction, and region drawing',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _FakeTextEditorController(
      file: _editorFile,
      document: _editorDocument(),
    )..saveCompletion = Completer<void>();
    addTearDown(controller.dispose);
    await _openEditor(tester, controller);
    final translation =
        find.byKey(const ValueKey('manga-region-translation-text'));
    await tester.enterText(translation, '人工译文');
    // Invoke the action while the text field still owns the input connection.
    tester
        .widget<Button>(find.byKey(const ValueKey('save-manga-text-project')))
        .onPressed!();
    await tester.pump();

    expect(tester.widget<TextBox>(translation).readOnly, isTrue);
    expect(
      tester
          .widget<TextBox>(
              find.byKey(const ValueKey('manga-region-source-text')))
          .readOnly,
      isTrue,
    );
    expect(
      tester
          .widget<ToggleSwitch>(
              find.byKey(const ValueKey('manga-region-direction')))
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<ToggleButton>(
              find.byKey(const ValueKey('toggle-manga-region-draw')))
          .onChanged,
      isNull,
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '保存中输入'),
    );
    await tester.pump();
    expect(tester.widget<TextBox>(translation).controller!.text, '人工译文');
    controller.saveCompletion!.complete();
    await _pumpUntilFound(tester, find.textContaining('工程已保存'));
    expect(tester.widget<TextBox>(translation).readOnly, isFalse);
    expect(_savedRegion(controller)['translation'], '人工译文');
  });

  testWidgets('rendering locks edits and reloads repeated result paths',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('manga-editor-image-'),
    );
    final resultFile = File('${directory!.path}/result.png');
    await tester.runAsync(() => resultFile.writeAsBytes(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=',
        )));
    addTearDown(() => directory.delete(recursive: true));
    final controller = _FakeTextEditorController(
      file: _editorFile,
      document: _editorDocument(),
    )
      ..renderPath = resultFile.path
      ..renderCompletion = Completer<void>();
    addTearDown(controller.dispose);
    await _openEditor(tester, controller);
    final translation =
        find.byKey(const ValueKey('manga-region-translation-text'));
    await tester.enterText(translation, '第一次译文');
    final renderButton =
        find.byKey(const ValueKey('render-manga-text-project'));
    tester.widget<FilledButton>(renderButton).onPressed!();
    await tester.pump();
    expect(tester.widget<TextBox>(translation).readOnly, isTrue);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '渲染中输入'),
    );
    await tester.pump();
    expect(tester.widget<TextBox>(translation).controller!.text, '第一次译文');
    controller.renderCompletion!.complete();
    await _pumpUntilFound(
      tester,
      find.byKey(ValueKey<String>('${resultFile.path}#1')),
    );
    expect(_savedRegion(controller)['translation'], '第一次译文');

    controller.renderCompletion = null;
    await tester.enterText(translation, '第二次译文');
    await tester.tap(renderButton);
    await _pumpUntilFound(
      tester,
      find.byKey(ValueKey<String>('${resultFile.path}#2')),
    );
    expect(find.byKey(ValueKey<String>('${resultFile.path}#1')), findsNothing);
    expect(controller.renderCount, 2);
    expect(_savedRegion(controller)['translation'], '第二次译文');
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('route back saves unsaved changes and waits for completion',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _FakeTextEditorController(
      file: _editorFile,
      document: _editorDocument(),
    )..saveCompletion = Completer<void>();
    addTearDown(controller.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(FluentApp(
      navigatorKey: navigator,
      theme: buildQingJuanTheme(
        Brightness.light,
        platform: TargetPlatform.windows,
      ),
      home: const Center(child: Text('书架页面')),
    ));
    unawaited(navigator.currentState!.push<void>(PageRouteBuilder<void>(
      pageBuilder: (_, __, ___) => MangaTextEditorPage(
        controller: controller,
        files: const <MangaTranslationFile>[_editorFile],
        initialFile: _editorFile,
      ),
    )));
    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey('manga-text-region-inspector')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('manga-region-translation-text')),
      '返回时自动保存',
    );
    await tester.pump();
    await navigator.currentState!.maybePop();
    await tester.pump();
    expect(
        find.byKey(const ValueKey('manga-text-editor-page')), findsOneWidget);
    expect(_savedRegion(controller)['translation'], '返回时自动保存');
    await navigator.currentState!.maybePop();
    await tester.pump();
    expect(
        find.byKey(const ValueKey('manga-text-editor-page')), findsOneWidget);
    controller.saveCompletion!.complete();
    for (var i = 0; i < 10; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('manga-text-editor-page')), findsNothing);
    expect(find.text('书架页面'), findsOneWidget);
  });
}

const _editorFile = MangaTranslationFile(
  path: r'C:\fixtures\editor.png',
  sourceRoot: r'C:\fixtures',
  relativePath: 'editor.png',
  hasProject: true,
);

Map<String, dynamic> _editorDocument() => <String, dynamic>{
      _editorFile.path: <String, dynamic>{
        'original_width': 100,
        'original_height': 140,
        'regions': <Map<String, dynamic>>[
          <String, dynamic>{
            'order': 1,
            'bbox': <int>[10, 15, 70, 110],
            'text': 'ねー',
            'translation': '',
            'direction': 'v',
          },
        ],
      },
    };

Map<String, dynamic> _savedRegion(_FakeTextEditorController controller) =>
    ((controller.savedDocument![_editorFile.path]
            as Map<String, dynamic>)['regions'] as List)
        .single as Map<String, dynamic>;

Future<void> _openEditor(
  WidgetTester tester,
  _FakeTextEditorController controller,
) async {
  await tester.pumpWidget(FluentApp(
    theme: buildQingJuanTheme(
      Brightness.light,
      platform: TargetPlatform.windows,
    ),
    home: MangaTextEditorPage(
      controller: controller,
      files: <MangaTranslationFile>[controller.file],
      initialFile: controller.file,
    ),
  ));
  await _pumpUntilFound(
    tester,
    find.byKey(const ValueKey('manga-text-region-inspector')),
  );
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder,
) async {
  for (var attempt = 0; attempt < 40; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('等待界面元素超时：$finder');
}

class _FakeTextEditorController extends MangaTranslationController {
  factory _FakeTextEditorController({
    required MangaTranslationFile file,
    required Map<String, dynamic> document,
  }) {
    final api = ApiClient(() => 'http://127.0.0.1:19453');
    return _FakeTextEditorController._(
      file: file,
      document: document,
      api: api,
    );
  }

  _FakeTextEditorController._({
    required this.file,
    required Map<String, dynamic> document,
    required ApiClient api,
  })  : _document = document,
        _api = api,
        super(api);

  final MangaTranslationFile file;
  final Map<String, dynamic> _document;
  final ApiClient _api;
  Map<String, dynamic>? savedDocument;
  Completer<void>? saveCompletion;
  Completer<void>? renderCompletion;
  String? renderPath;
  int renderCount = 0;

  @override
  List<MangaTranslationFile> get files => <MangaTranslationFile>[file];

  @override
  Future<void> initialize() => Future<void>.value();

  @override
  Future<Map<String, dynamic>> loadTextEditorProject(
    MangaTranslationFile item,
  ) async {
    return _copy(_document);
  }

  @override
  Future<void> saveTextEditorProject(
    MangaTranslationFile item,
    Map<String, dynamic> project,
  ) async {
    savedDocument = _copy(project);
    await saveCompletion?.future;
  }

  @override
  Future<MangaTextEditorRenderResult> renderTextEditorProject(
    MangaTranslationFile item,
    Map<String, dynamic> project,
  ) async {
    savedDocument = _copy(project);
    renderCount += 1;
    await renderCompletion?.future;
    return MangaTextEditorRenderResult(
      resultPath: renderPath!,
      bookshelfBound: false,
      bookshelfWritten: false,
      missingBookshelfPages: 0,
      message: '已重新渲染译文。',
    );
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }
}

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
