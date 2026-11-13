<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import { CopyCheck, Search, Trash2, ShieldAlert, XCircle } from "lucide-vue-next";
import IsleCard from "./IsleCard.vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleBadge from "./IsleBadge.vue";
import AppleSelect from "./AppleSelect.vue";
import IsleCharts from "./IsleCharts.vue";
import { ISLE_CHART_COLORS } from "./isleChartsMath.ts";
import { createScopedRootApi } from "./apiClient.ts";
import { rootApiPath } from "./rootApi.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { formatBytes } from "./photoPresentation.ts";
import { requestConfirm } from "./useConfirmDialog.ts";
import {
  chooseDuplicateKeepPath,
  type DuplicateFileGroup,
  type DuplicateKeepStrategy,
} from "./usePhotoAISearchAndPeople.ts";

interface RootOption {
  rootID: string;
  name: string;
  generation: number;
  online: boolean;
  isDefault?: boolean;
}

interface DuplicateScanProgress {
  phase: string;
  scannedFiles: number;
  candidateFiles?: number;
  hashedFiles?: number;
  currentPath?: string;
}

interface DuplicateScanResponse {
  running: boolean;
  progress?: DuplicateScanProgress;
  lastDone?: number;
  lastError?: string;
  quotaReleaseNote?: string;
  result?: {
    minSizeBytes: number;
    scannedFiles: number;
    totalGroups: number;
    totalReclaimableBytes: number;
    totalReclaimablePhysicalBytes: number;
    truncated?: boolean;
    groups: DuplicateFileGroup[];
  };
}

const props = withDefaults(
  defineProps<{
    admin: boolean;
    roots?: RootOption[];
    fixedRootId?: string;
    fixedRootGeneration?: number;
  }>(),
  {
    roots: () => [],
    fixedRootId: undefined,
    fixedRootGeneration: undefined,
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

const minSizeOptions = [
  { value: 1, label: "大于等于 1 MB" },
  { value: 10, label: "大于等于 10 MB" },
  { value: 100, label: "大于等于 100 MB" },
];

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

const dedupeSavingsChart = computed(() => {
  const result = snapshot.value?.result;
  if (!result || !result.groups.length) return null;
  const keepBytes = result.groups.reduce((sum, g) => sum + Math.max(0, g.size), 0);
  const reclaimableBytes = Math.max(0, result.totalReclaimableBytes);
  const totalBytes = keepBytes + reclaimableBytes;
  if (totalBytes <= 0) return null;
  const savedPercent = Math.round((reclaimableBytes / totalBytes) * 100);
  return {
    totalBytes,
    savedPercent,
    segments: [
      { key: "keep", label: "保留原件体积", value: keepBytes, color: ISLE_CHART_COLORS.blue, displayValue: formatBytes(keepBytes) },
      { key: "reclaim", label: "可释放冗余空间", value: reclaimableBytes, color: ISLE_CHART_COLORS.green, displayValue: formatBytes(reclaimableBytes) },
    ],
  };
});

const progressLabel = computed(() => {
  const p = snapshot.value?.progress;
  if (!p) return "正在准备扫描授权目录…";
  switch (p.phase) {
    case "walking":
      return `正在遍历目录 · 已发现 ${p.scannedFiles} 个候选文件`;
    case "sampling":
      return `正在比对首尾采样指纹 · 候选 ${p.candidateFiles ?? 0} 个文件`;
    case "hashing":
      return `正在核验完整 SHA-256 指纹 · 已完成 ${p.hashedFiles ?? 0}/${p.candidateFiles ?? 0}`;
    default:
      return `正在核对重复文件指纹（已扫描 ${p.scannedFiles} 项）…`;
  }
});

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
  } catch {
    stopPolling();
  }
}

