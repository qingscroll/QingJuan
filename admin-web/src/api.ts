import type {
  BackendUpdateStartPayload,
  BackendUpdateStartResponse,
  BackendUpdateStatus,
  BackendServiceAction,
  BackendServiceActionResponse,
  BackendServiceStatus,
  Book,
  BookSource,
  ConnectionTokenStatus,
  Device,
  RuntimeLogBatch,
  RegistrationSettings,
  RegistrationSettingsUpdate,
  ServiceDiagnostics,
  ServiceMeta,
  SessionInfo,
  Settings,
  SettingsUpdate,
  SitePlugin,
  SitePluginPackageInspection,
  SitePluginAccount,
  SitePluginBookshelfImportJob,
  SitePluginLoginPoll,
  SitePluginLoginQrCode,
  Task,
  TaskLog,
  TranslationModelCheck,
  UserAdminView,
  UserCreatePayload,
  UserPasswordPayload,
  UserUpdatePayload,
} from "./types";

let csrfToken = "";
let csrfHeader = "X-QingJuan-CSRF";

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export function clearSessionSecurity(): void {
  csrfToken = "";
}

export async function login(password: string): Promise<SessionInfo> {
  const session = await request<SessionInfo>("/admin/api/login", {
    method: "POST",
    body: JSON.stringify({ password }),
  });
  rememberSession(session);
  return session;
}

export async function getAdminSession(): Promise<SessionInfo> {
  const session = await request<SessionInfo>("/admin/api/session");
  rememberSession(session);
  return session;
}

export async function logout(): Promise<void> {
  await request<void>("/admin/api/logout", { method: "POST" });
  clearSessionSecurity();
}

export const getMeta = (): Promise<ServiceMeta> => request("/api/v1/meta");
export const getConnectionTokenStatus = (): Promise<ConnectionTokenStatus> =>
  request("/admin/api/connection-token");
export const revealConnectionToken = (): Promise<{ token: string }> =>
  request("/admin/api/connection-token/reveal", { method: "POST" });
export const getRuntimeLogs = (limit = 500): Promise<RuntimeLogBatch> =>
  request(`/admin/api/runtime-logs?limit=${encodeURIComponent(limit)}`);
export const getServiceDiagnostics = (): Promise<ServiceDiagnostics> =>
  request("/admin/api/diagnostics");
export const getBackendServiceStatus = (): Promise<BackendServiceStatus> =>
  request("/admin/api/backend-service");
export const controlBackendService = (
  action: BackendServiceAction,
): Promise<BackendServiceActionResponse> =>
  request("/admin/api/backend-service/actions", {
    method: "POST",
    body: JSON.stringify({ action }),
  });
export const getBackendUpdateStatus = (): Promise<BackendUpdateStatus> =>
  request("/admin/api/backend-update");
export const checkBackendUpdate = (): Promise<BackendUpdateStatus> =>
  request("/admin/api/backend-update/check", { method: "POST" });
export const startBackendUpdate = (
  payload: BackendUpdateStartPayload,
): Promise<BackendUpdateStartResponse> =>
  request("/admin/api/backend-update", { method: "POST", body: JSON.stringify(payload) });
export const getRegistrationSettings = (): Promise<RegistrationSettings> =>
  request("/admin/api/registration-settings");
export const updateRegistrationSettings = (
  payload: RegistrationSettingsUpdate,
): Promise<RegistrationSettings> =>
  request("/admin/api/registration-settings", {
    method: "PUT",
    body: JSON.stringify(payload),
  });
export const getUsers = (): Promise<UserAdminView[]> => request("/admin/api/users");
export const createUser = (payload: UserCreatePayload): Promise<UserAdminView> =>
  request("/admin/api/users", { method: "POST", body: JSON.stringify(payload) });
export const updateUser = (userId: string, payload: UserUpdatePayload): Promise<UserAdminView> =>
  request(`/admin/api/users/${encodeURIComponent(userId)}`, {
    method: "PATCH",
    body: JSON.stringify(payload),
  });
export const resetUserPassword = (userId: string, payload: UserPasswordPayload): Promise<void> =>
  request(`/admin/api/users/${encodeURIComponent(userId)}/password`, {
    method: "PUT",
    body: JSON.stringify(payload),
  });
export const revokeUserSessions = (userId: string): Promise<void> =>
  request(`/admin/api/users/${encodeURIComponent(userId)}/sessions/revoke`, { method: "POST" });
export const checkTranslationModel = (force = false): Promise<TranslationModelCheck> =>
  request(`/api/v1/translation-model/check?force=${force}`, { method: "POST" });
