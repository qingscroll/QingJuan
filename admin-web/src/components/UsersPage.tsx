import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  CheckCircleOutlined,
  EditOutlined,
  GithubOutlined,
  KeyOutlined,
  LogoutOutlined,
  ReloadOutlined,
  SafetyCertificateOutlined,
  SearchOutlined,
  StopOutlined,
  UserAddOutlined,
  UserOutlined,
} from "@ant-design/icons";
import {
  Alert,
  App,
  Button,
  Form,
  Input,
  Modal,
  Popconfirm,
  Segmented,
  Space,
  Table,
  Tag,
  Tooltip,
  Typography,
} from "antd";
import type { ColumnsType } from "antd/es/table";

import * as api from "../api";
import { UserResourceLimits } from "./UserResourceLimits";
import type { UserAdminView, UserCreatePayload, UserRole, UserStatus } from "../types";

type UserFilter = "all" | UserStatus;

type CreateUserFields = UserCreatePayload & {
  confirmPassword: string;
};

type ResetPasswordFields = {
  password: string;
  confirmPassword: string;
};

type EditProfileFields = {
  displayName: string;
};

export function UsersPage() {
  const { message } = App.useApp();
  const [users, setUsers] = useState<UserAdminView[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<UserFilter>("all");
  const [pendingAction, setPendingAction] = useState("");
  const [createOpen, setCreateOpen] = useState(false);
  const [createSubmitting, setCreateSubmitting] = useState(false);
  const [editTarget, setEditTarget] = useState<UserAdminView | null>(null);
  const [editSubmitting, setEditSubmitting] = useState(false);
  const [resetTarget, setResetTarget] = useState<UserAdminView | null>(null);
  const [resourceTarget, setResourceTarget] = useState<UserAdminView | null>(null);
  const [resetSubmitting, setResetSubmitting] = useState(false);
  const [createForm] = Form.useForm<CreateUserFields>();
  const [editForm] = Form.useForm<EditProfileFields>();
  const [resetForm] = Form.useForm<ResetPasswordFields>();
  const loadRequest = useRef(0);
  const pendingUserChanges = useRef<Map<string, UserAdminView> | null>(null);

  const loadUsers = useCallback(async () => {
    const request = ++loadRequest.current;
    const changes = new Map<string, UserAdminView>();
    pendingUserChanges.current = changes;
    setLoading(true);
    setLoadError("");
    try {
      const loaded = await api.getUsers();
      if (request !== loadRequest.current) return;
      const loadedIds = new Set(loaded.map((user) => user.id));
      // Successful writes during this read are newer than its server snapshot.
      setUsers([
        ...Array.from(changes.values()).filter((user) => !loadedIds.has(user.id)),
        ...loaded.map((user) => changes.get(user.id) ?? user),
      ]);
    } catch (error) {
      if (request === loadRequest.current) {
        setLoadError(error instanceof Error ? error.message : "用户列表加载失败");
      }
    } finally {
      if (request === loadRequest.current) {
        pendingUserChanges.current = null;
        setLoading(false);
      }
    }
  }, []);

  useEffect(() => {
    void loadUsers();
    return () => {
      loadRequest.current += 1;
      pendingUserChanges.current = null;
    };
  }, [loadUsers]);

  const counts = useMemo(() => ({
    active: users.filter((user) => user.status === "active").length,
    disabled: users.filter((user) => user.status === "disabled").length,
  }), [users]);

  const filtered = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase();
    return users.filter((user) => {
      if (filter !== "all" && user.status !== filter) return false;
      if (!normalized) return true;
      return [
        user.username,
        user.email ?? "",
        user.githubLogin ?? "",
        user.displayName,
        user.role === "admin" ? "管理员" : "普通用户",
        user.status === "active" ? "已启用" : "已停用",
        user.githubLogin ? "GitHub 已绑定" : "GitHub 未绑定",
        user.twoFactorEnabled ? "2FA 两步验证 已启用" : "2FA 两步验证 未启用",
      ].some((value) => value.toLocaleLowerCase().includes(normalized));
    });
  }, [filter, query, users]);

  const replaceUser = (updated: UserAdminView) => {
    pendingUserChanges.current?.set(updated.id, updated);
    setUsers((current) => current.map((user) => user.id === updated.id ? updated : user));
  };

  const submitCreate = async (values: CreateUserFields) => {
    setCreateSubmitting(true);
    try {
      const created = await api.createUser({
        username: values.username.trim(),
        displayName: values.displayName.trim(),
        password: values.password,
      });
      pendingUserChanges.current?.set(created.id, created);
      setUsers((current) => [created, ...current.filter((user) => user.id !== created.id)]);
      createForm.resetFields();
      setCreateOpen(false);
      message.success("普通用户已创建");
    } catch (error) {
      message.error(error instanceof Error ? error.message : "用户创建失败");
    } finally {
      setCreateSubmitting(false);
    }
  };

  const updateStatus = async (user: UserAdminView) => {
    if (user.role === "admin") return;
    const status: UserStatus = user.status === "active" ? "disabled" : "active";
    setPendingAction(`status:${user.id}`);
    try {
      replaceUser(await api.updateUser(user.id, { status }));
      message.success(status === "active" ? "用户已启用" : "用户已停用");
    } catch (error) {
      message.error(error instanceof Error ? error.message : "用户状态更新失败");
    } finally {
      setPendingAction("");
    }
  };

  const submitProfileEdit = async (values: EditProfileFields) => {
    if (!editTarget) return;
    setEditSubmitting(true);
    try {
      replaceUser(await api.updateUser(editTarget.id, {
        displayName: values.displayName.trim(),
      }));
      editForm.resetFields();
      setEditTarget(null);
      message.success("账号资料已更新");
    } catch (error) {
      message.error(error instanceof Error ? error.message : "账号资料更新失败");
    } finally {
      setEditSubmitting(false);
    }
  };

  const updateRole = async (user: UserAdminView) => {
    if (isDefaultAdministrator(user) || (user.role === "user" && user.status === "disabled")) {
      return;
    }
    const role: UserRole = user.role === "admin" ? "user" : "admin";
    setPendingAction(`role:${user.id}`);
    try {
      replaceUser(await api.updateUser(user.id, { role }));
      message.success(role === "admin" ? "用户已提升为管理员" : "管理员已降为普通用户");
    } catch (error) {
      message.error(error instanceof Error ? error.message : "用户权限更新失败");
    } finally {
      setPendingAction("");
    }
  };

  const submitPasswordReset = async (values: ResetPasswordFields) => {
    if (!resetTarget) return;
    setResetSubmitting(true);
    try {
      await api.resetUserPassword(resetTarget.id, { password: values.password });
      resetForm.resetFields();
      setResetTarget(null);
      message.success("用户密码已重置");
    } catch (error) {
      message.error(error instanceof Error ? error.message : "密码重置失败");
    } finally {
      setResetSubmitting(false);
    }
  };

  const revokeSessions = async (user: UserAdminView) => {
    setPendingAction(`sessions:${user.id}`);
    try {
      await api.revokeUserSessions(user.id);
      message.success("用户登录会话已撤销");
    } catch (error) {
      message.error(error instanceof Error ? error.message : "会话撤销失败");
    } finally {
      setPendingAction("");
    }
  };

  const columns: ColumnsType<UserAdminView> = [
    {
      title: "用户",
      key: "user",
      width: 250,
      render: (_, user) => (
        <div className="user-title-cell">
          <Space size={6} wrap>
            <Typography.Text strong>{user.displayName}</Typography.Text>
            {user.role === "admin" && <Tag color="gold">管理员</Tag>}
          </Space>
          <Typography.Text type="secondary">@{user.username}</Typography.Text>
          <div className="user-mobile-security" aria-label={`${user.displayName} 的登录安全状态`}>
            <Tag
              icon={<GithubOutlined />}
              color={user.githubLogin ? "blue" : "default"}
              aria-label={user.githubLogin ? `GitHub 已绑定 @${user.githubLogin}` : "GitHub 未绑定"}
            >
              {user.githubLogin ? `GitHub @${user.githubLogin}` : "GitHub 未绑定"}
            </Tag>
            <Tag
              color={user.twoFactorEnabled ? "success" : "default"}
              aria-label={user.twoFactorEnabled ? "两步验证已启用" : "两步验证未启用"}
            >
              {user.twoFactorEnabled ? "2FA 已启用" : "2FA 未启用"}
            </Tag>
          </div>
        </div>
      ),
    },
    {
      title: "邮箱",
      dataIndex: "email",
      key: "email",
      width: 220,
      render: (email: string | null) => email ?? "—",
    },
    {
      title: "GitHub",
      dataIndex: "githubLogin",
      key: "githubLogin",
      width: 180,
      responsive: ["md"],
      render: (login: string | null) => login
        ? <Tag icon={<GithubOutlined />} color="blue" aria-label={`GitHub 已绑定 @${login}`}>@{login}</Tag>
        : <Tag aria-label="GitHub 未绑定">未绑定</Tag>,
    },
    {
      title: "两步验证",
      dataIndex: "twoFactorEnabled",
      key: "twoFactorEnabled",
      width: 120,
      responsive: ["md"],
      render: (enabled: boolean) => enabled
        ? <Tag color="success" aria-label="两步验证已启用">已启用</Tag>
        : <Tag aria-label="两步验证未启用">未启用</Tag>,
    },
    {
      title: "账号状态",
      dataIndex: "status",
      key: "status",
      width: 110,
      render: (status: UserStatus) => status === "active"
        ? <Tag color="success">已启用</Tag>
        : <Tag color="error">已停用</Tag>,
    },
    {
      title: "书架",
      dataIndex: "bookCount",
      key: "bookCount",
      width: 90,
      align: "right",
      render: (count: number) => `${count} 本`,
      sorter: (left, right) => left.bookCount - right.bookCount,
    },
    {
      title: "创建时间",
      dataIndex: "createdAt",
      key: "createdAt",
      width: 140,
      render: (value: string) => formatUserDate(value),
      sorter: (left, right) => left.createdAt.localeCompare(right.createdAt),
    },
    {
      title: "最近登录",
      dataIndex: "lastLoginAt",
      key: "lastLoginAt",
      width: 140,
      render: (value: string | null) => value ? formatUserDate(value) : "从未登录",
      sorter: (left, right) => (left.lastLoginAt ?? "").localeCompare(right.lastLoginAt ?? ""),
    },
    {
      title: "操作",
      key: "actions",
      width: 560,
      fixed: "right",
      render: (_, user) => (
        <Space size={4} wrap>
          <Button size="small" onClick={() => setResourceTarget(user)}
            aria-label={`管理 ${user.displayName} 的资源限制`}>资源限制</Button>
          <Button
            size="small"
            icon={<EditOutlined />}
            onClick={() => {
              editForm.setFieldsValue({ displayName: user.displayName });
              setEditTarget(user);
            }}
            aria-label={`编辑 ${user.displayName} 的账号资料`}
          >
            编辑资料
          </Button>
          {user.role === "admin" ? (
            <Tooltip title="系统管理员不能被停用">
              <span>
                <Button size="small" disabled aria-label={`${user.displayName} 是管理员，不能停用`}>
                  管理员不可停用
                </Button>
              </span>
            </Tooltip>
          ) : (
            <Popconfirm
              title={`${user.status === "active" ? "停用" : "启用"} ${user.displayName}？`}
              description={user.status === "active"
                ? "停用后该用户将无法登录，已有会话也会失效。"
                : "启用后该用户可以重新登录自己的书架。"}
              okText={user.status === "active" ? "确认停用" : "确认启用"}
              cancelText="取消"
              okButtonProps={{
                danger: user.status === "active",
                loading: pendingAction === `status:${user.id}`,
              }}
              onConfirm={() => updateStatus(user)}
            >
              <Button
                size="small"
                danger={user.status === "active"}
                icon={user.status === "active" ? <StopOutlined /> : <CheckCircleOutlined />}
                disabled={Boolean(pendingAction) && pendingAction !== `status:${user.id}`}
                aria-label={`${user.status === "active" ? "停用" : "启用"} ${user.displayName}`}
              >
                {user.status === "active" ? "停用" : "启用"}
              </Button>
            </Popconfirm>
          )}
          {isDefaultAdministrator(user) ? (
            <Tooltip title="内置管理员必须保留管理员权限">
              <span>
                <Button
                  size="small"
                  icon={<SafetyCertificateOutlined />}
                  disabled
                  aria-label={`${user.displayName} 是内置管理员，不能降权`}
                >
                  不可降权
                </Button>
              </span>
            </Tooltip>
          ) : user.role === "user" && user.status === "disabled" ? (
            <Tooltip title="请先启用该用户，再提升管理员权限">
              <span>
                <Button
                  size="small"
                  icon={<SafetyCertificateOutlined />}
                  disabled
                  aria-label={`${user.displayName} 已停用，不能提权`}
                >
                  提权
                </Button>
              </span>
            </Tooltip>
          ) : (
            <Popconfirm
              title={`${user.role === "admin" ? "降低" : "提升"} ${user.displayName} 的权限？`}
              description={user.role === "admin"
                ? "降权后该账号将不能再通过客户端修改服务级配置，现有登录会话也会失效。"
                : "提权后该账号可通过客户端修改书源、插件和模型等服务级配置，请确认该用户可信。"}
              okText={user.role === "admin" ? "确认降权" : "确认提权"}
              cancelText="取消"
              okButtonProps={{
                danger: user.role === "admin",
                loading: pendingAction === `role:${user.id}`,
              }}
              onConfirm={() => updateRole(user)}
            >
              <Button
                size="small"
                danger={user.role === "admin"}
                icon={user.role === "admin" ? <UserOutlined /> : <SafetyCertificateOutlined />}
                disabled={Boolean(pendingAction) && pendingAction !== `role:${user.id}`}
                aria-label={`${user.role === "admin" ? "降低" : "提升"} ${user.displayName} 的权限`}
              >
                {user.role === "admin" ? "降权" : "提权"}
              </Button>
            </Popconfirm>
          )}
          {isDefaultAdministrator(user) ? (
            <Tooltip title="管理密码请在服务器运行 qingjuan-password 修改">
              <span>
                <Button
                  size="small"
                  icon={<KeyOutlined />}
                  disabled
                  aria-label={`${user.displayName} 是管理员，不能在此重置密码`}
                >
                  重置密码
                </Button>
              </span>
            </Tooltip>
          ) : (
            <Button
              size="small"
              icon={<KeyOutlined />}
              onClick={() => {
                resetForm.resetFields();
                setResetTarget(user);
              }}
              aria-label={`重置 ${user.displayName} 的密码`}
            >
              重置密码
            </Button>
          )}
          <Popconfirm
            title={`撤销 ${user.displayName} 的全部登录会话？`}
            description="该用户需要在所有设备上重新登录。"
            okText="确认撤销"
            cancelText="取消"
            okButtonProps={{ loading: pendingAction === `sessions:${user.id}` }}
            onConfirm={() => revokeSessions(user)}
          >
            <Button
              size="small"
              icon={<LogoutOutlined />}
              disabled={Boolean(pendingAction) && pendingAction !== `sessions:${user.id}`}
              aria-label={`撤销 ${user.displayName} 的登录会话`}
            >
              撤销会话
            </Button>
          </Popconfirm>
        </Space>
      ),
    },
  ];

  return (
    <div className="page-stack">
      <Alert
        className="user-scope-alert"
        type="info"
        showIcon
        title="每位用户拥有独立书架和阅读进度"
        description="GitHub 绑定与两步验证状态仅供查看；管理员角色可通过客户端修改服务级配置。内置管理员不能降权或停用。"
      />
      {loadError && (
        <Alert
          type="error"
          showIcon
          title="用户列表加载失败"
          description={loadError}
          action={<Button size="small" aria-label="重试" onClick={() => void loadUsers()}>重试</Button>}
        />
      )}
      <div className="table-panel">
        <div className="table-toolbar user-toolbar">
          <Input
            allowClear
            prefix={<SearchOutlined />}
            placeholder="搜索用户名、邮箱、GitHub 或显示名称"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            className="table-search"
          />
          <Space wrap className="user-toolbar-actions">
            <Typography.Text type="secondary">已启用 {counts.active} / 共 {users.length} 位</Typography.Text>
            <Tooltip title="刷新用户列表">
              <Button
                icon={<ReloadOutlined spin={loading} />}
                aria-label="刷新用户列表"
                onClick={() => void loadUsers()}
              />
            </Tooltip>
            <Button
              type="primary"
              icon={<UserAddOutlined />}
              aria-label="创建普通用户"
              onClick={() => {
                createForm.resetFields();
                setCreateOpen(true);
              }}
            >
              创建普通用户
            </Button>
          </Space>
        </div>
        <div className="user-filter-row">
          <Segmented<UserFilter>
            value={filter}
            onChange={setFilter}
            options={[
              { label: `全部 ${users.length}`, value: "all" },
              { label: `已启用 ${counts.active}`, value: "active" },
              { label: `已停用 ${counts.disabled}`, value: "disabled" },
            ]}
          />
        </div>
        <Table
          rowKey="id"
          columns={columns}
          dataSource={filtered}
          loading={loading}
          rowClassName={(user) => user.role === "admin" ? "user-row-admin" : ""}
          scroll={{ x: 1_820 }}
          locale={{
            emptyText: query || filter !== "all" ? "没有匹配的用户" : "尚未创建客户端用户",
          }}
          pagination={{ pageSize: 12, showSizeChanger: false, hideOnSinglePage: true }}
        />
      </div>

      {resourceTarget && <UserResourceLimits key={resourceTarget.id} userId={resourceTarget.id}
        displayName={resourceTarget.displayName} onClose={() => setResourceTarget(null)} />}
      <Modal
        open={createOpen}
        title="创建普通用户"
        okText="创建用户"
        cancelText="取消"
        confirmLoading={createSubmitting}
        okButtonProps={{ "aria-label": "创建用户" }}
        onOk={() => createForm.submit()}
        onCancel={() => {
          if (createSubmitting) return;
          createForm.resetFields();
          setCreateOpen(false);
        }}
      >
        <Form<CreateUserFields>
          form={createForm}
          layout="vertical"
          requiredMark={false}
          autoComplete="off"
          onFinish={(values) => void submitCreate(values)}
        >
          <Alert
            className="user-dialog-alert"
            type="info"
            showIcon
            title="新账号默认为普通用户"
            description="创建后，用户可在客户端登录并使用自己的独立书架。"
          />
          <Form.Item
            label="用户名"
            name="username"
            rules={[
              { required: true, whitespace: true, message: "请输入用户名" },
              { min: 3, max: 32, message: "用户名需要 3–32 个字符" },
            ]}
          >
            <Input
              autoFocus
              autoComplete="username"
              maxLength={32}
              placeholder="用于客户端登录"
            />
          </Form.Item>
          <Form.Item
            label="显示名称"
            name="displayName"
            rules={[
              { required: true, whitespace: true, message: "请输入显示名称" },
              { max: 64, message: "显示名称不能超过 64 个字符" },
            ]}
          >
            <Input placeholder="用户在界面中看到的名称" />
          </Form.Item>
          <PasswordFields />
        </Form>
      </Modal>

      <Modal
        open={Boolean(editTarget)}
        title={`编辑 ${editTarget?.displayName ?? "用户"} 的账号资料`}
        okText="保存资料"
        cancelText="取消"
        confirmLoading={editSubmitting}
        okButtonProps={{ "aria-label": "保存账号资料" }}
        onOk={() => editForm.submit()}
        onCancel={() => {
          if (editSubmitting) return;
          editForm.resetFields();
          setEditTarget(null);
        }}
      >
        <Form<EditProfileFields>
          form={editForm}
          layout="vertical"
          requiredMark={false}
          autoComplete="off"
          onFinish={(values) => void submitProfileEdit(values)}
        >
          {editTarget && isDefaultAdministrator(editTarget) && (
            <Alert
              className="user-dialog-alert"
              type="info"
              showIcon
              title="正在修改内置管理员资料"
              description="用户名和管理员权限不可修改；管理密码仍需在服务器运行 qingjuan-password 修改。"
            />
          )}
          <Form.Item label="用户名">
            <Input value={editTarget?.username ?? ""} disabled />
          </Form.Item>
          <Form.Item label="邮箱" extra="邮箱由用户注册流程验证，暂不支持在管理端修改。">
            <Input value={editTarget?.email ?? ""} placeholder="—" disabled />
          </Form.Item>
          <Form.Item
            label="显示名称"
            name="displayName"
            rules={[
              { required: true, whitespace: true, message: "请输入显示名称" },
              { max: 64, message: "显示名称不能超过 64 个字符" },
            ]}
          >
            <Input autoFocus maxLength={64} placeholder="用户在界面中看到的名称" />
          </Form.Item>
        </Form>
      </Modal>

      <Modal
        open={Boolean(resetTarget)}
        title={`重置 ${resetTarget?.displayName ?? "用户"} 的密码`}
        okText="重置密码"
        cancelText="取消"
        confirmLoading={resetSubmitting}
        okButtonProps={{ "aria-label": "重置密码" }}
        onOk={() => resetForm.submit()}
        onCancel={() => {
          if (resetSubmitting) return;
          resetForm.resetFields();
          setResetTarget(null);
        }}
      >
        <Form<ResetPasswordFields>
          form={resetForm}
          layout="vertical"
          requiredMark={false}
          autoComplete="off"
          onFinish={(values) => void submitPasswordReset(values)}
        >
          <Alert
            className="user-dialog-alert"
            type="warning"
            showIcon
            title="用户需要使用新密码重新登录"
            description="管理界面不会显示或保存提交后的明文密码。"
          />
          <PasswordFields />
        </Form>
      </Modal>
    </div>
  );
}

function PasswordFields() {
  return (
    <>
      <Form.Item
        label="新密码"
        name="password"
        rules={[
          { required: true, message: "请输入新密码" },
          { min: 12, max: 256, message: "密码需要 12–256 个字符" },
        ]}
      >
        <Input.Password autoComplete="new-password" placeholder="至少 12 个字符" />
      </Form.Item>
      <Form.Item
        label="确认新密码"
        name="confirmPassword"
        dependencies={["password"]}
        rules={[
          { required: true, message: "请再次输入新密码" },
          ({ getFieldValue }) => ({
            validator(_, value: string) {
              if (!value || getFieldValue("password") === value) return Promise.resolve();
              return Promise.reject(new Error("两次输入的密码不一致"));
            },
          }),
        ]}
      >
        <Input.Password autoComplete="new-password" placeholder="再次输入新密码" />
      </Form.Item>
    </>
  );
}

function isDefaultAdministrator(user: UserAdminView): boolean {
  return user.isDefaultAdmin;
}

function formatUserDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "–";
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}
