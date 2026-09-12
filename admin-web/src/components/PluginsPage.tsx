import { useEffect, useMemo, useRef, useState } from "react";
import { DownloadOutlined, LoginOutlined, LogoutOutlined, SearchOutlined } from "@ant-design/icons";
import {
  Alert,
  App,
  Button,
  Input,
  List,
  Modal,
  Progress,
  Segmented,
  Space,
  Switch,
  Table,
  Tag,
  Typography,
} from "antd";
import type { ColumnsType } from "antd/es/table";

import * as api from "../api";
import { PluginPackageImport } from "./PluginPackageImport";
import { PluginMaintenance } from "./PluginMaintenance";
import type {
  SitePlugin,
  SitePluginBookshelfImportJob,
  SitePluginLoginPoll,
  SitePluginLoginQrCode,
} from "../types";

type PluginFilter = "all" | "enabled" | "disabled";

type PluginsPageProps = {
  plugins: SitePlugin[];
  onSetEnabled: (pluginId: string, enabled: boolean) => Promise<void>;
  onDataChanged?: () => Promise<void>;
  supportsMaintenance?: boolean;
};

const categoryLabel: Record<SitePlugin["category"], string> = {
  novel: "小说解析器",
  manga: "漫画解析器",
  general: "通用回退",
};

const capabilityLabel: Record<string, string> = {
  preview: "作品解析",
  chapter: "章节下载",
  search: "站内搜索",
  on_demand: "边看边下",
  account_login: "账号登录",
  cookie_login: "Cookie 登录",
  bookshelf_import: "书架导入",
};

const terminalLoginStatuses = new Set(["success", "cancelled", "expired", "error"]);

