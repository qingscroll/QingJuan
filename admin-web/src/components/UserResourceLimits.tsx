import { useEffect, useRef, useState } from "react";
import { Alert, Button, Form, InputNumber, Modal, Space, Spin, Typography } from "antd";
import * as api from "../api";
import type { ResourceUsage } from "../resource_types";

interface Props {
  userId: string;
  displayName: string;
  onClose: () => void;
}

export function UserResourceLimits({ userId, displayName, onClose }: Props) {
  const [usage, setUsage] = useState<ResourceUsage | null>(null);
  const [storage, setStorage] = useState<number | null>(null);
  const [requests, setRequests] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const generation = useRef(0);

  const fill = (value: ResourceUsage) => {
    setUsage(value);
    setStorage(value.limits.storageBytes);
    setRequests(value.limits.dailyModelRequests);
  };
  const load = async () => {
    const current = ++generation.current;
    setBusy(true);
    setError("");
    setSaved(false);
    setUsage(null);
    try {
      const value = await api.getUserResourceUsage(userId);
      if (current === generation.current) fill(value);
    } catch (cause) {
      if (current === generation.current) setError(cause instanceof Error ? cause.message : "资源用量加载失败");
    } finally {
      if (current === generation.current) setBusy(false);
    }
  };
  useEffect(() => {
    void load();
    return () => { generation.current++; };
  }, [userId]);

  const save = async () => {
    if (!usage || busy) return;
    const current = generation.current;
    setBusy(true);
    setError("");
    setSaved(false);
    try {
      const value = await api.updateUserResourceLimits(userId, {
        expectedRevision: usage.limits.revision, storageBytes: storage, dailyModelRequests: requests,
      });
      if (current === generation.current) { fill(value); setSaved(true); }
    } catch (cause) {
      if (current === generation.current) setError(cause instanceof Error ? cause.message : "资源限制保存失败");
    } finally {
      if (current === generation.current) setBusy(false);
    }
  };

  return <Modal open title={`${displayName} 的资源限制`} onCancel={() => { if (!busy) onClose(); }} mask={{ closable: !busy }}
    closable={!busy} keyboard={!busy} footer={<Space>
      <Button onClick={() => void load()} disabled={busy}>重新加载</Button>
      <Button onClick={onClose} disabled={busy}>关闭</Button>
      <Button type="primary" aria-label="保存限制" onClick={() => void save()} loading={busy} disabled={!usage || busy}>保存限制</Button>
    </Space>}>
    {error && <Alert type="error" title={error} showIcon />}
    {saved && <Alert type="success" title="资源限制已保存" showIcon />}
    {busy && !usage ? <Spin /> : usage && <>
      <Typography.Paragraph>今日模型请求：{usage.modelRequests} 次。下次重置：{new Date(usage.resetsAt).toLocaleString()}。</Typography.Paragraph>
      <Typography.Paragraph>已用存储：{usage.storageUsedBytes.toLocaleString()} 字节（含书籍文件及导出产物）。</Typography.Paragraph>
      <Form layout="vertical" disabled={busy}>
        <Form.Item label="存储上限（字节）" extra="留空表示不限；0 禁止新增内容。降低上限会阻止继续增长，已有内容会保留。">
          <InputNumber aria-label="存储上限（字节）" value={storage} onChange={setStorage}
            min={0} max={1_000_000_000_000_000} precision={0} style={{ width: "100%" }} />
        </Form.Item>
        <Form.Item label="每日模型请求上限" extra="留空表示不限；0 禁止模型请求。文字翻译、视觉识别、译图及重试均按实际请求计数。">
          <InputNumber aria-label="每日模型请求上限" value={requests} onChange={setRequests}
            min={0} max={10_000_000} precision={0} style={{ width: "100%" }} />
        </Form.Item>
      </Form>
      <Typography.Paragraph type="secondary">待执行任务按账号轮流分配；同一账号内部保持排队顺序。</Typography.Paragraph>
    </>}
  </Modal>;
}
