import 'book.dart';

enum TranslationModelCheckStatus { ready, disabled, unconfigured, failed }

class TranslationModelCheck {
  const TranslationModelCheck({
    required this.enabled,
    required this.configured,
    required this.available,
    required this.status,
    required this.model,
    required this.supportsVision,
    required this.checkedAt,
    required this.latencyMs,
    required this.message,
    required this.cached,
  });

  factory TranslationModelCheck.fromJson(JsonMap json) => TranslationModelCheck(
        enabled: json['enabled'] as bool? ?? false,
        configured: json['configured'] as bool? ?? false,
        available: json['available'] as bool? ?? false,
        status: switch (json['status']) {
          'ready' => TranslationModelCheckStatus.ready,
          'disabled' => TranslationModelCheckStatus.disabled,
          'unconfigured' => TranslationModelCheckStatus.unconfigured,
          _ => TranslationModelCheckStatus.failed,
        },
        model: json['model'] as String?,
        supportsVision: json['supportsVision'] as bool? ?? false,
        checkedAt: DateTime.tryParse(json['checkedAt'] as String? ?? ''),
        latencyMs: (json['latencyMs'] as num?)?.toInt(),
        message: json['message'] as String? ?? '后端模型自检失败',
        cached: json['cached'] as bool? ?? false,
      );

  factory TranslationModelCheck.clientFailure() => TranslationModelCheck(
        enabled: false,
        configured: false,
        available: false,
        status: TranslationModelCheckStatus.failed,
        model: null,
        supportsVision: false,
        checkedAt: DateTime.now().toUtc(),
        latencyMs: null,
        message: '后端已连接，但模型自检请求失败',
        cached: false,
      );

  final bool enabled;
  final bool configured;
  final bool available;
  final TranslationModelCheckStatus status;
  final String? model;
  final bool supportsVision;
  final DateTime? checkedAt;
  final int? latencyMs;
  final String message;
  final bool cached;
}

class TranslationModelSettings {
  const TranslationModelSettings({
    required this.enabled,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.supportsVision,
    required this.apiKeyConfigured,
    this.clearApiKey = false,
  });

  factory TranslationModelSettings.fromJson(JsonMap json) =>
      TranslationModelSettings(
        enabled: json['enabled'] as bool? ?? false,
        baseUrl: json['baseUrl'] as String? ?? 'https://api.openai.com/v1',
        apiKey: json['apiKey'] as String? ?? '',
        model: json['model'] as String? ?? 'gpt-5.4',
        supportsVision: json['supportsVision'] as bool? ?? false,
        apiKeyConfigured: json['apiKeyConfigured'] as bool? ?? false,
      );

  const TranslationModelSettings.defaults()
      : enabled = false,
        baseUrl = 'https://api.openai.com/v1',
        apiKey = '',
        model = 'gpt-5.4',
        supportsVision = false,
        apiKeyConfigured = false,
        clearApiKey = false;

  JsonMap toJson() => <String, dynamic>{
        'enabled': enabled,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'apiKeyAction': clearApiKey
            ? 'clear'
            : (apiKey.trim().isEmpty ? 'keep' : 'replace'),
        'model': model,
        'supportsVision': supportsVision,
      };

  TranslationModelSettings copyWith({
    bool? enabled,
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? supportsVision,
    bool? apiKeyConfigured,
    bool? clearApiKey,
  }) =>
      TranslationModelSettings(
        enabled: enabled ?? this.enabled,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        supportsVision: supportsVision ?? this.supportsVision,
        apiKeyConfigured: apiKeyConfigured ?? this.apiKeyConfigured,
        clearApiKey: clearApiKey ?? this.clearApiKey,
      );

  final bool enabled;
  final String baseUrl;
  final String apiKey;
  final String model;
  final bool supportsVision;
  final bool apiKeyConfigured;
  final bool clearApiKey;
}

class MangaOcrSettings {
  const MangaOcrSettings({
    required this.enabled,
    required this.baseUrl,
    required this.apiKey,
    required this.apiKeyConfigured,
    this.clearApiKey = false,
  });

  factory MangaOcrSettings.fromJson(JsonMap json) => MangaOcrSettings(
        enabled: json['enabled'] as bool? ?? false,
        baseUrl: json['baseUrl'] as String? ?? '',
        apiKey: json['apiKey'] as String? ?? '',
        apiKeyConfigured: json['apiKeyConfigured'] as bool? ?? false,
      );

