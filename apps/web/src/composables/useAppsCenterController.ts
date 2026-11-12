import { computed, ref, watch } from "vue";
import { describeUserFacingError } from "../userFacingError.ts";
import { requestConfirm } from "../useConfirmDialog.ts";
import {
  DEFAULT_MCP_PROMPT,
  createAppsCenterClient,
  getAppDataBackupUrl,
  hasCronModule,
  hasWebModule,
  normalizeAccessPolicy,
} from "../appsCenterApi.ts";
import type {
  AppCronRunEntry,
  AppMemberSummary,
  McpCallLogEntry,
  PublicAppItem,
} from "../types/appsCenter.ts";

export const AVAILABLE_CHANNELS = [
  { id: "bark", label: "Bark" },
  { id: "webhook", label: "Webhook" },
  { id: "email", label: "邮件" },
  { id: "wecom", label: "企业微信" },
  { id: "dingtalk", label: "钉钉" },
] as const;

export const WEB_MODE_OPTIONS = [
  { value: "static" as const, label: "纯静态 (Static · 0 MB)" },
  { value: "on-demand" as const, label: "按需唤醒 (On-Demand · 闲置自动休眠)" },
  { value: "persistent" as const, label: "常驻守护 (Persistent · 24/7 运行)" },
];

export const STATE_LABELS: Record<string, string> = {
  running: "运行中",
  success: "成功",
  failure: "失败",
  timeout: "超时",
  interrupted: "中断",
  skipped: "已跳过",
};

export const DELIVERY_LABELS: Record<string, string> = {
  queued: "等待发送",
  sent: "已发送",
  not_configured: "渠道未配置",
  backoff: "渠道退避中",
  queue_full: "发送队列已满",
  interrupted: "发送结果未确认",
  authentication_failed: "认证失败",
  tls_failed: "加密连接失败",
  connection_failed: "连接失败",
  delivery_failed: "发送失败",
};

const CATEGORY_LABELS: Record<string, string> = {
  network: "网络与通信",
  media: "影音工具",
  finance: "家庭账本",
  utility: "实用工具",
  system: "系统监控",
  automation: "数据看板",
};

export function appMode(app: PublicAppItem): "static" | "on-demand" | "persistent" {
  const raw = app.web?.mode || app.mode || "on-demand";
  if (raw === "static") return "static";
  if (raw === "persistent" || raw === "daemon") return "persistent";
  return "on-demand";
}

export function appStatus(app: PublicAppItem): string {
  return app.status || app.web?.status || (appMode(app) === "static" ? "static" : "sleeping");
}

export function appMemoryMB(app: PublicAppItem): number {
  if (typeof app.memoryMB === "number" && app.memoryMB > 0) return Math.round(app.memoryMB);
  if (typeof app.web?.memoryMB === "number" && app.web.memoryMB > 0) return Math.round(app.web.memoryMB);
  const rss = app.rssBytes ?? app.web?.rssBytes ?? 0;
  return rss > 0 ? Math.max(1, Math.round(rss / (1024 * 1024))) : 0;
}

export function runtimeBadge(app: PublicAppItem): string {
  const mode = appMode(app);
  const status = appStatus(app);
  const mb = appMemoryMB(app);
  if (mode === "static") return "纯静态 · 0 MB";
  if (mode === "persistent") return status === "running" ? `常驻守护 · ${mb} MB` : "常驻守护 · 已停止 0 MB";
  if (status === "running") return `按需唤醒 · 运行中 ${mb} MB`;
  if (status === "starting") return "按需唤醒 · 唤醒中…";
  return "按需唤醒 · 休眠 0 MB";
}

export function workbenchBadge(app: PublicAppItem): string {
  const mode = appMode(app);
  const status = appStatus(app);
  const mb = appMemoryMB(app);
  if (mode === "static") return "静态 0 MB";
  return status === "running" ? `运行中 · ${mb} MB` : `就绪 · ${mb} MB`;
}

export function accessBadge(app: PublicAppItem): string {
  const policy = app.access?.policy || "admin_only";
  if (policy === "all_members") return "🌐 全员可用";
  if (policy === "selected_members") return `👥 已授权 ${(app.access?.allowedUserIDs || []).length} 人`;
  return "🔒 仅管理员";
}

