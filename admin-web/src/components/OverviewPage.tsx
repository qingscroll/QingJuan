import {
  ArrowRightOutlined,
  BookOutlined,
  CheckCircleOutlined,
  ClockCircleOutlined,
  CloudServerOutlined,
  LaptopOutlined,
  PlayCircleOutlined,
  PoweroffOutlined,
  ReloadOutlined,
  TranslationOutlined,
} from "@ant-design/icons";
import { Alert, App, Button, Card, Col, Popconfirm, Progress, Row, Space, Statistic, Tag, Typography } from "antd";
import { useState, type ReactNode } from "react";

import type { BackendServiceAction, DashboardData } from "../types";
import { formatDate } from "./AdminShell";
import { ConnectionTokenPanel } from "./ConnectionTokenPanel";
import { taskStatusLabel, taskStatusColor } from "./TasksPage";

type OverviewPageProps = {
  data: DashboardData;
  bookTitles: Map<string, string>;
  onNavigate: (key: "devices" | "library" | "tasks" | "diagnostics" | "upgrade" | "settings") => void;
  onControlService: (action: BackendServiceAction) => Promise<void>;
};

export function OverviewPage({ data, bookTitles, onNavigate, onControlService }: OverviewPageProps) {
  const { message } = App.useApp();
  const [serviceAction, setServiceAction] = useState<BackendServiceAction | null>(null);
  const activeTasks = data.tasks.filter((task) => ["queued", "running"].includes(task.status));
  const completedTasks = data.tasks.filter((task) => task.status === "completed").length;
  const recentTasks = [...data.tasks]
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
    .slice(0, 4);
  const serviceRunning = data.serviceControl.businessApiAvailable;

  const controlService = async (action: BackendServiceAction) => {
    setServiceAction(action);
    try {
      await onControlService(action);
    } catch (error) {
      message.error(error instanceof Error ? error.message : "服务操作失败");
    } finally {
      setServiceAction(null);
    }
  };

  return (
    <div className="page-stack">
      <Row gutter={[16, 16]} className="overview-summary-row">
        <Col flex="1 1 220px">
          <SummaryCard icon={<BookOutlined />} label="书库作品" value={data.books.length} hint="服务端已保存" />
        </Col>
        <Col flex="1 1 220px">
          <SummaryCard
            icon={<LaptopOutlined />}
            label="在线设备"
            value={data.devices.filter((device) => device.online).length}
            hint={`共 ${data.devices.length} 台已登记`}
            tone="blue"
          />
        </Col>
        <Col flex="1 1 220px">
          <SummaryCard icon={<ClockCircleOutlined />} label="进行中任务" value={activeTasks.length} hint="下载与翻译队列" tone="blue" />
        </Col>
        <Col flex="1 1 220px">
          <SummaryCard icon={<CheckCircleOutlined />} label="已完成任务" value={completedTasks} hint="当前任务历史" tone="green" />
        </Col>
        <Col flex="1 1 220px">
          <SummaryCard
            icon={<TranslationOutlined />}
            label="翻译模型"
            value={data.settings.translationModel.enabled ? "已启用" : "未启用"}
            hint={data.settings.translationModel.model || "尚未配置模型"}
            tone="amber"
          />
        </Col>
      </Row>

      <Row gutter={[16, 16]}>
        <Col xs={24} xl={16}>
          <Card
            className="panel-card"
            title="最近任务"
            extra={<Button type="link" onClick={() => onNavigate("tasks")} icon={<ArrowRightOutlined />} iconPlacement="end">查看全部</Button>}
          >
            {recentTasks.length === 0 ? (
              <div className="quiet-empty">还没有任务记录。客户端发起下载或翻译后会显示在这里。</div>
            ) : (
              <div className="recent-task-list">
                {recentTasks.map((task) => (
                  <div className="recent-task" key={task.id}>
                    <div className="recent-task-main">
                      <Space wrap>
                        <Typography.Text strong>{bookTitles.get(task.bookId) ?? "书籍已删除"}</Typography.Text>
                        <Tag color={taskStatusColor[task.status]}>{taskStatusLabel[task.status]}</Tag>
                      </Space>
                      <Typography.Text type="secondary" ellipsis>{task.message || task.error || "等待处理"}</Typography.Text>
                    </div>
                    <div className="recent-task-progress">
                      <Progress percent={Math.round(task.progress)} size="small" status={task.status === "failed" ? "exception" : undefined} />
                      <Typography.Text type="secondary">{formatDate(task.updatedAt)}</Typography.Text>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </Card>
        </Col>
        <Col xs={24} xl={8}>
          <Card className="panel-card service-card" title="服务信息">
            <div className="service-identity">
              <div className="service-icon"><CloudServerOutlined /></div>
              <div>
                <strong>qingjuan-backend</strong>
                <span>
                  版本 {data.meta.appVersion} · <Tag color={serviceRunning ? "success" : "default"}>
                    {serviceRunning ? "运行中" : "已关闭"}
                  </Tag>
                </span>
              </div>
            </div>
            <dl className="detail-list">
              <div><dt>API 版本</dt><dd>v{data.meta.apiVersion}</dd></div>
              <div><dt>实例 ID</dt><dd title={data.meta.instanceId}>{data.meta.instanceId.slice(0, 12)}</dd></div>
              <div><dt>服务代次</dt><dd>{data.serviceControl.generation}</dd></div>
              <div><dt>RapidOCR</dt><dd>{data.meta.capabilities.rapidOcr ? "可用" : "不可用"}</dd></div>
              <div><dt>浏览器回退</dt><dd>{data.meta.capabilities.browserFallback ? "可用" : "不可用"}</dd></div>
              <div><dt>下载并发</dt><dd>{data.settings.downloadConcurrency}</dd></div>
            </dl>
            {!serviceRunning && (
              <Alert
                className="service-control-alert"
                type="warning"
                showIcon
                title="业务服务已关闭"
                description="客户端业务请求和新队列任务已暂停；管理通道保持在线，便于重新开启服务。"
              />
            )}
            <Space className="service-control-actions" wrap>
              <Button
                type="primary"
                icon={<PlayCircleOutlined />}
                disabled={serviceRunning}
                loading={serviceAction === "start"}
                onClick={() => void controlService("start")}
              >
                开启服务
              </Button>
              <Popconfirm
                title="关闭后端业务服务？"
                description={activeTasks.length > 0
                  ? `当前有 ${activeTasks.length} 个任务进行中；当前任务会安全结束，后续任务将暂停。`
                  : "关闭后客户端请求会暂停，管理通道仍保持在线。"}
                okText="确认关闭"
                cancelText="取消"
                onConfirm={() => controlService("stop")}
              >
                <Button
                  danger
                  icon={<PoweroffOutlined />}
                  disabled={!serviceRunning}
                  loading={serviceAction === "stop"}
                >
                  关闭服务
                </Button>
              </Popconfirm>
              <Popconfirm
                title="重启后端业务服务？"
                description="客户端请求会短暂暂停，管理页面无需重新登录。"
                okText="确认重启"
                cancelText="取消"
                onConfirm={() => controlService("restart")}
              >
                <Button
                  icon={<ReloadOutlined />}
                  loading={serviceAction === "restart"}
                >
                  重启服务
                </Button>
              </Popconfirm>
            </Space>
            <ConnectionTokenPanel status={data.connectionToken} />
            <Space className="service-actions" wrap>
              <Button onClick={() => onNavigate("devices")}>管理设备</Button>
              <Button onClick={() => onNavigate("library")}>管理书库</Button>
              <Button onClick={() => onNavigate("diagnostics")}>系统诊断</Button>
              <Button onClick={() => onNavigate("upgrade")}>后端升级</Button>
              <Button onClick={() => onNavigate("settings")}>模型设置</Button>
            </Space>
          </Card>
        </Col>
      </Row>
    </div>
  );
}

function SummaryCard({
  icon,
  label,
  value,
  hint,
  tone = "clay",
}: {
  icon: ReactNode;
  label: string;
  value: string | number;
  hint: string;
  tone?: "clay" | "blue" | "green" | "amber";
}) {
  return (
    <Card className={`summary-card tone-${tone}`} variant="borderless">
      <div className="summary-icon">{icon}</div>
      <Statistic title={label} value={value} />
      <Typography.Text type="secondary" ellipsis>{hint}</Typography.Text>
    </Card>
  );
}
