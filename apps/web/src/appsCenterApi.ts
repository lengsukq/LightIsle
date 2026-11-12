import { readApiFailure } from "./apiFailure.ts";
import type {
  AccessPolicyType,
  AppCronDraft,
  AppCronRunEntry,
  AppLaunchResponse,
  AppLogsNormalizedResponse,
  AppMutationResult,
  AppProbePayload,
  AppProbeResponse,
  AppWebDraft,
  AppsOverviewResponse,
  McpCallLogEntry,
  McpConfigResponse,
  McpDebugExecPayload,
  McpDebugExecResponse,
  McpTokenRotateResponse,
} from "./types/appsCenter.ts";

export type { AccessPolicyType, AppCronDraft, AppWebDraft };

export const DEFAULT_MCP_COMMAND =
  "/Applications/LightIsle.app/Contents/Resources/core/lightisled";

export const DEFAULT_MCP_PROMPT = `请帮我将当前 Mac 上的「LightIsle（轻屿）全功能管理与控制 MCP Server」安装并注册到你的 MCP 配置文件中：
- MCP 服务名称：lightisle
- 传输方式：stdio
- 可执行命令：${DEFAULT_MCP_COMMAND}
- 命令参数：["mcp", "--data-dir", "~/Library/Application Support/LightIsle"]
配置完成后，请先读取 lightisle://specs/mcp-security 资源，并调用 lightisle_get_health、lightisle_get_system 与 lightisle_list_roots 验证连接（所有操作均记入 SQLite 审计，文件删除仅移入回收站，禁止格式化磁盘与注销存储根）。`;

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

export function normalizeLogsResponse(res: unknown): AppLogsNormalizedResponse {
  const obj = res && typeof stalenessGuard(res) === "object" ? (res as Record<string, unknown>) : {};
  const webOutput =
    typeof obj.webOutput === "string"
      ? obj.webOutput
      : typeof obj.logs === "string"
        ? obj.logs
        : "";
  const cronRuns = Array.isArray(obj.cronRuns)
    ? (obj.cronRuns as AppCronRunEntry[])
    : Array.isArray(obj.runs)
      ? (obj.runs as AppCronRunEntry[])
      : [];
  return { webOutput, cronRuns };
}

function stalenessGuard(value: unknown): unknown {
  return value;
}

export function getAppDataBackupUrl(id: string): string {
  return `/api/v2/apps/${encodeURIComponent(id)}/data-backup`;
}

export function createAppsCenterClient(fetchImpl: typeof fetch = globalThis.fetch) {
  async function request<T = Record<string, unknown>>(
    url: string,
    options: RequestInit = {},
  ): Promise<T> {
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
    return (await response.json()) as T;
  }

  return {
    request,
    fetchApps(refresh = false): Promise<AppsOverviewResponse> {
      return request<AppsOverviewResponse>(
        refresh ? "/api/v2/apps/refresh" : "/api/v2/apps",
        refresh ? { method: "POST" } : {},
      );
    },
    setMcpEnabled(enabled: boolean): Promise<McpConfigResponse> {
      return request<McpConfigResponse>("/api/v2/apps/mcp", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ enabled: Boolean(enabled) }),
      });
    },
    setMcpConfig(
      options: { mcpEnabled?: boolean; mcpLanEnabled?: boolean } = {},
    ): Promise<McpConfigResponse> {
      const payload: Record<string, unknown> = {};
      if (typeof options.mcpEnabled === "boolean") {
        payload.mcpEnabled = options.mcpEnabled;
      }
      if (typeof options.mcpLanEnabled === "boolean") {
        payload.mcpLanEnabled = options.mcpLanEnabled;
      }
      return request<McpConfigResponse>("/api/v2/apps/mcp", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    },
    rotateMcpToken(): Promise<McpTokenRotateResponse> {
      return request<McpTokenRotateResponse>("/api/v2/apps/mcp/token/rotate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}),
      });
    },
    debugMcp(payload: McpDebugExecPayload = {}): Promise<McpDebugExecResponse> {
      return request<McpDebugExecResponse>("/api/v2/apps/mcp/debug", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    },
    fetchMcpLogs(): Promise<{ logs: McpCallLogEntry[] }> {
      return request<{ logs: McpCallLogEntry[] }>("/api/v2/apps/mcp/logs");
    },
    clearMcpLogs(): Promise<{ ok?: boolean }> {
      return request<{ ok?: boolean }>("/api/v2/apps/mcp/logs", {
        method: "DELETE",
      });
    },
    probeApp(id: string, payload: AppProbePayload = {}): Promise<AppProbeResponse> {
      return request<AppProbeResponse>(`/api/v2/apps/${encodeURIComponent(id)}/probe`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    },
    scaffoldApp(payload: Record<string, unknown> = {}): Promise<AppMutationResult> {
      return request<AppMutationResult>("/api/v2/apps/scaffold", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    },
    launchApp(id: string): Promise<AppLaunchResponse> {
      return request<AppLaunchResponse>(`/api/v2/apps/${encodeURIComponent(id)}/launch`, {
        method: "POST",
      });
    },
    runAction(
      id: string,
      action: "start" | "stop" | "restart" | "run_cron",
    ): Promise<AppMutationResult> {
      return request<AppMutationResult>(`/api/v2/apps/${encodeURIComponent(id)}/action`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action }),
      });
    },
    saveAccess(
      app: { id: string; revision?: string },
      policy: string,
      allowedUserIDs: number[],
    ): Promise<AppMutationResult> {
      return request<AppMutationResult>(`/api/v2/apps/${encodeURIComponent(app.id)}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(buildAccessPutPayload(app, policy, allowedUserIDs)),
      });
    },
    saveConfig(
      app: { id: string; revision?: string; web?: unknown; mode?: string; cron?: unknown },
      webDraft: AppWebDraft,
      cronDraft: AppCronDraft,
    ): Promise<AppMutationResult> {
      return request<AppMutationResult>(`/api/v2/apps/${encodeURIComponent(app.id)}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(buildConfigPutPayload(app, webDraft, cronDraft)),
      });
    },
    async fetchLogs(id: string): Promise<AppLogsNormalizedResponse> {
      const res = await request<unknown>(`/api/v2/apps/${encodeURIComponent(id)}/logs`);
      return normalizeLogsResponse(res);
    },
    deleteApp(id: string): Promise<AppMutationResult> {
      return request<AppMutationResult>(`/api/v2/apps/${encodeURIComponent(id)}`, {
        method: "DELETE",
      });
    },
    restoreAppData(id: string, archiveBody: BodyInit): Promise<AppMutationResult> {
      return request<AppMutationResult>(`/api/v2/apps/${encodeURIComponent(id)}/data-restore`, {
        method: "POST",
        headers: { "Content-Type": "application/gzip" },
        body: archiveBody,
      });
    },
  };
}
