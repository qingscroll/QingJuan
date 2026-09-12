import { act, fireEvent, render, screen, within } from "@testing-library/react";
import { App } from "antd";
import * as api from "../api";
import type { BackupInspection } from "../backup_types";
import { BackupsPage } from "./BackupsPage";

vi.mock("../api", () => ({
  getBackups: vi.fn(), getUsers: vi.fn(), createBackup: vi.fn(),
  inspectBackup: vi.fn(), restoreBackup: vi.fn(), downloadBackup: vi.fn(),
}));

const inspection: BackupInspection = {
  restoreId: "a".repeat(32), confirmationToken: "b".repeat(64),
  expiresAt: 2000000000, appVersion: "2.2.1", createdAt: "2026-09-11T12:00:00Z",
  mode: "replace", migrationOwnerId: null,
  backupCounts: { books: 3 }, currentCounts: { books: 7 },
  replacementScope: ["书库文件及阅读记录"], warnings: ["现有数据将被替换"],
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(api.getBackups).mockResolvedValue([]);
  vi.mocked(api.getUsers).mockResolvedValue([]);
  vi.mocked(api.inspectBackup).mockResolvedValue(inspection);
});

it("requires a successful inspection and explicit scope acknowledgement before restoring", async () => {
  let resolve!: (value: { restored: true; mode: "replace"; message: string }) => void;
  vi.mocked(api.restoreBackup).mockReturnValue(new Promise((done) => { resolve = done; }));
  const restored = vi.fn();
  render(<App><BackupsPage multiUser={false} onRestored={restored} /></App>);
  await screen.findByText("尚无备份，请先创建完整备份");
  expect(api.restoreBackup).not.toHaveBeenCalled();
  fireEvent.change(screen.getByLabelText("青卷备份 ZIP 文件"), { target: { files: [new File(["backup"], "backup.zip")] } });
  fireEvent.click(screen.getByRole("button", { name: "上传并检查" }));
  const dialog = await screen.findByRole("dialog");
  expect(within(dialog).getByText("书库文件及阅读记录")).toBeInTheDocument();
  expect(within(dialog).getByText("3")).toBeInTheDocument();
  expect(within(dialog).getByText("7")).toBeInTheDocument();
  const confirm = within(dialog).getByRole("button", { name: "确认恢复" });
  expect(confirm).toBeDisabled();
  fireEvent.click(within(dialog).getByRole("checkbox"));
  fireEvent.click(confirm);
  fireEvent.click(confirm);
  expect(api.restoreBackup).toHaveBeenCalledTimes(1);
  expect(api.restoreBackup).toHaveBeenCalledWith(inspection);
  await act(async () => resolve({ restored: true, mode: "replace", message: "恢复完成" }));
  expect(restored).toHaveBeenCalledTimes(1);
});

it("does not offer restore when inspection fails and leaves the selected file retryable", async () => {
  vi.mocked(api.inspectBackup).mockRejectedValue(new Error("备份文件损坏"));
  render(<App><BackupsPage multiUser={false} onRestored={vi.fn()} /></App>);
  await screen.findByText("尚无备份，请先创建完整备份");
  fireEvent.change(screen.getByLabelText("青卷备份 ZIP 文件"), { target: { files: [new File(["bad"], "bad.zip")] } });
  fireEvent.click(screen.getByRole("button", { name: "上传并检查" }));
  expect(await screen.findByText("备份文件损坏")).toBeInTheDocument();
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  expect(api.restoreBackup).not.toHaveBeenCalled();
  expect(screen.getByRole("button", { name: "上传并检查" })).toBeEnabled();
});

it("requires sensitive-data acknowledgement before creating a backup", async () => {
  vi.mocked(api.createBackup).mockResolvedValue({ id: "a", appVersion: "2.2.1", createdAt: "2026-09-11T12:00:00Z", sizeBytes: 1024, sha256: "b", containsSensitiveData: true });
  render(<App><BackupsPage multiUser={false} onRestored={vi.fn()} /></App>);
  await screen.findByText("尚无备份，请先创建完整备份");
  const create = screen.getByRole("button", { name: "创建备份" });
  expect(create).toBeDisabled();
  fireEvent.click(screen.getByRole("checkbox", { name: /我了解备份包含/ }));
  fireEvent.click(create);
  await screen.findByRole("button", { name: /下载/ });
  expect(api.createBackup).toHaveBeenCalledTimes(1);
});
