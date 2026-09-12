import { act, fireEvent, render, screen, within } from "@testing-library/react";
import { App } from "antd";

import * as api from "../api";
import type { SitePlugin, SitePluginLoginPoll, SitePluginLoginQrCode } from "../types";
import { PluginsPage } from "./PluginsPage";

const plugins: SitePlugin[] = [
  { id: "fanqie", name: "番茄小说" },
  { id: "qidian", name: "起点读书" },
].map((plugin) => ({
  ...plugin, description: "账号登录", category: "novel", domains: [], bookKinds: [], tags: [],
  capabilities: ["account_login"], version: "1.0.0", enabled: true, defaultEnabled: true,
  accountLoggedIn: false,
}));

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

const qr = (flowId: string): SitePluginLoginQrCode => ({
  flowId, qrImageBase64: `image-${flowId}`, expiresAt: "2030-01-01T00:00:00Z",
});
const waiting: SitePluginLoginPoll = { status: "waiting", message: "等待扫码", loggedIn: false };
const success: SitePluginLoginPoll = { status: "success", message: "登录成功", loggedIn: true };

function openLogin(name: string) {
  fireEvent.click(within(screen.getByRole("row", { name: new RegExp(name) }))
    .getByRole("button", { name: /扫码登录$/ }));
}

async function closeLogin() {
  fireEvent.click(await screen.findByRole("button", { name: /^关\s*闭$/ }));
}

let polls: Array<() => void>;
beforeEach(() => {
  polls = [];
  const setInterval = window.setInterval.bind(window);
  vi.spyOn(window, "setInterval").mockImplementation((callback, delay, ...args) => {
    if (delay === 2000 && typeof callback === "function") {
      polls.push(() => callback());
      return (100_000 + polls.length) as unknown as ReturnType<typeof window.setInterval>;
    }
    return setInterval(callback, delay, ...args) as unknown as ReturnType<typeof window.setInterval>;
  });
  vi.spyOn(api, "pollSitePluginLogin").mockResolvedValue(waiting);
});

function renderPage() {
  const onDataChanged = vi.fn().mockResolvedValue(undefined);
  return {
    ...render(<App><PluginsPage plugins={plugins} onSetEnabled={vi.fn()}
      onDataChanged={onDataChanged} /></App>),
    onDataChanged,
  };
}

describe("plugin QR login request lifetime", () => {
  it.each(["success", "error"] as const)("ignores a late %s after switching plugins", async (outcome) => {
    const old = deferred<SitePluginLoginQrCode>();
    vi.spyOn(api, "startSitePluginLogin").mockReturnValueOnce(old.promise).mockResolvedValueOnce(qr("qidian-new"));
    renderPage();
    openLogin("番茄小说");
    await closeLogin();
    openLogin("起点读书");
    expect(await screen.findByAltText("起点读书登录二维码")).toHaveAttribute("src", "data:image/png;base64,image-qidian-new");

    await act(async () => {
      if (outcome === "success") old.resolve(qr("fanqie-old"));
      else old.reject(new Error("旧番茄请求失败"));
    });

    expect(screen.getByAltText("起点读书登录二维码")).toHaveAttribute("src", "data:image/png;base64,image-qidian-new");
    expect(screen.queryByText("旧番茄请求失败")).not.toBeInTheDocument();
    await act(async () => { polls.at(-1)!(); });
    expect(api.pollSitePluginLogin).toHaveBeenLastCalledWith("qidian", "qidian-new");
  }, 15000);

  it.each(["success", "error"] as const)("keeps a retried flow after a closed request returns %s", async (outcome) => {
    const old = deferred<SitePluginLoginQrCode>();
    vi.spyOn(api, "startSitePluginLogin").mockReturnValueOnce(old.promise)
      .mockRejectedValueOnce(new Error("获取失败，请重新获取"))
      .mockResolvedValueOnce(qr("fanqie-retry"));
    renderPage();
    openLogin("番茄小说");
    await closeLogin();
    openLogin("番茄小说");
    fireEvent.click(await screen.findByRole("button", { name: "重新获取" }));
    expect(await screen.findByAltText("番茄小说登录二维码")).toHaveAttribute("src", "data:image/png;base64,image-fanqie-retry");

    await act(async () => {
      if (outcome === "success") old.resolve(qr("fanqie-old"));
      else old.reject(new Error("已关闭的请求失败"));
    });

    expect(screen.getByAltText("番茄小说登录二维码")).toHaveAttribute("src", "data:image/png;base64,image-fanqie-retry");
    expect(screen.queryByText("已关闭的请求失败")).not.toBeInTheDocument();
    await act(async () => { polls.at(-1)!(); });
    expect(api.pollSitePluginLogin).toHaveBeenLastCalledWith("fanqie", "fanqie-retry");
  }, 15000);

  it.each(["success", "error"] as const)("polls a new flow while an old poll is pending and ignores its late %s", async (outcome) => {
    const old = deferred<SitePluginLoginPoll>();
    vi.spyOn(api, "startSitePluginLogin").mockResolvedValueOnce(qr("fanqie-old")).mockResolvedValueOnce(qr("qidian-new"));
    vi.mocked(api.pollSitePluginLogin).mockReturnValueOnce(old.promise);
    const { onDataChanged } = renderPage();
    openLogin("番茄小说");
    await screen.findByAltText("番茄小说登录二维码");
    await act(async () => { polls.at(-1)!(); });
    await closeLogin();
    openLogin("起点读书");
    await screen.findByAltText("起点读书登录二维码");
    await act(async () => { polls.at(-1)!(); });
    expect(api.pollSitePluginLogin).toHaveBeenLastCalledWith("qidian", "qidian-new");

    await act(async () => {
      if (outcome === "success") old.resolve(success);
      else old.reject(new Error("旧登录状态读取失败"));
    });

    expect(screen.getByAltText("起点读书登录二维码")).toHaveAttribute("src", "data:image/png;base64,image-qidian-new");
    expect(screen.queryByText("旧登录状态读取失败")).not.toBeInTheDocument();
    expect(onDataChanged).not.toHaveBeenCalled();
  }, 15000);

  it.each(["close", "unmount"] as const)("does not refresh account data after %s with a pending login poll", async (action) => {
    const old = deferred<SitePluginLoginPoll>();
    vi.spyOn(api, "startSitePluginLogin").mockResolvedValue(qr("fanqie-old"));
    vi.mocked(api.pollSitePluginLogin).mockReturnValueOnce(old.promise);
    const { unmount, onDataChanged } = renderPage();
    openLogin("番茄小说");
    await screen.findByAltText("番茄小说登录二维码");
    await act(async () => { polls.at(-1)!(); });

    if (action === "close") await closeLogin();
    else unmount();
    await act(async () => { old.resolve(success); });

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(onDataChanged).not.toHaveBeenCalled();
  }, 15000);
});
