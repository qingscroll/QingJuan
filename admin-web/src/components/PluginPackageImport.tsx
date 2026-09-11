import { useRef, useState } from "react";
import { UploadOutlined } from "@ant-design/icons";
import { Alert, App, Button, Checkbox, Descriptions, Modal, Space, Typography } from "antd";

import * as api from "../api";
import type { SitePluginPackageInspection } from "../types";

export function PluginPackageImport({ onChanged }: { onChanged?: () => Promise<void> }) {
  const { message } = App.useApp();
  const [open, setOpen] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [inspection, setInspection] = useState<SitePluginPackageInspection | null>(null);
  const [busy, setBusy] = useState(false);
  const [trusted, setTrusted] = useState(false);
  const [error, setError] = useState("");
  const generation = useRef(0);

  const close = () => {
    if (busy) return;
    generation.current += 1;
    setOpen(false);
    setFile(null);
    setInspection(null);
    setTrusted(false);
    setError("");
  };

  const inspect = async (selected: File | null) => {
    const current = ++generation.current;
    setFile(selected);
    setInspection(null);
    setTrusted(false);
    setError("");
    if (!selected) return;
    if (!selected.size || selected.size > 2 * 1024 * 1024) {
      setError("请选择不超过 2 MiB 的 ZIP 或 .qjplugin 插件包");
      return;
    }
    setBusy(true);
    try {
      const result = await api.inspectSitePluginPackage(selected);
      if (current === generation.current) setInspection(result);
    } catch (cause) {
      if (current === generation.current) setError(cause instanceof Error ? cause.message : "插件包校验失败");
    } finally {
      if (current === generation.current) setBusy(false);
    }
  };

  const install = async () => {
    if (!file || !inspection || !trusted || busy) return;
    setBusy(true);
    setError("");
    try {
      await api.importSitePluginPackage(file, Boolean(inspection.installedVersion));
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "插件导入失败");
      setBusy(false);
      return;
    }
    setBusy(false);
    setOpen(false);
    setFile(null);
    setInspection(null);
    setTrusted(false);
    message.success("插件已安装并生效");
    try {
      await onChanged?.();
    } catch {
      message.warning("插件已安装，列表刷新失败，请刷新页面");
    }
  };

  return (
    <>
      <Button type="primary" aria-label="导入插件" icon={<UploadOutlined />} onClick={() => setOpen(true)}>导入插件</Button>
      <Modal
        title="导入站点插件" open={open} destroyOnHidden onCancel={close}
        confirmLoading={busy} okText={inspection?.installedVersion ? "确认更新" : "安装插件"}
        cancelText="取消" onOk={() => void install()}
        okButtonProps={{ disabled: !inspection || !trusted || busy }}
        cancelButtonProps={{ disabled: busy }} closable={!busy} mask={{ closable: !busy }}
      >
        <Space orientation="vertical" size={16} style={{ width: "100%" }}>
          <Typography.Paragraph>
            选择 ZIP 或 .qjplugin 文件，根目录包含 manifest.json 和 plugin.py，大小不超过 2 MiB。
          </Typography.Paragraph>
          <input
            type="file" aria-label="选择插件包" accept=".zip,.qjplugin" disabled={busy}
            onChange={(event) => void inspect(event.target.files?.[0] ?? null)}
          />
          {error && <Alert type="error" showIcon title={error} />}
          {inspection && <Descriptions column={1} size="small" items={[
            { key: "name", label: "插件", children: `${inspection.plugin.name} (${inspection.plugin.id})` },
            { key: "version", label: "版本", children: inspection.installedVersion
              ? `${inspection.installedVersion} → ${inspection.plugin.version}` : inspection.plugin.version },
            { key: "author", label: "作者声明", children: inspection.plugin.author },
            { key: "domains", label: "站点", children: inspection.plugin.domains.join("、") },
            { key: "description", label: "说明", children: inspection.plugin.description },
          ]} />}
          <Alert type="warning" showIcon title="仅安装你信任的插件"
            description="插件会以青卷后端权限运行 Python 代码，可访问服务器数据和网络。作者信息由插件声明，未经认证。更新会保留启停状态。" />
          <Checkbox checked={trusted} disabled={!inspection || busy} onChange={(event) => setTrusted(event.target.checked)}>
            我信任此插件来源并同意运行其代码
          </Checkbox>
        </Space>
      </Modal>
    </>
  );
}
