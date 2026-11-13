import { readApiFailure } from "./apiFailure.ts";
import type {
  AccessPolicyType,
  AppCronDraft,
  AppCronRunEntry,
  AppLaunchResponse,
  AppLogsNormalizedResponse,
  AppMutationResult,
  AppStorageMutationPayload,
  AppStorageSnapshot,
  AppWebDraft,
  AppsOverviewResponse,
} from "./types/appsCenter.ts";

export type { AccessPolicyType, AppCronDraft, AppWebDraft };

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
    scaffoldApp(payload: Record<string, unknown> = {}): Promise<AppMutationResult> {
      return request<AppMutationResult>("/api/v2/apps/scaffold", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    },
    installTemplate(id: string, locationId?: string): Promise<AppMutationResult> {
      const payload = locationId ? { locationId } : {};
      return request<AppMutationResult>(`/api/v2/apps/templates/${encodeURIComponent(id)}/install`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
    },
    getAppStorage(): Promise<{ appStorage: AppStorageSnapshot }> {
      return request<{ appStorage: AppStorageSnapshot }>("/api/v2/apps/storage");
    },
    mutateAppStorage(payload: AppStorageMutationPayload): Promise<AppMutationResult> {
      return request<AppMutationResult>("/api/v2/apps/storage", {
        method: "PUT",
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
