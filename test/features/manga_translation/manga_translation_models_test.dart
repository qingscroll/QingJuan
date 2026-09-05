import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/features/manga_translation/manga_translation_models.dart';

void main() {
  test('九种工作流保持上游顺序和 API 值', () {
    expect(
      MangaWorkflowMode.values.map((mode) => mode.apiValue),
      <String>[
        'normal',
        'export_translation',
        'export_original',
        'translate_json_only',
        'import_translation_render',
        'colorize_only',
        'upscale_only',
        'inpaint_only',
        'replace_translation',
      ],
    );
    expect(MangaWorkflowMode.normal.label, '正常翻译流程');
    expect(MangaWorkflowMode.exportOriginal.startLabel, '仅生成原文模板');
    expect(
      MangaWorkflowMode.translateJsonOnly.startLabel,
      '开始仅翻译（JSON）',
    );
    expect(
      MangaWorkflowMode.replaceTranslation.description,
      contains('manga_translator_work/translated_images'),
    );
  });

  test('工程路径保持上游目录和 sidecar 命名', () {
    final source = File('chapter/page01.png').absolute.path;
    final paths = MangaWorkspacePaths.forSource(source);

    expect(paths.workRoot, endsWith('manga_translator_work'));
    expect(paths.projectPath,
        endsWith('json${Platform.pathSeparator}page01_translations.json'));
    expect(paths.legacyProjectPath,
        endsWith('chapter${Platform.pathSeparator}page01_translations.json'));
    expect(paths.originalPath,
        endsWith('originals${Platform.pathSeparator}page01_original.json'));
    expect(
        paths.translatedPath,
        endsWith(
            'translations${Platform.pathSeparator}page01_translated.json'));
    expect(paths.inpaintedPath,
        endsWith('inpainted${Platform.pathSeparator}page01_inpainted.png'));
    expect(
      paths.directories
          .map((directory) => directory.split(Platform.pathSeparator).last),
      <String>[
        'json',
        'originals',
        'translations',
        'inpainted',
        'editor_base',
        'translated_images',
        'result',
        'yolo_labels',
        'paint_overlay',
      ],
    );
  });
}
