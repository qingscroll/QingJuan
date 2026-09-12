import { fireEvent, render, screen, within } from "@testing-library/react";
import { App } from "antd";

import * as api from "../api";
import type { SitePlugin, SitePluginBookshelfImportJob } from "../types";
import { PluginsPage } from "./PluginsPage";

const plugin: SitePlugin = {
  id: "qidian", name: "起点读书", description: "账号书架", category: "novel", domains: [],
  bookKinds: [], tags: [], capabilities: ["account_login", "bookshelf_import"], version: "1.0.0",
  enabled: true, defaultEnabled: true, accountLoggedIn: true,
};
const running: SitePluginBookshelfImportJob = {
  id: "original-job", pluginId: plugin.id, status: "running", progress: 20, message: "正在导入原任务",
  discoveredCount: 5, processedCount: 1, importedCount: 1, skippedCount: 0, unsupportedCount: 0,
  failedCount: 0, items: [],
};
const completed: SitePluginBookshelfImportJob = {
  ...running, status: "completed", progress: 100, message: "原任务导入完成", processedCount: 5, importedCount: 5,
};

function renderPage() {
  const onDataChanged = vi.fn().mockResolvedValue(undefined);
  render(<App><PluginsPage plugins={[plugin]} onSetEnabled={vi.fn()} onDataChanged={onDataChanged} /></App>);
  fireEvent.click(screen.getByRole("button", { name: /添加账号书架$/ }));
  return onDataChanged;
}

it("retries progress reads for the original job without creating a duplicate import", async () => {
  const start = vi.spyOn(api, "startSitePluginBookshelfImport").mockResolvedValue(running);
  const poll = vi.spyOn(api, "getSitePluginBookshelfImport")
    .mockRejectedValueOnce(new api.ApiError("网络暂时中断", 0))
    .mockRejectedValueOnce(new api.ApiError("网络仍未恢复", 0))
    .mockResolvedValue(completed);
  const onDataChanged = renderPage();
  const dialog = await screen.findByRole("dialog");
  await within(dialog).findByText("网络暂时中断");
  fireEvent.click(within(dialog).getByRole("button", { name: /重\s*试/ }));
  await within(dialog).findByText("网络仍未恢复");
  fireEvent.click(within(dialog).getByRole("button", { name: /重\s*试/ }));
  await within(dialog).findByText("原任务导入完成");

  expect(start).toHaveBeenCalledTimes(1);
  expect(poll.mock.calls).toEqual(Array.from({ length: 3 }, () => [plugin.id, running.id]));
  expect(onDataChanged).toHaveBeenCalledTimes(1);
  expect(within(dialog).getByRole("button", { name: /完\s*成/ })).toBeEnabled();
});

it("still retries creation when the backend never returned a job", async () => {
  const start = vi.spyOn(api, "startSitePluginBookshelfImport")
    .mockRejectedValueOnce(new api.ApiError("站点账号暂不可用", 400)).mockResolvedValueOnce(running);
  vi.spyOn(api, "getSitePluginBookshelfImport").mockResolvedValue(completed);
  renderPage();
  const dialog = await screen.findByRole("dialog");
  await within(dialog).findByText("站点账号暂不可用");
  fireEvent.click(within(dialog).getByRole("button", { name: /重\s*试/ }));
  await within(dialog).findByText("原任务导入完成");

  expect(start).toHaveBeenCalledTimes(2);
  expect(api.getSitePluginBookshelfImport).toHaveBeenCalledWith(plugin.id, running.id);
});
