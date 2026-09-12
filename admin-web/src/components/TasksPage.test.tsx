import { act, fireEvent, render, screen, within } from "@testing-library/react";
import { App } from "antd";
import { getTaskLogs } from "../api";
import type { Task, TaskLog } from "../types";
import { TasksPage } from "./TasksPage";

vi.mock("../api", () => ({ getTaskLogs: vi.fn() }));
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function task(id: string, status: Task["status"]): Task {
  return { id, bookId: id, taskType: "download", status, totalCount: 10,
    completedCount: 4, progress: 40, message: "正在处理", attempts: 1,
    updatedAt: "2026-09-11T12:00:00Z", createdAt: "2026-09-11T12:00:00Z", chapterIndexes: [1, 2], error: null };
}
function row(id: string) { return screen.getByText(`作品 ${id}`).closest("tr")!; }
const titles = new Map([["a", "作品 a"], ["b", "作品 b"]]);
beforeEach(() => { vi.clearAllMocks(); });

describe("task controls", () => {
  it("keeps each task locked until its own operation ends while other tasks can progress", async () => {
    const first = deferred<void>();
    const second = deferred<void>();
    const onControl = vi.fn((id: string) => id === "a" ? first.promise : second.promise);
    render(<App><TasksPage tasks={[task("a", "running"), task("b", "running")]}
      bookTitles={titles} onRetry={vi.fn()} onControl={onControl} /></App>);
    fireEvent.click(within(row("a")).getByRole("button", { name: "暂停" }));
    fireEvent.click(within(row("b")).getByRole("button", { name: "暂停" }));
    expect(within(row("a")).getByRole("button", { name: "取消任务" })).toBeDisabled();
    expect(within(row("b")).getByRole("button", { name: "取消任务" })).toBeDisabled();
    fireEvent.click(within(row("a")).getByRole("button", { name: "暂停" }));
    expect(onControl).toHaveBeenCalledTimes(2);
    await act(async () => second.resolve());
    expect(within(row("a")).getByRole("button", { name: "暂停" })).toBeDisabled();
    expect(within(row("b")).getByRole("button", { name: "暂停" })).toBeEnabled();
    await act(async () => first.resolve());
    expect(within(row("a")).getByRole("button", { name: "暂停" })).toBeEnabled();
  }, 15000);

  it("failed tasks cannot cancel while retry is in flight and errors restore controls", async () => {
    const pending = deferred<void>();
    render(<App><TasksPage tasks={[task("a", "failed")]} bookTitles={titles}
      onRetry={() => pending.promise} onControl={vi.fn()} /></App>);
    fireEvent.click(within(row("a")).getByRole("button", { name: /重试/ }));
    expect(within(row("a")).getByRole("button", { name: "取消任务" })).toBeDisabled();
    await act(async () => pending.reject(new Error("任务状态已变化，请刷新")));
    expect(await screen.findByText("任务状态已变化，请刷新")).toBeInTheDocument();
    expect(within(row("a")).getByRole("button", { name: "取消任务" })).toBeEnabled();
  });

  it("maps requested, paused and terminal states to valid actions and percentage", () => {
    const { rerender } = render(<App><TasksPage tasks={[task("a", "pause_requested")]}
      bookTitles={titles} onRetry={vi.fn()} onControl={vi.fn()} /></App>);
    expect(screen.getByText("正在暂停")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "暂停" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "取消任务" })).toBeEnabled();
    expect(screen.getByText("40%")).toBeInTheDocument();
    rerender(<App><TasksPage tasks={[task("a", "paused")]} bookTitles={titles}
      onRetry={vi.fn()} onControl={vi.fn()} /></App>);
    expect(screen.getByRole("button", { name: "继续" })).toBeEnabled();
    rerender(<App><TasksPage tasks={[task("a", "cancelled")]} bookTitles={titles}
      onRetry={vi.fn()} onControl={vi.fn()} /></App>);
    expect(screen.queryByRole("button", { name: "取消任务" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "继续" })).not.toBeInTheDocument();
  });

  it("does not display unsupported task controls on old backends", () => {
    render(<App><TasksPage tasks={[task("a", "running")]} bookTitles={titles} onRetry={vi.fn()} /></App>);
    expect(screen.queryByRole("button", { name: "暂停" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "取消任务" })).not.toBeInTheDocument();
  });

  it("opening another log drawer discards the previous task's late logs", async () => {
    const first = deferred<TaskLog[]>();
    const second = deferred<TaskLog[]>();
    vi.mocked(getTaskLogs).mockImplementation((id) => id === "a" ? first.promise : second.promise);
    render(<App><TasksPage tasks={[task("a", "failed"), task("b", "completed")]}
      bookTitles={titles} onRetry={vi.fn()} /></App>);
    fireEvent.click(within(row("a")).getByRole("button", { name: /日志/ }));
    fireEvent.click(within(row("b")).getByRole("button", { name: /日志/ }));
    await act(async () => second.resolve([{ sequence: 1, level: "info", message: "当前任务日志", createdAt: "2026-09-11T12:00:00Z", taskId: "b" }]));
    expect(screen.getByText("当前任务日志")).toBeInTheDocument();
    await act(async () => first.resolve([{ sequence: 1, level: "info", message: "旧任务日志", createdAt: "2026-09-11T12:00:00Z", taskId: "a" }]));
    expect(screen.queryByText("旧任务日志")).not.toBeInTheDocument();
    expect(screen.getByText("当前任务日志")).toBeInTheDocument();
  });
});
