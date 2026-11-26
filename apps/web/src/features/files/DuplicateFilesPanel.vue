<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import { CopyCheck, Search, ShieldAlert, Trash2, XCircle } from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCharts from "../../components/ui/IsleCharts.vue";
import { createScopedRootApi } from "../../api/apiClient.ts";
import { rootApiPath, rootMediaPath } from "../../api/rootApi.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import { formatBytes } from "../photos/photoPresentation.ts";
import {
  chooseDuplicateKeepPath,
  type DuplicateFileGroup,
  type DuplicateKeepStrategy,
} from "../photos/usePhotoAISearchAndPeople.ts";
import DuplicateGroupCard from "./DuplicateGroupCard.vue";
import {
  DUPLICATE_MIN_SIZE_OPTIONS as minSizeOptions,
  buildDedupeSavingsChart,
  calculateSelectedTrashBytes,
  formatDuplicateScanProgress,
  type DuplicateScanResponse,
  type RootOption,
} from "./duplicateFilesSupport.ts";

const props = withDefaults(
  defineProps<{
    admin: boolean;
    roots?: RootOption[];
    fixedRootId?: string;
    fixedRootGeneration?: number;
    embedded?: boolean;
  }>(),
  {
    roots: () => [],
    fixedRootId: undefined,
    fixedRootGeneration: undefined,
    embedded: true,
  },
);

const emit = defineEmits<{
  (e: "trashed"): void;
}>();

const selectedRootId = ref("");
const minSizeMiB = ref<number>(1);
const strategy = ref<DuplicateKeepStrategy>("shortest_path");
const startingScan = ref(false);
const cancellingScan = ref(false);
const trashing = ref(false);
const error = ref("");
const success = ref("");
const snapshot = ref<DuplicateScanResponse | null>(null);
const keepByGroup = ref<Record<string, string>>({});
const checkedTrash = ref<Record<string, Set<string>>>({});
let pollTimer: ReturnType<typeof setInterval> | null = null;

const onlineRoots = computed(() => (props.roots ?? []).filter((r) => r.online));
const rootSelectOptions = computed(() =>
  onlineRoots.value.map((r) => ({
    value: r.rootID,
    label: r.name + (r.isDefault ? " · 默认" : ""),
  })),
);

const activeRootId = computed(() => {
  if (props.fixedRootId !== undefined) return props.fixedRootId || undefined;
  const matched =
    onlineRoots.value.find((r) => r.rootID === selectedRootId.value) ??
    onlineRoots.value[0] ??
    null;
  return matched?.rootID;
});

const activeRootGeneration = computed(() => {
  if (props.fixedRootId !== undefined) return props.fixedRootGeneration ?? 0;
  const matched =
    onlineRoots.value.find((r) => r.rootID === selectedRootId.value) ??
    onlineRoots.value[0] ??
    null;
  return matched?.generation ?? 0;
});

const isRunning = computed(() => startingScan.value || Boolean(snapshot.value?.running));
const dedupeSavingsChart = computed(() => buildDedupeSavingsChart(snapshot.value?.result));
const progressLabel = computed(() => formatDuplicateScanProgress(snapshot.value?.progress));

let epoch = 0;
const { api } = createScopedRootApi({
  getRootId: () => activeRootId.value,
  getRootGeneration: () => activeRootGeneration.value,
  getEpoch: () => epoch,
  getSignal: () => new AbortController().signal,
});

function endpoint(path: string): string {
  return rootApiPath(activeRootId.value, path);
}

function itemThumbnailUrl(path: string): string {
  return rootMediaPath(
    activeRootId.value,
    activeRootGeneration.value,
    `/api/v2/files/thumbnail?path=${encodeURIComponent(path)}&size=512`,
  );
}

