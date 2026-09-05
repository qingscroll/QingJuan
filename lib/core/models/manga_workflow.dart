typedef MangaJson = Map<String, dynamic>;

class MangaWorkflowResult {
  const MangaWorkflowResult({
    required this.mode,
    required this.imageKey,
    required this.mimeType,
    this.outputImageBase64,
    this.inpaintedImageBase64,
    this.project,
    this.projectDocument,
    this.original,
    this.translated,
    this.pageTranslation,
    this.diagnostics = const <String, dynamic>{},
  });

  factory MangaWorkflowResult.fromJson(Map<String, dynamic> json) {
    return MangaWorkflowResult(
      mode: json['mode'] as String? ?? '',
      imageKey: json['imageKey'] as String? ?? '',
      mimeType: json['mimeType'] as String? ?? 'image/png',
      outputImageBase64: _nonEmptyString(json['outputImageBase64']),
      inpaintedImageBase64: _nonEmptyString(json['inpaintedImageBase64']),
      project: _jsonMap(json['project']),
      projectDocument: _jsonMap(json['projectDocument']),
      original: json['original'],
      translated: json['translated'],
      pageTranslation: json['pageTranslation'],
      diagnostics: _jsonMap(json['diagnostics']) ?? const <String, dynamic>{},
    );
  }

  final String mode;
  final String imageKey;
  final String mimeType;
  final String? outputImageBase64;
  final String? inpaintedImageBase64;
  final MangaJson? project;
  final MangaJson? projectDocument;
  final dynamic original;
  final dynamic translated;
  final dynamic pageTranslation;
  final MangaJson diagnostics;

  static String? _nonEmptyString(dynamic value) {
    final text = value is String ? value.trim() : '';
    return text.isEmpty ? null : text;
  }

  static MangaJson? _jsonMap(dynamic value) {
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value);
  }
}