  const MangaOcrSettings.defaults()
      : enabled = false,
        baseUrl = '',
        apiKey = '',
        apiKeyConfigured = false,
        clearApiKey = false;

  JsonMap toJson() => <String, dynamic>{
        'enabled': enabled,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'apiKeyAction': clearApiKey
            ? 'clear'
            : (apiKey.trim().isEmpty ? 'keep' : 'replace'),
      };

  MangaOcrSettings copyWith({
    bool? enabled,
    String? baseUrl,
    String? apiKey,
    bool? apiKeyConfigured,
    bool? clearApiKey,
  }) =>
      MangaOcrSettings(
        enabled: enabled ?? this.enabled,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        apiKeyConfigured: apiKeyConfigured ?? this.apiKeyConfigured,
        clearApiKey: clearApiKey ?? this.clearApiKey,
      );

  final bool enabled;
  final String baseUrl;
  final String apiKey;
  final bool apiKeyConfigured;
  final bool clearApiKey;
}

class TranslationSettings {
  const TranslationSettings({
    required this.systemPrompt,
    required this.autoTranslateNextChapters,
    required this.downloadConcurrency,
    required this.translationModel,
    required this.mangaOcr,
    required this.bika,
  });

  factory TranslationSettings.fromJson(JsonMap json) {
    final rawTranslationModel = json['translationModel'] as JsonMap?;
    final rawProviders = (json['providers'] as JsonMap?) ?? const {};
    final selectedProvider = json['defaultProvider'] as String? ?? 'openai';
    final legacySelected = rawProviders[selectedProvider] as JsonMap?;
    final legacyOpenAi = rawProviders['openai'] as JsonMap?;
    final migratedTranslationModel = rawTranslationModel ??
        (selectedProvider != 'anthropic' ? legacySelected : null) ??
        legacyOpenAi ??
        const <String, dynamic>{};
    return TranslationSettings(
      systemPrompt: json['systemPrompt'] as String? ?? '',
      autoTranslateNextChapters:
          (json['autoTranslateNextChapters'] as num?)?.toInt() ?? 2,
      downloadConcurrency: (json['downloadConcurrency'] as num?)?.toInt() ?? 4,
      translationModel:
          TranslationModelSettings.fromJson(migratedTranslationModel),
      mangaOcr: MangaOcrSettings.fromJson(
        (json['mangaOcr'] as JsonMap?) ?? <String, dynamic>{},
      ),
      bika: (json['bika'] as JsonMap?) ?? <String, dynamic>{},
    );
  }

  factory TranslationSettings.defaults() => const TranslationSettings(
        systemPrompt: '请准确翻译并保留原文段落结构。',
        autoTranslateNextChapters: 2,
        downloadConcurrency: 4,
        translationModel: TranslationModelSettings.defaults(),
        mangaOcr: MangaOcrSettings.defaults(),
        bika: <String, dynamic>{'email': '', 'password': ''},
      );

  JsonMap toJson() => <String, dynamic>{
        'systemPrompt': systemPrompt,
        'autoTranslateNextChapters': autoTranslateNextChapters,
        'downloadConcurrency': downloadConcurrency,
        'translationModel': translationModel.toJson(),
        'mangaOcr': mangaOcr.toJson(),
        'bika': <String, dynamic>{
          'email': '',
          'password': '',
          'passwordAction': 'keep',
        },
      };

  TranslationSettings copyWith({
    String? systemPrompt,
    int? autoTranslateNextChapters,
    int? downloadConcurrency,
    TranslationModelSettings? translationModel,
    MangaOcrSettings? mangaOcr,
  }) =>
      TranslationSettings(
        systemPrompt: systemPrompt ?? this.systemPrompt,
        autoTranslateNextChapters:
            autoTranslateNextChapters ?? this.autoTranslateNextChapters,
        downloadConcurrency: downloadConcurrency ?? this.downloadConcurrency,
        translationModel: translationModel ?? this.translationModel,
        mangaOcr: mangaOcr ?? this.mangaOcr,
        bika: bika,
      );

  final String systemPrompt;
  final int autoTranslateNextChapters;
  final int downloadConcurrency;
  final TranslationModelSettings translationModel;
  final MangaOcrSettings mangaOcr;
  final JsonMap bika;
}
