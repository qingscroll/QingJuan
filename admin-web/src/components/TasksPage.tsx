import { useEffect, useMemo, useRef, useState } from "react";
import { FileSearchOutlined, RedoOutlined, SearchOutlined } from "@ant-design/icons";
import { Alert, App, Button, Drawer, Input, Progress, Space, Table, Tag, Timeline, Typography } from "antd";
import type { ColumnsType } from "antd/es/table";

import { getTaskLogs } from "../api";
import type { Task, TaskLog, TaskStatus } from "../types";
import { formatDate } from "../format";

export const taskStatusLabel: Record<TaskStatus, string> = {
  queued: "等待中",
  running: "进行中",
  completed: "已完成",
  failed: "失败",
  pause_requested: "正在暂停",
  paused: "已暂停",
  cancel_requested: "正在取消",
  cancelled: "已取消",
};

export const taskStatusColor: Record<TaskStatus, string> = {
  queued: "default",
  running: "processing",
  completed: "success",
  failed: "error",
  pause_requested: "processing",
  paused: "warning",
  cancel_requested: "processing",
  cancelled: "default",
};

type TasksPageProps = {
  tasks: Task[];
  bookTitles: Map<string, string>;
  onRetry: (taskId: string) => Promise<void>;
  onControl?: (taskId: string, action: "pause" | "resume" | "cancel") => Promise<void>;
};

