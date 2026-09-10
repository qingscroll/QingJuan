import 'book.dart';

class SitePlugin {
  const SitePlugin({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.domains,
    required this.bookKinds,
    required this.tags,
    required this.capabilities,
    required this.version,
    required this.enabled,
    required this.defaultEnabled,
    this.accountLoggedIn = false,
    this.origin = 'builtin',
    this.author = '',
    this.apiVersion = 1,
    this.loadError,
  });

  factory SitePlugin.fromJson(JsonMap json) => SitePlugin(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '未命名插件',
        description: json['description'] as String? ?? '',
        category: json['category'] as String? ?? 'general',
        domains: _stringList(json['domains']),
        bookKinds: _stringList(json['bookKinds']),
        tags: _stringList(json['tags']),
        capabilities: _stringList(json['capabilities']),
        version: json['version'] as String? ?? '1.0.0',
        enabled: json['enabled'] as bool? ?? true,
        defaultEnabled: json['defaultEnabled'] as bool? ?? true,
        accountLoggedIn: json['accountLoggedIn'] as bool? ?? false,
        origin: json['origin'] as String? ?? 'builtin',
        author: json['author'] as String? ?? '',
        apiVersion: json['apiVersion'] as int? ?? 1,
        loadError: json['loadError'] as String?,
      );

  final String id;
  final String name;
  final String description;
  final String category;
  final List<String> domains;
  final List<String> bookKinds;
  final List<String> tags;
  final List<String> capabilities;
  final String version;
  final bool enabled;
  final bool defaultEnabled;
  final bool accountLoggedIn;
  final String origin;
  final String author;
  final int apiVersion;
  final String? loadError;
  bool get isInstalled => origin == 'installed';

  SitePlugin copyWith({
    bool? enabled,
    bool? accountLoggedIn,
  }) =>
      SitePlugin(
        id: id,
        name: name,
        description: description,
        category: category,
        domains: domains,
        bookKinds: bookKinds,
        tags: tags,
        capabilities: capabilities,
        version: version,
        enabled: enabled ?? this.enabled,
        defaultEnabled: defaultEnabled,
        accountLoggedIn: accountLoggedIn ?? this.accountLoggedIn,
        origin: origin,
        author: author,
        apiVersion: apiVersion,
        loadError: loadError,
      );

  static List<String> _stringList(Object? value) =>
      ((value as List?) ?? const []).whereType<String>().toList();
}

class SitePluginPackageInspection {
  const SitePluginPackageInspection(
      {required this.plugin, required this.sha256, this.installedVersion});

  factory SitePluginPackageInspection.fromJson(JsonMap json) =>
      SitePluginPackageInspection(
        plugin: SitePlugin.fromJson(
            Map<String, dynamic>.from(json['plugin'] as Map)),
        sha256: json['sha256'] as String,
        installedVersion: json['installedVersion'] as String?,
      );

  final SitePlugin plugin;
  final String sha256;
  final String? installedVersion;
}

class SitePluginAccount {
  const SitePluginAccount({required this.loggedIn, this.expiresAt});

  factory SitePluginAccount.fromJson(JsonMap json) => SitePluginAccount(
        loggedIn: json['loggedIn'] as bool? ?? false,
        expiresAt: json['expiresAt'] as String?,
      );

  final bool loggedIn;
  final String? expiresAt;
}

class SitePluginLoginQrCode {
  const SitePluginLoginQrCode({
    required this.flowId,
    required this.qrImageBase64,
    required this.expiresAt,
  });

  factory SitePluginLoginQrCode.fromJson(JsonMap json) => SitePluginLoginQrCode(
        flowId: json['flowId'] as String? ?? '',
        qrImageBase64: json['qrImageBase64'] as String? ?? '',
        expiresAt: json['expiresAt'] as String? ?? '',
      );

  final String flowId;
  final String qrImageBase64;
  final String expiresAt;
}

class SitePluginLoginPoll {
  const SitePluginLoginPoll({
    required this.status,
    required this.message,
    required this.loggedIn,
  });

  factory SitePluginLoginPoll.fromJson(JsonMap json) => SitePluginLoginPoll(
        status: json['status'] as String? ?? 'error',
        message: json['message'] as String? ?? '登录状态未知',
        loggedIn: json['loggedIn'] as bool? ?? false,
      );

  final String status;
  final String message;
  final bool loggedIn;

  bool get isTerminal =>
      status == 'success' ||
      status == 'cancelled' ||
      status == 'expired' ||
      status == 'error';
}

class SitePluginBookshelfImportItem {
  const SitePluginBookshelfImportItem({
    required this.sourceId,
    required this.title,
    required this.status,
    required this.message,
    this.bookId,
  });

  factory SitePluginBookshelfImportItem.fromJson(JsonMap json) =>
      SitePluginBookshelfImportItem(
        sourceId: json['sourceId'] as String? ?? '',
        title: json['title'] as String? ?? '未命名作品',
        status: json['status'] as String? ?? 'failed',
        message: json['message'] as String? ?? '',
        bookId: json['bookId'] as String?,
      );

  final String sourceId;
  final String title;
  final String status;
  final String message;
  final String? bookId;
}

class SitePluginBookshelfImportJob {
  const SitePluginBookshelfImportJob({
    required this.id,
    required this.pluginId,
    required this.status,
    required this.progress,
    required this.message,
    required this.discoveredCount,
    required this.processedCount,
    required this.importedCount,
    required this.skippedCount,
    required this.unsupportedCount,
    required this.failedCount,
    required this.items,
    this.error,
  });

  factory SitePluginBookshelfImportJob.fromJson(JsonMap json) {
    final items = (json['items'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map(
          (item) => SitePluginBookshelfImportItem.fromJson(
            Map<String, dynamic>.from(item),
          ),
        )
        .toList(growable: false);
    return SitePluginBookshelfImportJob(
      id: json['id'] as String? ?? '',
      pluginId: json['pluginId'] as String? ?? '',
      status: json['status'] as String? ?? 'failed',
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      message: json['message'] as String? ?? '',
      discoveredCount: (json['discoveredCount'] as num?)?.toInt() ?? 0,
      processedCount: (json['processedCount'] as num?)?.toInt() ?? 0,
      importedCount: (json['importedCount'] as num?)?.toInt() ?? 0,
      skippedCount: (json['skippedCount'] as num?)?.toInt() ?? 0,
      unsupportedCount: (json['unsupportedCount'] as num?)?.toInt() ?? 0,
      failedCount: (json['failedCount'] as num?)?.toInt() ?? 0,
      items: items,
      error: json['error'] as String?,
    );
  }

  final String id;
  final String pluginId;
  final String status;
  final double progress;
  final String message;
  final int discoveredCount;
  final int processedCount;
  final int importedCount;
  final int skippedCount;
  final int unsupportedCount;
  final int failedCount;
  final List<SitePluginBookshelfImportItem> items;
  final String? error;

  bool get isActive => status == 'queued' || status == 'running';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
}
