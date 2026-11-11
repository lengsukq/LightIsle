import { readApiFailure } from "./apiFailure.ts";

export const DEFAULT_MCP_COMMAND =
  "/Applications/LightIsle.app/Contents/Resources/core/lightisled";

export const DEFAULT_MCP_PROMPT = `请帮我将当前 Mac 上的「LightIsle（轻屿）全功能管理与控制 MCP Server」安装并注册到你的 MCP 配置文件中：
- MCP 服务名称：lightisle
- 传输方式：stdio
- 可执行命令：${DEFAULT_MCP_COMMAND}
- 命令参数：["mcp", "--data-dir", "~/Library/Application Support/LightIsle"]
配置完成后，请先读取 lightisle://specs/mcp-security 资源，并调用 lightisle_get_health、lightisle_get_system 与 lightisle_list_roots 验证连接（所有操作均记入 SQLite 审计，文件删除仅移入回收站，禁止格式化磁盘与注销存储根）。`;

export type AccessPolicyType = "admin_only" | "selected_members" | "all_members";

export type AppWebDraft = {
  enabled: boolean;
  mode: "static" | "on-demand" | "persistent";
  idleTimeoutSeconds: number;
  autoRestart: boolean;
};

export type AppCronDraft = {
  enabled: boolean;
  cron: string;
  timezone: string;
  events: string[];
  channels: string[];
};

export function normalizeAccessPolicy(policy?: string): AccessPolicyType {
  if (policy === "selected_members" || policy === "allowlist") {
    return "selected_members";
  }
  if (policy === "all_members" || policy === "authenticated") {
    return "all_members";
  }
  return "admin_only";
}

export function hasWebModule(app: unknown): boolean {
  if (!app || typeof app !== "object") return false;
  const candidate = app as { web?: { mode?: string } | null; mode?: string };
  if (candidate.web && typeof candidate.web === "object") {
    return candidate.web.mode !== "none";
  }
  return Boolean(candidate.mode && candidate.mode !== "none");
}

export function hasCronModule(app: unknown): boolean {
  if (!app || typeof app !== "object") return false;
  const candidate = app as {
    cron?: {
      hasCron?: boolean;
      entry?: unknown;
      cron?: unknown;
      schedule?: { cron?: unknown } | null;
    } | null;
  };
  if (!candidate.cron || typeof candidate.cron !== "object") return false;
  const c = candidate.cron;
  if (typeof c.hasCron === "boolean") {
    return c.hasCron;
  }
  return Boolean(c.entry || c.cron || (c.schedule && c.schedule.cron));
}

export function buildAccessPutPayload(
  app: { revision?: string } | null | undefined,
  policy: string,
  allowedUserIDs: number[],
): Record<string, unknown> {
  const normalized = normalizeAccessPolicy(policy);
  return {
    ...(app?.revision ? { revision: app.revision } : {}),
    access: {
      policy: normalized,
      allowedUserIDs:
        normalized === "selected_members" && Array.isArray(allowedUserIDs)
          ? [...allowedUserIDs]
          : [],
    },
  };
}

export function buildConfigPutPayload(
  app: { revision?: string; web?: unknown; mode?: string; cron?: unknown } | null | undefined,
  webDraft?: AppWebDraft,
  cronDraft?: AppCronDraft,
): Record<string, unknown> {
  const payload: Record<string, unknown> = {};
  if (app?.revision) {
    payload.revision = app.revision;
  }
  if (hasWebModule(app) && webDraft) {
    payload.web = {
      enabled: Boolean(webDraft.enabled),
      mode: webDraft.mode || "on-demand",
      idleTimeoutSeconds: Math.max(60, Number(webDraft.idleTimeoutSeconds) || 900),
      autoRestart: Boolean(webDraft.autoRestart),
    };
  }
  if (hasCronModule(app) && cronDraft) {
    payload.cron = {
      enabled: Boolean(cronDraft.enabled),
      cron: String(cronDraft.cron || "*/15 * * * *").trim(),
      timezone: String(cronDraft.timezone || "Asia/Shanghai").trim() || "Asia/Shanghai",
      events: Array.isArray(cronDraft.events) ? [...cronDraft.events] : ["failure", "timeout"],
      channels: Array.isArray(cronDraft.channels) ? [...cronDraft.channels] : [],
    };
  }
  return payload;
}

export function normalizeLogsResponse(res: unknown): {
  webOutput: string;
  cronRuns: Array<Record<string, any>>;
} {
  const obj = res && typeof res === "object" ? (res as Record<string, unknown>) : {};
  const webOutput =
    typeof obj.webOutput === "string"
      ? obj.webOutput
      : typeof obj.logs === "string"
        ? obj.logs
        : "";
  const cronRuns = Array.isArray(obj.cronRuns)
    ? (obj.cronRuns as Array<Record<string, any>>)
    : Array.isArray(obj.runs)
      ? (obj.runs as Array<Record<string, any>>)
      : [];
  return { webOutput, cronRuns };
}

