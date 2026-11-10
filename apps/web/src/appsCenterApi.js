import { readApiFailure } from "./apiFailure.js";

export const DEFAULT_MCP_COMMAND =
  "/Applications/LightIsle.app/Contents/Resources/core/lightisled";

export const DEFAULT_MCP_PROMPT = `请帮我将当前 Mac 上的「LightIsle（轻屿）开发者 MCP Server」安装并注册到你的 MCP 配置文件中：
- MCP 服务名称：lightisle-dev
- 传输方式：stdio
- 可执行命令：${DEFAULT_MCP_COMMAND}
- 命令参数：["mcp", "--data-dir", "~/Library/Application Support/LightIsle"]
配置完成后，请立即调用 lightisle_get_environment 工具和读取 lightisle://specs/plugin-v2 资源，验证连接是否成功。`;

export function normalizeAccessPolicy(policy) {
  if (policy === "selected_members" || policy === "allowlist") {
    return "selected_members";
  }
  if (policy === "all_members" || policy === "authenticated") {
    return "all_members";
  }
  return "admin_only";
}

export function hasWebModule(app) {
  if (!app) return false;
  if (app.web && typeof app.web === "object") {
    return app.web.mode !== "none";
  }
  return Boolean(app.mode && app.mode !== "none");
}

export function hasCronModule(app) {
  if (!app || !app.cron) return false;
  const c = app.cron;
  if (typeof c.hasCron === "boolean") {
    return c.hasCron;
  }
  return Boolean(c.entry || c.cron || (c.schedule && c.schedule.cron));
}

export function buildAccessPutPayload(app, policy, allowedUserIDs) {
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

export function buildConfigPutPayload(app, webDraft, cronDraft) {
  const payload = {};
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

export function normalizeLogsResponse(res) {
  const webOutput =
    typeof res?.webOutput === "string"
      ? res.webOutput
      : typeof res?.logs === "string"
        ? res.logs
        : "";
  const cronRuns = Array.isArray(res?.cronRuns)
    ? res.cronRuns
    : Array.isArray(res?.runs)
      ? res.runs
      : [];
  return { webOutput, cronRuns };
}

export function getAppDataBackupUrl(id) {
  return `/api/v2/apps/${encodeURIComponent(id)}/data-backup`;
}

export function createAppsCenterClient(fetchImpl = globalThis.fetch) {
  async function request(url, options = {}) {
    const headers = {
      "X-LightIsle-Request": "1",
      ...(options.headers || {}),
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
    fetchApps(refresh = false) {
      return request(
        refresh ? "/api/v2/apps/refresh" : "/api/v2/apps",
        refresh ? { method: "POST" } : {}
      );
    },
    setMcpEnabled(enabled) {
      return request("/api/v2/apps/mcp", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ enabled: Boolean(enabled) }),
      });
    },
    launchApp(id) {
      return request(`/api/v2/apps/${encodeURIComponent(id)}/launch`, {
        method: "POST",
      });
    },
    runAction(id, action) {
      return request(`/api/v2/apps/${encodeURIComponent(id)}/action`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action }),
      });
    },
    saveAccess(app, policy, allowedUserIDs) {
      return request(`/api/v2/apps/${encodeURIComponent(app.id)}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(buildAccessPutPayload(app, policy, allowedUserIDs)),
      });
    },
    saveConfig(app, webDraft, cronDraft) {
      return request(`/api/v2/apps/${encodeURIComponent(app.id)}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(buildConfigPutPayload(app, webDraft, cronDraft)),
      });
    },
    async fetchLogs(id) {
      const res = await request(`/api/v2/apps/${encodeURIComponent(id)}/logs`);
      return normalizeLogsResponse(res);
    },
    deleteApp(id) {
      return request(`/api/v2/apps/${encodeURIComponent(id)}`, {
        method: "DELETE",
      });
    },
    restoreAppData(id, archiveBody) {
      return request(`/api/v2/apps/${encodeURIComponent(id)}/data-restore`, {
        method: "POST",
        headers: { "Content-Type": "application/gzip" },
        body: archiveBody,
      });
    },
  };
}
