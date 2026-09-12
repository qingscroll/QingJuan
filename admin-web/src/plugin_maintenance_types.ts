export type PluginMaintenanceReport = {
  pluginId: string;
  version: string;
  sha256: string;
  apiVersion: number;
  supportedApiVersion: number;
  pythonVersion: string;
  enabled: boolean;
  compatible: boolean;
  activeCalls: number;
  rollbackVersion: string | null;
  rollbackSha256: string | null;
  rollbackAvailable: boolean;
  checkedAt: string;
  checks: { code: string; label: string; status: "passed" | "failed" | "warning"; message: string }[];
};