export function TasksPage({ tasks, bookTitles, onRetry, onControl }: TasksPageProps) {
  const { message } = App.useApp();
  const [query, setQuery] = useState("");
  const [logTask, setLogTask] = useState<Task | null>(null);
  const [logs, setLogs] = useState<TaskLog[]>([]);
  const [logsLoading, setLogsLoading] = useState(false);
  const [logError, setLogError] = useState("");
  const [pendingIds, setPendingIds] = useState<Set<string>>(new Set());
  const pending = useRef(new Set<string>());
  const logRequest = useRef(0);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; logRequest.current++; };
  }, []);

  const runAction = async (taskId: string, operation: () => Promise<void>) => {
    if (pending.current.has(taskId)) return;
    pending.current.add(taskId);
    setPendingIds(new Set(pending.current));
    try { await operation(); }
    catch (error) {
      if (mounted.current) message.error(error instanceof Error ? error.message : "任务操作失败");
    } finally {
      pending.current.delete(taskId);
      if (mounted.current) setPendingIds(new Set(pending.current));
    }
  };

  const filtered = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase();
    if (!normalized) return tasks;
    return tasks.filter((task) =>
      [bookTitles.get(task.bookId) ?? "", task.message, task.error ?? "", taskStatusLabel[task.status]]
        .some((value) => value.toLocaleLowerCase().includes(normalized)),
    );
  }, [bookTitles, query, tasks]);

  const openLogs = async (task: Task) => {
    const request = ++logRequest.current;
    setLogTask(task);
    setLogs([]);
    setLogError("");
    setLogsLoading(true);
    try {
      const result = await getTaskLogs(task.id);
      if (mounted.current && request === logRequest.current) setLogs(result);
    } catch (error) {
      if (mounted.current && request === logRequest.current) {
        setLogError(error instanceof Error ? error.message : "日志加载失败");
      }
    } finally {
      if (mounted.current && request === logRequest.current) setLogsLoading(false);
    }
  };

  const columns: ColumnsType<Task> = [
    {
      title: "任务",
      key: "task",
      width: 260,
      render: (_, task) => (
        <div className="book-title-cell">
          <Typography.Text strong ellipsis={{ tooltip: bookTitles.get(task.bookId) }}>
            {bookTitles.get(task.bookId) ?? "书籍已删除"}
          </Typography.Text>
          <Typography.Text type="secondary">
            {task.taskType === "translate" ? "章节翻译" : "章节下载"} · {task.totalCount} 项
          </Typography.Text>
        </div>
      ),
    },
    {
      title: "状态",
      dataIndex: "status",
      key: "status",
      width: 100,
      filters: Object.entries(taskStatusLabel).map(([value, text]) => ({ value, text })),
      onFilter: (value, task) => task.status === value,
      render: (status: TaskStatus) => <Tag color={taskStatusColor[status]}>{taskStatusLabel[status]}</Tag>,
    },
    {
      title: "进度",
      key: "progress",
      width: 230,
      render: (_, task) => (
        <Progress
          percent={Math.max(0, Math.min(100, Math.round(task.progress)))}
          status={task.status === "failed" ? "exception" : task.status === "completed" ? "success" : undefined}
          size="small"
        />
      ),
    },
    {
      title: "说明",
      key: "message",
      render: (_, task) => (
        <Typography.Text type={task.error ? "danger" : "secondary"} ellipsis={{ tooltip: task.error || task.message }}>
          {task.error || task.message || "等待处理"}
        </Typography.Text>
      ),
    },
    {
      title: "更新",
      dataIndex: "updatedAt",
      key: "updatedAt",
      width: 140,
      render: (value: string) => formatDate(value),
      sorter: (left, right) => left.updatedAt.localeCompare(right.updatedAt),
      defaultSortOrder: "descend",
    },
    {
      title: "操作",
      key: "actions",
      fixed: "right",
      width: 280,
      render: (_, task) => (
        <Space size={2}>
          {onControl && ([
            ...(["queued", "running"].includes(task.status) ? ["pause" as const] : []),
            ...(task.status === "paused" ? ["resume" as const] : []),
            ...(["queued", "running", "paused", "pause_requested", "failed"].includes(task.status) ? ["cancel" as const] : []),
          ]).map((action) => (
            <Button key={action} type="text" disabled={pendingIds.has(task.id)}
              onClick={() => void runAction(task.id, () => onControl(task.id, action))}>
              {{ pause: "暂停", resume: "继续", cancel: "取消任务" }[action]}
            </Button>
          ))}
          <Button type="text" icon={<FileSearchOutlined />} onClick={() => void openLogs(task)}>日志</Button>
          {task.status === "failed" && (
            <Button
              type="text"
              icon={<RedoOutlined />}
              loading={pendingIds.has(task.id)}
              disabled={pendingIds.has(task.id)}
              onClick={() => void runAction(task.id, () => onRetry(task.id))}
            >
              重试
            </Button>
          )}
        </Space>
      ),
    },
  ];

  return (
    <>
      <div className="table-panel">
        <div className="table-toolbar">
          <Input
            allowClear
            prefix={<SearchOutlined />}
            placeholder="搜索书名、状态或任务说明"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            className="table-search"
          />
          <Typography.Text type="secondary">共 {filtered.length} 个任务</Typography.Text>
        </div>
        <Table
          rowKey="id"
          columns={columns}
          dataSource={filtered}
          scroll={{ x: 1080 }}
          locale={{ emptyText: query ? "没有匹配的任务" : "暂无任务记录" }}
          pagination={{ pageSize: 12, showSizeChanger: false, hideOnSinglePage: true }}
        />
      </div>

      <Drawer
        title={logTask ? `${bookTitles.get(logTask.bookId) ?? "任务"} · 运行日志` : "运行日志"}
        size={Math.min(560, window.innerWidth)}
        open={Boolean(logTask)}
        onClose={() => { logRequest.current++; setLogTask(null); }}
      >
        {logError && <Alert type="error" showIcon title={logError}
          action={<Button onClick={() => logTask && void openLogs(logTask)}>重新加载日志</Button>} />}
        {logsLoading ? (
          <div className="drawer-loading">正在读取日志…</div>
        ) : logs.length === 0 && !logError ? (
          <div className="quiet-empty">这个任务还没有运行日志。</div>
        ) : (
          <Timeline
            items={logs.map((log) => ({
              color: log.level === "error" ? "red" : log.level === "warning" ? "orange" : "blue",
              children: (
                <div className="log-entry">
                  <Space size={6} wrap>
                    <Tag color={log.level === "error" ? "red" : log.level === "warning" ? "orange" : "blue"}>
                      {log.level === "error" ? "错误" : log.level === "warning" ? "警告" : "信息"}
                    </Tag>
                    <Typography.Text type="secondary">#{log.sequence}</Typography.Text>
                    <Typography.Text type="secondary">{formatDate(log.createdAt)}</Typography.Text>
                  </Space>
                  <Typography.Text>{log.message}</Typography.Text>
                </div>
              ),
            }))}
          />
        )}
      </Drawer>
    </>
  );
}
