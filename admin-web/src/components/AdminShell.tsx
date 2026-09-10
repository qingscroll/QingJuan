import { useCallback, useEffect, useMemo, useState } from "react";
import {
  AppstoreOutlined,
  ApiOutlined,
  BookOutlined,
  CloudDownloadOutlined,
  DatabaseOutlined,
  DashboardOutlined,
  FileTextOutlined,
  LaptopOutlined,
  LogoutOutlined,
  MenuOutlined,
  ReloadOutlined,
  SettingOutlined,
  TeamOutlined,
  UnorderedListOutlined,
  UserAddOutlined,
} from "@ant-design/icons";
import { Alert, App, Badge, Button, Layout, Menu, Space, Spin, Tooltip, Typography } from "antd";

import * as api from "../api";
import { ThemeToggle } from "../theme";
import type {
  BackendServiceAction,
  DashboardData,
  SessionInfo,
  SettingsUpdate,
  Task,
} from "../types";
import { BackendUpgradePage } from "./BackendUpgradePage";
import { DevicesPage } from "./DevicesPage";
import { DiagnosticsPage } from "./DiagnosticsPage";
import { LibraryPage } from "./LibraryPage";
import { LogsPage } from "./LogsPage";
import { OverviewPage } from "./OverviewPage";
import { PluginsPage } from "./PluginsPage";
import { RegistrationSettingsPage } from "./RegistrationSettingsPage";
import { SettingsPage } from "./SettingsPage";
import { SourcesPage } from "./SourcesPage";
import { TasksPage } from "./TasksPage";
import { UsersPage } from "./UsersPage";

const { Header, Content, Sider } = Layout;

export type NavigationKey = "overview" | "devices" | "users" | "registration" | "library" | "tasks" | "diagnostics" | "upgrade" | "logs" | "sources" | "plugins" | "settings";

const navigationKeys: readonly NavigationKey[] = [
  "overview",
  "devices",
  "users",
  "registration",
  "library",
  "tasks",
  "diagnostics",
  "upgrade",
  "logs",
  "sources",
  "plugins",
  "settings",
];

const multiUserNavigationKeys = new Set<NavigationKey>(["users", "registration"]);

export function navigationAvailable(
  key: NavigationKey,
  capabilities: Record<string, boolean> | null | undefined,
): boolean {
  return !multiUserNavigationKeys.has(key) || capabilities?.multiUser === true;
}

