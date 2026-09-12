import { useEffect, useRef, useState } from "react";
import { Alert, Button, Descriptions, Modal, Space, Typography } from "antd";
import * as api from "../api";
import type { SitePlugin } from "../types";
import type { PluginMaintenanceReport } from "../plugin_maintenance_types";
import { formatDate } from "../format";

export function PluginMaintenance({ plugin, onChanged }: {
  plugin: SitePlugin; onChanged?: () => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  const [report, setReport] = useState<PluginMaintenanceReport | null>(null);
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const locked = useRef(false);
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => { alive.current = false; };
  }, []);

  const check = async () => {
    if (locked.current) return;
    locked.current = true;
    setOpen(true); setBusy(true); setReport(null); setError(""); setSuccess(""); setConfirm(false);
    try {
      const result = await api.checkPluginMaintenance(plugin.id);
      if (alive.current) setReport(result);
    } catch (failure) {
      if (alive.current) setError(failure instanceof Error ? failure.message : "插件自检失败");
    } finally {
      locked.current = false;
      if (alive.current) setBusy(false);
    }
  };
  const rollback = async () => {
    if (locked.current || !confirm || !report?.rollbackAvailable || !report.rollbackVersion) return;
    locked.current = true; setBusy(true); setError("");
    try {
      const result = await api.rollbackSitePlugin(plugin.id, report.version, report.sha256);
      if (!alive.current) return;
      setSuccess(`已回退到 ${result.version}`);
      try { await onChanged?.(); }
      catch { if (alive.current) setError("回退已完成，但插件列表刷新失败，请重新加载列表"); }
    } catch (failure) {
      if (alive.current) setError(failure instanceof Error ? failure.message : "回退请求失败，请重新自检确认当前版本");
    } finally {
      locked.current = false;
      if (alive.current) { setBusy(false); setConfirm(false); setReport(null); }
    }
  };
  return <>
    <Button size="small" aria-label={`自检${plugin.name}`} onClick={() => void check()}>自检与回退</Button>
    <Modal open={open} title={`${plugin.name}维护`} closable={!busy}
      mask={{ closable: !busy }} keyboard={!busy}
      onCancel={() => { if (!locked.current) setOpen(false); }}
      footer={<Space wrap>
        <Button disabled={busy} onClick={() => setOpen(false)}>关闭</Button>
        <Button loading={busy && !confirm} disabled={busy} onClick={() => void check()}>重新自检</Button>
        {report?.rollbackAvailable && <Button danger loading={busy && confirm} disabled={busy || report.activeCalls > 0}
          onClick={() => confirm ? void rollback() : setConfirm(true)}>
          {confirm ? "确认回退插件" : "回退上一版本"}
        </Button>}
      </Space>}>
      <Space orientation="vertical" size={12} style={{ width: "100%" }}>
        {error && <Alert type="error" showIcon title={error} />}
        {success && <Alert type="success" showIcon title={success} />}
        {busy && !report && <Typography.Text>正在检查安装记录…</Typography.Text>}
        {report && <>
          <Descriptions size="small" column={1} items={[
            { key: "version", label: "当前版本", children: report.version },
            { key: "protocol", label: "插件协议", children: `${report.apiVersion}（后端支持 ${report.supportedApiVersion}）` },
            { key: "python", label: "运行环境", children: `Python ${report.pythonVersion}` },
            { key: "previous", label: "可回退版本", children: report.rollbackVersion ?? "暂无已保存的上一版本" },
            { key: "time", label: "检查时间", children: formatDate(report.checkedAt) },
          ]} />
          {report.checks.map((item) => <Alert key={item.code} showIcon title={item.label}
            type={item.status === "passed" ? "success" : item.status === "failed" ? "error" : "warning"}
            description={item.message} />)}
          {report.activeCalls > 0 && <Alert type="info" title="插件仍在处理请求，请等待完成后重新自检" />}
          {confirm && <Alert type="warning" showIcon title={`确认从 ${report.version} 回退到 ${report.rollbackVersion}？`}
            description="回退会切换当前服务使用的插件版本，并保留本次版本供再次切换。已导入书籍和已下载章节会保留。" />}
        </>}
      </Space>
    </Modal>
  </>;
}
