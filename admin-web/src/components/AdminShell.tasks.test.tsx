import { act, fireEvent, render, screen } from "@testing-library/react";
import { App } from "antd";

import * as api from "../api";
import type { Task, Settings } from "../types";
import { AdminShell } from "./AdminShell";

vi.mock("../api");

const session = { authenticated: true as const, expiresAt: "2026-09-12T00:00:00Z", csrfToken: "test-csrf", csrfHeader: "X-CSRF-Token" };
const settings: Settings = {
  systemPrompt: "", autoTranslateNextChapters: 0, downloadConcurrency: 2,
  translationModel: { enabled: false, baseUrl: "", model: "", supportsVision: false, apiKeyConfigured: false },
  mangaOcr: { enabled: false, baseUrl: "", apiKeyConfigured: false },
  bika: { emailConfigured: false, passwordConfigured: false },
};
const task = (status: Task["status"]): Task => ({ id: "task-1", bookId: "book-1", taskType: "download", status,
  totalCount: 10, completedCount: 4, progress: 40, attempts: 1, chapterIndexes: [1],
  message: "章节下载", error: null, createdAt: "2026-09-11T12:00:00Z", updatedAt: "2026-09-11T12:00:00Z" });
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { resolve, promise };
}
let poll: (() => void) | undefined;

beforeEach(() => {
  vi.clearAllMocks();
  window.history.replaceState(null, "", "#tasks");
  poll = undefined;
  vi.spyOn(window, "setInterval").mockImplementation((callback, delay) => {
    if (delay === 5000 && typeof callback === "function") poll = () => callback();
    return 1 as unknown as ReturnType<typeof window.setInterval>;
  });
  vi.spyOn(window, "clearInterval").mockImplementation(() => undefined);
  vi.mocked(api.getMeta).mockResolvedValue({ service: "qingjuan-backend", apiVersion: "1", appVersion: "2.2.1", instanceId: "test-instance", capabilities: { taskControl: true } });
  vi.mocked(api.getBackendServiceStatus).mockResolvedValue({ schemaVersion: 1, state: "running", businessApiAvailable: true,
    managementApiAvailable: true, generation: 1, startedAt: "2026-09-11T12:00:00Z", stoppedAt: null, lastActionAt: null, message: "运行中" });
  vi.mocked(api.getConnectionTokenStatus).mockResolvedValue({ configured: true, revealAvailable: false, maskedToken: "test", fingerprint: "1234" });
  vi.mocked(api.getDevices).mockResolvedValue([]);
  vi.mocked(api.getBooks).mockResolvedValue([]);
  vi.mocked(api.getTasks).mockResolvedValue([task("running")]);
  vi.mocked(api.getSources).mockResolvedValue([]);
  vi.mocked(api.getSitePlugins).mockResolvedValue([]);
  vi.mocked(api.getSettings).mockResolvedValue(settings);
  vi.mocked(api.controlTask).mockResolvedValue(task("pause_requested"));
});

afterEach(() => { window.history.replaceState(null, "", "/"); });

describe("task polling", () => {
  it("discards a stale poll after pause and keeps polling until the safe boundary", async () => {
    const stale = deferred<Task[]>();
    render(<App><AdminShell session={session} onLogout={vi.fn()} /></App>);
    expect(await screen.findByText("进行中")).toBeInTheDocument();
    vi.mocked(api.getTasks).mockReturnValueOnce(stale.promise);
    await act(async () => { poll!(); });
    fireEvent.click(screen.getByRole("button", { name: "暂停" }));
    expect(await screen.findByText("正在暂停")).toBeInTheDocument();
    await act(async () => { stale.resolve([task("running")]); });
    expect(screen.getByText("正在暂停")).toBeInTheDocument();
    expect(screen.queryByText("进行中")).not.toBeInTheDocument();
    vi.mocked(api.getTasks).mockResolvedValueOnce([task("paused")]);
    await act(async () => { poll!(); });
    expect(await screen.findByText("已暂停")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "继续" })).toBeEnabled();
    expect(window.clearInterval).toHaveBeenCalled();
  }, 15000);

  it("a full dashboard refresh started earlier does not overwrite a newer control response", async () => {
    const stale = deferred<Task[]>();
    render(<App><AdminShell session={session} onLogout={vi.fn()} /></App>);
    expect(await screen.findByText("进行中")).toBeInTheDocument();
    vi.mocked(api.getTasks).mockReturnValueOnce(stale.promise);
    fireEvent.click(screen.getByRole("button", { name: "刷新全部数据" }));
    fireEvent.click(screen.getByRole("button", { name: "暂停" }));
    expect(await screen.findByText("正在暂停")).toBeInTheDocument();
    await act(async () => { stale.resolve([task("running")]); });
    expect(screen.getByText("正在暂停")).toBeInTheDocument();
    expect(screen.queryByText("进行中")).not.toBeInTheDocument();
  }, 15000);

  it("a refresh after restoring data invalidates a poll for the previous library", async () => {
    const stale = deferred<Task[]>();
    render(<App><AdminShell session={session} onLogout={vi.fn()} /></App>);
    expect(await screen.findByText("进行中")).toBeInTheDocument();
    vi.mocked(api.getTasks).mockReturnValueOnce(stale.promise);
    await act(async () => { poll!(); });
    vi.mocked(api.getTasks).mockResolvedValueOnce([task("completed")]);
    fireEvent.click(screen.getByRole("button", { name: "刷新全部数据" }));
    expect(await screen.findByText("已完成")).toBeInTheDocument();
    await act(async () => { stale.resolve([task("running")]); });
    expect(screen.getByText("已完成")).toBeInTheDocument();
    expect(screen.queryByText("进行中")).not.toBeInTheDocument();
  }, 15000);
});
