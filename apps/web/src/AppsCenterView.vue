<script setup lang="ts">
import { computed, ref, watch } from "vue";
import {
  RefreshCcw, Trash2, Clock, Bell, ScrollText, Settings2,
  Play, Square, RotateCw, ExternalLink, Maximize2, Minimize2,
  ArrowLeft, Sparkles, Cpu, Globe, Lock, Users, Copy, Power, Terminal,
  Download, Upload
} from "lucide-vue-next";
import { describeUserFacingError } from "./userFacingError.ts";
import { requestConfirm } from "./useConfirmDialog.ts";
import {
  DEFAULT_MCP_PROMPT,
  createAppsCenterClient,
  getAppDataBackupUrl,
  hasCronModule,
  hasWebModule,
  normalizeAccessPolicy,
} from "./appsCenterApi.ts";
import AppsMcpDebugModal from "./AppsMcpDebugModal.vue";
import AppleSelect from "./AppleSelect.vue";
import IsleModal from "./IsleModal.vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleEmpty from "./IsleEmpty.vue";

const apiClient = createAppsCenterClient();

export type AppMember = { id: number; username: string; role: string };
export type CronRun = {
  id?: number; startedAt: number; finishedAt: number; state: string;
  exitCode: number; output?: string; deliveries?: Record<string, string>;
};
export type AppDiagnostic = {
  summary: string;
  reason: string;
  logExcerpt?: string;
  checks?: string[];
  solutions?: string[];
  dataSafe?: string;
};
export type AppItem = {
  id: string; name: string; description?: string; version?: string; category?: string;
  iconUrl?: string; revision?: string; status?: string; mode?: string; pid?: number;
  rssBytes?: number; memoryMB?: number; launchUrl?: string; lastError?: string;
  validationError?: string; diagnostic?: AppDiagnostic;
  pendingActivation?: boolean;
  access?: { policy: "admin_only" | "selected_members" | "all_members"; allowedUserIDs?: number[]; allowedUserIds?: number[] };
  web?: {
    enabled?: boolean; mode?: "static" | "on-demand" | "persistent" | "daemon";
    entry?: string; idleTimeoutSeconds?: number; autoRestart?: boolean;
    status?: string; pid?: number; rssBytes?: number; memoryMB?: number; lastError?: string;
  };
  cron?: {
    hasCron?: boolean; enabled?: boolean; entry?: string; cron?: string; timezone?: string;
    schedule?: { cron?: string; timezone?: string };
    events?: string[]; channels?: string[];
    notification?: { events?: string[]; channels?: string[] };
    running?: boolean; nextRun?: number; nextRunAt?: number; lastRun?: CronRun;
  };
};

const props = defineProps<{ active?: boolean; admin?: boolean }>();
const apps = ref<AppItem[]>([]);
const isAdmin = ref(!!props.admin);
const mcpEnabled = ref(false);
const mcpLanEnabled = ref(false);
const mcpToken = ref("");
const mcpPrompt = ref("");
const lanMcpPrompt = ref("");
const mcpConfigJson = ref("");
const lanHttpUrl = ref("");
const lanSseUrl = ref("");
const mcpLogs = ref<Array<Record<string, any>>>([]);
const showingMcpDebugModal = ref(false);
const members = ref<AppMember[]>([]);
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

const editingAccessApp = ref<AppItem | null>(null);
const accessPolicy = ref<"admin_only" | "selected_members" | "all_members">("admin_only");
const accessAllowedUserIDs = ref<number[]>([]);

const editingConfigApp = ref<AppItem | null>(null);
const webEnabled = ref(true);
const webMode = ref<"static" | "on-demand" | "persistent">("on-demand");
const webIdleTimeoutSeconds = ref(900);
const webAutoRestart = ref(true);
const cronEnabled = ref(false);
const cronExpr = ref("*/15 * * * *");
const cronTimezone = ref("Asia/Shanghai");
const cronEvents = ref<string[]>(["failure", "timeout"]);
const cronChannels = ref<string[]>([]);

const viewingLogsApp = ref<AppItem | null>(null);
const logsLoading = ref(false);
const webOutput = ref("");
const cronRuns = ref<CronRun[]>([]);

const availableChannels = [
  { id: "bark", label: "Bark" }, { id: "webhook", label: "Webhook" },
  { id: "email", label: "邮件" }, { id: "wecom", label: "企业微信" }, { id: "dingtalk", label: "钉钉" },
];
const webModeOptions = [
  { value: "static", label: "纯静态 (Static · 0 MB)" },
  { value: "on-demand", label: "按需唤醒 (On-Demand · 闲置自动休眠)" },
  { value: "persistent", label: "常驻守护 (Persistent · 24/7 运行)" },
];
const categoryLabels: Record<string, string> = {
  network: "网络与通信", media: "影音工具", finance: "家庭账本",
  utility: "实用工具", system: "系统监控", automation: "数据看板",
};
const stateLabels: Record<string, string> = {
  running: "运行中", success: "成功", failure: "失败", timeout: "超时", interrupted: "中断", skipped: "已跳过",
};
const deliveryLabels: Record<string, string> = {
  queued: "等待发送", sent: "已发送", not_configured: "渠道未配置", backoff: "渠道退避中",
  queue_full: "发送队列已满", interrupted: "发送结果未确认", authentication_failed: "认证失败",
  tls_failed: "加密连接失败", connection_failed: "连接失败", delivery_failed: "发送失败",
};