async function loadCached() {
  if (props.fixedRootId === undefined && props.roots.length > 0 && !activeRootId.value) return;
  try {
    const res = await api<DuplicateScanResponse>(endpoint("/api/v2/files/duplicates"));
    handleSnapshot(res, true);
  } catch {
    // Quiet initial status fetch before user triggers a scan.
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
  <IsleCard
    title="重复大文件扫描与空间清理"
    :subtitle="admin ? '支持按文件体积、采样指纹与完整 SHA-256 核对重复文件，并自动识别 macOS APFS 写时复制克隆块。' : '仅扫描你有权访问的个人目录与共享空间，清理时强制保留至少 1 份原件并移入回收站。'"
  >
    <template #icon>
      <div class="block-header-icon"><CopyCheck :size="18" /></div>
    </template>
    <template #actions>
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
          <XCircle :size="14" /><span>取消扫描</span>
        </IsleButton>
        <IsleButton variant="primary" size="sm" :loading="isRunning" @click="runScan">
          <Search :size="14" /><span>{{ isRunning ? "后台核对中…" : "开始扫描重复文件" }}</span>
        </IsleButton>
      </div>
    </template>

    <IsleBanner v-if="error" type="error" compact dismissible :message="error" @close="error = ''" />
    <IsleBanner v-if="success" type="success" compact dismissible :message="success" @close="success = ''" />

    <div v-if="isRunning" class="dup-progress-box" role="status" aria-live="polite">
      <strong>{{ progressLabel }}</strong>
      <small v-if="snapshot?.progress?.currentPath" class="dup-progress-path">
        当前：{{ snapshot.progress.currentPath }}
      </small>
    </div>

    <div v-if="!snapshot?.result && !isRunning" class="dup-empty">
      点击右上角「开始扫描重复文件」即可在你授权访问的目录内查找完全相同的重复大文件，释放个人配额与磁盘空间。
    </div>

    <template v-else-if="snapshot?.result">
      <div class="dup-summary-bar">
        <div v-if="dedupeSavingsChart" class="dup-chart-overview">
          <IsleCharts
            kind="donut"
            :size="56"
            :stroke-width="6"
            :segments="dedupeSavingsChart.segments"
            :total="dedupeSavingsChart.totalBytes"
            :show-legend="false"
            :center-label="`省 ${dedupeSavingsChart.savedPercent}%`"
            center-sublabel="冗余占比"
            :aria-label="`可释放冗余空间占重复集合的 ${dedupeSavingsChart.savedPercent}%`"
          />
          <IsleCharts
            kind="segmented"
            :segments="dedupeSavingsChart.segments"
            :total="dedupeSavingsChart.totalBytes"
            :bar-height="10"
            compact-legend
            aria-label="保留原件体积与可释放冗余空间对比"
          />
        </div>
        <div class="dup-summary-controls">
          <div class="dup-metrics">
            <span>已检查 <strong>{{ snapshot.result.scannedFiles }}</strong> 个文件</span>
            <span>发现 <strong>{{ snapshot.result.totalGroups }}</strong> 组重复</span>
            <span>可释放逻辑配额 <strong>{{ formatBytes(snapshot.result.totalReclaimableBytes) }}</strong></span>
            <span v-if="snapshot.result.totalReclaimablePhysicalBytes !== snapshot.result.totalReclaimableBytes">
              物理磁盘可释放 <strong>{{ formatBytes(snapshot.result.totalReclaimablePhysicalBytes) }}</strong>
            </span>
          </div>
          <div v-if="snapshot.result.groups.length" class="dup-strategy-bar">
            <span class="dup-strategy-label">保留策略：</span>
            <button type="button" class="dup-chip" :class="{ active: strategy === 'shortest_path' }" @click="setStrategy('shortest_path')">保留最短路径</button>
            <button type="button" class="dup-chip" :class="{ active: strategy === 'oldest' }" @click="setStrategy('oldest')">保留最早文件</button>
            <button type="button" class="dup-chip" :class="{ active: strategy === 'newest' }" @click="setStrategy('newest')">保留最新修改</button>
            <IsleButton
              variant="danger"
              size="sm"
              :loading="trashing"
              :disabled="totalSelectedTrashCount === 0 || isRunning"
              @click="trashSelectedDuplicates"
            >
              <Trash2 :size="14" /><span>移入回收站 ({{ totalSelectedTrashCount }})</span>
            </IsleButton>
          </div>
        </div>
      </div>

      <div v-if="!snapshot.result.groups.length" class="dup-empty">
        未发现体积达到阈值的重复文件，当前存储空间非常整洁。
      </div>

      <div v-else class="dup-group-list">
        <div v-for="group in snapshot.result.groups" :key="group.groupId" class="dup-group-card">
          <div class="dup-group-head">
            <div>
              <strong>单文件 {{ formatBytes(group.size) }} · 共 {{ group.count }} 份相同副本</strong>
              <IsleBadge v-if="group.allApfsClones" variant="accent" size="sm" style="margin-left:8px">
                APFS 零拷贝克隆（共享物理块）
              </IsleBadge>
            </div>
            <small>可清理 {{ formatBytes(group.reclaimableBytes) }}</small>
          </div>

          <div class="dup-item-rows">
            <label
              v-for="item in group.items"
              :key="item.path"
              class="dup-item-row"
              :class="{ 'is-keep': !(checkedTrash[group.groupId]?.has(item.path)) }"
            >
              <input
                type="checkbox"
                :checked="checkedTrash[group.groupId]?.has(item.path) ?? false"
                :disabled="!item.canTrash"
                @change="toggleTrashPath(group, item.path, item.canTrash)"
              />
              <span class="dup-item-path" :title="item.path">{{ item.path }}</span>
              <span class="dup-item-tags">
                <IsleBadge v-if="item.isApfsClone" variant="neutral" size="sm">APFS 克隆</IsleBadge>
                <IsleBadge v-if="!item.canTrash" variant="warning" size="sm">只读目录</IsleBadge>
                <IsleBadge v-else-if="!(checkedTrash[group.groupId]?.has(item.path))" variant="online" size="sm">保留此份</IsleBadge>
                <IsleBadge v-else variant="danger" size="sm">移入回收站</IsleBadge>
              </span>
            </label>
          </div>
        </div>
      </div>
    </template>

    <template #footer>
      <div class="dup-footer-note">
        <ShieldAlert :size="14" />
        <span>{{ snapshot?.quotaReleaseNote ?? "移入回收站后可随时恢复；个人空间配额将在从回收站永久删除后释放。" }}</span>
      </div>
    </template>
  </IsleCard>
</template>

<style scoped>
.dup-toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
}
.dup-progress-box {
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 10px 12px;
  margin-bottom: 12px;
  border-radius: 10px;
  background: rgba(0, 113, 227, 0.08);
  font-size: 13px;
}
.dup-progress-path {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 11.5px;
  color: var(--text-secondary, #6e6e73);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.dup-empty {
  padding: 18px 4px;
  font-size: 13px;
  color: var(--text-secondary, #6e6e73);
}
.dup-summary-bar {
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 12px 14px;
  border-radius: 12px;
  background: rgba(120, 120, 128, 0.07);
  margin-bottom: 12px;
  font-size: 13px;
}
.dup-chart-overview {
  display: flex;
  align-items: center;
  gap: 14px;
  padding-bottom: 10px;
  border-bottom: 1px solid color-mix(in srgb, var(--border-subtle, rgba(142, 142, 147, 0.25)) 60%, transparent);
}
.dup-summary-controls {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}
.dup-metrics {
  display: flex;
  flex-wrap: wrap;
  gap: 14px;
}
.dup-strategy-bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
}
.dup-strategy-label {
  font-size: 12px;
  opacity: 0.75;
}
.dup-chip {
  padding: 4px 10px;
  border-radius: 999px;
  font-size: 12px;
  border: 1px solid var(--border-subtle, rgba(0, 0, 0, 0.12));
  background: transparent;
  color: inherit;
  cursor: pointer;
}
.dup-chip.active {
  background: var(--accent, #0071e3);
  color: #fff;
  border-color: transparent;
}
.dup-group-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.dup-group-card {
  padding: 12px 14px;
  border-radius: 12px;
  border: 1px solid var(--border-subtle, rgba(0, 0, 0, 0.08));
}
.dup-group-head {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  align-items: center;
  gap: 8px;
  margin-bottom: 8px;
  font-size: 13px;
}
.dup-item-rows {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.dup-item-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 8px;
  border-radius: 8px;
  background: rgba(120, 120, 128, 0.05);
  font-size: 12px;
  cursor: pointer;
}
.dup-item-row.is-keep {
  background: rgba(52, 199, 89, 0.08);
}
.dup-item-path {
  flex: 1;
  min-width: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.dup-item-tags {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.dup-footer-note {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: var(--text-secondary, #6e6e73);
}
</style>
