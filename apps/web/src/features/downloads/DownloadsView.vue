<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import {
  AlertCircle, ArrowDownToLine, Ban, Check, CheckCircle2, ChevronLeft, ChevronRight,
  Clock, Copy, Folder, Link2, ListTodo, LoaderCircle, Pause, Play, RefreshCw,
  RotateCcw, SlidersHorizontal, Trash2, X,
} from "lucide-vue-next";
import { apiRequest } from "../../api/apiClient.ts";
import { createMediaStatusPoller } from "../../api/mediaStatusPoller.ts";
import { describeRootOperationFailure } from "../../api/rootDiscovery.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import { formatBinaryBytes as bytes } from "../../utils/format.ts";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleChip from "../../components/ui/IsleChip.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import { readDownloadCenter, type DownloadTask } from "./downloadCenterTransport.ts";

type FolderItem = { name: string; path: string; type: "file" | "folder"; canWrite?: boolean };
type FolderListReply = { entries: FolderItem[]; nextCursor?: string; canWrite?: boolean };
type TaskFilter = "all" | "active" | "completed" | "issues";

const props = withDefaults(
  defineProps<{ active?: boolean; api?: (path: string, init?: RequestInit) => Promise<unknown> }>(),
  { active: true },
);
const requestApi = (path: string, init?: RequestInit) => (props.api ? props.api(path, init) : apiRequest(path, init));

const tasks = ref<DownloadTask[]>([]);
const hasSnapshot = ref(false);
const status = ref<{ available: boolean; networkAllowed?: boolean; version?: string; reason?: string }>({ available: false });
const loading = ref(false), error = ref(""), busy = ref("");
const newURL = ref(""), newDestination = ref("."), newMaxGB = ref("");
const advancedOpen = ref(false), creating = ref(false), taskFilter = ref<TaskFilter>("all");
const copiedTaskId = ref("");
let copiedTimer: number | undefined;

const folderPickerOpen = ref(false), pickerDir = ref(".");
const pickerFolders = ref<FolderItem[]>([]), pickerNextCursor = ref("");
const pickerCanWrite = ref(true), pickerLoading = ref(false), pickerError = ref("");
let pickerGen = 0;

const speedSamples = ref(new Map<string, { bytes: number; at: number; bps: number }>());

function updateSpeedSamples(nextTasks: DownloadTask[]) {
  const now = Date.now();
  const next = new Map(speedSamples.value);
  const activeIds = new Set<string>();
  for (const t of nextTasks) {
    if (t.status !== "running" || t.phase === "publishing") continue;
    activeIds.add(t.id);
    const prev = next.get(t.id);
    if (prev) {
      const dtSec = (now - prev.at) / 1000;
      const delta = t.completedBytes - prev.bytes;
      if (dtSec >= 0.5) next.set(t.id, { bytes: t.completedBytes, at: now, bps: delta > 0 ? Math.round(delta / dtSec) : 0 });
    } else {
      next.set(t.id, { bytes: t.completedBytes, at: now, bps: 0 });
    }
  }
  for (const key of next.keys()) if (!activeIds.has(key)) next.delete(key);
  speedSamples.value = next;
}

const taskSpeedBps = (id: string) => speedSamples.value.get(id)?.bps ?? 0;
const selectedDestOption = computed(() => newDestination.value.trim() || ".");
const destinationSelectOptions = computed(() => {
  const current = selectedDestOption.value;
  const opts = [{ value: ".", label: "保存至：共享根目录 (.)" }, { value: "Downloads", label: "保存至：Downloads" }];
  if (current !== "." && current !== "Downloads") opts.push({ value: current, label: `保存至：${current}` });
  opts.push({ value: "__browse__", label: "浏览共享目录…" });
  return opts;
});

function onDestinationSelect(val: string | number | boolean | null) {
  if (typeof val !== "string") return;
  if (val === "__browse__") { openFolderPicker(); return; }
  newDestination.value = val;
}

const advancedSummary = computed(() => {
  const parts: string[] = [];
  if (newMaxGB.value.trim()) parts.push(`单文件上限 ${newMaxGB.value.trim()} GiB`);
  if (selectedDestOption.value !== "." && selectedDestOption.value !== "Downloads") parts.push(`自定义目录：${selectedDestOption.value}`);
  return parts.length ? parts.join(" · ") : "可配置单文件上限（GiB）与自定义相对路径";
});

const pickerBreadcrumbs = computed(() => {
  if (pickerDir.value === ".") return [{ label: "共享根目录", path: "." }];
  const parts = pickerDir.value.split("/");
  return [{ label: "共享根目录", path: "." }, ...parts.map((part, i) => ({ label: part, path: parts.slice(0, i + 1).join("/") }))];
});