export function PluginsPage({ plugins, onSetEnabled, onDataChanged, supportsMaintenance = false }: PluginsPageProps) {
  const { message, modal } = App.useApp();
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<PluginFilter>("all");
  const [updating, setUpdating] = useState("");
  const [loginPlugin, setLoginPlugin] = useState<SitePlugin | null>(null);
  const [loginQr, setLoginQr] = useState<SitePluginLoginQrCode | null>(null);
  const [loginStatus, setLoginStatus] = useState<SitePluginLoginPoll | null>(null);
  const [loginError, setLoginError] = useState("");
  const [cookiePlugin, setCookiePlugin] = useState<SitePlugin | null>(null);
  const [cookieInput, setCookieInput] = useState("");
  const [cookieSubmitting, setCookieSubmitting] = useState(false);
  const [cookieError, setCookieError] = useState("");
  const [importPlugin, setImportPlugin] = useState<SitePlugin | null>(null);
  const [importJob, setImportJob] = useState<SitePluginBookshelfImportJob | null>(null);
  const [importError, setImportError] = useState("");
  const loginRequest = useRef(0);
  const importPolling = useRef(false);
  const onDataChangedRef = useRef(onDataChanged);
  onDataChangedRef.current = onDataChanged;

  useEffect(() => () => { loginRequest.current++; }, []);

  useEffect(() => {
    if (
      !loginPlugin
      || !loginQr
      || Boolean(loginError)
      || (loginStatus && terminalLoginStatuses.has(loginStatus.status))
    ) {
      return undefined;
    }
    const request = loginRequest.current;
    let disposed = false;
    let polling = false;
    const poll = async () => {
      if (disposed || request !== loginRequest.current || polling) return;
      polling = true;
      try {
        const result = await api.pollSitePluginLogin(loginPlugin.id, loginQr.flowId);
        if (disposed || request !== loginRequest.current) return;
        setLoginStatus(result);
        if (result.loggedIn) await onDataChangedRef.current?.();
      } catch (error) {
        if (!disposed && request === loginRequest.current) {
          setLoginError(error instanceof Error ? error.message : "登录状态读取失败");
        }
      } finally {
        polling = false;
      }
    };
    const timer = window.setInterval(() => void poll(), 2000);
    return () => {
      disposed = true;
      window.clearInterval(timer);
    };
  }, [loginError, loginPlugin?.id, loginQr?.flowId, loginStatus?.status]);

  useEffect(() => {
    if (
      !importPlugin
      || !importJob
      || Boolean(importError)
      || !["queued", "running"].includes(importJob.status)
    ) {
      return undefined;
    }
    let disposed = false;
    const poll = async () => {
      if (importPolling.current) return;
      importPolling.current = true;
      try {
        const result = await api.getSitePluginBookshelfImport(importPlugin.id, importJob.id);
        if (disposed) return;
        setImportJob(result);
        if (!["queued", "running"].includes(result.status)) {
          await onDataChangedRef.current?.();
        }
      } catch (error) {
        if (!disposed) setImportError(error instanceof Error ? error.message : "导入进度读取失败");
      } finally {
        importPolling.current = false;
      }
    };
    const timer = window.setInterval(() => void poll(), 1000);
    void poll();
    return () => {
      disposed = true;
      window.clearInterval(timer);
    };
  }, [importError, importJob?.id, importJob?.status, importPlugin?.id]);

  const counts = useMemo(() => ({
    enabled: plugins.filter((plugin) => plugin.enabled).length,
    disabled: plugins.filter((plugin) => !plugin.enabled).length,
  }), [plugins]);

  const filtered = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase();
    return plugins.filter((plugin) => {
      if (filter === "enabled" && !plugin.enabled) return false;
      if (filter === "disabled" && plugin.enabled) return false;
      if (!normalized) return true;
      return [
        plugin.id,
        plugin.name,
        plugin.description,
        categoryLabel[plugin.category],
        plugin.version,
        ...plugin.domains,
        ...plugin.bookKinds,
        ...plugin.tags,
        ...plugin.capabilities,
      ].some((value) => value.toLocaleLowerCase().includes(normalized));
    });
  }, [filter, plugins, query]);

  const updatePlugin = async (plugin: SitePlugin, enabled: boolean) => {
    setUpdating(plugin.id);
    try {
      await onSetEnabled(plugin.id, enabled);
    } catch (error) {
      message.error(error instanceof Error ? error.message : "插件状态保存失败");
    } finally {
      setUpdating("");
    }
  };

  const openLogin = async (plugin: SitePlugin) => {
    const request = ++loginRequest.current;
    setLoginPlugin(plugin);
    setLoginQr(null);
    setLoginStatus(null);
    setLoginError("");
    try {
      const result = await api.startSitePluginLogin(plugin.id);
      if (request === loginRequest.current) setLoginQr(result);
    } catch (error) {
      if (request === loginRequest.current) {
        setLoginError(error instanceof Error ? error.message : "登录二维码获取失败");
      }
    }
  };

  const closeLogin = () => {
    loginRequest.current++;
    setLoginPlugin(null);
    setLoginQr(null);
    setLoginStatus(null);
    setLoginError("");
  };

  const logoutAccount = async (plugin: SitePlugin) => {
    try {
      await api.logoutSitePluginAccount(plugin.id);
      await onDataChangedRef.current?.();
      message.success("站点账号已退出");
    } catch (error) {
      message.error(error instanceof Error ? error.message : "退出账号失败");
    }
  };

  const openCookieLogin = (plugin: SitePlugin) => {
    setCookiePlugin(plugin);
    setCookieInput("");
    setCookieError("");
  };

  const closeCookieLogin = () => {
    if (cookieSubmitting) return;
    setCookieInput("");
    setCookieError("");
    setCookiePlugin(null);
  };

  const submitCookieLogin = async () => {
    if (!cookiePlugin) return;
    const cookies = cookieInput.trim();
    if (!cookies) {
      setCookieError("请粘贴已登录浏览器请求中的 Cookie 请求头");
      return;
    }
    setCookieInput("");
    setCookieError("");
    setCookieSubmitting(true);
    try {
      await api.loginSitePluginWithCookies(cookiePlugin.id, cookies);
      setCookiePlugin(null);
      await onDataChangedRef.current?.();
      message.success("站点账号已连接");
    } catch (error) {
      setCookieError(error instanceof Error ? error.message : "Cookie 登录失败");
    } finally {
      setCookieSubmitting(false);
    }
  };

  const openBookshelfImport = async (plugin: SitePlugin) => {
    setImportPlugin(plugin);
    setImportJob(null);
    setImportError("");
    try {
      setImportJob(await api.startSitePluginBookshelfImport(plugin.id));
    } catch (error) {
      setImportError(error instanceof Error ? error.message : "账号书架导入失败");
    }
  };

  const retryBookshelfImport = () => {
    if (importJob) {
      setImportError("");
    } else if (importPlugin) {
      void openBookshelfImport(importPlugin);
    }
  };

  const columns: ColumnsType<SitePlugin> = [
    {
      title: "插件",
      key: "plugin",
      width: 310,
      render: (_, plugin) => (
        <div className="plugin-title-cell">
          <Space size={6} wrap>
            <Typography.Text strong>{plugin.name}</Typography.Text>
            <Tag>{plugin.id}</Tag>
            <Tag color={plugin.origin === "installed" ? "purple" : "default"}>
              {plugin.origin === "installed" ? "导入插件" : "内置"}
            </Tag>
            {plugin.capabilities.includes("account_login") && (
              <Tag color={plugin.accountLoggedIn ? "green" : "default"}>
                {plugin.accountLoggedIn ? "账号已登录" : "账号未登录"}
              </Tag>
            )}
          </Space>
          <Typography.Text type="secondary" ellipsis={{ tooltip: plugin.description }}>
            {plugin.description}
          </Typography.Text>
          {plugin.author && <Typography.Text type="secondary">作者：{plugin.author}</Typography.Text>}
          {plugin.loadError && <Typography.Text type="danger">{plugin.loadError}</Typography.Text>}
        </div>
      ),
    },
    {
      title: "类别",
      dataIndex: "category",
      key: "category",
      width: 112,
      render: (category: SitePlugin["category"]) => (
        <Tag color={category === "general" ? "default" : "blue"}>{categoryLabel[category]}</Tag>
      ),
    },
    {
      title: "匹配站点",
      dataIndex: "domains",
      key: "domains",
      width: 220,
      render: (domains: string[]) => domains.length
        ? domains.map((domain) => <Tag key={domain}>{domain}</Tag>)
        : <Typography.Text type="secondary">未匹配时回退</Typography.Text>,
    },
    {
      title: "能力",
      dataIndex: "capabilities",
      key: "capabilities",
      width: 230,
      render: (capabilities: string[]) => capabilities.map((capability) => (
        <Tag key={capability}>{capabilityLabel[capability] ?? capability}</Tag>
      )),
    },
    {
      title: "账号操作",
      key: "account-actions",
      width: 260,
      render: (_, plugin) => plugin.capabilities.includes("account_login") ? (
        <Space size={6} wrap>
          {plugin.accountLoggedIn ? (
            <Button
              size="small"
              icon={<LogoutOutlined />}
              onClick={() => void logoutAccount(plugin)}
            >
              退出账号
            </Button>
          ) : (
            <>
              <Button
                size="small"
                icon={<LoginOutlined />}
                disabled={!plugin.enabled}
                onClick={() => void openLogin(plugin)}
              >
                扫码登录
              </Button>
              {plugin.capabilities.includes("cookie_login") && (
                <Button
                  size="small"
                  disabled={!plugin.enabled}
                  onClick={() => openCookieLogin(plugin)}
                >
                  Cookie 登录
                </Button>
              )}
            </>
          )}
          {plugin.capabilities.includes("bookshelf_import") && (
            <Button
              size="small"
              type="primary"
              icon={<DownloadOutlined />}
              disabled={!plugin.enabled || !plugin.accountLoggedIn}
              onClick={() => void openBookshelfImport(plugin)}
            >
              添加账号书架
            </Button>
          )}
        </Space>
      ) : <Typography.Text type="secondary">无需账号</Typography.Text>,
    },
    {
      title: "版本",
      dataIndex: "version",
      key: "version",
      width: 88,
      render: (version: string) => `v${version}`,
    },
    {
      title: "安装管理",
      key: "package-actions",
      width: 160,
      render: (_, plugin) => plugin.origin === "installed" ? (
        <Space wrap>
        {supportsMaintenance && <PluginMaintenance plugin={plugin} onChanged={onDataChanged} />}
        <Button danger size="small" aria-label={`卸载${plugin.name}`} disabled={Boolean(updating)} onClick={() => modal.confirm({
          title: `卸载${plugin.name}？`,
          content: "卸载后该站点无法继续通过此插件解析或下载。已导入书籍和缓存章节会保留。",
          okText: "卸载", cancelText: "取消", okButtonProps: { danger: true, "aria-label": "确认卸载插件" },
          onOk: async () => {
            setUpdating(plugin.id);
            try {
              await api.uninstallSitePlugin(plugin.id);
            } catch (error) {
              message.error(error instanceof Error ? error.message : "卸载失败");
              throw error;
            } finally {
              setUpdating("");
            }
            message.success("插件已卸载");
            await onDataChangedRef.current?.();
          },
        })}>卸载</Button>
        </Space>
      ) : <Typography.Text type="secondary">随程序更新</Typography.Text>,
    },
    {
      title: "状态",
      key: "enabled",
      width: 138,
      fixed: "right",
      render: (_, plugin) => (
        <Space size={8}>
          <Switch
            aria-label={`${plugin.name}插件`}
            checked={plugin.enabled}
            loading={updating === plugin.id}
            disabled={Boolean(updating) && updating !== plugin.id}
            onChange={(enabled) => void updatePlugin(plugin, enabled)}
          />
          <Typography.Text type={plugin.enabled ? undefined : "secondary"}>
            {plugin.enabled ? "已启用" : "已停用"}
          </Typography.Text>
        </Space>
      ),
    },
  ];

  return (
    <div className="page-stack">
      <Alert
        className="plugin-scope-alert"
        type="info"
        showIcon
        title="插件状态由当前 Linux 后端统一管理"
        description="支持导入、更新和卸载独立插件包，修改会影响连接此服务的全部客户端。内置解析器仍随青卷更新。"
      />
      <div className="table-panel">
        <div className="table-toolbar plugin-toolbar">
          <Input
            allowClear
            prefix={<SearchOutlined />}
            placeholder="搜索插件名称、ID、域名或标签"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            className="table-search"
          />
          <Typography.Text type="secondary">已启用 {counts.enabled} / 共 {plugins.length} 个</Typography.Text>
          <PluginPackageImport onChanged={onDataChanged} />
        </div>
        <div className="plugin-filter-row">
          <Segmented<PluginFilter>
            value={filter}
            onChange={setFilter}
            options={[
              { label: `全部 ${plugins.length}`, value: "all" },
              { label: `已启用 ${counts.enabled}`, value: "enabled" },
              { label: `已停用 ${counts.disabled}`, value: "disabled" },
            ]}
          />
        </div>
        <Table
          rowKey="id"
          columns={columns}
          dataSource={filtered}
          scroll={{ x: 1_358 }}
          locale={{ emptyText: query || filter !== "all" ? "没有匹配的插件" : "当前后端没有插件" }}
          pagination={{ pageSize: 12, showSizeChanger: false, hideOnSinglePage: true }}
        />
      </div>
      <Modal
        open={Boolean(loginPlugin)}
        title={`${loginPlugin?.name ?? "站点"}扫码登录`}
        onCancel={closeLogin}
        footer={[
          loginError || (loginStatus && ["cancelled", "expired", "error"].includes(loginStatus.status)) ? (
            <Button key="retry" onClick={() => loginPlugin && void openLogin(loginPlugin)}>
              重新获取
            </Button>
          ) : null,
          <Button key="close" type="primary" onClick={closeLogin}>
            {loginStatus?.status === "success" ? "完成" : "关闭"}
          </Button>,
        ]}
      >
        <div className="plugin-login-dialog">
          {!loginError && loginStatus?.status !== "success" && loginQr && (
            <img
              src={`data:image/png;base64,${loginQr.qrImageBase64}`}
              alt={`${loginPlugin?.name ?? "站点"}登录二维码`}
              width={240}
              height={240}
            />
          )}
          {!loginQr && !loginError && <Progress type="circle" percent={30} showInfo={false} status="active" />}
          <Typography.Text>{loginError || loginStatus?.message || "正在获取登录二维码…"}</Typography.Text>
          <Typography.Text type="secondary">
            登录凭据只保存在当前青卷后端进程内，不会显示或写入浏览器存储。
          </Typography.Text>
          {loginPlugin?.capabilities.includes("cookie_login") && (
            <Typography.Text type="secondary">
              若当前网络无法获取二维码，请关闭此窗口并选择“Cookie 登录”。
            </Typography.Text>
          )}
        </div>
      </Modal>
      <Modal
        open={Boolean(cookiePlugin)}
        title={`${cookiePlugin?.name ?? "站点"} Cookie 登录`}
        onCancel={closeCookieLogin}
        confirmLoading={cookieSubmitting}
        okText="验证并登录"
        cancelText="取消"
        okButtonProps={{ disabled: !cookieInput.trim() }}
        onOk={() => void submitCookieLogin()}
      >
        <Space direction="vertical" size={12} style={{ width: "100%" }}>
          <Alert
            type="warning"
            showIcon
            title="仅用于扫码受限时的手动兜底"
            description={`请从已登录${cookiePlugin?.name ?? "站点"}网页请求中复制 Cookie 请求头。提交后输入会立即清空，凭据只保存在当前青卷后端进程内存中。`}
          />
          <Input.Password
            aria-label={`${cookiePlugin?.name ?? "站点"} Cookie 请求头`}
            autoComplete="off"
            placeholder="name=value; name2=value2"
            value={cookieInput}
            onChange={(event) => {
              setCookieInput(event.target.value);
              if (cookieError) setCookieError("");
            }}
            onPressEnter={() => void submitCookieLogin()}
          />
          {cookieError && <Alert type="error" showIcon title="Cookie 登录失败" description={cookieError} />}
        </Space>
      </Modal>
      <Modal
        open={Boolean(importPlugin)}
        title={`添加${importPlugin?.name ?? "站点"}账号书架`}
        mask={{
          closable: Boolean(
            importError || (importJob && !["queued", "running"].includes(importJob.status)),
          ),
        }}
        closable={Boolean(importError || (importJob && !["queued", "running"].includes(importJob.status)))}
        onCancel={() => {
          if (importError || (importJob && !["queued", "running"].includes(importJob.status))) {
            setImportPlugin(null);
          }
        }}
        width={680}
        footer={[
          importError ? (
            <Button key="retry" onClick={retryBookshelfImport}>
              重试
            </Button>
          ) : null,
          <Button
            key="close"
            type="primary"
            disabled={!importError && (!importJob || ["queued", "running"].includes(importJob.status))}
            onClick={() => setImportPlugin(null)}
          >
            完成
          </Button>,
        ]}
      >
        {importError ? (
          <Alert type="error" showIcon title="书架导入失败" description={importError} />
        ) : importJob ? (
          <Space direction="vertical" size={12} style={{ width: "100%" }}>
            <Progress percent={Math.round(importJob.progress)} status={importJob.status === "failed" ? "exception" : undefined} />
            <Typography.Text>{importJob.message}</Typography.Text>
            <Space wrap>
              <Tag>发现 {importJob.discoveredCount} 本</Tag>
              <Tag color="green">新增 {importJob.importedCount} 本</Tag>
              <Tag>跳过 {importJob.skippedCount} 本</Tag>
              <Tag color={importJob.unsupportedCount ? "orange" : undefined}>
                暂不支持 {importJob.unsupportedCount} 本
              </Tag>
              <Tag color={importJob.failedCount ? "red" : undefined}>失败 {importJob.failedCount} 本</Tag>
            </Space>
            <List
              size="small"
              className="plugin-import-list"
              dataSource={importJob.items}
              renderItem={(item) => (
                <List.Item>
                  <List.Item.Meta
                    title={(
                      <Space>
                        <Tag color={item.status === "unsupported" ? "orange" : undefined}>
                          {item.status === "imported"
                            ? "新增"
                            : item.status === "skipped"
                              ? "跳过"
                              : item.status === "unsupported"
                                ? "暂不支持"
                                : "失败"}
                        </Tag>
                        {item.title}
                      </Space>
                    )}
                    description={item.message}
                  />
                </List.Item>
              )}
            />
          </Space>
        ) : (
          <div className="plugin-import-loading"><Progress type="circle" percent={30} showInfo={false} status="active" /></div>
        )}
      </Modal>
    </div>
  );
}
