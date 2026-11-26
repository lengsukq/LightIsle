<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { HardDrive, RefreshCcw } from "lucide-vue-next";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleCharts from "../../components/ui/IsleCharts.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import {
  type Volume,
  formatDiskSize as formatSize,
  isSystemVolume,
  diskUsageSegments,
} from "./diskManagementSupport.ts";

type RootMountInfo = {
  rootID: string;
  name: string;
  volumeMount?: string;
};

const volumes = ref<Volume[]>([]);
const rootsByMount = ref<Record<string, string[]>>({});
const rootsLoaded = ref(false);
const loading = ref(false);
const error = ref("");
let controller = new AbortController();
let disposed = false;

const primaryVolumes = computed(() => volumes.value.filter((v) => !isSystemVolume(v)));
const hasMountCorrelation = computed(
  () => rootsLoaded.value && Object.keys(rootsByMount.value).length > 0,
);
const unregisteredVolumes = computed(() =>
  hasMountCorrelation.value
    ? primaryVolumes.value.filter((v) => !rootsByMount.value[v.mount]?.length)
    : primaryVolumes.value,
);
const registeredVolumes = computed(() =>
  hasMountCorrelation.value
    ? primaryVolumes.value.filter((v) => Boolean(rootsByMount.value[v.mount]?.length))
    : [],
);

async function fetchRegisteredMounts(signal: AbortSignal) {
  try {
    const res = await apiFetch("/api/v2/roots", { signal });
    if (!res.ok) return;
    const data = (await res.json()) as { roots?: RootMountInfo[] };
    const map: Record<string, string[]> = {};
    for (const root of data.roots ?? []) {
      if (!root.volumeMount) continue;
      if (!map[root.volumeMount]) map[root.volumeMount] = [];
      map[root.volumeMount]!.push(root.name);
    }
    if (!disposed) {
      rootsByMount.value = map;
      rootsLoaded.value = true;
    }
  } catch {
    // Single-root servers or transient probe failures fall back to displaying primary volumes.
  }
}

async function refresh() {
  if (loading.value) return;
  controller.abort();
  controller = new AbortController();
  loading.value = true;
  error.value = "";
  try {
    const mountsPromise = fetchRegisteredMounts(controller.signal);
    const response = await apiFetch("/api/v2/system", { signal: controller.signal });
    if (!response.ok) throw await readApiFailure(response);
    const data = (await response.json()) as { volumes?: Volume[] };
    await mountsPromise;
    if (!disposed) {
      volumes.value = Array.isArray(data.volumes) ? data.volumes : [];
    }
  } catch (e) {
    if (!disposed && !(e instanceof Error && e.name === "AbortError")) {
      error.value = describeUserFacingError(e);
    }
  } finally {
    if (!disposed) loading.value = false;
  }
}

onMounted(() => void refresh());
onUnmounted(() => {
  disposed = true;
  controller.abort();
});
</script>

