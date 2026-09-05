import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
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
    const file = MangaTranslationFile(
      path: r'C:\fixtures\page-0001.png',
      sourceRoot: r'C:\fixtures',
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
      const ValueKey<String>(
        r'edit-manga-file-C:\fixtures\page-0001.png',
      ),
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
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }
}

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
