class BackupArtifact {
  const BackupArtifact(
      {required this.id,
      required this.createdAt,
      required this.appVersion,
      required this.sizeBytes,
      required this.sha256});

  final String id;
  final String createdAt;
  final String appVersion;
  final int sizeBytes;
  final String sha256;

  factory BackupArtifact.fromJson(Map<String, dynamic> json) => BackupArtifact(
        id: json['id'] as String,
        createdAt: json['createdAt'] as String,
        appVersion: json['appVersion'] as String,
        sizeBytes: (json['sizeBytes'] as num).toInt(),
        sha256: json['sha256'] as String,
      );
}

class BackupInspection {
  const BackupInspection(
      {required this.restoreId,
      required this.confirmationToken,
      required this.createdAt,
      required this.appVersion,
      required this.backupCounts,
      required this.currentCounts,
      required this.replacementScope,
      required this.warnings});

  final String restoreId;
  final String confirmationToken;
  final String createdAt;
  final String appVersion;
  final Map<String, int> backupCounts;
  final Map<String, int> currentCounts;
  final List<String> replacementScope;
  final List<String> warnings;

  factory BackupInspection.fromJson(Map<String, dynamic> json) =>
      BackupInspection(
        restoreId: json['restoreId'] as String,
        confirmationToken: json['confirmationToken'] as String,
        createdAt: json['createdAt'] as String,
        appVersion: json['appVersion'] as String,
        backupCounts: Map<String, int>.from(json['backupCounts'] as Map),
        currentCounts: Map<String, int>.from(json['currentCounts'] as Map),
        replacementScope: List<String>.from(json['replacementScope'] as List),
        warnings: List<String>.from(json['warnings'] as List),
      );
}