export function cronSummary(app: PublicAppItem): string {
  const c = app.cron;
  if (!hasCronModule(app) || !c) return "无定时任务";
  const expr = c.cron || c.schedule?.cron || "未设 Cron";
  const tz = c.timezone || c.schedule?.timezone || "Asia/Shanghai";
  return `${c.enabled ? "⏰ 定时开启" : "⏸ 定时暂停"} · ${expr} (${tz})`;
}

export function categoryLabel(category?: string): string {
  return category ? (CATEGORY_LABELS[category] || category) : "轻应用";
}

export function localTime(seconds?: number): string {
  return seconds ? new Date(seconds * 1000).toLocaleString() : "";
}

export function flipItem<T>(list: T[], value: T): T[] {
  return list.includes(value) ? list.filter((v) => v !== value) : [...list, value];
}

export async function writeAppsClipboard(text: string): Promise<void> {
  if (navigator.clipboard && window.isSecureContext) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const editor = document.createElement("textarea");
  editor.value = text;
  editor.readOnly = true;
  editor.style.position = "fixed";
  editor.style.left = "-9999px";
  document.body.appendChild(editor);
  editor.select();
  const copied = document.execCommand("copy");
  editor.remove();
  if (!copied) throw new Error("copy_not_available");
}

export function useAppsCenterController(props: { active?: boolean; admin?: boolean }) {
  const apiClient = createAppsCenterClient();
  const apps = ref<PublicAppItem[]>([]);
  const isAdmin = ref(!!props.admin);
  const mcpEnabled = ref(false);
  const mcpLanEnabled = ref(false);
  const mcpToken = ref("");
  const mcpPrompt = ref("");
  const lanMcpPrompt = ref("");
  const mcpConfigJson = ref("");
  const lanHttpUrl = ref("");
  const lanSseUrl = ref("");
  const mcpLogs = ref<McpCallLogEntry[]>([]);
  const showingMcpDebugModal = ref(false);
  const members = ref<AppMemberSummary[]>([]);
  const configuredChannels = ref<string[]>([]);
  const busy = ref(false);
  const error = ref("");
  const notice = ref("");
  const failedIcons = ref<Set<string>>(new Set());

  const launchingAppId = ref("");
  const activeWorkbenchAppId = ref("");
  const activeIframeUrl = ref("");
  const iframeKey = ref(0);
  const workbenchFullscreen = ref(false);

  const editingAccessApp = ref<PublicAppItem | null>(null);
  const accessPolicy = ref<"admin_only" | "selected_members" | "all_members">("admin_only");
  const accessAllowedUserIDs = ref<number[]>([]);

  const editingConfigApp = ref<PublicAppItem | null>(null);
  const webEnabled = ref(true);
  const webMode = ref<"static" | "on-demand" | "persistent">("on-demand");
  const webIdleTimeoutSeconds = ref(900);
  const webAutoRestart = ref(true);
  const cronEnabled = ref(false);
  const cronExpr = ref("*/15 * * * *");
  const cronTimezone = ref("Asia/Shanghai");
  const cronEvents = ref<string[]>(["failure", "timeout"]);
  const cronChannels = ref<string[]>([]);

  const viewingLogsApp = ref<PublicAppItem | null>(null);
  const logsLoading = ref(false);
  const webOutput = ref("");
  const cronRuns = ref<AppCronRunEntry[]>([]);
  const restoringApp = ref<PublicAppItem | null>(null);
  const restoreInputRef = ref<HTMLInputElement | null>(null);

  const activeWorkbenchApp = computed(() => apps.value.find((a) => a.id === activeWorkbenchAppId.value) ?? null);
  const nonAdminMembers = computed(() => members.value.filter((m) => m.role !== "admin"));
  watch(() => props.admin, (val) => {
    if (typeof val === "boolean") isAdmin.value = val;
  });

  function applyAppsPayload(payload: Record<string, unknown>) {
    if (Array.isArray(payload.apps)) apps.value = payload.apps as PublicAppItem[];
    if (typeof payload.isAdmin === "boolean") isAdmin.value = payload.isAdmin;
    if (typeof payload.mcpEnabled === "boolean") mcpEnabled.value = payload.mcpEnabled;
    if (typeof payload.mcpLanEnabled === "boolean") mcpLanEnabled.value = payload.mcpLanEnabled;
    if (typeof payload.mcpToken === "string") mcpToken.value = payload.mcpToken;
    if (typeof payload.mcpPrompt === "string" && payload.mcpPrompt) mcpPrompt.value = payload.mcpPrompt;
    if (typeof payload.lanMcpPrompt === "string" && payload.lanMcpPrompt) lanMcpPrompt.value = payload.lanMcpPrompt;
    if (typeof payload.mcpConfigJson === "string" && payload.mcpConfigJson) mcpConfigJson.value = payload.mcpConfigJson;
    if (typeof payload.lanHttpUrl === "string") lanHttpUrl.value = payload.lanHttpUrl;
    if (typeof payload.lanSseUrl === "string") lanSseUrl.value = payload.lanSseUrl;
    if (Array.isArray(payload.mcpLogs)) mcpLogs.value = payload.mcpLogs as McpCallLogEntry[];
    if (Array.isArray(payload.members)) members.value = payload.members as AppMemberSummary[];
    if (Array.isArray(payload.configuredChannels)) configuredChannels.value = payload.configuredChannels as string[];
  }

  function upsertSingleApp(updated?: PublicAppItem) {
    if (!updated || !updated.id) return;
    const idx = apps.value.findIndex((item) => item.id === updated.id);
    if (idx >= 0) apps.value.splice(idx, 1, updated);
    else apps.value.push(updated);
  }

  async function reload(refresh = false) {
    if (busy.value) return;
    busy.value = true;
    error.value = "";
    try {
      const payload = await apiClient.fetchApps(refresh);
      applyAppsPayload(payload);
      if (refresh) notice.value = "应用列表与插件目录已刷新。";
    } catch (e) {
      error.value = "读取应用列表失败：" + describeUserFacingError(e);
    } finally {
      busy.value = false;
    }
  }

  async function toggleMcp() {
    if (busy.value) return;
    busy.value = true;
    error.value = "";
    notice.value = "";
    const next = !mcpEnabled.value;
    try {
      const res = await apiClient.setMcpEnabled(next);
      mcpEnabled.value = typeof res.mcpEnabled === "boolean" ? res.mcpEnabled : next;
      if (typeof res.mcpPrompt === "string" && res.mcpPrompt) mcpPrompt.value = res.mcpPrompt;
      notice.value = mcpEnabled.value ? "已开启 AI Agent (MCP) 开发者服务。" : "已关闭 AI Agent (MCP) 开发者服务。";
    } catch (e) {
      error.value = "切换 MCP 开发者服务失败：" + describeUserFacingError(e);
    } finally {
      busy.value = false;
    }
  }

  async function copyMcpPrompt(enableFirst = false) {
    error.value = "";
    notice.value = "";
    try {
      if (enableFirst && !mcpEnabled.value) {
        busy.value = true;
        const res = await apiClient.setMcpEnabled(true);
        mcpEnabled.value = typeof res.mcpEnabled === "boolean" ? res.mcpEnabled : true;
        if (typeof res.mcpPrompt === "string" && res.mcpPrompt) mcpPrompt.value = res.mcpPrompt;
      }
      await writeAppsClipboard(mcpPrompt.value || DEFAULT_MCP_PROMPT);
      notice.value = mcpEnabled.value
        ? "已复制 AI Agent (MCP) 接入提示词，请直接粘贴给你本地的 AI Agent。"
        : "已复制 MCP 接入提示词（当前 MCP 服务处于关闭状态，可点击「一键开启 MCP 并复制」启用）。";
    } catch (e) {
      error.value = "复制提示词失败：" + describeUserFacingError(e);
    } finally {
      busy.value = false;
    }
  }

  async function handleDebugCopy(text: string, msg: string) {
    try {
      await writeAppsClipboard(text);
      notice.value = msg;
    } catch (e) {
      error.value = "复制内容失败：" + describeUserFacingError(e);
    }
  }

  async function refreshDiagnosticSnapshot() {
    if (!isAdmin.value) return;
    try {
      applyAppsPayload(await apiClient.fetchApps(false));
    } catch {
      /* Preserve primary action error when diagnostic refresh fails. */
    }
  }

  async function openApp(app: PublicAppItem) {
    if (launchingAppId.value) return;
    launchingAppId.value = app.id;
    error.value = "";
    notice.value = "";
    try {
      const res = await apiClient.launchApp(app.id);
      if (res.app) upsertSingleApp(res.app);
      else if (res.status) {
        app.status = res.status;
        if (app.web) app.web.status = res.status;
      }
      activeWorkbenchAppId.value = app.id;
      activeIframeUrl.value = res.launchUrl || app.launchUrl || `/apps/${encodeURIComponent(app.id)}/`;
      iframeKey.value++;
    } catch (e) {
      error.value = `打开「${app.name}」失败：` + describeUserFacingError(e);
      void refreshDiagnosticSnapshot();
    } finally {
      launchingAppId.value = "";
    }
  }

  function closeWorkbench() {
    activeWorkbenchAppId.value = "";
    activeIframeUrl.value = "";
    workbenchFullscreen.value = false;
    void reload(false);
  }

  function refreshWorkbench() {
    iframeKey.value++;
  }

  function openInNewTab() {
    if (activeIframeUrl.value) window.open(activeIframeUrl.value, "_blank", "noopener");
  }

  async function loadLogs(app: PublicAppItem) {
    viewingLogsApp.value = app;
    logsLoading.value = true;
    error.value = "";
    try {
      const res = await apiClient.fetchLogs(app.id);
      if (viewingLogsApp.value?.id === app.id) {
        webOutput.value = res.webOutput;
        cronRuns.value = res.cronRuns as AppCronRunEntry[];
      }
    } catch (e) {
      if (viewingLogsApp.value?.id === app.id) error.value = "读取应用日志失败：" + describeUserFacingError(e);
    } finally {
      logsLoading.value = false;
    }
  }

  function openLogsModal(app: PublicAppItem) {
    webOutput.value = "";
    cronRuns.value = [];
    void loadLogs(app);
  }

  async function runAction(app: PublicAppItem, action: "start" | "stop" | "restart" | "run_cron") {
    if (busy.value) return;
    busy.value = true;
    error.value = "";
    notice.value = "";
    try {
      const res = await apiClient.runAction(app.id, action);
      if (res.app) upsertSingleApp(res.app);
      if (Array.isArray(res.apps)) apps.value = res.apps;
      const labels = {
        start: "已启动应用进程",
        stop: "已停止进程并释放内存",
        restart: "已重启应用进程",
        run_cron: "已触发单次定时任务执行",
      };
      notice.value = `${app.name}：${labels[action]}。`;
      if (viewingLogsApp.value?.id === app.id) await loadLogs(app);
    } catch (e) {
      error.value = "执行操作失败：" + describeUserFacingError(e);
      void refreshDiagnosticSnapshot();
    } finally {
      busy.value = false;
    }
  }

  function openAccessModal(app: PublicAppItem) {
    editingAccessApp.value = app;
    accessPolicy.value = normalizeAccessPolicy(app.access?.policy);
    accessAllowedUserIDs.value = [...(app.access?.allowedUserIDs || app.access?.allowedUserIds || [])];
  }

  async function saveAccess() {
    const app = editingAccessApp.value;
    if (!app || busy.value) return;
    busy.value = true;
    error.value = "";
    try {
      const res = await apiClient.saveAccess(app, accessPolicy.value, accessAllowedUserIDs.value);
      if (res.app) upsertSingleApp(res.app);
      if (Array.isArray(res.apps)) apps.value = res.apps;
      notice.value = `已保存「${app.name}」的成员访问权限。`;
      editingAccessApp.value = null;
    } catch (e) {
      error.value = "保存权限失败：" + describeUserFacingError(e);
    } finally {
      busy.value = false;
    }
  }

  function openConfigDrawer(app: PublicAppItem) {
    editingConfigApp.value = app;
    webEnabled.value = app.web?.enabled ?? true;
    webMode.value = appMode(app);
    webIdleTimeoutSeconds.value = app.web?.idleTimeoutSeconds ?? 900;
    webAutoRestart.value = app.web?.autoRestart ?? true;
    const c = app.cron;
    cronEnabled.value = c?.enabled ?? false;
    cronExpr.value = c?.cron || c?.schedule?.cron || "*/15 * * * *";
    cronTimezone.value = c?.timezone || c?.schedule?.timezone || "Asia/Shanghai";
    cronEvents.value = [...(c?.events || c?.notification?.events || ["failure", "timeout"])];
    cronChannels.value = [...(c?.channels || c?.notification?.channels || [])];
  }

  async function saveConfig() {
    const app = editingConfigApp.value;
    if (!app || busy.value) return;
    busy.value = true;
    error.value = "";
    try {
      const res = await apiClient.saveConfig(
        app,
        {
          enabled: webEnabled.value,
          mode: webMode.value,
          idleTimeoutSeconds: Math.max(60, Number(webIdleTimeoutSeconds.value) || 900),
          autoRestart: webAutoRestart.value,
        },
        {
          enabled: cronEnabled.value,
          cron: cronExpr.value,
          timezone: cronTimezone.value,
          events: cronEvents.value,
          channels: cronChannels.value,
        },
      );
      if (res.app) upsertSingleApp(res.app);
      if (Array.isArray(res.apps)) apps.value = res.apps;
      notice.value = `已保存「${app.name}」的生命周期与定时设置。`;
      editingConfigApp.value = null;
    } catch (e) {
      error.value = "保存设置失败：" + describeUserFacingError(e);
    } finally {
      busy.value = false;
    }
  }

  function exportAppData(app: PublicAppItem) {
    window.open(getAppDataBackupUrl(app.id), "_blank", "noopener");
  }

  function triggerRestoreAppData(app: PublicAppItem) {
    restoringApp.value = app;
    if (restoreInputRef.value) {
      restoreInputRef.value.value = "";
      restoreInputRef.value.click();
    }
  }

  async function onRestoreFileChange(ev: Event) {
    const input = ev.target as HTMLInputElement;
    const file = input?.files?.[0];
    const app = restoringApp.value;
    if (!file || !app || busy.value) return;
    const ok = await requestConfirm({
      title: `恢复「${app.name}」业务数据`,
      message: `确定使用归档「${file.name}」恢复「${app.name}」的 plugin-data/${app.id}/ 业务数据吗？当前应用数据将被该归档替换。`,
      confirmText: "确认恢复",
      variant: "danger",
    });
    if (!ok) return;
    busy.value = true;
    error.value = "";
    try {
      const res = await apiClient.restoreAppData(app.id, file);
      applyAppsPayload(res);
      notice.value = `已恢复「${app.name}」的应用业务数据。`;
    } catch (e) {
      error.value = "恢复应用数据失败：" + describeUserFacingError(e);
    } finally {
      busy.value = false;
      restoringApp.value = null;
    }
  }

  async function removeApp(app: PublicAppItem) {
    const ok = await requestConfirm({
      title: `删除轻应用「${app.name}」`,
      message: `确定删除轻应用「${app.name}」吗？这会移除 plugins/${app.id}/ 目录，但独立数据目录 plugin-data/${app.id}/ 会安全保留。`,
      confirmText: "确认删除",
      variant: "danger",
    });
    if (!ok) return;
    busy.value = true;
    error.value = "";
    try {
      await apiClient.deleteApp(app.id);
      apps.value = apps.value.filter((item) => item.id !== app.id);
      if (activeWorkbenchAppId.value === app.id) closeWorkbench();
      notice.value = `已删除轻应用「${app.name}」。`;
    } catch (e) {
      error.value = "删除应用失败：" + describeUserFacingError(e);
    } finally {
      busy.value = false;
    }
  }

  watch(() => props.active, (active) => {
    if (active !== false) void reload(false);
  }, { immediate: true });

  return {
    apps,
    isAdmin,
    mcpEnabled,
    mcpLanEnabled,
    mcpToken,
    mcpPrompt,
    lanMcpPrompt,
    mcpConfigJson,
    lanHttpUrl,
    lanSseUrl,
    mcpLogs,
    showingMcpDebugModal,
    members,
    configuredChannels,
    busy,
    error,
    notice,
    failedIcons,
    launchingAppId,
    activeWorkbenchApp,
    activeIframeUrl,
    iframeKey,
    workbenchFullscreen,
    editingAccessApp,
    accessPolicy,
    accessAllowedUserIDs,
    nonAdminMembers,
    editingConfigApp,
    webEnabled,
    webMode,
    webIdleTimeoutSeconds,
    webAutoRestart,
    cronEnabled,
    cronExpr,
    cronTimezone,
    cronEvents,
    cronChannels,
    viewingLogsApp,
    logsLoading,
    webOutput,
    cronRuns,
    restoreInputRef,
    hasWeb: hasWebModule,
    hasCron: hasCronModule,
    applyAppsPayload,
    reload,
    toggleMcp,
    copyMcpPrompt,
    handleDebugCopy,
    openApp,
    closeWorkbench,
    refreshWorkbench,
    openInNewTab,
    runAction,
    openAccessModal,
    saveAccess,
    openConfigDrawer,
    saveConfig,
    loadLogs,
    openLogsModal,
    exportAppData,
    triggerRestoreAppData,
    onRestoreFileChange,
    removeApp,
  };
}