<template>
  <IsleCard
    class="disk-panel"
    aria-label="存储卷状态概览"
    title="Mac 物理存储卷"
    subtitle="展示尚未接入轻屿的挂载卷；已接入存储池的容量分布已统一汇总于上方「存储目录管理」。"
  >
    <template #icon><HardDrive :size="18" aria-hidden="true" /></template>
    <template #actions>
      <div class="disk-actions">
        <IsleBadge v-if="primaryVolumes.length" variant="accent" size="sm" class="disk-count-badge disk-tabular">
          {{ primaryVolumes.length }} 个在线卷
        </IsleBadge>
        <button
          type="button"
          class="storage-header-refresh"
          :disabled="loading"
          aria-label="刷新存储卷"
          title="刷新存储卷"
          @click="refresh"
        >
          <RefreshCcw :size="14" :class="{ 'is-spinning': loading }" />
        </button>
      </div>
    </template>

    <IsleBanner v-if="error" type="error" compact role="alert">{{ error }}</IsleBanner>

    <p v-if="loading && !primaryVolumes.length && !error" class="disk-loading-hint" role="status">
      正在读取存储卷状态…
    </p>

    <IsleEmpty
      v-else-if="!primaryVolumes.length && !error"
      compact
      description="暂未检测到可用存储卷。请确认硬盘已连接，或在 Mac 管理端「存储 → 磁盘设备」检查挂载状态。"
    />

    <div v-else-if="primaryVolumes.length" class="disk-body">
      <IsleGroupedList
        v-if="unregisteredVolumes.length"
        :title="registeredVolumes.length ? '未接入轻屿的存储卷' : undefined"
        :subtitle="registeredVolumes.length ? '如需作为 NAS 存储池使用，请在 Mac 管理端「存储 → 存储位置」添加目录' : undefined"
        variant="item"
        flush
      >
        <TransitionGroup name="isle-list" tag="div" class="disk-volume-list">
          <article v-for="v in unregisteredVolumes" :key="v.mount" class="disk-volume-row">
            <div class="disk-volume-head">
              <div class="disk-volume-title">
                <strong class="disk-volume-name">{{ v.name || v.mount }}</strong>
                <IsleBadge v-if="registeredVolumes.length" variant="neutral" size="sm">未接入轻屿</IsleBadge>
              </div>
              <IsleBadge :variant="v.readOnly ? 'warning' : 'online'" size="sm" dot>
                {{ v.readOnly ? "只读" : "在线" }}
              </IsleBadge>
            </div>
            <p class="disk-volume-meta disk-tabular">
              {{ v.filesystem || "未知文件系统" }} · {{ v.mount }} · 可用 {{ formatSize(v.free) }} / 总计 {{ formatSize(v.total) }}
            </p>
            <IsleCharts
              v-if="v.total > 0"
              kind="segmented"
              :segments="diskUsageSegments(v.total, v.free)"
              :bar-height="8"
              :show-legend="false"
            />
          </article>
        </TransitionGroup>
      </IsleGroupedList>

      <p v-else-if="registeredVolumes.length" class="disk-dedup-note">
        当前检测到的全部可用磁盘卷均已接入上方「存储目录管理」，未发现待接入的闲置存储卷。
      </p>

      <IsleDisclosure
        v-if="registeredVolumes.length"
        variant="inline"
        :title="`已接入物理卷硬件参数（${registeredVolumes.length} 个）`"
        subtitle="查看设备节点、文件系统与挂载路径（挂卸载与 SMART 检测请在 Mac 端操作）"
      >
        <IsleGroupedList variant="item" flush>
          <div v-for="v in registeredVolumes" :key="v.mount" class="disk-hardware-row">
            <div class="disk-hardware-main">
              <strong class="disk-volume-name">{{ v.name || v.mount }}</strong>
              <span class="disk-hardware-meta disk-tabular">
                {{ v.device || "未知设备" }} · {{ v.filesystem || "未知文件系统" }} · {{ v.mount }}
                <template v-if="rootsByMount[v.mount]?.length">
                  · 关联目录：{{ rootsByMount[v.mount]!.join(" / ") }}
                </template>
              </span>
            </div>
            <IsleBadge :variant="v.readOnly ? 'warning' : 'online'" size="sm" dot>
              {{ v.readOnly ? "只读" : "在线" }}
            </IsleBadge>
          </div>
        </IsleGroupedList>
      </IsleDisclosure>
    </div>
  </IsleCard>
</template>

<style scoped>
.disk-panel {
  min-width: 0;
}
.disk-body {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.disk-loading-hint,
.disk-dedup-note {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary);
}
.disk-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.disk-count-badge {
  flex-shrink: 0;
}
.disk-tabular {
  font-variant-numeric: tabular-nums;
}
.disk-volume-list {
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.disk-volume-row {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
  padding: 12px 16px;
}
.disk-volume-row + .disk-volume-row {
  border-top: 1px solid var(--fluid-divider, rgba(20, 19, 17, 0.06));
}
.disk-volume-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  min-width: 0;
  flex-wrap: wrap;
}
.disk-volume-title {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  min-width: 0;
  flex-wrap: wrap;
}
.disk-volume-name {
  font-size: 13.5px;
  font-weight: 620;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.disk-volume-meta {
  margin: 0;
  font-size: 12px;
  color: var(--text-secondary);
  overflow-wrap: anywhere;
}
.disk-hardware-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
  padding: 10px 14px;
}
.disk-hardware-main {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
  flex: 1 1 200px;
}
.disk-hardware-meta {
  font-size: 11.5px;
  color: var(--text-secondary);
  overflow-wrap: anywhere;
}
</style>
