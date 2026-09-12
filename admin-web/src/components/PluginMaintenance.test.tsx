import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import * as api from "../api";
import type { SitePlugin } from "../types";
import type { PluginMaintenanceReport } from "../plugin_maintenance_types";
import { PluginMaintenance } from "./PluginMaintenance";

const plugin = { id: "sample", name: "示例", version: "2.0" } as SitePlugin;
const report: PluginMaintenanceReport = {
  pluginId: "sample", version: "2.0", sha256: "current-hash", apiVersion: 1,
  supportedApiVersion: 1, pythonVersion: "3.13", enabled: true, compatible: true,
  activeCalls: 0, rollbackVersion: "1.0", rollbackSha256: "previous-hash", rollbackAvailable: true,
  checkedAt: "2026-09-11T00:00:00Z", checks: [{ code: "package", label: "安装包检查", status: "passed", message: "完整性通过" }],
};

it("confirms the inspected version and refreshes the list after rollback", async () => {
  const user = userEvent.setup();
  vi.spyOn(api, "checkPluginMaintenance").mockResolvedValue(report);
  const rollback = vi.spyOn(api, "rollbackSitePlugin").mockResolvedValue({ ...plugin, version: "1.0" });
  const changed = vi.fn().mockResolvedValue(undefined);
  render(<PluginMaintenance plugin={plugin} onChanged={changed} />);
  await user.click(screen.getByRole("button", { name: "自检示例" }));
  expect(await screen.findByText("完整性通过")).toBeInTheDocument();
  await user.click(screen.getByRole("button", { name: "回退上一版本" }));
  expect(rollback).not.toHaveBeenCalled();
  expect(screen.getByText("确认从 2.0 回退到 1.0？")).toBeInTheDocument();
  await user.click(screen.getByRole("button", { name: "确认回退插件" }));
  await waitFor(() => expect(rollback).toHaveBeenCalledWith("sample", "2.0", "current-hash"));
  expect(await screen.findByText("已回退到 1.0")).toBeInTheDocument();
  expect(changed).toHaveBeenCalledTimes(1);
  expect(screen.queryByRole("button", { name: "确认回退插件" })).not.toBeInTheDocument();
});

it("discards a stale inspection on request failure and requires checking again", async () => {
  const user = userEvent.setup();
  vi.spyOn(api, "checkPluginMaintenance").mockResolvedValue(report);
  vi.spyOn(api, "rollbackSitePlugin").mockRejectedValue(new Error("版本已被其他管理员更新"));
  render(<PluginMaintenance plugin={plugin} />);
  await user.click(screen.getByRole("button", { name: "自检示例" }));
  await user.click(await screen.findByRole("button", { name: "回退上一版本" }));
  await user.click(screen.getByRole("button", { name: "确认回退插件" }));
  expect(await screen.findByText("版本已被其他管理员更新")).toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "回退上一版本" })).not.toBeInTheDocument();
  expect(screen.queryByRole("button", { name: "确认回退插件" })).not.toBeInTheDocument();
  await user.click(screen.getByRole("button", { name: "重新自检" }));
  expect(await screen.findByRole("button", { name: "回退上一版本" })).toBeEnabled();
});

it("holds rollback while a plugin is in use", async () => {
  const user = userEvent.setup();
  vi.spyOn(api, "checkPluginMaintenance").mockResolvedValue({ ...report, activeCalls: 1 });
  render(<PluginMaintenance plugin={plugin} />);
  await user.click(screen.getByRole("button", { name: "自检示例" }));
  expect(await screen.findByRole("button", { name: "回退上一版本" })).toBeDisabled();
});