export const getDevices = (): Promise<Device[]> => request("/api/v1/devices");
export const getBooks = (): Promise<Book[]> => request("/api/v1/books");
export const getTasks = (): Promise<Task[]> => request("/api/v1/tasks");
export const getSources = (): Promise<BookSource[]> => request("/api/v1/sources");
export const getSitePlugins = (): Promise<SitePlugin[]> => request("/api/v1/plugins");
export function inspectSitePluginPackage(file: File): Promise<SitePluginPackageInspection> {
  const body = new FormData();
  body.append("file", file);
  return request("/api/v1/plugins/inspect", { method: "POST", body });
}
export function importSitePluginPackage(file: File, replace = false): Promise<SitePlugin> {
  const body = new FormData();
  body.append("file", file);
  body.append("replace", String(replace));
  return request("/api/v1/plugins/import", { method: "POST", body });
}
export const uninstallSitePlugin = (pluginId: string): Promise<void> =>
  request(`/api/v1/plugins/${encodeURIComponent(pluginId)}`, { method: "DELETE" });
export const getSettings = (): Promise<Settings> => request("/api/v1/settings");
export const getTaskLogs = (taskId: string): Promise<TaskLog[]> =>
  request(`/api/v1/tasks/${encodeURIComponent(taskId)}/logs`);
export const retryTask = (taskId: string): Promise<Task> =>
  request(`/api/v1/tasks/${encodeURIComponent(taskId)}/retry`, { method: "POST" });
export const deleteBook = (bookId: string): Promise<{ status: string; bookId: string }> =>
  request(`/api/v1/books/${encodeURIComponent(bookId)}`, { method: "DELETE" });
export const updateSettings = (payload: SettingsUpdate): Promise<Settings> =>
  request("/api/v1/settings", { method: "PUT", body: JSON.stringify(payload) });
export const setDeviceBanned = (deviceId: string, banned: boolean): Promise<Device> =>
  request(`/api/v1/devices/${encodeURIComponent(deviceId)}/ban`, {
    method: "PUT",
    body: JSON.stringify({ banned }),
  });
export const setSitePluginEnabled = (pluginId: string, enabled: boolean): Promise<SitePlugin> =>
  request(`/api/v1/plugins/${encodeURIComponent(pluginId)}`, {
    method: "PUT",
    body: JSON.stringify({ enabled }),
  });
export const startSitePluginLogin = (pluginId: string): Promise<SitePluginLoginQrCode> =>
  request(`/api/v1/plugins/${encodeURIComponent(pluginId)}/account/login-qrcode`, {
    method: "POST",
  });
export const pollSitePluginLogin = (
  pluginId: string,
  flowId: string,
): Promise<SitePluginLoginPoll> =>
  request(
    `/api/v1/plugins/${encodeURIComponent(pluginId)}/account/login-qrcode/${encodeURIComponent(flowId)}`,
  );
export const loginSitePluginWithCookies = (
  pluginId: string,
  cookies: string,
): Promise<SitePluginAccount> =>
  request(`/api/v1/plugins/${encodeURIComponent(pluginId)}/account/login-cookies`, {
    method: "POST",
    body: JSON.stringify({ cookies }),
  });
export const logoutSitePluginAccount = (pluginId: string): Promise<SitePluginAccount> =>
  request(`/api/v1/plugins/${encodeURIComponent(pluginId)}/account`, { method: "DELETE" });
export const startSitePluginBookshelfImport = (
  pluginId: string,
): Promise<SitePluginBookshelfImportJob> =>
  request(`/api/v1/plugins/${encodeURIComponent(pluginId)}/bookshelf/import-jobs`, {
    method: "POST",
  });
export const getSitePluginBookshelfImport = (
  pluginId: string,
  jobId: string,
): Promise<SitePluginBookshelfImportJob> =>
  request(
    `/api/v1/plugins/${encodeURIComponent(pluginId)}/bookshelf/import-jobs/${encodeURIComponent(jobId)}`,
  );

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const method = (init.method ?? "GET").toUpperCase();
  const headers = new Headers(init.headers);
  headers.set("Accept", "application/json");
  if (init.body && !(init.body instanceof FormData)) {
    headers.set("Content-Type", "application/json");
  }
  if (!new Set(["GET", "HEAD", "OPTIONS"]).has(method) && csrfToken) {
    headers.set(csrfHeader, csrfToken);
  }

  let response: Response;
  try {
    response = await fetch(path, {
      ...init,
      method,
      headers,
      credentials: "same-origin",
    });
  } catch {
    throw new ApiError("无法连接青卷后端，请检查服务状态和网络。", 0);
  }

  const payload = await readPayload(response);
  if (!response.ok) {
    if (
      response.status === 401
      && (path.startsWith("/api/v1/") || (path.startsWith("/admin/api/") && path !== "/admin/api/login"))
    ) {
      window.dispatchEvent(new Event("qingjuan:session-expired"));
    }
    const detail = isRecord(payload) && typeof payload.detail === "string" ? payload.detail : "请求失败";
    throw new ApiError(detail, response.status);
  }
  return payload as T;
}

async function readPayload(response: Response): Promise<unknown> {
  if (response.status === 204) {
    return undefined;
  }
  const contentType = response.headers.get("Content-Type") ?? "";
  if (contentType.includes("application/json")) {
    return response.json();
  }
  const text = await response.text();
  return text ? { detail: text } : undefined;
}

function rememberSession(session: SessionInfo): void {
  csrfToken = session.csrfToken;
  csrfHeader = session.csrfHeader;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
