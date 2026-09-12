import { useCallback, useEffect, useRef, useState } from "react";
import { Alert, App, Button, Card, Checkbox, Descriptions, Form, Modal, Select, Space, Table, Typography } from "antd";

import * as api from "../api";
import type { BackupArtifact, BackupInspection, BackupMode } from "../backup_types";
import type { UserAdminView } from "../types";

const countLabels: Record<string, string> = {
  books: "书籍", tasks: "任务", reading_progress: "阅读记录", link_jobs: "链接导入记录",
  users: "账号", book_sources: "书源", site_plugin_packages: "已安装插件",
};
const date = (value: string) => new Date(value).toLocaleString();

type Props = { multiUser: boolean; onRestored: () => void };

export function BackupsPage({ multiUser, onRestored }: Props) {
  const { message } = App.useApp();
  const [artifacts, setArtifacts] = useState<BackupArtifact[]>([]);
  const [users, setUsers] = useState<UserAdminView[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [mode, setMode] = useState<BackupMode>("replace");
  const [owner, setOwner] = useState<string>();
  const [file, setFile] = useState<File>();
  const [acknowledged, setAcknowledged] = useState(false);
  const [inspection, setInspection] = useState<BackupInspection | null>(null);
  const [confirmed, setConfirmed] = useState(false);
  const mounted = useRef(true);
  const lock = useRef(false);
  const revision = useRef(0);

  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; revision.current++; };
  }, []);

  const load = useCallback(async () => {
    const current = ++revision.current;
    setLoading(true);
    try {
      const [next, accounts] = await Promise.all([api.getBackups(), multiUser ? api.getUsers() : Promise.resolve([])]);
      if (!mounted.current || current !== revision.current) return;
      setArtifacts(next);
      setUsers(accounts);
      setError("");
    } catch (caught) {
      if (mounted.current && current === revision.current) setError(caught instanceof Error ? caught.message : "备份列表加载失败");
    } finally {
      if (mounted.current && current === revision.current) setLoading(false);
    }
  }, [multiUser]);

  useEffect(() => { void load(); }, [load]);

  async function run(name: string, action: () => Promise<void>) {
    if (lock.current) return;
    lock.current = true;
    setBusy(name);
    setError("");
    try { await action(); }
    catch (caught) {
      if (mounted.current) setError(caught instanceof Error ? caught.message : "备份操作失败，请稍后重试");
    } finally {
      lock.current = false;
      if (mounted.current) setBusy("");
    }
  }

  async function create() {
    const artifact = await api.createBackup();
    if (!mounted.current) return;
    setArtifacts((current) => [artifact, ...current.filter((item) => item.id !== artifact.id)]);
    void message.success("备份已生成，请下载并妥善保存");
  }

  async function download(artifact: BackupArtifact) {
    const blob = await api.downloadBackup(artifact.id);
    if (!mounted.current) return;
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `qingjuan-backup-${artifact.id}.zip`;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function inspect() {
    if (!file) return;
    const result = await api.inspectBackup(file, mode, mode === "migrate_local" ? owner : undefined);
    if (mounted.current) { setConfirmed(false); setInspection(result); }
  }

  async function restore() {
    if (!inspection || !confirmed) return;
    const selected = inspection;
    // A failed/lost response requires a new inspection before another restore.
    try {
      const result = await api.restoreBackup(selected);
      if (mounted.current) {
        void message.success(result.message);
        onRestored();
        await load();
      }
    } finally {
      if (mounted.current) { setInspection(null); setConfirmed(false); }
    }
  }

  return <Space orientation="vertical" size="large" style={{ width: "100%" }}>
    {error && <Alert type="error" showIcon title={error} action={<Button disabled={!!busy} onClick={() => void load()}>刷新</Button>} />}
    {busy && <Alert type="info" showIcon title="正在处理备份数据" description="请保持此页打开。需要一致性快照时，服务会短暂等待当前文件操作完成。" />}
    <Card title="创建完整备份">
      <Space orientation="vertical" style={{ width: "100%" }}>
        <Typography.Paragraph>保存书籍文件、阅读记录、设置、账号与插件。备份期间其他客户端可能短暂显示服务维护中。</Typography.Paragraph>
        <Checkbox checked={acknowledged} disabled={!!busy} onChange={(event) => setAcknowledged(event.target.checked)}>
          我了解备份包含账号和服务密钥，将妥善保管备份文件
        </Checkbox>
        <Button type="primary" loading={busy === "create"} disabled={!acknowledged || !!busy} onClick={() => void run("create", create)}>创建备份</Button>
      </Space>
    </Card>
    <Card title="备份文件" extra={<Button disabled={!!busy || loading} onClick={() => void load()}>刷新</Button>}>
      <Table rowKey="id" dataSource={artifacts} loading={loading} pagination={{ pageSize: 8 }} scroll={{ x: 600 }} locale={{ emptyText: "尚无备份，请先创建完整备份" }} columns={[
        { title: "创建时间", dataIndex: "createdAt", render: date },
        { title: "版本", dataIndex: "appVersion" },
        { title: "大小", dataIndex: "sizeBytes", render: (bytes: number) => `${(bytes / 1048576).toFixed(1)} MB` },
        { title: "操作", render: (_, artifact) => <Button aria-label="下载备份" disabled={!!busy} loading={busy === artifact.id} onClick={() => void run(artifact.id, () => download(artifact))}>下载</Button> },
      ]} />
    </Card>
    <Card title="恢复或迁移备份">
      <Form layout="vertical">
        <Form.Item label="恢复方式">
          <Select value={mode} disabled={!!busy} onChange={setMode} options={[
            { value: "replace", label: "完整恢复：替换当前数据" },
            ...(multiUser ? [{ value: "migrate_local", label: "迁移本机书库：导入到空服务器的指定账号" }] : []),
          ]} />
        </Form.Item>
        {mode === "migrate_local" && <Form.Item label="接收本机书库的账号" required>
          <Select aria-label="接收本机书库的账号" value={owner} disabled={!!busy} onChange={setOwner} options={users.filter((user) => user.status === "active").map((user) => ({ value: user.id, label: `${user.displayName} (${user.username})` }))} />
        </Form.Item>}
        <Form.Item label="青卷备份 ZIP 文件" required>
          <input aria-label="青卷备份 ZIP 文件" type="file" accept=".zip,application/zip" disabled={!!busy} onChange={(event) => setFile(event.target.files?.[0])} />
        </Form.Item>
        <Typography.Paragraph type="secondary">先上传并检查备份的版本、完整性和数据范围，核对后才会执行恢复。仅使用可信备份，其中可能包含可执行插件。</Typography.Paragraph>
        <Button loading={busy === "inspect"} disabled={!!busy || !file || (mode === "migrate_local" && !owner)} onClick={() => void run("inspect", inspect)}>上传并检查</Button>
      </Form>
    </Card>
    <Modal open={inspection !== null} title="核对恢复范围" width={720} okText="确认恢复" cancelText="取消" confirmLoading={busy === "restore"} okButtonProps={{ danger: true, disabled: !confirmed || !!busy }} cancelButtonProps={{ disabled: !!busy }} closable={!busy} mask={{ closable: !busy }} onCancel={() => setInspection(null)} onOk={() => void run("restore", restore)}>
      {inspection && <Space orientation="vertical" style={{ width: "100%" }}>
        <Descriptions column={1} items={[
          { key: "version", label: "备份版本", children: inspection.appVersion },
          { key: "date", label: "创建时间", children: date(inspection.createdAt) },
          { key: "scope", label: "将替换的数据", children: inspection.replacementScope.join("；") },
          ...(inspection.migrationOwnerId ? [{ key: "owner", label: "书库归属账号", children: users.find((user) => user.id === inspection.migrationOwnerId)?.displayName ?? inspection.migrationOwnerId }] : []),
        ]} />
        <Table rowKey="key" pagination={false} size="small" dataSource={Object.keys(inspection.backupCounts).map((key) => ({ key, label: countLabels[key] ?? key, before: inspection.currentCounts[key] ?? 0, after: inspection.backupCounts[key] }))} columns={[
          { title: "数据", dataIndex: "label" }, { title: "当前数量", dataIndex: "before" }, { title: "备份数量", dataIndex: "after" },
        ]} />
        {inspection.warnings.map((warning) => <Alert key={warning} type="warning" showIcon title={warning} />)}
        <Checkbox checked={confirmed} disabled={!!busy} onChange={(event) => setConfirmed(event.target.checked)}>我已保存需要保留的数据，确认按以上范围恢复</Checkbox>
      </Space>}
    </Modal>
  </Space>;
}
