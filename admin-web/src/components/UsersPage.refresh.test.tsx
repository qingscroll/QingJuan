import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { App } from "antd";

import * as api from "../api";
import type { UserAdminView } from "../types";
import { UsersPage } from "./UsersPage";

const reader: UserAdminView = {
  id: "reader", username: "reader", displayName: "阅读者", role: "user", status: "active",
  isDefaultAdmin: false, email: null, githubLogin: null, twoFactorEnabled: false,
  createdAt: "2030-01-01T00:00:00Z", lastLoginAt: null, bookCount: 0,
};
const other: UserAdminView = { ...reader, id: "other", username: "other", displayName: "其他用户" };

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

const refresh = () => fireEvent.click(screen.getByRole("button", { name: "刷新用户列表" }));

it.each([
  { action: "停用 阅读者", confirm: "确认停用", update: { status: "disabled" as const }, after: "启用 阅读者" },
  { action: "提升 阅读者 的权限", confirm: "确认提权", update: { role: "admin" as const }, after: "降低 阅读者 的权限" },
])("keeps a successful $action when an older refresh arrives", async ({ action, confirm, update, after }) => {
  const pendingList = deferred<UserAdminView[]>();
  const pendingUpdate = deferred<UserAdminView>();
  vi.spyOn(api, "getUsers").mockResolvedValueOnce([reader, other]).mockReturnValueOnce(pendingList.promise);
  vi.spyOn(api, "updateUser").mockReturnValueOnce(pendingUpdate.promise);
  render(<App><UsersPage /></App>);
  await screen.findByText("阅读者");
  fireEvent.click(screen.getByRole("button", { name: action }));
  fireEvent.click(await screen.findByRole("button", { name: confirm }));
  await waitFor(() => expect(api.updateUser).toHaveBeenCalledWith(reader.id, update));
  refresh();
  await act(async () => pendingUpdate.resolve({ ...reader, ...update }));
  expect(screen.getByRole("button", { name: after })).toBeInTheDocument();

  await act(async () => pendingList.resolve([reader, other]));

  expect(screen.getByRole("button", { name: after })).toBeInTheDocument();
  expect(screen.getByText("其他用户")).toBeInTheDocument();
}, 15_000);

it.each(["success", "error"] as const)("ignores an older refresh's late %s after a newer refresh", async (outcome) => {
  const older = deferred<UserAdminView[]>();
  const newer = deferred<UserAdminView[]>();
  vi.spyOn(api, "getUsers").mockResolvedValueOnce([reader])
    .mockReturnValueOnce(older.promise).mockReturnValueOnce(newer.promise);
  render(<App><UsersPage /></App>);
  await screen.findByText("阅读者");
  refresh();
  refresh();
  await act(async () => newer.resolve([{ ...reader, displayName: "最新名称" }]));
  await act(async () => {
    if (outcome === "success") older.resolve([reader]);
    else older.reject(new Error("旧刷新失败"));
  });

  expect(screen.getByText("最新名称")).toBeInTheDocument();
  expect(screen.queryByText("旧刷新失败")).not.toBeInTheDocument();
});

it("keeps a newly created user and the other accounts when the initial list arrives late", async () => {
  const initial = deferred<UserAdminView[]>();
  vi.spyOn(api, "getUsers").mockReturnValueOnce(initial.promise);
  vi.spyOn(api, "createUser").mockResolvedValue(reader);
  render(<App><UsersPage /></App>);
  fireEvent.click(screen.getByRole("button", { name: "创建普通用户" }));
  const dialog = screen.getByRole("dialog");
  fireEvent.change(within(dialog).getByLabelText("用户名"), { target: { value: "reader" } });
  fireEvent.change(within(dialog).getByLabelText("显示名称"), { target: { value: "阅读者" } });
  for (const label of ["新密码", "确认新密码"]) {
    fireEvent.change(within(dialog).getByLabelText(label), { target: { value: "reader-password-123" } });
  }
  fireEvent.click(within(dialog).getByRole("button", { name: "创建用户" }));
  await screen.findByText("阅读者");
  await act(async () => initial.resolve([other]));

  expect(screen.getByText("阅读者")).toBeInTheDocument();
  expect(screen.getByText("其他用户")).toBeInTheDocument();
});
