import 'book.dart';

class StorageCategory {
  const StorageCategory(
      {required this.id,
      required this.label,
      required this.bytes,
      required this.fileCount,
      required this.cleanable,
      required this.description});
  factory StorageCategory.fromJson(JsonMap json) => StorageCategory(
      id: json['id'] as String,
      label: json['label'] as String,
      bytes: json['bytes'] as int,
      fileCount: json['fileCount'] as int,
      cleanable: json['cleanable'] as bool,
      description: json['description'] as String);
  final String id, label, description;
  final int bytes, fileCount;
  final bool cleanable;
}

class BookStorageReport {
  const BookStorageReport(
      {required this.bookId,
      required this.totalBytes,
      required this.protectedBytes,
      required this.reclaimableBytes,
      required this.fileCount,
      required this.categories,
      required this.warnings});
  factory BookStorageReport.fromJson(JsonMap json) => BookStorageReport(
      bookId: json['bookId'] as String,
      totalBytes: json['totalBytes'] as int,
      protectedBytes: json['protectedBytes'] as int,
      reclaimableBytes: json['reclaimableBytes'] as int,
      fileCount: json['fileCount'] as int,
      categories:
          _maps(json['categories']).map(StorageCategory.fromJson).toList(),
      warnings: (json['warnings'] as List).cast<String>());
  final String bookId;
  final int totalBytes, protectedBytes, reclaimableBytes, fileCount;
  final List<StorageCategory> categories;
  final List<String> warnings;
}

class StorageArtifact {
  const StorageArtifact(
      {required this.id,
      required this.format,
      required this.sizeBytes,
      required this.createdAt});
  factory StorageArtifact.fromJson(JsonMap json) => StorageArtifact(
      id: json['id'] as String,
      format: json['format'] as String,
      sizeBytes: json['sizeBytes'] as int,
      createdAt: json['createdAt'] as String);
  final String id, format, createdAt;
  final int sizeBytes;
}

class StorageCleanupPreview {
  const StorageCleanupPreview(
      {required this.bookId,
      required this.cleanupId,
      required this.confirmationToken,
      required this.totalBytes,
      required this.fileCount,
      required this.artifacts,
      required this.warnings});
  factory StorageCleanupPreview.fromJson(JsonMap json) => StorageCleanupPreview(
      bookId: json['bookId'] as String,
      cleanupId: json['cleanupId'] as String,
      confirmationToken: json['confirmationToken'] as String,
      totalBytes: json['totalBytes'] as int,
      fileCount: json['fileCount'] as int,
      artifacts:
          _maps(json['artifacts']).map(StorageArtifact.fromJson).toList(),
      warnings: (json['warnings'] as List).cast<String>());
  final String bookId, cleanupId, confirmationToken;
  final int totalBytes, fileCount;
  final List<StorageArtifact> artifacts;
  final List<String> warnings;
}

class StorageCleanupResult {
  const StorageCleanupResult(
      {required this.bookId,
      required this.deletedBytes,
      required this.deletedFiles,
      required this.warnings,
      required this.storage});
  factory StorageCleanupResult.fromJson(JsonMap json) => StorageCleanupResult(
      bookId: json['bookId'] as String,
      deletedBytes: json['deletedBytes'] as int,
      deletedFiles: json['deletedFiles'] as int,
      warnings: (json['warnings'] as List).cast<String>(),
      storage: BookStorageReport.fromJson(
          Map<String, dynamic>.from(json['storage'] as Map)));
  final String bookId;
  final int deletedBytes, deletedFiles;
  final List<String> warnings;
  final BookStorageReport storage;
}

Iterable<JsonMap> _maps(Object? value) =>
    (value as List).map((item) => Map<String, dynamic>.from(item as Map));