const defaultMcpPrompt = DEFAULT_MCP_PROMPT;
const restoringApp = ref<AppItem | null>(null);
const restoreInputRef = ref<HTMLInputElement | null>(null);

const activeWorkbenchApp = computed(() => apps.value.find(a => a.id === activeWorkbenchAppId.value) ?? null);
const nonAdminMembers = computed(() => members.value.filter(m => m.role !== "admin"));
watch(() => props.admin, val => { if (typeof val === "boolean") isAdmin.value = val; });

function appMode(app: AppItem): "static" | "on-demand" | "persistent" {
  const raw = app.web?.mode || app.mode || "on-demand";
  if (raw === "static") return "static";
  if (raw === "persistent" || raw === "daemon") return "persistent";
  return "on-demand";
}
function appStatus(app: AppItem): string {
  return app.status || app.web?.status || (appMode(app) === "static" ? "static" : "sleeping");
}
function appMemoryMB(app: AppItem): number {
  if (typeof app.memoryMB === "number" && app.memoryMB > 0) return Math.round(app.memoryMB);
  if (typeof app.web?.memoryMB === "number" && app.web.memoryMB > 0) return Math.round(app.web.memoryMB);
  const rss = app.rssBytes ?? app.web?.rssBytes ?? 0;
  return rss > 0 ? Math.max(1, Math.round(rss / (1024 * 1024))) : 0;
}
function runtimeBadge(app: AppItem): string {
  const mode = appMode(app), status = appStatus(app), mb = appMemoryMB(app);
  if (mode === "static") return "纯静态 · 0 MB";
  if (mode === "persistent") return status === "running" ? `常驻守护 · ${mb} MB` : "常驻守护 · 已停止 0 MB";
  if (status === "running") return `按需唤醒 · 运行中 ${mb} MB`;
  if (status === "starting") return "按需唤醒 · 唤醒中…";
  return "按需唤醒 · 休眠 0 MB";
}
function workbenchBadge(app: AppItem): string {
  const mode = appMode(app), status = appStatus(app), mb = appMemoryMB(app);
  if (mode === "static") return "静态 0 MB";
  return status === "running" ? `运行中 · ${mb} MB` : `就绪 · ${mb} MB`;
}
function accessBadge(app: AppItem): string {
  const policy = app.access?.policy || "admin_only";
  if (policy === "all_members") return "🌐 全员可用";
  if (policy === "selected_members") return `👥 已授权 ${(app.access?.allowedUserIDs || []).length} 人`;
  return "🔒 仅管理员";
}
function hasWeb(app: AppItem): boolean {
  return hasWebModule(app);
}
function hasCron(app: AppItem): boolean {
  return hasCronModule(app);
}
function cronSummary(app: AppItem): string {
  const c = app.cron;
  if (!hasCron(app) || !c) return "无定时任务";
  const expr = c.cron || c.schedule?.cron || "未设 Cron";
  const tz = c.timezone || c.schedule?.timezone || "Asia/Shanghai";
  return `${c.enabled ? "⏰ 定时开启" : "⏸ 定时暂停"} · ${expr} (${tz})`;
}
function categoryLabel(category?: string): string {
  return category ? (categoryLabels[category] || category) : "轻应用";
}
function localTime(seconds?: number): string {
  return seconds ? new Date(seconds * 1000).toLocaleString() : "";
}
function flip<T>(list: T[], value: T): T[] {
  return list.includes(value) ? list.filter(v => v !== value) : [...list, value];
}

function applyAppsPayload(payload: Record<string, unknown>) {
  if (Array.isArray(payload.apps)) apps.value = payload.apps as AppItem[];
  if (typeof payload.isAdmin === "boolean") isAdmin.value = payload.isAdmin;
  if (typeof payload.mcpEnabled === "boolean") mcpEnabled.value = payload.mcpEnabled;
  if (typeof payload.mcpLanEnabled === "boolean") mcpLanEnabled.value = payload.mcpLanEnabled;
  if (typeof payload.mcpToken === "string") mcpToken.value = payload.mcpToken;
  if (typeof payload.mcpPrompt === "string" && payload.mcpPrompt) mcpPrompt.value = payload.mcpPrompt;
  if (typeof payload.lanMcpPrompt === "string" && payload.lanMcpPrompt) lanMcpPrompt.value = payload.lanMcpPrompt;
  if (typeof payload.mcpConfigJson === "string" && payload.mcpConfigJson) mcpConfigJson.value = payload.mcpConfigJson;
  if (typeof payload.lanHttpUrl === "string") lanHttpUrl.value = payload.lanHttpUrl;
  if (typeof payload.lanSseUrl === "string") lanSseUrl.value = payload.lanSseUrl;
  if (Array.isArray(payload.mcpLogs)) mcpLogs.value = payload.mcpLogs as Array<Record<string, any>>;
  if (Array.isArray(payload.members)) members.value = payload.members as AppMember[];
  if (Array.isArray(payload.configuredChannels)) configuredChannels.value = payload.configuredChannels as string[];
}
function upsertSingleApp(updated?: AppItem) {
  if (!updated || !updated.id) return;
  const idx = apps.value.findIndex(item => item.id === updated.id);
  if (idx >= 0) apps.value.splice(idx, 1, updated);
  else apps.value.push(updated);
}

