import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { App } from "antd";

import * as api from "../api";
import type { SitePlugin } from "../types";
import { PluginPackageImport } from "./PluginPackageImport";
import { PluginsPage } from "./PluginsPage";

const plugin: SitePlugin = {
  id: "sample", name: "示例插件", version: "1.1.0", author: "示例作者", origin: "installed",
  description: "独立导入的解析器", category: "novel", domains: ["example.test"], bookKinds: ["长小说"],
  tags: [], capabilities: ["preview", "chapter"], defaultEnabled: true, enabled: true, accountLoggedIn: false,
};

it("inspects a file before allowing code installation and explicitly updates an existing version", async () => {
  const user = userEvent.setup();
  const inspect = vi.spyOn(api, "inspectSitePluginPackage").mockResolvedValue({plugin, installedVersion: "1.0.0", sha256: "digest"});
  const install = vi.spyOn(api, "importSitePluginPackage").mockResolvedValue(plugin);
  const changed = vi.fn().mockResolvedValue(undefined);
  render(<App><PluginPackageImport onChanged={changed} /></App>);
  await user.click(screen.getByRole("button", {name: "导入插件"}));
  const file = new File(["zip"], "sample.qjplugin", {type: "application/zip"});
  await user.upload(screen.getByLabelText("选择插件包"), file);
  await waitFor(() => expect(inspect).toHaveBeenCalledWith(file));
  expect(await screen.findByText("1.0.0 → 1.1.0")).toBeInTheDocument();
  expect(install).not.toHaveBeenCalled();
  expect(screen.getByRole("button", {name: "确认更新"})).toBeDisabled();
  await user.click(screen.getByRole("checkbox"));
  await user.click(screen.getByRole("button", {name: "确认更新"}));
  await waitFor(() => expect(install).toHaveBeenCalledWith(file, true));
  await waitFor(() => expect(changed).toHaveBeenCalledTimes(1));
});

it("shows validation failure and permits selecting a corrected package", async () => {
  const user = userEvent.setup();
  vi.spyOn(api, "inspectSitePluginPackage")
    .mockRejectedValueOnce(new Error("插件包结构无效"))
    .mockResolvedValueOnce({plugin, installedVersion: null, sha256: "digest"});
  render(<App><PluginPackageImport /></App>);
  await user.click(screen.getByRole("button", {name: "导入插件"}));
  await user.upload(screen.getByLabelText("选择插件包"), new File(["bad"], "bad.zip"));
  expect(await screen.findByText("插件包结构无效")).toBeInTheDocument();
  expect(screen.getByRole("button", {name: "安装插件"})).toBeDisabled();
  await user.upload(screen.getByLabelText("选择插件包"), new File(["ok"], "good.zip"));
  expect(await screen.findByText("示例插件 (sample)")).toBeInTheDocument();
  expect(screen.queryByText("插件包结构无效")).not.toBeInTheDocument();
});

it("allows uninstall only for installed plugins after confirmation", async () => {
  const user = userEvent.setup();
  const uninstall = vi.spyOn(api, "uninstallSitePlugin").mockResolvedValue(undefined);
  const changed = vi.fn().mockResolvedValue(undefined);
  render(<App><PluginsPage plugins={[plugin, {...plugin, id: "builtin", name: "内置插件", origin: "builtin"}]}
    onSetEnabled={vi.fn()} onDataChanged={changed} /></App>);
  expect(screen.getAllByRole("button", {name: /^卸载/})).toHaveLength(1);
  await user.click(screen.getByRole("button", {name: "卸载示例插件"}));
  expect((await screen.findAllByText("卸载示例插件？")).length).toBeGreaterThan(0);
  expect(uninstall).not.toHaveBeenCalled();
  await user.click(screen.getByRole("button", {name: "确认卸载插件"}));
  await waitFor(() => expect(uninstall).toHaveBeenCalledWith("sample"));
  await waitFor(() => expect(changed).toHaveBeenCalledTimes(1));
});
