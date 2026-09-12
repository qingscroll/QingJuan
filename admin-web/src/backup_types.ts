export type BackupMode = "replace" | "migrate_local";

export type BackupArtifact = {
  id: string;
  createdAt: string;
  appVersion: string;
  sizeBytes: number;
  sha256: string;
  containsSensitiveData: true;
};

export type BackupInspection = {
  restoreId: string;
  confirmationToken: string;
  expiresAt: number;
  appVersion: string;
  createdAt: string;
  mode: BackupMode;
  migrationOwnerId: string | null;
  backupCounts: Record<string, number>;
  currentCounts: Record<string, number>;
  replacementScope: string[];
  warnings: string[];
};

export type BackupRestoreResult = {
  restored: true;
  mode: BackupMode;
  message: string;
};