async function loadPickerFolders(more = false) {
  const req = ++pickerGen;
  const target = pickerDir.value;
  pickerLoading.value = true;
  pickerError.value = "";
  try {
    const query = new URLSearchParams({ path: target, limit: "100" });
    if (more && pickerNextCursor.value) query.set("cursor", pickerNextCursor.value);
    const data = (await requestApi("/api/v2/files?" + query.toString())) as FolderListReply;
    if (req !== pickerGen || target !== pickerDir.value) return;
    const dirs = (data.entries ?? []).filter((item) => item.type === "folder");
    pickerFolders.value = more ? [...pickerFolders.value, ...dirs] : dirs;
    pickerNextCursor.value = data.nextCursor ?? "";
    pickerCanWrite.value = data.canWrite !== false;
  } catch (e) {
    if (req === pickerGen) pickerError.value = "读取文件夹失败：" + describeUserFacingError(e);
  } finally {
    if (req === pickerGen) pickerLoading.value = false;
  }
}

function openFolderPicker() {
  pickerDir.value = newDestination.value.trim().replace(/^\/+|\/+$/g, "") || ".";
  pickerFolders.value = [];
  pickerNextCursor.value = "";
  folderPickerOpen.value = true;
  void loadPickerFolders(false);
}

function navigatePicker(nextPath: string) {
  pickerDir.value = nextPath;
  pickerFolders.value = [];
  pickerNextCursor.value = "";
  void loadPickerFolders(false);
}

function confirmPickerFolder() {
  newDestination.value = pickerDir.value;
  folderPickerOpen.value = false;
}

let timer: number | undefined;
let disposed = false;
const activePollMs = 3000;
const idlePollMs = 15000;
let lastLoadAt = 0;
let loadVersion = 0;

const activeTasks = computed(() => tasks.value.filter((t) => t.status === "queued" || t.status === "running" || t.status === "paused"));
const completedTasksCount = computed(() => tasks.value.filter((t) => t.status === "completed").length);
const issueTasksCount = computed(() => tasks.value.filter((t) => t.status === "failed" || t.status === "cancelled").length);
const historyTasks = computed(() => {
  if (taskFilter.value === "active") return [];
  if (taskFilter.value === "completed") return tasks.value.filter((t) => t.status === "completed");
  if (taskFilter.value === "issues") return tasks.value.filter((t) => t.status === "failed" || t.status === "cancelled");
  return tasks.value.filter((t) => t.status === "completed" || t.status === "failed" || t.status === "cancelled");
});
const showActiveSection = computed(() => activeTasks.value.length > 0 && (taskFilter.value === "all" || taskFilter.value === "active"));
const historySectionTitle = computed(() =>
  taskFilter.value === "completed" ? "近期记录 · 已完成" : taskFilter.value === "issues" ? "近期记录 · 异常与已取消" : "近期记录",
);

const poller = createMediaStatusPoller((signal) => readDownloadCenter(requestApi, signal), {
  onValue: (value) => { tasks.value = value.tasks; updateSpeedSamples(value.tasks); status.value = value.status; hasSnapshot.value = true; error.value = ""; },
  onError: (e) => { error.value = "读取下载任务失败：" + describeRootOperationFailure(e); },
});

async function load() {
  if (disposed) return;
  const version = ++loadVersion;
  lastLoadAt = Date.now();
  loading.value = true;
  try { await poller.refresh(); }
  finally { if (!disposed && version === loadVersion) loading.value = false; }
}

async function create() {
  if (creating.value || disposed || status.value.networkAllowed === false) return;
  const url = newURL.value.trim();
  if (!url) { error.value = "请输入 http/https/ftp 或磁力链接。"; return; }
  const destination = newDestination.value.trim() || ".";
  let maxBytes = 0;
  if (newMaxGB.value.trim()) {
    const gb = Number(newMaxGB.value);
    if (!Number.isFinite(gb) || gb <= 0 || gb > 1024) {
      error.value = "大小上限必须大于 0 且不超过 1024 GiB，留空使用服务端上限。";
      advancedOpen.value = true;
      return;
    }
    maxBytes = Math.round(gb * 1024 ** 3);
  }
  creating.value = true;
  error.value = "";
  poller.invalidate();
  try {
    await requestApi("/api/v2/downloads", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-LightIsle-Request": "1" },
      body: JSON.stringify({ url, destination, maxBytes }),
    });
    if (disposed) return;
    newURL.value = "";
    newMaxGB.value = "";
    taskFilter.value = "all";
    poller.invalidate();
    await load();
  } catch (e) {
    if (!disposed) error.value = "创建任务失败：" + describeUserFacingError(e);
  } finally {
    if (!disposed) creating.value = false;
  }
}