export function navigationFromHash(hash: string): NavigationKey {
  const candidate = hash.replace(/^#\/?/, "");
  return navigationKeys.includes(candidate as NavigationKey)
    ? candidate as NavigationKey
    : "overview";
}

const navigation = [
  { key: "overview", icon: <AppstoreOutlined />, label: "服务概览" },
  { key: "devices", icon: <LaptopOutlined />, label: "设备管理" },
  { key: "users", icon: <TeamOutlined />, label: "用户管理" },
  { key: "registration", icon: <UserAddOutlined />, label: "注册设置" },
  { key: "library", icon: <BookOutlined />, label: "书库管理" },
  { key: "tasks", icon: <UnorderedListOutlined />, label: "任务中心" },
  { key: "diagnostics", icon: <DashboardOutlined />, label: "系统诊断" },
  { key: "upgrade", icon: <CloudDownloadOutlined />, label: "后端升级" },
  { key: "logs", icon: <FileTextOutlined />, label: "运行日志" },
  { key: "sources", icon: <DatabaseOutlined />, label: "书源状态" },
  { key: "plugins", icon: <ApiOutlined />, label: "插件管理" },
  { key: "settings", icon: <SettingOutlined />, label: "模型设置" },
];

const pageTitles: Record<NavigationKey, { title: string; subtitle: string }> = {
  overview: { title: "服务概览", subtitle: "快速掌握后端、书库和任务运行情况" },
  devices: { title: "设备管理", subtitle: "查看连接此后端的客户端，并控制设备访问" },
  users: { title: "用户管理", subtitle: "管理 Linux 后端用户及其登录状态" },
  registration: { title: "注册设置", subtitle: "配置新用户注册判断、邮箱验证码与身份牌" },
  library: { title: "书库管理", subtitle: "查看当前服务保存的作品并处理无用内容" },
  tasks: { title: "任务中心", subtitle: "跟踪下载与翻译任务，查看诊断日志" },
  diagnostics: { title: "系统诊断", subtitle: "检查服务健康、资源容量与近期异常" },
  upgrade: { title: "后端升级", subtitle: "检查、安装并验证 Linux 后端更新" },
  logs: { title: "运行日志", subtitle: "查看后端服务、任务程序与抓取器的详细输出" },
  sources: { title: "书源状态", subtitle: "确认已启用书源及最近连接状态" },
  plugins: { title: "插件管理", subtitle: "管理当前 Linux 后端的内置站点解析器" },
  settings: { title: "模型设置", subtitle: "维护翻译模型、OCR 与并发参数" },
};

type AdminShellProps = {
  session: SessionInfo;
  onLogout: () => Promise<void>;
};

export function AdminShell({ session, onLogout }: AdminShellProps) {
  const { message } = App.useApp();
  const [selected, setSelected] = useState<NavigationKey>(() => navigationFromHash(window.location.hash));
  const [collapsed, setCollapsed] = useState(false);
  const [data, setData] = useState<DashboardData | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");

  const navigate = useCallback((key: NavigationKey) => {
    setSelected(key);
    const hash = `#${key}`;
    if (window.location.hash !== hash) {
      window.history.replaceState(
        null,
        "",
        `${window.location.pathname}${window.location.search}${hash}`,
      );
    }
  }, []);

  useEffect(() => {
    const handleHashChange = () => setSelected(navigationFromHash(window.location.hash));
    window.addEventListener("hashchange", handleHashChange);
    return () => window.removeEventListener("hashchange", handleHashChange);
  }, []);

  const loadAll = useCallback(async (silent = false) => {
    if (silent) setRefreshing(true);
    else setLoading(true);
    setError("");
    try {
      const [meta, serviceControl, connectionToken, devices, books, tasks, sources, plugins, settings] = await Promise.all([
        api.getMeta(),
        api.getBackendServiceStatus(),
        api.getConnectionTokenStatus(),
        api.getDevices(),
        api.getBooks(),
        api.getTasks(),
        api.getSources(),
        api.getSitePlugins(),
        api.getSettings(),
      ]);
      setData({ meta, serviceControl, connectionToken, devices, books, tasks, sources, plugins, settings });
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "管理数据加载失败");
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    void loadAll();
  }, [loadAll]);

  useEffect(() => {
    if (data && !navigationAvailable(selected, data.meta.capabilities)) {
      navigate("overview");
    }
  }, [data, navigate, selected]);

  const hasActiveTasks = data?.tasks.some((task) => ["queued", "running"].includes(task.status));
  useEffect(() => {
    if (!hasActiveTasks) return;
    const timer = window.setInterval(() => {
      api.getTasks().then((tasks) => {
        setData((current) => (current ? { ...current, tasks } : current));
      }).catch(() => undefined);
    }, 5000);
    return () => window.clearInterval(timer);
  }, [hasActiveTasks]);

  useEffect(() => {
    const timer = window.setInterval(() => {
      Promise.all([api.getBackendServiceStatus(), api.getDevices()]).then(([serviceControl, devices]) => {
        setData((current) => (current ? { ...current, serviceControl, devices } : current));
      }).catch(() => undefined);
    }, 30000);
    return () => window.clearInterval(timer);
  }, []);

  const bookTitles = useMemo(
    () => new Map(data?.books.map((book) => [book.id, book.title]) ?? []),
    [data?.books],
  );

  const deleteBook = async (bookId: string) => {
    await api.deleteBook(bookId);
    setData((current) => current ? {
      ...current,
      books: current.books.filter((book) => book.id !== bookId),
      tasks: current.tasks.filter((task) => task.bookId !== bookId),
    } : current);
    message.success("书籍已从服务端删除");
  };

  const retryTask = async (taskId: string) => {
    const retried = await api.retryTask(taskId);
    setData((current) => current ? {
      ...current,
      tasks: current.tasks.map((task) => task.id === retried.id ? retried : task),
    } : current);
    message.success("任务已重新加入队列");
  };

  const saveSettings = async (payload: SettingsUpdate) => {
    const settings = await api.updateSettings(payload);
    setData((current) => current ? { ...current, settings } : current);
    message.success("模型设置已保存");
  };

  const setDeviceBanned = async (deviceId: string, banned: boolean) => {
    const updated = await api.setDeviceBanned(deviceId, banned);
    setData((current) => current ? {
      ...current,
      devices: current.devices.map((device) => device.id === updated.id ? updated : device),
    } : current);
    message.success(banned ? "设备已封禁" : "设备封禁已解除");
  };

  const setPluginEnabled = async (pluginId: string, enabled: boolean) => {
    const updated = await api.setSitePluginEnabled(pluginId, enabled);
    setData((current) => current ? {
      ...current,
      plugins: current.plugins.map((plugin) => plugin.id === updated.id ? updated : plugin),
    } : current);
    message.success(`${updated.name}已${enabled ? "启用" : "停用"}`);
  };

  const refreshPluginBooks = async () => {
    const [plugins, books] = await Promise.all([
      api.getSitePlugins(),
      api.getBooks(),
    ]);
    setData((current) => current ? { ...current, plugins, books } : current);
  };

  const updateTask = (task: Task) => {
    setData((current) => current ? {
      ...current,
      tasks: current.tasks.map((existing) => existing.id === task.id ? task : existing),
    } : current);
  };

  const controlBackendService = async (action: BackendServiceAction) => {
    const serviceControl = await api.controlBackendService(action);
    setData((current) => current ? { ...current, serviceControl } : current);
    const actionLabel = { start: "开启", stop: "关闭", restart: "重启" }[action];
    message.success(`后端业务服务已${actionLabel}`);
  };

  const currentPage = data ? {
    overview: (
      <OverviewPage
        data={data}
        bookTitles={bookTitles}
        onNavigate={navigate}
        onControlService={controlBackendService}
      />
    ),
    devices: <DevicesPage devices={data.devices} onSetBanned={setDeviceBanned} />,
    users: navigationAvailable("users", data.meta.capabilities) ? <UsersPage /> : null,
    registration: navigationAvailable("registration", data.meta.capabilities)
      ? <RegistrationSettingsPage />
      : null,
    library: <LibraryPage books={data.books} onDelete={deleteBook} />,
    tasks: (
      <TasksPage
        tasks={data.tasks}
        bookTitles={bookTitles}
        onRetry={async (taskId) => {
          await retryTask(taskId);
          const refreshed = await api.getTasks();
          const task = refreshed.find((item) => item.id === taskId);
          if (task) updateTask(task);
        }}
      />
    ),
    diagnostics: <DiagnosticsPage onOpenLogs={() => navigate("logs")} />,
    upgrade: (
      <BackendUpgradePage
        activeTaskCount={data.tasks.filter((task) => ["queued", "running"].includes(task.status)).length}
      />
    ),
    logs: <LogsPage />,
    sources: <SourcesPage sources={data.sources} />,
    plugins: (
      <PluginsPage
        plugins={data.plugins}
        onSetEnabled={setPluginEnabled}
        onDataChanged={refreshPluginBooks}
      />
    ),
    settings: <SettingsPage settings={data.settings} onSave={saveSettings} />,
  }[selected] : null;

  return (
    <Layout className="admin-layout">
      <button
        type="button"
        className={`sider-backdrop${collapsed ? "" : " is-visible"}`}
        aria-label="关闭导航"
        onClick={() => setCollapsed(true)}
      />
      <Sider
        width={232}
        collapsedWidth={0}
        collapsed={collapsed}
        trigger={null}
        breakpoint="lg"
        onBreakpoint={setCollapsed}
        className="admin-sider"
      >
        <div className="sider-brand">
          <div>
            <strong>青卷</strong>
            <span>服务管理</span>
          </div>
        </div>
        <Menu
          mode="inline"
          selectedKeys={[selected]}
          items={navigation.filter((item) => navigationAvailable(
            item.key as NavigationKey,
            data?.meta.capabilities,
          ))}
          onClick={({ key }) => {
            navigate(key as NavigationKey);
            if (window.matchMedia("(max-width: 991px)").matches) setCollapsed(true);
          }}
        />
        <div className="sider-status">
          <span
            className={`status-dot${data?.serviceControl.businessApiAvailable === false ? " is-stopped" : ""}`}
            aria-hidden="true"
          />
          <div>
            <strong>
              {data?.serviceControl.businessApiAvailable === false ? "管理通道在线" : "服务已连接"}
            </strong>
            <span>
              API v{data?.meta.apiVersion ?? "–"} · {data?.serviceControl.businessApiAvailable === false
                ? "业务请求暂停"
                : `在线设备 ${data?.devices.filter((device) => device.online).length ?? 0}`}
            </span>
          </div>
        </div>
      </Sider>

      <Layout>
        <Header className="admin-header">
          <Space size={14} className="header-service-meta">
            <Button
              className="mobile-menu-button"
              type="text"
              icon={<MenuOutlined />}
              aria-label="打开导航"
              onClick={() => setCollapsed(false)}
            />
            <Badge
              status={data?.serviceControl.businessApiAvailable ? "success" : "default"}
              text={data?.serviceControl.businessApiAvailable ? "业务服务在线" : "业务服务已关闭"}
            />
            <Typography.Text className="header-instance" ellipsis>
              {data ? `实例 ${data.meta.instanceId.slice(0, 8)}` : "正在读取实例"}
            </Typography.Text>
          </Space>
          <Space size={4} className="header-actions">
            <Typography.Text className="session-expiry" type="secondary">
              会话至 {formatDate(session.expiresAt, true)}
            </Typography.Text>
            <ThemeToggle />
            <Tooltip title="刷新全部数据">
              <Button
                type="text"
                icon={<ReloadOutlined spin={refreshing} />}
                aria-label="刷新全部数据"
                onClick={() => void loadAll(true)}
              />
            </Tooltip>
            <Tooltip title="退出管理界面">
              <Button type="text" icon={<LogoutOutlined />} aria-label="退出登录" onClick={() => void onLogout()} />
            </Tooltip>
          </Space>
        </Header>

        <Content className="admin-content">
          <div className="page-heading">
            <div>
              <Typography.Title level={2}>{pageTitles[selected].title}</Typography.Title>
              <Typography.Text type="secondary">{pageTitles[selected].subtitle}</Typography.Text>
            </div>
            {data && <Typography.Text className="version-label">QingJuan {data.meta.appVersion}</Typography.Text>}
          </div>

          {error && (
            <Alert
              className="content-alert"
              type="error"
              showIcon
              title="暂时无法加载管理数据"
              description={error}
              action={<Button size="small" onClick={() => void loadAll()}>重试</Button>}
            />
          )}

          {loading && !data ? (
            <div className="content-loading"><Spin size="large" /><span>正在整理服务数据…</span></div>
          ) : currentPage}
        </Content>
      </Layout>
    </Layout>
  );
}

export function formatDate(value: string | null | undefined, timeOnly = false): string {
  if (!value) return "–";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "–";
  return new Intl.DateTimeFormat("zh-CN", timeOnly
    ? { hour: "2-digit", minute: "2-digit", hour12: false }
    : { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false }
  ).format(date);
}
