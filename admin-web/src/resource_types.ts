export interface ResourceLimits {
  storageBytes: number | null;
  dailyModelRequests: number | null;
  revision: number;
}

export interface ResourceUsage {
  limits: ResourceLimits;
  modelRequests: number;
  day: string;
  resetsAt: string;
  storageUsedBytes: number;
}

export interface ResourceLimitUpdate {
  expectedRevision: number;
  storageBytes: number | null;
  dailyModelRequests: number | null;
}