async function reload(refresh = false) {
  if (busy.value) return;
  busy.value = true; error.value = "";
  try {
    const payload = await apiClient.fetchApps(refresh);
    applyAppsPayload(payload);
    if (refresh) notice.value = "应用列表与插件目录已刷新。";
  } catch (e) { error.value = "读取应用列表失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

async function toggleMcp() {
  if (busy.value) return;
  busy.value = true; error.value = ""; notice.value = "";
  const next = !mcpEnabled.value;
  try {
    const res = await apiClient.setMcpEnabled(next);
    mcpEnabled.value = typeof res.mcpEnabled === "boolean" ? res.mcpEnabled : next;
    if (typeof res.mcpPrompt === "string" && res.mcpPrompt) mcpPrompt.value = res.mcpPrompt;
    notice.value = mcpEnabled.value ? "已开启 AI Agent (MCP) 开发者服务。" : "已关闭 AI Agent (MCP) 开发者服务。";
  } catch (e) { error.value = "切换 MCP 开发者服务失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

async function writeClipboard(text: string) {
  if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(text); return; }
  const editor = document.createElement("textarea");
  editor.value = text; editor.readOnly = true; editor.style.position = "fixed"; editor.style.left = "-9999px";
  document.body.appendChild(editor); editor.select();
  const copied = document.execCommand("copy"); editor.remove();
  if (!copied) throw new Error("copy_not_available");
}

async function copyMcpPrompt(enableFirst = false) {
  error.value = ""; notice.value = "";
  try {
    if (enableFirst && !mcpEnabled.value) {
      busy.value = true;
      const res = await apiClient.setMcpEnabled(true);
      mcpEnabled.value = typeof res.mcpEnabled === "boolean" ? res.mcpEnabled : true;
      if (typeof res.mcpPrompt === "string" && res.mcpPrompt) mcpPrompt.value = res.mcpPrompt;
    }
    await writeClipboard(mcpPrompt.value || defaultMcpPrompt);
    notice.value = mcpEnabled.value
      ? "已复制 AI Agent (MCP) 接入提示词，请直接粘贴给你本地的 AI Agent。"
      : "已复制 MCP 接入提示词（当前 MCP 服务处于关闭状态，可点击「一键开启 MCP 并复制」启用）。";
  } catch (e) { error.value = "复制提示词失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

async function refreshDiagnosticSnapshot() {
  if (!isAdmin.value) return;
  try { applyAppsPayload(await apiClient.fetchApps(false)); } catch { /* keep primary error */ }
}

async function openApp(app: AppItem) {
  if (launchingAppId.value) return;
  launchingAppId.value = app.id; error.value = ""; notice.value = "";
  try {
    const res = await apiClient.launchApp(app.id);
    if (res.app) upsertSingleApp(res.app);
    else if (res.status) { app.status = res.status; if (app.web) app.web.status = res.status; }
    activeWorkbenchAppId.value = app.id;
    activeIframeUrl.value = res.launchUrl || app.launchUrl || `/apps/${encodeURIComponent(app.id)}/`;
    iframeKey.value++;
  } catch (e) {
    error.value = `打开「${app.name}」失败：` + describeUserFacingError(e);
    void refreshDiagnosticSnapshot();
  }
  finally { launchingAppId.value = ""; }
}

function closeWorkbench() {
  activeWorkbenchAppId.value = ""; activeIframeUrl.value = ""; workbenchFullscreen.value = false;
  void reload(false);
}
function refreshWorkbench() { iframeKey.value++; }
function openInNewTab() { if (activeIframeUrl.value) window.open(activeIframeUrl.value, "_blank", "noopener"); }

async function runAction(app: AppItem, action: "start" | "stop" | "restart" | "run_cron") {
  if (busy.value) return;
  busy.value = true; error.value = ""; notice.value = "";
  try {
    const res = await apiClient.runAction(app.id, action);
    if (res.app) upsertSingleApp(res.app);
    if (Array.isArray(res.apps)) apps.value = res.apps;
    const labels = { start: "已启动应用进程", stop: "已停止进程并释放内存", restart: "已重启应用进程", run_cron: "已触发单次定时任务执行" };
    notice.value = `${app.name}：${labels[action]}。`;
    if (viewingLogsApp.value?.id === app.id) await loadLogs(app);
  } catch (e) {
    error.value = "执行操作失败：" + describeUserFacingError(e);
    void refreshDiagnosticSnapshot();
  }
  finally { busy.value = false; }
}

function openAccessModal(app: AppItem) {
  editingAccessApp.value = app;
  accessPolicy.value = normalizeAccessPolicy(app.access?.policy);
  accessAllowedUserIDs.value = [...(app.access?.allowedUserIDs || app.access?.allowedUserIds || [])];
}
async function saveAccess() {
  const app = editingAccessApp.value;
  if (!app || busy.value) return;
  busy.value = true; error.value = "";
  try {
    const res = await apiClient.saveAccess(app, accessPolicy.value, accessAllowedUserIDs.value);
    if (res.app) upsertSingleApp(res.app);
    if (Array.isArray(res.apps)) apps.value = res.apps;
    notice.value = `已保存「${app.name}」的成员访问权限。`; editingAccessApp.value = null;
  } catch (e) { error.value = "保存权限失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

function openConfigDrawer(app: AppItem) {
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
  busy.value = true; error.value = "";
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
      }
    );
    if (res.app) upsertSingleApp(res.app);
    if (Array.isArray(res.apps)) apps.value = res.apps;
    notice.value = `已保存「${app.name}」的生命周期与定时设置。`; editingConfigApp.value = null;
  } catch (e) { error.value = "保存设置失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

async function loadLogs(app: AppItem) {
  viewingLogsApp.value = app; logsLoading.value = true; error.value = "";
  try {
    const res = await apiClient.fetchLogs(app.id);
    if (viewingLogsApp.value?.id === app.id) {
      webOutput.value = res.webOutput;
      cronRuns.value = res.cronRuns as CronRun[];
    }
  } catch (e) { if (viewingLogsApp.value?.id === app.id) error.value = "读取应用日志失败：" + describeUserFacingError(e); }
  finally { logsLoading.value = false; }
}
function openLogsModal(app: AppItem) { webOutput.value = ""; cronRuns.value = []; void loadLogs(app); }

function exportAppData(app: AppItem) {
  window.open(getAppDataBackupUrl(app.id), "_blank", "noopener");
}
function triggerRestoreAppData(app: AppItem) {
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
  busy.value = true; error.value = "";
  try {
    const res = await apiClient.restoreAppData(app.id, file);
    applyAppsPayload(res);
    notice.value = `已恢复「${app.name}」的应用业务数据。`;
  } catch (e) { error.value = "恢复应用数据失败：" + describeUserFacingError(e); }
  finally { busy.value = false; restoringApp.value = null; }
}

async function removeApp(app: AppItem) {
  const ok = await requestConfirm({
    title: `删除轻应用「${app.name}」`,
    message: `确定删除轻应用「${app.name}」吗？这会移除 plugins/${app.id}/ 目录，但独立数据目录 plugin-data/${app.id}/ 会安全保留。`,
    confirmText: "确认删除",
    variant: "danger",
  });
  if (!ok) return;
  busy.value = true; error.value = "";
  try {
    await apiClient.deleteApp(app.id);
    apps.value = apps.value.filter(item => item.id !== app.id);
    if (activeWorkbenchAppId.value === app.id) closeWorkbench();
    notice.value = `已删除轻应用「${app.name}」。`;
  } catch (e) { error.value = "删除应用失败：" + describeUserFacingError(e); }
  finally { busy.value = false; }
}

watch(() => props.active, active => { if (active !== false) void reload(false); }, { immediate: true });
</script>

<template>
  <section class="apps-center">
    <div v-if="activeWorkbenchApp && activeIframeUrl" class="app-workbench" :class="{ fullscreen: workbenchFullscreen }">
      <header class="workbench-topbar">
        <div class="workbench-left">
          <IsleButton variant="glass" size="sm" @click="closeWorkbench"><ArrowLeft :size="15" /> 返回应用中心</IsleButton>
          <strong class="workbench-title">{{ activeWorkbenchApp.name }}</strong>
          <IsleBadge variant="accent" size="sm">{{ workbenchBadge(activeWorkbenchApp) }}</IsleBadge>
        </div>
        <div class="workbench-actions">
          <IsleButton variant="glass" size="sm" @click="refreshWorkbench"><RotateCw :size="14" /> 刷新画面</IsleButton>
          <IsleButton variant="glass" size="sm" @click="workbenchFullscreen = !workbenchFullscreen">
            <Minimize2 v-if="workbenchFullscreen" :size="14" /><Maximize2 v-else :size="14" />
            {{ workbenchFullscreen ? "退出全屏" : "全屏展开" }}
          </IsleButton>
          <IsleButton variant="primary" size="sm" @click="openInNewTab"><ExternalLink :size="14" /> 新标签页打开</IsleButton>
        </div>
      </header>
      <iframe
        :key="iframeKey" :src="activeIframeUrl"
        sandbox="allow-scripts allow-forms allow-same-origin allow-popups allow-downloads"
        referrerpolicy="no-referrer"
        class="app-workbench-iframe" :title="activeWorkbenchApp.name"
      />
    </div>

    <template v-else>
      <header class="apps-header">
        <div>
          <h2>应用中心</h2>
          <p v-if="isAdmin">按需唤醒家庭轻应用与定时采集插件，闲置自动休眠并支持按成员授权。</p>
          <p v-else>打开已授权的家庭轻应用，免二次登录。</p>
        </div>
        <IsleButton variant="glass" :disabled="busy" @click="reload(isAdmin)">
          <RefreshCcw :size="15" :class="{ spinning: busy }" />
          {{ busy ? "正在刷新…" : isAdmin ? "刷新应用列表" : "刷新" }}
        </IsleButton>
      </header>

      <section v-if="isAdmin" class="mcp-bar" aria-label="AI Agent (MCP) 开发者服务">
        <div class="mcp-bar-info">
          <div class="mcp-title-row">
            <Terminal :size="17" />
            <strong>AI Agent (MCP) 开发者服务：{{ mcpEnabled ? "已开启" : "已关闭" }}</strong>
            <IsleBadge :variant="mcpEnabled ? 'online' : 'offline'" dot size="sm">
              {{ mcpEnabled ? "允许本机 stdio MCP" : "默认关闭" }}
            </IsleBadge>
          </div>
          <small>开启后，AI Agent 可通过本机 <code>lightisled mcp</code> 或局域网 <code>/api/v2/mcp</code> 查询系统与磁盘指标、管理文件与安全回收站、调控相册影视与下载、配置成员配额与定时脚本并开发轻应用（全量记入 SQLite 审计，高危能力已物理隔离）。</small>
        </div>
        <div class="mcp-bar-actions">
          <IsleButton :variant="!mcpEnabled ? 'primary' : 'glass'" :disabled="busy" @click="toggleMcp">
            <Power :size="14" /> {{ mcpEnabled ? "关闭 MCP 服务" : "开启 MCP 服务" }}
          </IsleButton>
          <IsleButton variant="glass" :disabled="busy" @click="copyMcpPrompt(false)">
            <Copy :size="14" /> 复制 AI Agent (MCP) 接入提示词
          </IsleButton>
          <IsleButton v-if="!mcpEnabled" variant="primary" :disabled="busy" @click="copyMcpPrompt(true)">
            <Sparkles :size="14" /> 开启 MCP 并复制提示词
          </IsleButton>
          <IsleButton variant="glass" :disabled="busy" @click="showingMcpDebugModal = true">
            <Terminal :size="14" /> 局域网 MCP 与调试台
          </IsleButton>
        </div>
      </section>

      <IsleBanner v-if="launchingAppId" type="info" compact style="margin-bottom: 14px">
        <template #icon><RefreshCcw :size="16" class="spinning" /></template>
        正在唤醒轻应用...
      </IsleBanner>
      <IsleBanner v-if="error" type="error" compact style="margin-bottom: 14px" :message="error" />
      <IsleBanner v-if="notice" type="success" compact style="margin-bottom: 14px" :message="notice" />

      <IsleEmpty
        v-if="apps.length === 0 && !busy && !error"
        :icon="Sparkles"
        card
        :title="isAdmin ? '暂无轻应用插件' : '暂无已授权的轻应用'"
        :description="isAdmin ? '开启上方 MCP 服务并复制提示词给本地 AI Agent，即可生成或接入家庭轻应用。' : '如需访问家庭工具，请联系管理员在应用中心授权。'"
      />

      <div v-else class="apps-grid">
        <article v-for="app in apps" :key="app.id" class="app-card">
          <div class="app-card-top">
            <div class="app-icon-wrap">
              <img v-if="app.iconUrl && !failedIcons.has(app.id)" :src="app.iconUrl" :alt="app.name + ' 图标'" class="app-icon-img" @error="failedIcons.add(app.id)" />
              <Cpu v-else :size="24" />
            </div>
            <div class="app-title-meta">
              <div class="app-title-line">
                <strong>{{ app.name }}</strong>
                <IsleBadge variant="category" size="sm">{{ categoryLabel(app.category) }}</IsleBadge>
              </div>
              <small v-if="isAdmin" class="app-id-line">{{ app.id }}<template v-if="app.version"> · v{{ app.version }}</template></small>
              <p class="app-desc">{{ app.description || "轻屿本地家庭轻应用" }}</p>
            </div>
          </div>

          <div v-if="isAdmin" class="app-badges">
            <IsleBadge :variant="appStatus(app) === 'running' ? 'online' : 'neutral'" size="sm">{{ runtimeBadge(app) }}</IsleBadge>
            <IsleBadge v-if="app.pendingActivation" variant="warning" size="sm">待首次激活</IsleBadge>
            <IsleBadge variant="neutral" size="sm">{{ accessBadge(app) }}</IsleBadge>
            <IsleBadge variant="neutral" size="sm">{{ cronSummary(app) }}</IsleBadge>
          </div>
          <div v-if="isAdmin && app.diagnostic" class="app-diag-box" role="alert">
            <div class="app-diag-title">{{ app.diagnostic.summary }}</div>
            <p class="app-diag-line"><strong>原因：</strong>{{ app.diagnostic.reason }}</p>
            <pre v-if="app.diagnostic.logExcerpt" class="app-diag-pre">{{ app.diagnostic.logExcerpt }}</pre>
            <p v-if="app.diagnostic.checks?.length" class="app-diag-line"><strong>排查：</strong>{{ app.diagnostic.checks[0] }}</p>
            <p v-if="app.diagnostic.solutions?.length" class="app-diag-line"><strong>解决：</strong>{{ app.diagnostic.solutions[0] }}</p>
            <small v-if="app.diagnostic.dataSafe" class="app-diag-safe">{{ app.diagnostic.dataSafe }}</small>
          </div>
          <p v-else-if="isAdmin && (app.lastError || app.validationError || app.web?.lastError)" class="apps-error">
            {{ describeUserFacingError(app.lastError || app.validationError || app.web?.lastError) }}
          </p>
          <small v-if="isAdmin && app.cron?.lastRun" class="app-Subnote">
            上次定时执行：{{ stateLabels[app.cron.lastRun.state] || app.cron.lastRun.state }} · {{ localTime(app.cron.lastRun.finishedAt) }}
          </small>

          <div class="app-card-actions">
            <IsleButton v-if="app.web?.enabled !== false" variant="primary" :disabled="!!launchingAppId" @click="openApp(app)">
              <Play :size="14" /> {{ launchingAppId === app.id ? "正在唤醒轻应用..." : "立即打开" }}
            </IsleButton>
            <template v-if="isAdmin">
              <IsleButton variant="glass" :disabled="busy" @click="openAccessModal(app)"><Users :size="14" /> 成员权限</IsleButton>
              <IsleButton variant="glass" :disabled="busy" @click="openConfigDrawer(app)"><Settings2 :size="14" /> 生命周期与定时</IsleButton>
              <IsleButton variant="glass" :disabled="busy" @click="openLogsModal(app)"><ScrollText :size="14" /> 运行日志</IsleButton>
              <template v-if="appMode(app) !== 'static'">
                <IsleButton v-if="appStatus(app) === 'running'" variant="glass" :disabled="busy" @click="runAction(app, 'stop')"><Square :size="13" /> 停止</IsleButton>
                <IsleButton v-else variant="glass" :disabled="busy" @click="runAction(app, 'start')"><Play :size="13" /> 启动</IsleButton>
              </template>
              <IsleButton v-if="hasCron(app)" variant="glass" :disabled="busy" @click="runAction(app, 'run_cron')"><Clock :size="13" /> 立即采集</IsleButton>
              <IsleButton variant="glass" :disabled="busy" @click="exportAppData(app)"><Download :size="13" /> 导出数据</IsleButton>
              <IsleButton variant="glass" :disabled="busy" @click="triggerRestoreAppData(app)"><Upload :size="13" /> 恢复数据</IsleButton>
              <IsleButton variant="danger" :disabled="busy || appStatus(app) === 'running'" @click="removeApp(app)"><Trash2 :size="13" /> 删除</IsleButton>
            </template>
          </div>
        </article>
      </div>
      <input ref="restoreInputRef" type="file" accept=".tar.gz,.tgz,application/gzip" style="display:none" @change="onRestoreFileChange" />
    </template>

    <IsleModal
      v-if="editingAccessApp"
      :title="'成员权限 · ' + editingAccessApp.name"
      size="md"
      @close="editingAccessApp = null"
    >
      <template #icon>
        <Users :size="17" />
      </template>
      <div class="apps-radio-group">
        <label class="apps-radio-option"><input v-model="accessPolicy" type="radio" value="admin_only" /><div><strong><Lock :size="14" /> 仅管理员（默认推荐）</strong><small>仅管理员可见与使用</small></div></label>
        <label class="apps-radio-option"><input v-model="accessPolicy" type="radio" value="selected_members" /><div><strong><Users :size="14" /> 指定家庭成员</strong><small>管理员与勾选成员可见并使用</small></div></label>
        <label class="apps-radio-option"><input v-model="accessPolicy" type="radio" value="all_members" /><div><strong><Globe :size="14" /> 全员可用</strong><small>所有已登录家庭成员可用</small></div></label>
      </div>
      <div v-if="accessPolicy === 'selected_members'" class="apps-member-checklist">
        <strong>选择允许访问的家庭成员</strong>
        <p v-if="nonAdminMembers.length === 0" class="apps-hint">暂无普通家庭成员账号。</p>
        <label v-for="m in nonAdminMembers" :key="m.id" class="apps-check-item">
          <input type="checkbox" :checked="accessAllowedUserIDs.includes(m.id)" @change="accessAllowedUserIDs = flip(accessAllowedUserIDs, m.id)" />
          <span>{{ m.username }}</span>
        </label>
      </div>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:10px;width:100%">
          <IsleButton variant="glass" @click="editingAccessApp = null">取消</IsleButton>
          <IsleButton variant="primary" :disabled="busy" @click="saveAccess">保存权限</IsleButton>
        </div>
      </template>
    </IsleModal>

    <IsleModal
      v-if="editingConfigApp"
      :title="'生命周期与定时 · ' + editingConfigApp.name"
      size="md"
      @close="editingConfigApp = null"
    >
      <template #icon>
        <Settings2 :size="17" />
      </template>
      <div v-if="hasWeb(editingConfigApp)" class="apps-form-section">
        <strong>Web 运行模式</strong>
        <label class="apps-check-item"><input v-model="webEnabled" type="checkbox" /> 启用 Web 界面入口</label>
        <div class="apps-inputs">
          <label>运行模式
            <AppleSelect v-model="webMode" block :options="webModeOptions" />
          </label>
          <label v-if="webMode === 'on-demand'">闲置自动休眠时长（秒）
            <input v-model.number="webIdleTimeoutSeconds" type="number" min="60" max="86400" step="60" />
          </label>
        </div>
        <label v-if="webMode === 'persistent'" class="apps-check-item"><input v-model="webAutoRestart" type="checkbox" /> 进程异常退出时自动重启</label>
      </div>
      <div v-if="hasCron(editingConfigApp)" class="apps-form-section">
        <strong><Clock :size="14" /> 后台定时采集 / 任务 (Cron)</strong>
        <label class="apps-check-item"><input v-model="cronEnabled" type="checkbox" /> 启用定时任务调度</label>
        <div class="apps-inputs">
          <label>五段 Cron 表达式<input v-model.trim="cronExpr" placeholder="*/15 * * * *" /></label>
          <label>时区<input v-model.trim="cronTimezone" placeholder="Asia/Shanghai" /></label>
        </div>
        <div class="apps-checks">
          <strong><Bell :size="14" /> 通知事件</strong>
          <label v-for="ev in [{ id: 'failure', name: '执行失败' }, { id: 'timeout', name: '执行超时' }, { id: 'success', name: '执行成功' }]" :key="ev.id">
            <input type="checkbox" :checked="cronEvents.includes(ev.id)" @change="cronEvents = flip(cronEvents, ev.id)" />{{ ev.name }}
          </label>
        </div>
        <div class="apps-checks">
          <strong>通知渠道</strong>
          <label v-for="ch in availableChannels" :key="ch.id">
            <input type="checkbox" :disabled="!configuredChannels.includes(ch.id)" :checked="cronChannels.includes(ch.id)" @change="cronChannels = flip(cronChannels, ch.id)" />
            {{ ch.label }}<small v-if="!configuredChannels.includes(ch.id)">未配置</small>
          </label>
        </div>
      </div>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:10px;width:100%">
          <IsleButton variant="glass" @click="editingConfigApp = null">取消</IsleButton>
          <IsleButton variant="primary" :disabled="busy" @click="saveConfig">保存设置</IsleButton>
        </div>
      </template>
    </IsleModal>

    <IsleModal
      v-if="viewingLogsApp"
      :title="'运行日志 · ' + viewingLogsApp.name"
      size="wide"
      @close="viewingLogsApp = null"
    >
      <template #icon>
        <ScrollText :size="17" />
      </template>
      <template #header-actions>
        <IsleButton variant="glass" size="sm" :disabled="logsLoading" @click="loadLogs(viewingLogsApp)"><RefreshCcw :size="14" /> 刷新日志</IsleButton>
        <IsleButton v-if="hasCron(viewingLogsApp)" variant="glass" size="sm" :disabled="busy" @click="runAction(viewingLogsApp, 'run_cron')"><Play :size="14" /> 立即执行 Cron</IsleButton>
      </template>
      <div class="apps-form-section">
        <strong>Web 进程标准输出（最近日志）</strong>
        <pre class="apps-log-pre">{{ webOutput || "（当前无 Web 进程日志输出，或应用处于休眠/静态状态）" }}</pre>
      </div>
      <div class="apps-form-section">
        <strong>定时任务（Cron）最近执行记录</strong>
        <p v-if="cronRuns.length === 0" class="apps-hint">暂无定时执行记录。</p>
        <details v-for="(run, idx) in cronRuns" :key="run.id ?? idx" class="apps-log-detail">
          <summary>{{ localTime(run.startedAt) }} · {{ stateLabels[run.state] || run.state }}<span v-if="run.exitCode >= 0"> · 退出码 {{ run.exitCode }}</span></summary>
          <pre class="apps-log-pre">{{ run.output || "（没有标准输出）" }}</pre>
          <p v-for="(status, channel) in run.deliveries" :key="channel" class="apps-hint">
            {{ availableChannels.find(c => c.id === channel)?.label || channel }} · {{ deliveryLabels[status] || status }}
          </p>
        </details>
      </div>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;width:100%">
          <IsleButton variant="glass" @click="viewingLogsApp = null">关闭</IsleButton>
        </div>
      </template>
    </IsleModal>
    <AppsMcpDebugModal
      v-if="showingMcpDebugModal"
      :apps="apps"
      :mcp-enabled="mcpEnabled"
      :mcp-lan-enabled="mcpLanEnabled"
      :mcp-token="mcpToken"
      :mcp-prompt="mcpPrompt"
      :lan-mcp-prompt="lanMcpPrompt"
      :mcp-config-json="mcpConfigJson"
      :lan-http-url="lanHttpUrl"
      :lan-sse-url="lanSseUrl"
      :mcp-logs="mcpLogs"
      @close="showingMcpDebugModal = false"
      @updated="applyAppsPayload"
      @copy="(text, msg) => writeClipboard(text).then(() => { notice = msg; }).catch(() => {})"
    />
  </section>
</template>

<style scoped>
.apps-center { display: grid; gap: 18px; }
.mcp-bar { border: 1px solid var(--fluid-card-border); border-radius: 20px; padding: 18px 20px; background: var(--fluid-card-fill); box-shadow: var(--fluid-card-shadow); display: flex; justify-content: space-between; align-items: center; gap: 16px; flex-wrap: wrap; }
.mcp-bar-info { display: grid; gap: 5px; min-width: 0; flex: 1 1 280px; }
.mcp-title-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.mcp-title-row strong { font-size: 14.5px; font-weight: 680; }
.mcp-bar-info small { color: var(--text-secondary); font-size: 12.5px; line-height: 1.45; }
.waking-banner { display: flex; align-items: center; gap: 10px; padding: 12px 16px; border-radius: 14px; background: color-mix(in srgb, var(--accent-primary) 14%, transparent); color: var(--text-primary); font-weight: 600; font-size: 13px; }
.apps-empty { border: 1px dashed var(--fluid-card-border); border-radius: 20px; padding: 36px 24px; background: var(--fluid-card-fill); text-align: center; display: grid; justify-items: center; gap: 8px; color: var(--text-secondary); }
.apps-empty strong { color: var(--text-primary); font-size: 15px; }
.apps-empty p { margin: 0; font-size: 13px; max-width: 460px; line-height: 1.5; }
.apps-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 310px), 1fr)); gap: 16px; }
.app-card { border: 1px solid var(--fluid-card-border); border-radius: 20px; padding: 20px; background: var(--fluid-card-fill); box-shadow: var(--fluid-card-shadow); display: grid; gap: 14px; align-content: space-between; }
.app-card-top { display: flex; gap: 14px; align-items: flex-start; }
.app-icon-wrap { width: 48px; height: 48px; border-radius: 14px; background: color-mix(in srgb, var(--accent-primary) 12%, transparent); color: var(--accent-primary); display: flex; align-items: center; justify-content: center; flex-shrink: 0; overflow: hidden; }
.app-icon-img { width: 32px; height: 32px; object-fit: contain; }
.app-title-meta { display: grid; gap: 4px; min-width: 0; flex: 1; }
.app-title-line { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.app-title-line strong { font-size: 16px; font-weight: 680; }
.app-id-line, .app-Subnote { font-size: 12px; color: var(--text-secondary); }
.app-desc { font-size: 13px; color: var(--text-secondary); margin: 2px 0 0; line-height: 1.45; }
.app-badges { display: flex; flex-wrap: wrap; gap: 6px; }
.app-card-actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.app-workbench { display: grid; grid-template-rows: auto 1fr; border: 1px solid var(--fluid-card-border); border-radius: 20px; overflow: hidden; background: var(--fluid-card-fill); min-height: 76vh; }
.app-workbench.fullscreen { position: fixed; inset: 12px; z-index: 1200; min-height: calc(100vh - 24px); box-shadow: 0 24px 60px rgba(0, 0, 0, 0.45); }
.workbench-topbar { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 10px 16px; border-bottom: 1px solid var(--fluid-card-border); flex-wrap: wrap; }
.workbench-left, .workbench-actions { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.app-workbench-iframe { width: 100%; height: 100%; min-height: 70vh; border: 0; background: #fff; }
.apps-log-detail { border-top: 1px solid var(--fluid-card-border); padding-top: 8px; display: grid; gap: 6px; }
.apps-log-detail summary { cursor: pointer; font-size: 12.5px; font-weight: 600; }
.app-diag-box { border: 1px solid color-mix(in srgb, #f59e0b 38%, var(--fluid-card-border)); border-radius: 12px; padding: 10px 12px; background: color-mix(in srgb, #f59e0b 8%, transparent); display: grid; gap: 5px; }
.app-diag-title { font-size: 12.5px; font-weight: 680; color: #d97706; }
.app-diag-line { margin: 0; font-size: 12px; line-height: 1.48; color: var(--text-secondary); }
.app-diag-line strong { color: var(--text-primary); }
.app-diag-pre { margin: 2px 0; padding: 7px 9px; border-radius: 8px; background: rgba(15, 23, 42, 0.06); font-size: 11px; line-height: 1.45; overflow-x: auto; white-space: pre-wrap; word-break: break-word; }
.app-diag-safe { font-size: 11.5px; color: #059669; }
.spinning { animation: apps-spin 1s linear infinite; }
@keyframes apps-spin { to { transform: rotate(360deg); } }
</style>
