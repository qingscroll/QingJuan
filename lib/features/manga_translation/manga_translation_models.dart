import 'dart:io';

import 'package:path/path.dart' as path;

enum MangaWorkflowMode {
  normal(
    apiValue: 'normal',
    label: '正常翻译流程',
    description: '提示：标准翻译流程，会进行检测、OCR、翻译和渲染',
    startLabel: '开始翻译',
  ),
  exportTranslation(
    apiValue: 'export_translation',
    label: '导出翻译',
    description:
        '提示：导出翻译后，可在 manga_translator_work/translations/ 目录查看 图片名_translated.json 文件',
    startLabel: '导出翻译',
  ),
  exportOriginal(
    apiValue: 'export_original',
    label: '导出原文',
    description:
        '提示：导出原文后，可在 manga_translator_work/originals/ 目录手动翻译 图片名_original.json 文件，然后使用「导入翻译并渲染」模式',
    startLabel: '仅生成原文模板',
  ),
  translateJsonOnly(
    apiValue: 'translate_json_only',
    label: '仅翻译（JSON）',
    description:
        '提示：需要预先存在 JSON 数据。程序会从 JSON 读取原文并执行翻译，完成后回写 JSON，并删除图片名_original.json。',
    startLabel: '开始仅翻译（JSON）',
  ),
  importTranslationRender(
    apiValue: 'import_translation_render',
    label: '导入翻译并渲染',
    description:
        '提示：将从 manga_translator_work/originals/ 或 translations/ 目录读取 JSON 文件并渲染（优先使用 _original.json）',
    startLabel: '导入翻译并渲染',
  ),
  colorizeOnly(
    apiValue: 'colorize_only',
    label: '仅上色',
    description: '提示：仅对图片进行上色处理，不进行检测、OCR、翻译和渲染',
    startLabel: '开始上色',
  ),
  upscaleOnly(
    apiValue: 'upscale_only',
    label: '仅超分',
    description: '提示：仅对图片进行超分处理，不进行检测、OCR、翻译和渲染',
    startLabel: '开始超分',
  ),
  inpaintOnly(
    apiValue: 'inpaint_only',
    label: '仅修复',
    description: '提示：仅检测文字并执行图像修复，输出无字干净图，不进行翻译和渲染',
    startLabel: '开始修复',
  ),
  replaceTranslation(
    apiValue: 'replace_translation',
    label: '替换翻译',
    description:
        '提示：请将翻译图放到 manga_translator_work/translated_images 并与生肉图同名。程序会提取翻译图文字、在生肉图上匹配区域、修复原文字区域，再渲染译文。',
    startLabel: '开始替换翻译',
  );

  const MangaWorkflowMode({
    required this.apiValue,
    required this.label,
    required this.description,
    required this.startLabel,
  });

  final String apiValue;
  final String label;
  final String description;
  final String startLabel;

  static MangaWorkflowMode fromApiValue(String? value) {
    return values.firstWhere(
      (mode) => mode.apiValue == value,
      orElse: () => MangaWorkflowMode.normal,
    );
  }
}

enum MangaTranslationFileStatus {
  ready,
  running,
  succeeded,
  failed,
  stopped,
}

class MangaTranslationFile {
  const MangaTranslationFile({
    required this.path,
    required this.sourceRoot,
    required this.relativePath,
    this.hasProject = false,
    this.status = MangaTranslationFileStatus.ready,
    this.message = '',
    this.outputPath,
  });

  final String path;
  final String sourceRoot;
  final String relativePath;
  final bool hasProject;
  final MangaTranslationFileStatus status;
  final String message;
  final String? outputPath;

  String get name => path.split(Platform.pathSeparator).last;

  MangaTranslationFile copyWith({
    MangaTranslationFileStatus? status,
    bool? hasProject,
    String? message,
    String? outputPath,
  }) {
    return MangaTranslationFile(
      path: path,
      sourceRoot: sourceRoot,
      relativePath: relativePath,
      hasProject: hasProject ?? this.hasProject,
      status: status ?? this.status,
      message: message ?? this.message,
      outputPath: outputPath ?? this.outputPath,
    );
  }
}

class MangaTextEditorRenderResult {
  const MangaTextEditorRenderResult({
    required this.resultPath,
    required this.bookshelfBound,
    required this.bookshelfWritten,
    required this.missingBookshelfPages,
    required this.message,
  });

  final String resultPath;
  final bool bookshelfBound;
  final bool bookshelfWritten;
  final int missingBookshelfPages;
  final String message;
}

enum MangaTranslationRunState {
  ready,
  importing,
  starting,
  running,
  stopping,
  completed,
  partialFailure,
  failed,
  stopped,
}

class MangaWorkspacePaths {
  MangaWorkspacePaths._({required this.sourcePath})
      : sourceDirectory = path.dirname(sourcePath),
        stem = path.basenameWithoutExtension(sourcePath),
        fileName = path.basename(sourcePath) {
    workRoot = path.join(sourceDirectory, workDirectoryName);
    jsonDirectory = path.join(workRoot, 'json');
    originalsDirectory = path.join(workRoot, 'originals');
    translationsDirectory = path.join(workRoot, 'translations');
    inpaintedDirectory = path.join(workRoot, 'inpainted');
    editorBaseDirectory = path.join(workRoot, 'editor_base');
    translatedImagesDirectory = path.join(workRoot, 'translated_images');
    resultDirectory = path.join(workRoot, 'result');
    yoloLabelsDirectory = path.join(workRoot, 'yolo_labels');
    paintOverlayDirectory = path.join(workRoot, 'paint_overlay');
  }

  factory MangaWorkspacePaths.forSource(String sourcePath) {
    return MangaWorkspacePaths._(
      sourcePath: File(sourcePath).absolute.path,
    );
  }

  static const workDirectoryName = 'manga_translator_work';

  final String sourcePath;
  final String sourceDirectory;
  final String stem;
  final String fileName;
  late final String workRoot;
  late final String jsonDirectory;
  late final String originalsDirectory;
  late final String translationsDirectory;
  late final String inpaintedDirectory;
  late final String editorBaseDirectory;
  late final String translatedImagesDirectory;
  late final String resultDirectory;
  late final String yoloLabelsDirectory;
  late final String paintOverlayDirectory;

  String get projectPath =>
      path.join(jsonDirectory, '${stem}_translations.json');
  String get pendingRenderPath => '$projectPath.pending-render';
  String get legacyProjectPath =>
      path.join(sourceDirectory, '${stem}_translations.json');
  String get originalPath =>
      path.join(originalsDirectory, '${stem}_original.json');
  String get translatedPath =>
      path.join(translationsDirectory, '${stem}_translated.json');
  String get outputFileName => '$stem.png';
  String get inpaintedPath =>
      path.join(inpaintedDirectory, '${stem}_inpainted.png');
  String get editorBasePath => path.join(editorBaseDirectory, fileName);
  String get translatedImagePath =>
      path.join(translatedImagesDirectory, fileName);
  String get resultPath => path.join(resultDirectory, outputFileName);

  List<String> get directories => <String>[
        jsonDirectory,
        originalsDirectory,
        translationsDirectory,
        inpaintedDirectory,
        editorBaseDirectory,
        translatedImagesDirectory,
        resultDirectory,
        yoloLabelsDirectory,
        paintOverlayDirectory,
      ];
}