function stopPolling() {
  if (pollTimer !== null) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

function ensurePolling() {
  if (pollTimer !== null) return;
  pollTimer = setInterval(() => {
    void pollStatusOnce();
  }, 800);
}

function applyKeepStrategy(groups: DuplicateFileGroup[], strat: DuplicateKeepStrategy) {
  const nextKeep: Record<string, string> = {};
  const nextTrash: Record<string, Set<string>> = {};
  for (const g of groups) {
    const keepPath = chooseDuplicateKeepPath(g.items, strat);
    nextKeep[g.groupId] = keepPath;
    nextTrash[g.groupId] = new Set(
      g.items.filter((it) => it.path !== keepPath && it.canTrash).map((it) => it.path),
    );
  }
  keepByGroup.value = nextKeep;
  checkedTrash.value = nextTrash;
}

function handleSnapshot(res: DuplicateScanResponse, refreshSelections: boolean) {
  const wasRunning = Boolean(snapshot.value?.running);
  snapshot.value = res;
  if (res.running) {
    ensurePolling();
  } else {
    stopPolling();
    if (res.lastError && res.lastError !== "cancelled") {
      error.value = "扫描未完成：" + describeUserFacingError(res.lastError);
    }
    if ((refreshSelections || wasRunning) && res.result?.groups) {
      applyKeepStrategy(res.result.groups, strategy.value);
    }
  }
}

async function pollStatusOnce() {
  try {
    const res = await api<DuplicateScanResponse>(endpoint("/api/v2/files/duplicates"));
    handleSnapshot(res, false);
  } catch (e) {
    stopPolling();
    if (!(e instanceof Error && e.name === "AbortError")) {
      error.value = "刷新重复文件扫描状态失败：" + describeUserFacingError(e);
    }
  }
}

async function loadCached() {
  if (props.fixedRootId === undefined && props.roots.length > 0 && !activeRootId.value) return;
  try {
    const res = await api<DuplicateScanResponse>(endpoint("/api/v2/files/duplicates"));
    handleSnapshot(res, true);
  } catch (e) {
    if (!(e instanceof Error && e.name === "AbortError")) {
      error.value = "读取上次重复文件扫描状态失败：" + describeUserFacingError(e);
    }
  }
}

async function runScan() {
  if (isRunning.value) return;
  startingScan.value = true;
  error.value = "";
  success.value = "";
  try {
    const res = await api<DuplicateScanResponse>(endpoint("/api/v2/files/duplicates/scan"), "POST", {
      minSizeBytes: Number(minSizeMiB.value) * 1024 * 1024,
      maxGroups: 100,
      async: true,
    });
    handleSnapshot(res, true);
  } catch (e) {
    error.value = "扫描重复文件失败：" + describeUserFacingError(e);
  } finally {
    startingScan.value = false;
  }
}

async function cancelScan() {
  if (cancellingScan.value) return;
  cancellingScan.value = true;
  try {
    await api(endpoint("/api/v2/files/duplicates/cancel"), "POST", {});
    stopPolling();
    await loadCached();
  } catch (e) {
    error.value = "取消扫描失败：" + describeUserFacingError(e);
  } finally {
    cancellingScan.value = false;
  }
}

function setStrategy(next: DuplicateKeepStrategy) {
  strategy.value = next;
  if (snapshot.value?.result?.groups) {
    applyKeepStrategy(snapshot.value.result.groups, next);
  }
}

function toggleTrashPath(group: DuplicateFileGroup, path: string, canTrash: boolean) {
  if (!canTrash) return;
  const set = new Set(checkedTrash.value[group.groupId] ?? []);
  if (set.has(path)) {
    set.delete(path);
  } else {
    if (set.size + 1 >= group.items.length) {
      error.value = "每组重复文件至少必须保留 1 份原件，不能全部移入回收站。";
      return;
    }
    set.add(path);
    if (keepByGroup.value[group.groupId] === path) {
      const remaining = group.items.find((it) => !set.has(it.path));
      if (remaining) keepByGroup.value = { ...keepByGroup.value, [group.groupId]: remaining.path };
    }
  }
  checkedTrash.value = { ...checkedTrash.value, [group.groupId]: set };
}

const totalSelectedTrashCount = computed(() => {
  let count = 0;
  for (const set of Object.values(checkedTrash.value)) count += set.size;
  return count;
});

const selectedTrashBytes = computed(() =>
  calculateSelectedTrashBytes(snapshot.value?.result?.groups ?? [], checkedTrash.value),
);

async function trashSelectedDuplicates() {
  const groups = snapshot.value?.result?.groups ?? [];
  if (!groups.length || trashing.value) return;
  const payloadGroups: Array<{
    keepPath: string;
    trashItems: Array<{ path: string; size: number; identity: string }>;
  }> = [];
  let countToTrash = 0;
  let bytesToTrash = 0;

  for (const g of groups) {
    const set = checkedTrash.value[g.groupId];
    if (!set || !set.size) continue;
    const keepItem = g.items.find((it) => !set.has(it.path));
    if (!keepItem) {
      error.value = "每组重复文件至少必须保留 1 份原件。";
      return;
    }
    const trashItems = g.items
      .filter((it) => set.has(it.path) && it.canTrash)
      .map((it) => {
        countToTrash += 1;
        bytesToTrash += it.size;
        return { path: it.path, size: it.size, identity: it.identity };
      });
    if (trashItems.length) {
      payloadGroups.push({ keepPath: keepItem.path, trashItems });
    }
  }
  if (!payloadGroups.length) return;

  const confirmed = await requestConfirm({
    title: "确认将重复副本移入回收站？",
    message: `即将把已勾选的 ${countToTrash} 个重复副本（合计 ${formatBytes(bytesToTrash)}）安全移入回收站，每组均保留至少 1 份原件不动。移入回收站后可随时恢复。`,
    confirmText: "移入回收站",
    cancelText: "取消",
    variant: "danger",
  });
  if (!confirmed) return;

  trashing.value = true;
  error.value = "";
  success.value = "";
  try {
    const res = await api<{ trashed: number; stagedTrashBytes: number; quotaReleaseNote?: string }>(
      endpoint("/api/v2/files/duplicates/trash"),
      "POST",
      { groups: payloadGroups },
    );
    success.value = `已将 ${res.trashed} 个重复副本移入回收站（合计 ${formatBytes(res.stagedTrashBytes)}）。${res.quotaReleaseNote ?? ""}`;
    await loadCached();
    emit("trashed");
  } catch (e) {
    error.value = "清理重复文件失败：" + describeUserFacingError(e);
  } finally {
    trashing.value = false;
  }
}

watch(
  onlineRoots,
  (list) => {
    if (props.fixedRootId === undefined && !selectedRootId.value && list.length) {
      const def = list.find((r) => r.isDefault) ?? list[0];
      if (def) selectedRootId.value = def.rootID;
    }
  },
  { immediate: true },
);

watch([activeRootId, activeRootGeneration], () => {
  epoch += 1;
  stopPolling();
  snapshot.value = null;
  void loadCached();
});

onMounted(() => {
  void loadCached();
});

onUnmounted(() => {
  stopPolling();
});
</script>

<template>
  <div class="dup-panel" :class="{ 'dup-panel--card': !embedded }">
    <header class="dup-panel-header">
      <div class="dup-panel-heading">
        <h3 v-if="!embedded" class="dup-panel-title">
          <CopyCheck :size="17" aria-hidden="true" />
          <span>重复大文件扫描与空间清理</span>
        </h3>
        <p class="dup-panel-subtitle">
          <CopyCheck v-if="embedded" :size="14" class="dup-inline-icon" aria-hidden="true" />
          <span>{{ admin ? "支持按文件体积、采样指纹与完整 SHA-256 核对重复文件，并自动识别 macOS APFS 写时复制克隆块。" : "仅扫描你有权访问的个人目录与共享空间，清理时强制保留至少 1 份原件并移入回收站。" }}</span>
        </p>
      </div>
      <div class="dup-toolbar">
        <AppleSelect
          v-if="fixedRootId === undefined && onlineRoots.length > 1"
          v-model="selectedRootId"
          :options="rootSelectOptions"
          :disabled="isRunning"
          size="sm"
          aria-label="选择扫描目录"
        />
        <AppleSelect
          v-model="minSizeMiB"
          :options="minSizeOptions"
          :disabled="isRunning"
          size="sm"
          aria-label="最小文件体积"
        />
        <IsleButton v-if="isRunning" variant="glass" size="sm" :loading="cancellingScan" @click="cancelScan">
          <template #icon><XCircle :size="14" /></template>
          取消扫描
        </IsleButton>
        <IsleButton variant="primary" size="sm" :loading="isRunning" @click="runScan">
          <template #icon><Search :size="14" /></template>
          {{ isRunning ? "后台核对中…" : "开始扫描重复文件" }}
        </IsleButton>
      </div>
    </header>

    <IsleBanner v-if="error" type="error" compact closable :message="error" @close="error = ''" />
    <IsleBanner v-if="success" type="success" compact closable :message="success" @close="success = ''" />

    <div v-if="isRunning" class="dup-progress-box" role="status" aria-live="polite">
      <strong>{{ progressLabel }}</strong>
      <small v-if="snapshot?.progress?.currentPath" class="dup-progress-path">
        当前：{{ snapshot.progress.currentPath }}
      </small>
    </div>

    <div v-if="!snapshot?.result && !isRunning" class="dup-empty">
      点击「开始扫描重复文件」即可在你授权访问的目录内查找完全相同的重复大文件，释放个人配额与磁盘空间。
    </div>

    <template v-else-if="snapshot?.result">
      <div class="dup-summary-bar">
        <div class="dup-stats-strip">
          <div class="dup-metrics">
            <span>已检查 <strong>{{ snapshot.result.scannedFiles }}</strong> 个文件</span>
            <span>发现 <strong>{{ snapshot.result.totalGroups }}</strong> 组重复</span>
            <span>可释放逻辑配额 <strong>{{ formatBytes(snapshot.result.totalReclaimableBytes) }}</strong></span>
            <span v-if="snapshot.result.totalReclaimablePhysicalBytes !== snapshot.result.totalReclaimableBytes">
              物理磁盘可释放 <strong>{{ formatBytes(snapshot.result.totalReclaimablePhysicalBytes) }}</strong>
            </span>
          </div>
          <IsleBadge v-if="dedupeSavingsChart" variant="online" size="sm">
            冗余占比 {{ dedupeSavingsChart.savedPercent }}%
          </IsleBadge>
        </div>

        <IsleCharts
          v-if="dedupeSavingsChart"
          kind="segmented"
          :segments="dedupeSavingsChart.segments"
          :total="dedupeSavingsChart.totalBytes"
          :bar-height="10"
          compact-legend
          aria-label="保留原件体积与可释放冗余空间对比"
        />

        <div v-if="snapshot.result.groups.length" class="dup-strategy-bar">
          <span class="dup-strategy-label">保留策略：</span>
          <button type="button" class="dup-chip" :class="{ active: strategy === 'shortest_path' }" @click="setStrategy('shortest_path')">保留最短路径</button>
          <button type="button" class="dup-chip" :class="{ active: strategy === 'oldest' }" @click="setStrategy('oldest')">保留最早文件</button>
          <button type="button" class="dup-chip" :class="{ active: strategy === 'newest' }" @click="setStrategy('newest')">保留最新修改</button>
        </div>
      </div>

      <div v-if="!snapshot.result.groups.length" class="dup-empty">
        未发现体积达到阈值的重复文件，当前存储空间非常整洁。
      </div>

      <TransitionGroup v-else name="dup-group" tag="div" class="dup-group-list">
        <DuplicateGroupCard
          v-for="group in snapshot.result.groups"
          :key="group.groupId"
          :group="group"
          :checked-set="checkedTrash[group.groupId]"
          :thumbnail-url="itemThumbnailUrl"
          @toggle-item="toggleTrashPath($event.group, $event.path, $event.canTrash)"
        />
      </TransitionGroup>

      <div v-if="snapshot.result.groups.length" class="dup-sticky-action-bar">
        <div class="dup-sticky-summary">
          <strong>已选 {{ totalSelectedTrashCount }} 个重复副本</strong>
          <small v-if="selectedTrashBytes > 0">预计释放 {{ formatBytes(selectedTrashBytes) }}</small>
          <small v-else>每组至少保留 1 份原件</small>
        </div>
        <IsleButton
          variant="danger"
          size="sm"
          :loading="trashing"
          :disabled="totalSelectedTrashCount === 0 || isRunning"
          @click="trashSelectedDuplicates"
        >
          <template #icon><Trash2 :size="13" /></template>
          移入回收站 ({{ totalSelectedTrashCount }})
        </IsleButton>
      </div>
    </template>

    <footer class="dup-footer-note">
      <ShieldAlert :size="14" />
      <span>{{ snapshot?.quotaReleaseNote ?? "移入回收站后可随时恢复；个人空间配额将在从回收站永久删除后释放。" }}</span>
    </footer>
  </div>
</template>

<style scoped>
.dup-panel {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.dup-panel--card {
  padding: 16px 18px;
  border-radius: var(--radius-lg, 18px);
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  box-shadow: var(--fluid-card-shadow);
}
.dup-panel-header {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 10px 12px;
}
.dup-panel-heading {
  flex: 1 1 260px;
  min-width: 0;
  display: grid;
  gap: 3px;
}
.dup-panel-title {
  margin: 0;
  display: flex;
  align-items: center;
  gap: 7px;
  font-size: 15px;
  font-weight: 650;
  color: var(--text-primary);
}
.dup-panel-subtitle {
  margin: 0;
  display: flex;
  align-items: flex-start;
  gap: 6px;
  font-size: 12.5px;
  line-height: 1.45;
  color: var(--text-secondary);
}
.dup-inline-icon {
  flex-shrink: 0;
  margin-top: 2px;
  color: var(--accent-primary);
}
.dup-toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
}
.dup-progress-box {
  display: flex;
  flex-direction: column;
  gap: 3px;
  padding: 9px 12px;
  border-radius: 10px;
  border: 1px solid color-mix(in srgb, var(--accent-primary) 24%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--accent-primary) 7%, var(--fluid-card-top));
  font-size: 12.5px;
}
.dup-progress-path {
  font-size: 11.5px;
  color: var(--text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.dup-empty {
  padding: 12px 2px;
  font-size: 12.5px;
  color: var(--text-secondary);
}
.dup-summary-bar {
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 12px 14px;
  border-radius: 13px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  font-size: 12.5px;
}
.dup-stats-strip {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 8px 12px;
}
.dup-metrics {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 14px;
  font-variant-numeric: tabular-nums;
}
.dup-strategy-bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 5px;
  padding-top: 8px;
  border-top: 1px solid var(--fluid-divider, var(--fluid-card-border));
}
.dup-strategy-label {
  font-size: 12px;
  color: var(--text-secondary);
}
.dup-chip {
  padding: 4px 10px;
  border-radius: 999px;
  font-size: 11.5px;
  font-weight: 550;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: var(--text-secondary);
  cursor: pointer;
  transition: background-color 0.15s ease, border-color 0.15s ease, color 0.15s ease;
}
.dup-chip.active {
  background: color-mix(in srgb, var(--accent-primary) 12%, var(--fluid-card-top));
  color: var(--accent-primary);
  border-color: color-mix(in srgb, var(--accent-primary) 40%, var(--fluid-card-border));
  font-weight: 600;
}
.dup-group-list {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.dup-group-enter-active,
.dup-group-leave-active,
.dup-group-move {
  transition: opacity 0.24s ease, transform 0.24s cubic-bezier(0.22, 1, 0.36, 1);
}
.dup-group-enter-from,
.dup-group-leave-to {
  opacity: 0;
  transform: translate3d(0, 6px, 0);
}
.dup-group-leave-active {
  position: absolute;
  left: 0;
  right: 0;
  pointer-events: none;
}
.dup-sticky-action-bar {
  position: sticky;
  bottom: 0;
  z-index: 5;
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 10px;
  padding: 10px 14px;
  border-radius: 12px;
  border: 1px solid color-mix(in srgb, var(--accent-primary) 26%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--surface-elevated, var(--fluid-card-fill)) 94%, transparent);
  -webkit-backdrop-filter: blur(18px) saturate(145%);
  backdrop-filter: blur(18px) saturate(145%);
  box-shadow: var(--fluid-card-shadow);
}
.dup-sticky-summary {
  display: flex;
  align-items: baseline;
  flex-wrap: wrap;
  gap: 4px 10px;
  font-size: 12.5px;
  color: var(--text-primary);
  font-variant-numeric: tabular-nums;
}
.dup-sticky-summary small {
  font-size: 12px;
  color: var(--text-secondary);
}
.dup-footer-note {
  display: flex;
  align-items: center;
  gap: 6px;
  padding-top: 6px;
  border-top: 1px solid var(--fluid-divider, var(--fluid-card-border));
  font-size: 12px;
  color: var(--text-secondary);
}
.dup-footer-note svg {
  flex-shrink: 0;
}
@media (prefers-reduced-transparency: reduce) {
  .dup-sticky-action-bar {
    -webkit-backdrop-filter: none;
    backdrop-filter: none;
    background: var(--surface-elevated, var(--fluid-card-fill));
  }
}
@media (prefers-reduced-motion: reduce) {
  .dup-chip,
  .dup-group-enter-active,
  .dup-group-leave-active,
  .dup-group-move {
    transition: none;
  }
}
</style>