export function getAppDataBackupUrl(id: string): string {
  return `/api/v2/apps/${encodeURIComponent(id)}/data-backup`;
}

export function createAppsCenterClient(fetchImpl: typeof fetch = globalThis.fetch) {
  async function request(url: string, options: RequestInit = {}): Promise<any> {
    const headers: Record<string, string> = {
      "X-LightIsle-Request": "1",
      ...((options.headers as Record<string, string> | undefined) || {}),
    };
    const response = await fetchImpl(url, {
      credentials: "same-origin",
      cache: "no-store",
      ...options,
      headers,
    });
    if (!response.ok) {
      throw await readApiFailure(response);
    }
    return response.json();
  }

  return {
    request,
    fetchApps(refresh = false): Promise<any> {
      return request(
        refresh ? "/api/v2/apps/refresh" : "/api/v2/apps",
        refresh ? { method: "POST" } : {},
      );
    },
    setMcpEnabled(enabled: boolean): Promise<any> {
      return request("/api/v2/apps/mcp", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ enabled: Boolean(enabled) }),
      });
    },
    setMcpConfig(options: { mcpEnabled?: boolean; mcpLanEnabled?: boolean } = {}): Promise<any> {
      const payload: Record<string, unknown> = {};
      if (typeof options.mcpEnabled === "boolean") {
        payload.mcpEnabled = options.mcpEnabled;
      }
      if (typeof options.mcpLanEnabled === "boolean") {
        payload.mcpLanEnabled = options.mcpLanEnabled;
      }
      return request("/api/v2/apps/mcp", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    },
    rotateMcpToken(): Promise<any> {
      return request("/api/v2/apps/mcp/token/rotate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}),
      });
    },
    debugMcp(
      payload: {
        method?: string;
        tool?: string;
        uri?: string;
        args?: unknown;
        rawRpc?: string;
      } = {},
    ): Promise<any> {
      return request("/api/v2/apps/mcp/debug", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    },
    fetchMcpLogs(): Promise<{ logs: Array<Record<string, any>> }> {
      return request("/api/v2/apps/mcp/logs");
    },
    clearMcpLogs(): Promise<any> {
      return request("/api/v2/apps/mcp/logs", {
        method: "DELETE",
      });
    },
    probeApp(
      id: string,
      payload: { method?: string; path?: string; body?: string; role?: string } = {},
    ): Promise<any> {
      return request(`/api/v2/apps/${encodeURIComponent(id)}/probe`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    },
    scaffoldApp(payload: Record<string, unknown> = {}): Promise<any> {
      return request("/api/v2/apps/scaffold", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    },
    launchApp(id: string): Promise<any> {
      return request(`/api/v2/apps/${encodeURIComponent(id)}/launch`, {
        method: "POST",
      });
    },
    runAction(
      id: string,
      action: "start" | "stop" | "restart" | "run_cron",
    ): Promise<any> {
      return request(`/api/v2/apps/${encodeURIComponent(id)}/action`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action }),
      });
    },
    saveAccess(
      app: { id: string; revision?: string },
      policy: string,
      allowedUserIDs: number[],
    ): Promise<any> {
      return request(`/api/v2/apps/${encodeURIComponent(app.id)}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(buildAccessPutPayload(app, policy, allowedUserIDs)),
      });
    },
    saveConfig(
      app: { id: string; revision?: string; web?: unknown; mode?: string; cron?: unknown },
      webDraft: AppWebDraft,
      cronDraft: AppCronDraft,
    ): Promise<any> {
      return request(`/api/v2/apps/${encodeURIComponent(app.id)}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(buildConfigPutPayload(app, webDraft, cronDraft)),
      });
    },
    async fetchLogs(id: string): Promise<{ webOutput: string; cronRuns: Array<Record<string, any>> }> {
      const res = await request(`/api/v2/apps/${encodeURIComponent(id)}/logs`);
      return normalizeLogsResponse(res);
    },
    deleteApp(id: string): Promise<any> {
      return request(`/api/v2/apps/${encodeURIComponent(id)}`, {
        method: "DELETE",
      });
    },
    restoreAppData(id: string, archiveBody: BodyInit): Promise<any> {
      return request(`/api/v2/apps/${encodeURIComponent(id)}/data-restore`, {
        method: "POST",
        headers: { "Content-Type": "application/gzip" },
        body: archiveBody,
      });
    },
  };
}