async function action(task: DownloadTask, act: "pause" | "resume" | "retry" | "cancel") {
  if (busy.value || disposed) return;
  busy.value = task.id + ":" + act;
  poller.invalidate();
  try {
    await requestApi("/api/v2/downloads/" + encodeURIComponent(task.id) + "/actions", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-LightIsle-Request": "1" },
      body: JSON.stringify({ action: act }),
    });
    if (!disposed) { poller.invalidate(); await load(); }
  } catch (e) {
    if (!disposed) error.value = "操作失败：" + describeUserFacingError(e);
  } finally {
    if (!disposed) busy.value = "";
  }
}

async function remove(task: DownloadTask) {
  if (busy.value || disposed) return;
  if (!(await requestConfirm({ title: "删除下载记录", message: `删除任务“${task.filename || task.url}”的记录？进行中的任务会先取消。`, confirmText: "确认删除", variant: "danger" }))) return;
  busy.value = task.id + ":delete";
  poller.invalidate();
  try {
    await requestApi("/api/v2/downloads/" + encodeURIComponent(task.id), { method: "DELETE", headers: { "X-LightIsle-Request": "1" } });
    if (!disposed) { poller.invalidate(); await load(); }
  } catch (e) {
    if (!disposed) error.value = "删除失败：" + describeUserFacingError(e);
  } finally {
    if (!disposed) busy.value = "";
  }
}

async function copyTaskUrl(task: DownloadTask) {
  if (!task.url || !(await copyTextToClipboard(task.url))) return;
  copiedTaskId.value = task.id;
  if (copiedTimer !== undefined) clearTimeout(copiedTimer);
  copiedTimer = window.setTimeout(() => { copiedTaskId.value = ""; copiedTimer = undefined; }, TIMINGS_MS.COPIED_FEEDBACK);
}

const progress = (task: DownloadTask) => (task.totalBytes > 0 ? Math.min(100, Math.round((task.completedBytes / task.totalBytes) * 100)) : 0);
const statusLabels: Record<DownloadTask["status"], string> = { queued: "排队中", running: "下载中", paused: "已暂停", completed: "已完成", failed: "失败", cancelled: "已取消" };
const statusBadgeLabel = (task: DownloadTask) => (task.phase === "publishing" && task.status === "running" ? "正在保存" : statusLabels[task.status]);
const statusBadgeVariant = (task: DownloadTask) => (task.status === "completed" ? "online" : task.status === "failed" ? "danger" : task.status === "running" ? "accent" : task.status === "paused" ? "warning" : "neutral");
const describeError = (task: DownloadTask) => (!task.error ? "" : describeUserFacingError(new Error(task.error)));
const unavailableMsg = computed(() =>
  `暂时无法新建下载：${status.value.reason === "aria2_not_installed" ? "请先在 Mac 端「设置 → 工具 → 外部依赖」中安装下载组件" : "下载服务未就绪，请稍后重试"}。以前下载的文件不会删除。`,
);
const emptyDesc = computed(() =>
  status.value.available && status.value.networkAllowed !== false
    ? "在上方粘贴链接选择保存目录后点击「开始下载」，或在此查看历史下载记录。"
    : !status.value.available
      ? "离线下载服务当前未就绪或已暂停，暂无法新建下载；已有文件不受影响。"
      : "当前账号暂不可新建网络下载，请联系管理员或在此查看历史下载记录。",
);

function pollTick() {
  if (props.active === false || document.hidden || busy.value || creating.value) return;
  if (Date.now() - lastLoadAt < (activeTasks.value.length > 0 ? activePollMs : idlePollMs)) return;
  void load();
}
function syncPollTimer(active: boolean) {
  if (active && !disposed) { if (timer === undefined) timer = window.setInterval(pollTick, activePollMs); }
  else if (timer !== undefined) { clearInterval(timer); timer = undefined; }
}

watch(() => props.active, (active) => { syncPollTimer(active !== false); if (active !== false && !document.hidden) void load(); });
onMounted(() => { disposed = false; if (props.active !== false) void load(); syncPollTimer(props.active !== false); });
onUnmounted(() => { disposed = true; if (copiedTimer !== undefined) clearTimeout(copiedTimer); poller.dispose(); syncPollTimer(false); });
</script>

