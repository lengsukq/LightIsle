<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { HardDrive, RefreshCcw } from "lucide-vue-next";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleCharts from "../../components/ui/IsleCharts.vue";
import {
  type Volume,
  formatDiskSize as formatSize,
  isSystemVolume,
  diskUsageSegments,
} from "./diskManagementSupport.ts";

const volumes = ref<Volume[]>([]);
const loading = ref(false);
const error = ref("");
let controller = new AbortController();
let disposed = false;

const primaryVolumes = computed(() => volumes.value.filter((v) => !isSystemVolume(v)));

async function refresh() {
  if (loading.value) return;
  controller.abort();
  controller = new AbortController();
  loading.value = true;
  error.value = "";
  try {
    const response = await apiFetch("/api/v2/system", { signal: controller.signal });
    if (!response.ok) throw await readApiFailure(response);
    const data = (await response.json()) as { volumes?: Volume[] };
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
    title="Mac 存储卷概览"
    subtitle="查看当前挂载的磁盘容量与在线状态；挂卸载、改名、SMART 健康检测请在 Mac 管理端「存储 → 磁盘设备」操作。"
  >
    <template #icon><HardDrive :size="18" aria-hidden="true" /></template>
    <template #actions>
      <div class="disk-actions">
        <IsleBadge v-if="primaryVolumes.length" variant="accent" size="sm">
          {{ primaryVolumes.length }} 个在线卷
        </IsleBadge>
        <IsleButton variant="glass" size="sm" :loading="loading" @click="refresh">
          <template #icon><RefreshCcw :size="14" /></template>
          {{ loading ? "刷新中…" : "刷新" }}
        </IsleButton>
      </div>
    </template>

    <IsleBanner v-if="error" type="error" compact role="alert">{{ error }}</IsleBanner>

    <IsleEmpty
      v-if="!primaryVolumes.length && !loading && !error"
      compact
      description="暂未检测到可用存储卷。请确认硬盘已连接，或在 Mac 管理端「存储 → 磁盘设备」检查挂载状态。"
    />

    <div v-else class="disk-volume-grid">
      <article v-for="v in primaryVolumes" :key="v.mount" class="disk-volume-card">
        <div class="disk-volume-head">
          <strong class="disk-volume-name">{{ v.name || v.mount }}</strong>
          <IsleBadge :variant="v.readOnly ? 'warning' : 'online'" size="sm" dot>
            {{ v.readOnly ? "只读" : "在线" }}
          </IsleBadge>
        </div>
        <p class="disk-volume-meta">
          {{ v.filesystem || "未知文件系统" }} · 可用 {{ formatSize(v.free) }} / 总计 {{ formatSize(v.total) }}
        </p>
        <IsleCharts
          v-if="v.total > 0"
          kind="segmented"
          :segments="diskUsageSegments(v.total, v.free)"
          :height="8"
          :show-legend="false"
        />
      </article>
    </div>
  </IsleCard>
</template>

<style scoped>
.disk-panel {
  margin-top: 12px;
}
.disk-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.disk-volume-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  gap: 10px;
}
.disk-volume-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 12px 14px;
  border-radius: var(--radius-md, 14px);
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
}
.disk-volume-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.disk-volume-name {
  font-size: 13.5px;
  font-weight: 600;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.disk-volume-meta {
  margin: 0;
  font-size: 12px;
  color: var(--text-secondary);
}
</style>
