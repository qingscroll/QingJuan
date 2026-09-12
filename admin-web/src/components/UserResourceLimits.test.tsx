import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import * as api from "../api";
import { UserResourceLimits } from "./UserResourceLimits";
import type { ResourceUsage } from "../resource_types";

const usage: ResourceUsage = { limits: { revision: 2, storageBytes: 10000, dailyModelRequests: null },
  modelRequests: 12, day: "2026-09-11", resetsAt: "2026-09-12T00:00:00Z", storageUsedBytes: 0 };

it("saves explicit zero and blank without losing the inspected revision", async () => {
  const user = userEvent.setup();
  vi.spyOn(api, "getUserResourceUsage").mockResolvedValue(usage);
  const save = vi.spyOn(api, "updateUserResourceLimits").mockResolvedValue({ ...usage, limits: { ...usage.limits, revision: 3 } });
  render(<UserResourceLimits userId="reader" displayName="读者" onClose={vi.fn()} />);
  const storage = await screen.findByRole("spinbutton", { name: "存储上限（字节）" });
  await user.clear(storage);
  await user.type(screen.getByRole("spinbutton", { name: "每日模型请求上限" }), "0");
  await user.click(screen.getByRole("button", { name: "保存限制" }));
  await waitFor(() => expect(save).toHaveBeenCalledWith("reader", { expectedRevision: 2, storageBytes: null, dailyModelRequests: 0 }));
  expect(await screen.findByText("资源限制已保存")).toBeInTheDocument();
});

it("retains the draft on conflict and reloads before another save", async () => {
  const user = userEvent.setup();
  const get = vi.spyOn(api, "getUserResourceUsage").mockResolvedValue(usage);
  vi.spyOn(api, "updateUserResourceLimits").mockRejectedValue(new Error("资源限制已变化，请刷新后重试"));
  render(<UserResourceLimits userId="reader" displayName="读者" onClose={vi.fn()} />);
  await screen.findByRole("spinbutton", { name: "存储上限（字节）" });
  await waitFor(() => expect(screen.getByRole("button", { name: "保存限制" })).toBeEnabled());
  await user.click(screen.getByRole("button", { name: "保存限制" }));
  expect(await screen.findByText("资源限制已变化，请刷新后重试")).toBeInTheDocument();
  expect(screen.queryByText("资源限制已保存")).not.toBeInTheDocument();
  get.mockResolvedValue({ ...usage, limits: { ...usage.limits, revision: 4, dailyModelRequests: 20 } });
  await user.click(screen.getByRole("button", { name: "重新加载" }));
  await waitFor(() => expect(screen.getByRole("spinbutton", { name: "每日模型请求上限" })).toHaveValue("20"));
});
