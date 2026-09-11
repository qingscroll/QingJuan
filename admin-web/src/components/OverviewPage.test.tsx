import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { App } from "antd";

import type { DashboardData } from "../types";
import { OverviewPage } from "./OverviewPage";

const dashboard: DashboardData = {
  meta: {
    service: "qingjuan-backend",
    appVersion: "2.0.0",
    apiVersion: "1",
    instanceId: "0123456789abcdef",
    capabilities: {},
  },
  serviceControl: {
    schemaVersion: 1,
    state: "running",
    businessApiAvailable: true,
    managementApiAvailable: true,
    generation: 1,
    startedAt: "2026-09-07T00:00:00Z",
    stoppedAt: null,
    lastActionAt: null,
    message: "后端业务服务运行中",
  },
  connectionToken: {
    configured: true,
    revealAvailable: false,
    maskedToken: "qing…juan",
    fingerprint: "abcdef12",
  },
  devices: [],
  books: [],
  tasks: [],
  sources: [],
  plugins: [],
  settings: {
    systemPrompt: "",
    autoTranslateNextChapters: 0,
    downloadConcurrency: 2,
    translationModel: {
      enabled: false,
      baseUrl: "",
      model: "",
      supportsVision: false,
      apiKeyConfigured: false,
    },
    mangaOcr: {
      enabled: false,
      baseUrl: "",
      apiKeyConfigured: false,
    },
    bika: {
      emailConfigured: false,
      passwordConfigured: false,
    },
  },
};

describe("OverviewPage", () => {
  it("opens backend upgrade from the service information shortcut", () => {
    const onNavigate = vi.fn();
    render(
      <App>
        <OverviewPage
          data={dashboard}
          bookTitles={new Map()}
          onNavigate={onNavigate}
          onControlService={vi.fn()}
        />
      </App>,
    );

    fireEvent.click(screen.getByRole("button", { name: "后端升级" }));
    expect(onNavigate).toHaveBeenCalledWith("upgrade");
  });

  it("keeps the management plane usable and starts a stopped business service", async () => {
    const onControlService = vi.fn().mockResolvedValue(undefined);
    render(
      <App>
        <OverviewPage
          data={{
            ...dashboard,
            serviceControl: {
              ...dashboard.serviceControl,
              state: "stopped",
              businessApiAvailable: false,
              stoppedAt: "2026-09-07T01:00:00Z",
              message: "后端业务服务已关闭",
            },
          }}
          bookTitles={new Map()}
          onNavigate={vi.fn()}
          onControlService={onControlService}
        />
      </App>,
    );

    expect(screen.getByText("管理通道保持在线，便于重新开启服务。", { exact: false }))
      .toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /开启服务/ }));
    await waitFor(() => expect(onControlService).toHaveBeenCalledWith("start"));
  });
});