<template>
  <div class="downloads-page-wrap">
    <IslePageHeader title="下载中心" subtitle="支持 HTTP / HTTPS / FTP 与磁力离线任务，下载完成安全发布且同名文件零覆盖">
      <template #title-extra>
        <IsleHelpButton
          title="离线下载与文件保护规则"
          :items="[
            { title: '同名文件零覆盖', body: '任务下载完成后自动发布至所选共享目录；若遇到同名文件存在变动，将进入安全核对状态而绝不自动覆盖已有文件。' },
            { title: '组件依赖', body: '离线下载依赖宿主 Mac 上的 aria2 服务，可在轻屿 Mac 端「设置 → 工具 → 外部依赖」中一键检查。' },
          ]"
        />
      </template>
      <template #actions>
        <IsleBadge v-if="activeTasks.length > 0" variant="accent" size="sm" dot>{{ activeTasks.length }} 项进行中</IsleBadge>
        <IsleButton variant="glass" size="sm" :loading="loading" @click="load">
          <template #icon><RefreshCw :size="14" :class="{ 'spin-icon': loading }" /></template>
          {{ loading ? "加载中…" : "刷新队列" }}
        </IsleButton>
      </template>
    </IslePageHeader>

    <IsleBanner v-if="hasSnapshot && !status.available" type="warning" compact role="note" :message="unavailableMsg" />
    <IsleBanner v-if="hasSnapshot && status.networkAllowed === false" type="info" compact message="新建或继续网络下载需要管理员权限，已有任务和已下载的文件仍可管理。" />
    <IsleBanner v-if="error" type="error" compact closable :message="error" @close="error = ''" />

    <IsleCard v-if="status.available && status.networkAllowed !== false" aria-label="新建离线下载" padding="md">
      <form class="download-intake-form" @submit.prevent="create">
        <div class="download-quick-bar">
          <label class="download-url-box">
            <Link2 :size="15" class="download-url-icon" aria-hidden="true" />
            <input v-model="newURL" type="text" placeholder="粘贴直链（HTTP / HTTPS / FTP）或磁力链接…" aria-label="下载链接" required />
          </label>
          <div class="download-dest-select">
            <AppleSelect :model-value="selectedDestOption" :options="destinationSelectOptions" size="md" block aria-label="保存位置" @update:model-value="onDestinationSelect" />
          </div>
          <IsleButton type="submit" variant="primary" size="md" :loading="creating">
            <template #icon><ArrowDownToLine :size="15" aria-hidden="true" /></template>
            {{ creating ? "正在创建…" : "开始下载" }}
          </IsleButton>
        </div>

        <IsleDisclosure v-model="advancedOpen" variant="inline" title="高级选项" :subtitle="advancedSummary">
          <template #icon><SlidersHorizontal :size="14" /></template>
          <template #meta><IsleBadge v-if="newMaxGB.trim()" variant="accent" size="sm">上限 {{ newMaxGB.trim() }} GiB</IsleBadge></template>
          <div class="download-advanced-grid">
            <label class="download-adv-field">
              <span>单文件上限（GiB，选填）</span>
              <input v-model="newMaxGB" type="number" min="0.1" max="1024" step="0.1" placeholder="留空使用服务端上限" />
            </label>
            <div class="download-adv-field">
              <span>自定义保存相对路径</span>
              <div class="download-adv-dest-row">
                <input v-model="newDestination" type="text" aria-label="自定义保存位置" placeholder="例如 Downloads 或 .（根目录）" />
                <IsleButton variant="glass" size="sm" @click="openFolderPicker">
                  <template #icon><Folder :size="14" aria-hidden="true" /></template>浏览…
                </IsleButton>
              </div>
            </div>
          </div>
        </IsleDisclosure>
      </form>
    </IsleCard>

    <div v-if="tasks.length > 0" class="download-filter-bar" role="group" aria-label="按任务状态筛选">
      <IsleChip small :selected="taskFilter === 'all'" @select="taskFilter = 'all'">全部 ({{ tasks.length }})</IsleChip>
      <IsleChip small :selected="taskFilter === 'active'" @select="taskFilter = 'active'">进行中 ({{ activeTasks.length }})</IsleChip>
      <IsleChip small :selected="taskFilter === 'completed'" @select="taskFilter = 'completed'">已完成 ({{ completedTasksCount }})</IsleChip>
      <IsleChip v-if="issueTasksCount > 0 || taskFilter === 'issues'" small :selected="taskFilter === 'issues'" @select="taskFilter = 'issues'">异常/已取消 ({{ issueTasksCount }})</IsleChip>
    </div>

    <p v-if="loading && !hasSnapshot" class="footnote" role="status">正在读取下载中心…</p>
    <IsleEmpty v-else-if="hasSnapshot && !tasks.length && !loading && !error" card :icon="ArrowDownToLine" title="还没有下载任务" :description="emptyDesc" />
    <IsleEmpty v-else-if="tasks.length > 0 && !showActiveSection && !historyTasks.length" card compact :icon="ListTodo" title="当前筛选下没有任务" description="可切换回「全部」查看其他状态的下载记录。">
      <template #action><IsleButton variant="tonal" size="sm" @click="taskFilter = 'all'">查看全部任务</IsleButton></template>
    </IsleEmpty>

    <IsleGroupedList v-if="showActiveSection" title="进行中" :subtitle="`${activeTasks.length} 项正在排队或传输中`" flush>
      <TransitionGroup name="isle-list" tag="div" class="download-group-rows">
        <div v-for="task in activeTasks" :key="task.id" class="download-row is-active">
          <div class="download-row-top">
            <div class="download-row-heading">
              <span class="download-row-icon is-active" aria-hidden="true">
                <LoaderCircle v-if="task.status === 'running'" :size="15" class="spin-icon" />
                <Pause v-else-if="task.status === 'paused'" :size="15" />
                <Clock v-else :size="15" />
              </span>
              <strong class="download-row-name" :title="task.filename || task.url">{{ task.filename || task.url }}</strong>
              <IsleBadge :variant="statusBadgeVariant(task)" size="sm">{{ statusBadgeLabel(task) }}</IsleBadge>
            </div>
            <div class="download-row-actions">
              <IsleButton v-if="task.phase !== 'publishing' && (task.status === 'running' || task.status === 'queued')" variant="glass" size="sm" :disabled="busy !== '' || !status.available" @click="action(task, 'pause')">
                <template #icon><Pause :size="13" aria-hidden="true" /></template>暂停
              </IsleButton>
              <IsleButton v-if="task.status === 'paused'" variant="tonal" size="sm" :disabled="busy !== '' || !status.available || status.networkAllowed === false" @click="action(task, 'resume')">
                <template #icon><Play :size="13" aria-hidden="true" /></template>继续
              </IsleButton>
              <IsleButton variant="glass" size="sm" :disabled="busy !== ''" @click="action(task, 'cancel')">
                <template #icon><X :size="13" aria-hidden="true" /></template>取消
              </IsleButton>
              <IsleButton variant="ghost" size="sm" class="download-delete-btn" aria-label="删除任务记录" :disabled="busy !== ''" @click="remove(task)">
                <template #icon><Trash2 :size="13" aria-hidden="true" /></template>
              </IsleButton>
            </div>
          </div>

          <div v-if="task.totalBytes > 0" class="download-progress-track" role="progressbar" :aria-valuenow="progress(task)" aria-valuemin="0" aria-valuemax="100" :aria-label="(task.filename || '下载任务') + ' 进度'">
            <span class="download-progress-fill" :class="{ 'is-paused': task.status === 'paused' }" :style="{ width: progress(task) + '%' }" />
          </div>
          <div v-else-if="task.status === 'running'" class="download-progress-track is-indeterminate" role="progressbar" aria-valuetext="正在传输（总大小未知）" :aria-label="(task.filename || '下载任务') + ' 正在传输'">
            <span class="download-progress-shimmer" />
          </div>

          <div class="download-row-meta download-tabular">
            <span>目标：{{ task.destination === "." ? "共享根目录" : task.destination }}</span>
            <template v-if="task.totalBytes > 0"><span> · {{ progress(task) }}% · {{ bytes(task.completedBytes) }} / {{ bytes(task.totalBytes) }}</span></template>
            <template v-else-if="task.completedBytes > 0"><span> · 已下载 {{ bytes(task.completedBytes) }}（总大小未知）</span></template>
            <template v-else><span> · 等待建立连接</span></template>
            <template v-if="taskSpeedBps(task.id) > 0"><span> · {{ bytes(taskSpeedBps(task.id)) }}/s</span></template>
            <template v-if="task.maxBytes > 0"><span> · 上限 {{ bytes(task.maxBytes) }}</span></template>
            <span> · {{ formatDateTime(task.createdAt * 1000) }}</span>
          </div>
          <small v-if="task.partialPublish" class="download-row-note">部分文件已保存，任务尚未全部完成；重试会核对已有文件。</small>
          <small v-if="task.recoveryRequired" class="form-error">已有文件与记录不一致，请先在 Mac 核对；不会自动覆盖。</small>
        </div>
      </TransitionGroup>
    </IsleGroupedList>

    <IsleGroupedList v-if="historyTasks.length > 0" :title="historySectionTitle" :subtitle="`${historyTasks.length} 条记录`" flush>
      <TransitionGroup name="isle-list" tag="div" class="download-group-rows">
        <div v-for="task in historyTasks" :key="task.id" class="download-row is-history" :class="{ 'is-failed': task.status === 'failed' }">
          <div class="download-row-top">
            <div class="download-row-heading">
              <span class="download-row-icon" :class="`is-${task.status}`" aria-hidden="true">
                <CheckCircle2 v-if="task.status === 'completed'" :size="15" />
                <AlertCircle v-else-if="task.status === 'failed'" :size="15" />
                <Ban v-else :size="15" />
              </span>
              <strong class="download-row-name" :title="task.filename || task.url">{{ task.filename || task.url }}</strong>
              <IsleBadge :variant="statusBadgeVariant(task)" size="sm">{{ statusBadgeLabel(task) }}</IsleBadge>
            </div>
            <div class="download-row-actions is-reveal">
              <IsleButton v-if="task.status === 'failed' || task.status === 'cancelled'" variant="tonal" size="sm" :disabled="busy !== '' || ((!status.available || status.networkAllowed === false) && task.phase !== 'publishing')" @click="action(task, 'retry')">
                <template #icon><RotateCcw :size="13" aria-hidden="true" /></template>重试
              </IsleButton>
              <IsleButton variant="ghost" size="sm" aria-label="复制源链接" @click="copyTaskUrl(task)">
                <template #icon><Check v-if="copiedTaskId === task.id" :size="13" aria-hidden="true" /><Copy v-else :size="13" aria-hidden="true" /></template>
                {{ copiedTaskId === task.id ? "已复制" : "复制链接" }}
              </IsleButton>
              <IsleButton variant="ghost" size="sm" class="download-delete-btn" :disabled="busy !== ''" @click="remove(task)">
                <template #icon><Trash2 :size="13" aria-hidden="true" /></template>删除
              </IsleButton>
            </div>
          </div>

          <div class="download-row-meta download-tabular">
            <span>目标：{{ task.destination === "." ? "共享根目录" : task.destination }}</span>
            <template v-if="task.totalBytes > 0"><span> · {{ bytes(task.totalBytes) }}</span></template>
            <template v-else-if="task.completedBytes > 0"><span> · {{ bytes(task.completedBytes) }}</span></template>
            <template v-if="task.maxBytes > 0"><span> · 上限 {{ bytes(task.maxBytes) }}</span></template>
            <span> · {{ formatDateTime((task.completedAt || task.createdAt) * 1000) }}</span>
          </div>
          <small v-if="task.status === 'failed' && describeError(task)" class="form-error">{{ describeError(task) }}</small>
          <small v-if="task.partialPublish" class="download-row-note">部分文件已保存，任务尚未全部完成；重试会核对已有文件。</small>
          <small v-if="task.recoveryRequired" class="form-error">已有文件与记录不一致，请先在 Mac 核对；不会自动覆盖。</small>

          <IsleDisclosure v-if="task.publishedFiles?.length" variant="inline" :title="`文件处理记录（${task.publishedFilesTotal ?? task.publishedFiles.length} 项）`">
            <ul class="download-published-list">
              <li v-for="file in task.publishedFiles" :key="file.target">
                <span class="download-published-target">{{ file.target }}</span>
                <span class="download-tabular">{{ file.status === "published" ? "已保存" : file.status === "recovery_required" ? "需要核对" : "等待核对" }} · {{ bytes(file.size) }}</span>
              </li>
            </ul>
            <small v-if="task.publishedFilesTruncated" class="download-row-note">仅展示前 {{ task.publishedFiles.length }} 项；完整处理记录仍由服务端保留。</small>
          </IsleDisclosure>
        </div>
      </TransitionGroup>
    </IsleGroupedList>

    <IsleModal :open="folderPickerOpen" title="选择下载保存目录" :description="'当前位置：' + (pickerDir === '.' ? '共享根目录' : pickerDir)" size="md" @close="folderPickerOpen = false">
      <div class="picker-crumbs" aria-label="目录层级">
        <button v-for="(crumb, index) in pickerBreadcrumbs" :key="crumb.path" type="button" :disabled="pickerLoading || crumb.path === pickerDir" @click="navigatePicker(crumb.path)">
          {{ crumb.label }}<ChevronRight v-if="index < pickerBreadcrumbs.length - 1" :size="12" aria-hidden="true" />
        </button>
      </div>
      <div class="picker-folder-list">
        <p v-if="pickerLoading && !pickerFolders.length" class="picker-feedback"><LoaderCircle :size="15" class="spin-icon" /> 正在读取文件夹…</p>
        <template v-else>
          <button v-if="pickerDir !== '.'" type="button" class="picker-folder-row" :disabled="pickerLoading" @click="navigatePicker(pickerDir.split('/').slice(0, -1).join('/') || '.')">
            <ChevronLeft :size="15" /><span>返回上一级</span>
          </button>
          <button v-for="folder in pickerFolders" :key="folder.path" type="button" class="picker-folder-row" :disabled="pickerLoading" @click="navigatePicker(folder.path)">
            <Folder :size="16" /><span>{{ folder.name }}</span><ChevronRight :size="14" />
          </button>
          <p v-if="!pickerFolders.length && !pickerError" class="picker-feedback">当前文件夹下没有子文件夹，可直接选择当前位置。</p>
          <IsleButton v-if="pickerNextCursor" variant="glass" size="sm" class="picker-load-more" :loading="pickerLoading" @click="loadPickerFolders(true)">加载更多文件夹</IsleButton>
        </template>
      </div>
      <IsleBanner v-if="!pickerCanWrite && !pickerLoading" type="warning" compact message="当前目录为只读，请选择有写入权限的文件夹。" />
      <IsleBanner v-if="pickerError" type="error" compact :message="pickerError" />
      <template #footer>
        <IsleButton variant="glass" @click="folderPickerOpen = false">取消</IsleButton>
        <IsleButton variant="primary" :disabled="!pickerCanWrite || pickerLoading" @click="confirmPickerFolder">保存到此目录</IsleButton>
      </template>
    </IsleModal>
  </div>
