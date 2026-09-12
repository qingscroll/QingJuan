import 'book.dart';

class PluginMaintenanceCheck {
  const PluginMaintenanceCheck(
      {required this.code,
      required this.label,
      required this.status,
      required this.message});

  factory PluginMaintenanceCheck.fromJson(JsonMap json) =>
      PluginMaintenanceCheck(
          code: json['code'] as String,
          label: json['label'] as String,
          status: json['status'] as String,
          message: json['message'] as String);

  final String code;
  final String label;
  final String status;
  final String message;
}

class PluginMaintenanceReport {
  const PluginMaintenanceReport(
      {required this.pluginId,
      required this.version,
      required this.sha256,
      required this.apiVersion,
      required this.supportedApiVersion,
      required this.pythonVersion,
      required this.enabled,
      required this.compatible,
      required this.activeCalls,
      required this.rollbackAvailable,
      required this.checkedAt,
      required this.checks,
      this.rollbackVersion,
      this.rollbackSha256});

  factory PluginMaintenanceReport.fromJson(JsonMap json) =>
      PluginMaintenanceReport(
        pluginId: json['pluginId'] as String,
        version: json['version'] as String,
        sha256: json['sha256'] as String,
        apiVersion: json['apiVersion'] as int,
        supportedApiVersion: json['supportedApiVersion'] as int,
        pythonVersion: json['pythonVersion'] as String,
        enabled: json['enabled'] as bool,
        compatible: json['compatible'] as bool,
        activeCalls: json['activeCalls'] as int,
        rollbackAvailable: json['rollbackAvailable'] as bool,
        checkedAt: json['checkedAt'] as String,
        rollbackVersion: json['rollbackVersion'] as String?,
        rollbackSha256: json['rollbackSha256'] as String?,
        checks: (json['checks'] as List)
            .map((check) => PluginMaintenanceCheck.fromJson(
                Map<String, dynamic>.from(check as Map)))
            .toList(growable: false),
      );

  final String pluginId;
  final String version;
  final String sha256;
  final int apiVersion;
  final int supportedApiVersion;
  final String pythonVersion;
  final bool enabled;
  final bool compatible;
  final int activeCalls;
  final String? rollbackVersion;
  final String? rollbackSha256;
  final bool rollbackAvailable;
  final String checkedAt;
  final List<PluginMaintenanceCheck> checks;
}
