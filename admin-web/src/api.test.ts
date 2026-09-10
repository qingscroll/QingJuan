import {
  clearSessionSecurity,
  checkBackendUpdate,
  checkTranslationModel,
  controlBackendService,
  createUser,
  deleteBook,
  getUsers,
  getSitePluginBookshelfImport,
  getRuntimeLogs,
  getRegistrationSettings,
  getServiceDiagnostics,
  getBackendServiceStatus,
  getBackendUpdateStatus,
  login,
  loginSitePluginWithCookies,
  pollSitePluginLogin,
  revealConnectionToken,
  resetUserPassword,
  revokeUserSessions,
  setDeviceBanned,
  setSitePluginEnabled,
  startSitePluginBookshelfImport,
  startSitePluginLogin,
  startBackendUpdate,
  updateUser,
  updateRegistrationSettings,
} from "./api";

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("admin API client", () => {
  it("adds the session CSRF header to protected writes", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        authenticated: true,
        expiresAt: "2030-01-01T00:00:00Z",
        csrfToken: "csrf-value",
        csrfHeader: "X-QingJuan-CSRF",
      }))
      .mockResolvedValueOnce(jsonResponse({ status: "ok", bookId: "book-1" }));
    vi.stubGlobal("fetch", fetchMock);

    await login("correct horse battery staple");
    await deleteBook("book-1");

    const deleteOptions = fetchMock.mock.calls[1][1] as RequestInit;
    expect(deleteOptions.method).toBe("DELETE");
    expect((deleteOptions.headers as Headers).get("X-QingJuan-CSRF")).toBe("csrf-value");
    expect(deleteOptions.credentials).toBe("same-origin");
    clearSessionSecurity();
  });

  it("returns the backend detail for failed login", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(jsonResponse({ detail: "管理密码错误" }, 401)));

    await expect(login("wrong-password")).rejects.toMatchObject({
      message: "管理密码错误",
      status: 401,
    });
  });

  it("sends device ban changes with JSON and CSRF protection", async () => {
    const device = {
      id: "0123456789abcdef0123456789abcdef",
      name: "测试电脑",
      platform: "windows",
      ipAddress: "127.0.0.1",
      firstSeenAt: "2030-01-01T00:00:00Z",
      lastSeenAt: "2030-01-01T00:00:00Z",
      banned: true,
      bannedAt: "2030-01-01T00:00:00Z",
      online: false,
    };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        authenticated: true,
        expiresAt: "2030-01-01T00:00:00Z",
        csrfToken: "device-csrf",
        csrfHeader: "X-QingJuan-CSRF",
      }))
      .mockResolvedValueOnce(jsonResponse(device));
    vi.stubGlobal("fetch", fetchMock);

    await login("admin-password");
    await setDeviceBanned(device.id, true);

    const request = fetchMock.mock.calls[1];
    const options = request[1] as RequestInit;
    expect(request[0]).toBe(`/api/v1/devices/${device.id}/ban`);
    expect(options.method).toBe("PUT");
    expect(options.body).toBe(JSON.stringify({ banned: true }));
    expect((options.headers as Headers).get("X-QingJuan-CSRF")).toBe("device-csrf");
    clearSessionSecurity();
  });

  it("updates Linux site plugins through the protected business API", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        authenticated: true,
        expiresAt: "2030-01-01T00:00:00Z",
        csrfToken: "plugin-csrf",
        csrfHeader: "X-QingJuan-CSRF",
      }))
      .mockResolvedValueOnce(jsonResponse({
        id: "fanqie",
        name: "番茄小说",
        enabled: false,
      }));
    vi.stubGlobal("fetch", fetchMock);

    await login("admin-password");
    await setSitePluginEnabled("fanqie", false);

    const request = fetchMock.mock.calls[1];
    const options = request[1] as RequestInit;
    expect(request[0]).toBe("/api/v1/plugins/fanqie");
    expect(options.method).toBe("PUT");
    expect(options.body).toBe(JSON.stringify({ enabled: false }));
    expect((options.headers as Headers).get("X-QingJuan-CSRF")).toBe("plugin-csrf");
    clearSessionSecurity();
  });

  it("submits site credentials only in a protected Cookie-login request", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        authenticated: true,
        expiresAt: "2030-01-01T00:00:00Z",
        csrfToken: "plugin-login-csrf",
        csrfHeader: "X-QingJuan-CSRF",
      }))
      .mockResolvedValueOnce(jsonResponse({ loggedIn: true, expiresAt: null }));
    vi.stubGlobal("fetch", fetchMock);

    await login("admin-password");
    await loginSitePluginWithCookies("fanqie", "sessionid=private-value");

    const request = fetchMock.mock.calls[1];
    const options = request[1] as RequestInit;
    expect(request[0]).toBe("/api/v1/plugins/fanqie/account/login-cookies");
    expect(options.method).toBe("POST");
    expect(options.body).toBe(JSON.stringify({ cookies: "sessionid=private-value" }));
    expect((options.headers as Headers).get("X-QingJuan-CSRF")).toBe("plugin-login-csrf");
    expect(String(request[0])).not.toContain("private-value");
    clearSessionSecurity();
  });

  it("uses opaque Qidian login and bookshelf job identifiers", async () => {
    const queuedJob = {
      id: "job-1",
      pluginId: "qidian",
      status: "queued",
      progress: 0,
      message: "等待导入",
      discoveredCount: 0,
      processedCount: 0,
      importedCount: 0,
      skippedCount: 0,
      unsupportedCount: 0,
      failedCount: 0,
      items: [],
    };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        authenticated: true,
        expiresAt: "2030-01-01T00:00:00Z",
        csrfToken: "qidian-csrf",
        csrfHeader: "X-QingJuan-CSRF",
      }))
      .mockResolvedValueOnce(jsonResponse({
        flowId: "opaque-flow",
        qrImageBase64: "aW1hZ2U=",
        expiresAt: "2030-01-01T00:03:00Z",
      }))
      .mockResolvedValueOnce(jsonResponse({
        status: "success",
        message: "登录成功",
        loggedIn: true,
      }))
      .mockResolvedValueOnce(jsonResponse(queuedJob))
      .mockResolvedValueOnce(jsonResponse({
        ...queuedJob,
        status: "completed",
        progress: 100,
        message: "导入完成",
        discoveredCount: 2,
        processedCount: 2,
        importedCount: 1,
        skippedCount: 1,
      }));
    vi.stubGlobal("fetch", fetchMock);

    await login("admin-password");
    const qr = await startSitePluginLogin("qidian");
    const loginStatus = await pollSitePluginLogin("qidian", qr.flowId);
    const queued = await startSitePluginBookshelfImport("qidian");
    const completed = await getSitePluginBookshelfImport("qidian", queued.id);

    expect(loginStatus.loggedIn).toBe(true);
    expect(completed.importedCount).toBe(1);
    expect(fetchMock.mock.calls.slice(1).map((call) => call[0])).toEqual([
      "/api/v1/plugins/qidian/account/login-qrcode",
      "/api/v1/plugins/qidian/account/login-qrcode/opaque-flow",
      "/api/v1/plugins/qidian/bookshelf/import-jobs",
      "/api/v1/plugins/qidian/bookshelf/import-jobs/job-1",
    ]);
    expect((fetchMock.mock.calls[1][1] as RequestInit).method).toBe("POST");
    expect((fetchMock.mock.calls[2][1] as RequestInit).method).toBe("GET");
    expect((fetchMock.mock.calls[3][1] as RequestInit).method).toBe("POST");
    expect(((fetchMock.mock.calls[1][1] as RequestInit).headers as Headers)
      .get("X-QingJuan-CSRF")).toBe("qidian-csrf");
    expect(JSON.stringify([qr, loginStatus, queued, completed])).not.toContain("cookie");
    clearSessionSecurity();
  });

  it("protects token reveal while keeping runtime log reads non-mutating", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        authenticated: true,
        expiresAt: "2030-01-01T00:00:00Z",
        csrfToken: "observability-csrf",
        csrfHeader: "X-QingJuan-CSRF",
      }))
      .mockResolvedValueOnce(jsonResponse({ token: "connection-token-value" }))
      .mockResolvedValueOnce(jsonResponse({ items: [], sources: [], total: 0 }))
      .mockResolvedValueOnce(jsonResponse({ schemaVersion: 1, status: "healthy" }))
      .mockResolvedValueOnce(jsonResponse({ status: "ready", available: true }));
    vi.stubGlobal("fetch", fetchMock);

    await login("admin-password");
    await revealConnectionToken();
    await getRuntimeLogs(1000);
    await getServiceDiagnostics();
    await checkTranslationModel(true);

    const revealOptions = fetchMock.mock.calls[1][1] as RequestInit;
    const logsOptions = fetchMock.mock.calls[2][1] as RequestInit;
    const diagnosticsOptions = fetchMock.mock.calls[3][1] as RequestInit;
    const modelCheckOptions = fetchMock.mock.calls[4][1] as RequestInit;
    expect(fetchMock.mock.calls[1][0]).toBe("/admin/api/connection-token/reveal");
    expect(revealOptions.method).toBe("POST");
    expect((revealOptions.headers as Headers).get("X-QingJuan-CSRF")).toBe("observability-csrf");
    expect(fetchMock.mock.calls[2][0]).toBe("/admin/api/runtime-logs?limit=1000");
    expect(logsOptions.method).toBe("GET");
    expect((logsOptions.headers as Headers).has("X-QingJuan-CSRF")).toBe(false);
    expect(fetchMock.mock.calls[3][0]).toBe("/admin/api/diagnostics");
    expect(diagnosticsOptions.method).toBe("GET");
    expect((diagnosticsOptions.headers as Headers).has("X-QingJuan-CSRF")).toBe(false);
    expect(fetchMock.mock.calls[4][0]).toBe("/api/v1/translation-model/check?force=true");
    expect(modelCheckOptions.method).toBe("POST");
    expect((modelCheckOptions.headers as Headers).get("X-QingJuan-CSRF")).toBe("observability-csrf");
    clearSessionSecurity();
  });

  it("checks and starts backend updates through the protected admin contract", async () => {
    const updateStatus = {
      schemaVersion: 1,
      state: "available",
      supported: true,
      canUpdate: true,
      currentVersion: "2.0.0",
      targetVersion: "2.1.0",
      candidateId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      jobId: null,
      checkedAt: "2030-01-01T00:00:00Z",
      startedAt: null,
      finishedAt: null,
      message: "发现新版本",
      blockedReason: null,
      error: null,
    };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        authenticated: true,
        expiresAt: "2030-01-01T00:00:00Z",
        csrfToken: "update-csrf",
        csrfHeader: "X-QingJuan-CSRF",
      }))
      .mockResolvedValueOnce(jsonResponse(updateStatus))
      .mockResolvedValueOnce(jsonResponse(updateStatus))
      .mockResolvedValueOnce(jsonResponse({
        accepted: true,
        jobId: "update-job-1",
        fromVersion: "2.0.0",
        targetVersion: "2.1.0",
        disconnectExpected: true,
      }, 202));
    vi.stubGlobal("fetch", fetchMock);

    await login("admin-password");
    await getBackendUpdateStatus();
    await checkBackendUpdate();
    await startBackendUpdate({
      candidateId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      requestId: "request-1",
    });

    const requests = fetchMock.mock.calls.slice(1);
    expect(requests.map((call) => call[0])).toEqual([
      "/admin/api/backend-update",
      "/admin/api/backend-update/check",
      "/admin/api/backend-update",
    ]);
    expect(requests.map((call) => (call[1] as RequestInit).method)).toEqual([
      "GET",
      "POST",
      "POST",
    ]);
    expect(((requests[0][1] as RequestInit).headers as Headers).has("X-QingJuan-CSRF")).toBe(false);
    expect(((requests[1][1] as RequestInit).headers as Headers).get("X-QingJuan-CSRF"))
      .toBe("update-csrf");
    expect(((requests[2][1] as RequestInit).headers as Headers).get("X-QingJuan-CSRF"))
      .toBe("update-csrf");
    expect((requests[2][1] as RequestInit).body).toBe(JSON.stringify({
      candidateId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      requestId: "request-1",
    }));
    clearSessionSecurity();
  });

  it("reads and controls the backend business service with CSRF protection", async () => {
    const serviceStatus = {
      schemaVersion: 1,
      state: "running",
      businessApiAvailable: true,
      managementApiAvailable: true,
      generation: 2,
      startedAt: "2030-01-01T00:00:00Z",
      stoppedAt: null,
      lastActionAt: "2030-01-01T00:00:00Z",
      message: "后端业务服务运行中",
    };
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        authenticated: true,
        expiresAt: "2030-01-01T00:00:00Z",
        csrfToken: "service-csrf",
        csrfHeader: "X-QingJuan-CSRF",
      }))
      .mockResolvedValueOnce(jsonResponse(serviceStatus))
      .mockResolvedValueOnce(jsonResponse({
        ...serviceStatus,
        accepted: true,
        action: "restart",
      }));
    vi.stubGlobal("fetch", fetchMock);

    await login("admin-password");
    await getBackendServiceStatus();
    await controlBackendService("restart");

    const readOptions = fetchMock.mock.calls[1][1] as RequestInit;
    const actionOptions = fetchMock.mock.calls[2][1] as RequestInit;
    expect(fetchMock.mock.calls[1][0]).toBe("/admin/api/backend-service");
    expect(readOptions.method).toBe("GET");
    expect((readOptions.headers as Headers).has("X-QingJuan-CSRF")).toBe(false);
    expect(fetchMock.mock.calls[2][0]).toBe("/admin/api/backend-service/actions");
    expect(actionOptions.method).toBe("POST");
    expect((actionOptions.headers as Headers).get("X-QingJuan-CSRF")).toBe("service-csrf");
    expect(actionOptions.body).toBe(JSON.stringify({ action: "restart" }));
    clearSessionSecurity();
  });

  it("uses the admin user contract and protects every user write with CSRF", async () => {
    const adminUser = {
      id: "user-admin",
      username: "admin",
      email: null,
      githubLogin: null,
      twoFactorEnabled: true,
      displayName: "系统管理员",
      role: "admin",
      isDefaultAdmin: true,
      status: "active",
      createdAt: "2030-01-01T00:00:00Z",
      lastLoginAt: null,
      bookCount: 1,
    } as const;
    const createdUser = {
      ...adminUser,
      id: "user/a",
      username: "reader",
      email: "reader@example.test",
      githubLogin: "reader-octocat",
      twoFactorEnabled: false,
      displayName: "阅读者",
      role: "user",
      isDefaultAdmin: false,
      bookCount: 0,
    } as const;
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        authenticated: true,
        expiresAt: "2030-01-01T00:00:00Z",
        csrfToken: "users-csrf",
        csrfHeader: "X-QingJuan-CSRF",
      }))
      .mockResolvedValueOnce(jsonResponse([adminUser]))
      .mockResolvedValueOnce(jsonResponse(createdUser))
      .mockResolvedValueOnce(jsonResponse({ ...createdUser, status: "disabled" }))
      .mockResolvedValueOnce(jsonResponse({ ...createdUser, displayName: "新阅读者" }))
      .mockResolvedValueOnce(jsonResponse({ ...createdUser, role: "admin" }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);

    await login("admin-password");
    await getUsers();
    await createUser({ username: "reader", displayName: "阅读者", password: "new-user-password" });
    await updateUser(createdUser.id, { status: "disabled" });
    await updateUser(createdUser.id, { displayName: "新阅读者" });
    await updateUser(createdUser.id, { role: "admin" });
    await resetUserPassword(createdUser.id, { password: "replacement-password" });
    await revokeUserSessions(createdUser.id);

    expect(fetchMock.mock.calls.slice(1).map((call) => call[0])).toEqual([
      "/admin/api/users",
      "/admin/api/users",
      "/admin/api/users/user%2Fa",
      "/admin/api/users/user%2Fa",
      "/admin/api/users/user%2Fa",
      "/admin/api/users/user%2Fa/password",
      "/admin/api/users/user%2Fa/sessions/revoke",
    ]);
    const options = fetchMock.mock.calls.slice(1).map((call) => call[1] as RequestInit);
    expect(options.map((option) => option.method)).toEqual([
      "GET",
      "POST",
      "PATCH",
      "PATCH",
      "PATCH",
      "PUT",
      "POST",
    ]);
    expect((options[0].headers as Headers).has("X-QingJuan-CSRF")).toBe(false);
    for (const option of options.slice(1)) {
      expect((option.headers as Headers).get("X-QingJuan-CSRF")).toBe("users-csrf");
    }
    expect(options[1].body).toBe(JSON.stringify({
      username: "reader",
      displayName: "阅读者",
      password: "new-user-password",
    }));
    expect(options[2].body).toBe(JSON.stringify({ status: "disabled" }));
    expect(options[3].body).toBe(JSON.stringify({ displayName: "新阅读者" }));
    expect(options[4].body).toBe(JSON.stringify({ role: "admin" }));
    expect(options[5].body).toBe(JSON.stringify({ password: "replacement-password" }));
    clearSessionSecurity();
  });

  it("updates registration checks without placing SMTP secrets in the URL", async () => {
    const settings = {
      registration: {
        emailRequired: true,
        emailVerificationRequired: true,
        identityBadgeRequired: true,
        identityBadgeConfigured: true,
      },
      smtp: {
        host: "smtp.example.test",
        port: 587,
        security: "starttls",
        username: "mailer@example.test",
        fromAddress: "noreply@example.test",
        fromName: "青卷",
        passwordConfigured: true,
        configured: true,
      },
      github: {
        enabled: true,
        clientId: "Iv1.device-flow-client",
        configured: true,
      },
    } as const;
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        authenticated: true,
        expiresAt: "2030-01-01T00:00:00Z",
        csrfToken: "registration-csrf",
        csrfHeader: "X-QingJuan-CSRF",
      }))
      .mockResolvedValueOnce(jsonResponse(settings))
      .mockResolvedValueOnce(jsonResponse(settings));
    vi.stubGlobal("fetch", fetchMock);

    await login("admin-password");
    await getRegistrationSettings();
    await updateRegistrationSettings({
      emailVerificationRequired: true,
      identityBadgeRequired: true,
      smtp: {
        host: "smtp.example.test",
        port: 587,
        security: "starttls",
        username: "mailer@example.test",
        fromAddress: "noreply@example.test",
        fromName: "青卷",
      },
      github: {
        enabled: true,
        clientId: "Iv1.device-flow-client",
      },
      smtpPassword: "private-smtp-password",
      smtpPasswordAction: "replace",
      identityBadge: "private-identity-badge",
      identityBadgeAction: "replace",
    });

    const readRequest = fetchMock.mock.calls[1];
    const writeRequest = fetchMock.mock.calls[2];
    const writeOptions = writeRequest[1] as RequestInit;
    expect(readRequest[0]).toBe("/admin/api/registration-settings");
    expect((readRequest[1] as RequestInit).method).toBe("GET");
    expect(((readRequest[1] as RequestInit).headers as Headers).has("X-QingJuan-CSRF")).toBe(false);
    expect(writeRequest[0]).toBe("/admin/api/registration-settings");
    expect(writeOptions.method).toBe("PUT");
    expect((writeOptions.headers as Headers).get("X-QingJuan-CSRF")).toBe("registration-csrf");
    expect(String(writeRequest[0])).not.toContain("private-smtp-password");
    expect(String(writeRequest[0])).not.toContain("private-identity-badge");
    expect(JSON.parse(String(writeOptions.body))).toMatchObject({
      smtpPasswordAction: "replace",
      smtpPassword: "private-smtp-password",
      identityBadgeAction: "replace",
      identityBadge: "private-identity-badge",
      github: {
        enabled: true,
        clientId: "Iv1.device-flow-client",
      },
    });
    clearSessionSecurity();
  });
});