</template>

<style scoped>
.downloads-page-wrap { max-width: 1120px; margin: 0 auto; width: 100%; display: flex; flex-direction: column; gap: 14px; }
.download-intake-form { display: flex; flex-direction: column; gap: 6px; }
.download-quick-bar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.download-url-box {
  flex: 1 1 280px; min-width: 0; display: flex; align-items: center; gap: 8px; min-height: 38px; padding: 0 12px;
  border-radius: 10px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
  transition: border-color 0.16s ease, box-shadow 0.16s ease, background-color 0.16s ease;
}
.download-url-box:focus-within {
  background: var(--fluid-card-top); border-color: var(--accent-primary);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary) 16%, transparent);
}
.download-url-icon { color: var(--text-tertiary); flex-shrink: 0; }
.download-url-box input {
  flex: 1; min-width: 0; border: 0; outline: 0; background: transparent;
  color: var(--text-primary); font: inherit; font-size: 13px; padding: 7px 0;
}
.download-dest-select { flex: 0 1 220px; min-width: 175px; }
.download-advanced-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
.download-adv-field { display: flex; flex-direction: column; gap: 5px; min-width: 0; }
.download-adv-field > span { font-size: 12px; font-weight: 600; color: var(--text-secondary); }
.download-adv-field input {
  width: 100%; min-height: 34px; padding: 6px 10px; border-radius: 9px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
  color: var(--text-primary); font: inherit; font-size: 12.5px;
}
.download-adv-dest-row { display: flex; align-items: center; gap: 8px; }
.download-adv-dest-row input { flex: 1; min-width: 0; }
.download-filter-bar { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.download-group-rows { position: relative; display: flex; flex-direction: column; }
.download-row { display: flex; flex-direction: column; gap: 6px; padding: 13px 16px; transition: background-color 0.15s ease; }
.download-row + .download-row { border-top: 1px solid var(--fluid-divider, var(--fluid-card-border)); }
.download-row:hover, .download-row:focus-within { background: var(--fluid-card-hover); }
.download-row-top { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.download-row-heading { display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1 1 240px; }
.download-row-icon {
  width: 26px; height: 26px; border-radius: 7px; display: grid; place-items: center; flex-shrink: 0;
  background: color-mix(in srgb, var(--text-primary) 6%, transparent); color: var(--text-secondary);
}
.download-row-icon.is-active { background: color-mix(in srgb, var(--accent-primary) 12%, transparent); color: var(--accent-primary); }
.download-row-icon.is-completed { background: color-mix(in srgb, var(--success, #167a54) 12%, transparent); color: var(--success, #167a54); }
.download-row-icon.is-failed { background: color-mix(in srgb, var(--error, #c93b3b) 12%, transparent); color: var(--error, #c93b3b); }
.download-row-name { font-size: 13.5px; font-weight: 600; color: var(--text-primary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
.download-row-actions { display: inline-flex; align-items: center; gap: 6px; flex-wrap: wrap; flex-shrink: 0; transition: opacity 0.16s ease; }
@media (hover: hover) and (pointer: fine) {
  .download-row.is-history .download-row-actions.is-reveal { opacity: 0; pointer-events: none; }
  .download-row.is-history:hover .download-row-actions.is-reveal,
  .download-row.is-history:focus-within .download-row-actions.is-reveal { opacity: 1; pointer-events: auto; }
}
@media (hover: none), (pointer: coarse), (max-width: 767px) {
  .download-row.is-history .download-row-actions.is-reveal { opacity: 1; pointer-events: auto; }
}
.download-delete-btn:hover:not(:disabled) {
  color: var(--error, #c93b3b);
  background: color-mix(in srgb, var(--error, #c93b3b) 10%, transparent);
}
.download-progress-track { position: relative; height: 6px; border-radius: 999px; background: var(--stroke-subtle, rgba(142, 142, 147, 0.18)); overflow: hidden; }
.download-progress-fill {
  display: block; height: 100%; border-radius: inherit;
  background: linear-gradient(90deg, var(--accent-primary), var(--brand-cyan, var(--accent-secondary)));
  transition: width 0.35s cubic-bezier(0.22, 1, 0.36, 1);
}
.download-progress-fill.is-paused { opacity: 0.55; }
.download-progress-shimmer {
  position: absolute; inset: 0; width: 42%; border-radius: inherit;
  background: linear-gradient(90deg, transparent 0%, color-mix(in srgb, var(--accent-primary) 72%, #ffffff) 50%, transparent 100%);
  animation: downloadIndeterminate 1.4s cubic-bezier(0.4, 0, 0.2, 1) infinite;
}
@keyframes downloadIndeterminate { 0% { transform: translate3d(-110%, 0, 0); } 100% { transform: translate3d(260%, 0, 0); } }
.download-row-meta { font-size: 12px; line-height: 1.45; color: var(--text-secondary); }
.download-tabular { font-variant-numeric: tabular-nums; }
.download-row-note { font-size: 12px; color: var(--text-secondary); }
.download-published-list { margin: 0; padding-inline-start: 18px; display: grid; gap: 4px; font-size: 12px; color: var(--text-secondary); }
.download-published-list li { display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap; }
.download-published-target { color: var(--text-primary); overflow-wrap: anywhere; }
.isle-list-enter-active, .isle-list-leave-active, .isle-list-move { transition: opacity 0.22s ease, transform 0.22s cubic-bezier(0.22, 1, 0.36, 1); }
.isle-list-enter-from, .isle-list-leave-to { opacity: 0; transform: translate3d(0, 6px, 0); }
.isle-list-leave-active { position: absolute; left: 0; right: 0; pointer-events: none; }
.picker-crumbs { display: flex; flex-wrap: wrap; gap: 5px; }
.picker-crumbs button {
  display: inline-flex; align-items: center; gap: 4px; font-size: 12px; padding: 4px 9px; border-radius: 7px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill); color: var(--text-primary); cursor: pointer;
}
.picker-crumbs button:disabled { opacity: 0.65; cursor: default; }
.picker-folder-list {
  border: 1px solid var(--fluid-card-border); border-radius: 12px; padding: 4px; min-height: 96px;
  max-height: 210px; overflow: auto; background: var(--fluid-card-item-fill);
}
.picker-folder-row {
  width: 100%; min-height: 36px; padding: 6px 10px; display: flex; align-items: center; gap: 8px; text-align: left;
  border-radius: 8px; border: 0; background: transparent; color: var(--text-primary); cursor: pointer; font-size: 13px; transition: background-color 0.15s ease;
}
.picker-folder-row:hover { background: var(--fluid-card-hover); }
.picker-folder-row span { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.picker-feedback { margin: 0; padding: 10px; font-size: 12.5px; color: var(--text-secondary); display: flex; align-items: center; gap: 8px; }
.picker-load-more { margin: 6px auto; display: flex; }
.spin-icon { animation: spin 1s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
@media (max-width: 720px) {
  .download-dest-select { flex: 1 1 180px; }
  .download-row-top { align-items: flex-start; }
}
@media (prefers-reduced-motion: reduce) {
  .download-url-box, .download-row, .download-row-actions, .download-progress-fill, .picker-folder-row,
  .isle-list-enter-active, .isle-list-leave-active, .isle-list-move { transition: none; }
  .spin-icon, .download-progress-shimmer { animation: none; }
}
</style>
