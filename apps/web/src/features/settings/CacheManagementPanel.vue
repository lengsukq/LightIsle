<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { HardDrive, RefreshCw } from "lucide-vue-next";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleCharts from "../../components/ui/IsleCharts.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import { apiRequest } from "../../api/apiClient.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import {
  ISLE_WEB_CACHE_CATEGORIES,
  clearLocalCache,
  formatCacheBytes,
  inspectLocalCache,
  useIsleCache,
  type IsleServerCacheBucket,
  type IsleServerCacheStatus,
  type IsleWebCacheCategory,
  type IsleWebCacheReport,
} from "./useIsleCache.ts";

const props = defineProps<{
  isAdmin?: boolean;
  active?: boolean;
}>();

const { cacheEpochVersion } = useIsleCache();

const localReport = ref<IsleWebCacheReport | null>(null);
const serverStatus = ref<IsleServerCacheStatus | null>(null);
const serverStatusError = ref("");
const loading = ref(false);
const clearingLocal = ref(false);
const clearingServer = ref(false);
const notice = ref("");
const noticeError = ref(false);
const noticeScope = ref<"local" | "server">("local");
const lastUpdatedAt = ref(0);

const updatedLabel = computed(() =>
  lastUpdatedAt.value ? "更新于 " + formatDateTime(lastUpdatedAt.value).replace(/^.*?\s/, "") : "",
);

function catBytes(id: IsleWebCacheCategory): number {
  return localReport.value?.categories?.[id]?.usedBytes || 0;
}

function catCount(id: IsleWebCacheCategory): number {
  return localReport.value?.categories?.[id]?.entryCount || 0;
}

const hasLocalCache = computed(
  () => (localReport.value?.totalBytes || 0) > 0 || (localReport.value?.totalEntries || 0) > 0,
);

const hasServerCache = computed(() => {
  if (!serverStatus.value) return false;
  return (
    serverStatus.value.thumbnails.usedBytes > 0 ||
    serverStatus.value.thumbnails.entryCount > 0 ||
    serverStatus.value.mapTiles.usedBytes > 0 ||
    serverStatus.value.mapTiles.entryCount > 0
  );
});

async function refreshStats() {
  loading.value = true;
  try {
    localReport.value = await inspectLocalCache();
  } catch {
    // Ignore local inspection error
  }
  serverStatusError.value = "";
  if (!props.isAdmin) {
    serverStatus.value = null;
    lastUpdatedAt.value = Date.now();
    loading.value = false;
    return;
  }
  try {
    const data = await apiRequest<{
      thumbnails?: Partial<IsleServerCacheBucket>;
      mapTiles?: Partial<IsleServerCacheBucket>;
    }>("/api/v2/cache/status");
    serverStatus.value = {
      thumbnails: {
        usedBytes: Number(data?.thumbnails?.usedBytes) || 0,
        maxBytes: Number(data?.thumbnails?.maxBytes) || 0,
        entryCount: Number(data?.thumbnails?.entryCount) || 0,
      },
      mapTiles: {
        usedBytes: Number(data?.mapTiles?.usedBytes) || 0,
        maxBytes: Number(data?.mapTiles?.maxBytes) || 0,
        entryCount: Number(data?.mapTiles?.entryCount) || 0,
      },
    };
  } catch (err) {
    serverStatusError.value = `服务端缓存统计暂时无法读取：${describeUserFacingError(err)}`;
  } finally {
    lastUpdatedAt.value = Date.now();
    loading.value = false;
  }
}

async function handleClearLocal(categories: IsleWebCacheCategory[]) {
  if (!categories.length || clearingLocal.value) return;
  clearingLocal.value = true;
  noticeScope.value = "local";
  notice.value = "";
  noticeError.value = false;
  try {
    await clearLocalCache(categories);
    await refreshStats();
    const labels =
      categories.length === ISLE_WEB_CACHE_CATEGORIES.length
        ? "全部可回收本地缓存"
        : ISLE_WEB_CACHE_CATEGORIES.filter((c) => categories.includes(c.id))
            .map((c) => c.label)
            .join("、");
    notice.value = `已清理${labels}。`;
    noticeError.value = false;
  } catch (err) {
    notice.value = `清理浏览器缓存失败：${describeUserFacingError(err)}`;
    noticeError.value = true;
  } finally {
    clearingLocal.value = false;
  }
}

async function handleClearServer(categories: string[], label: string) {
  if (clearingServer.value) return;
  clearingServer.value = true;
  noticeScope.value = "server";
  notice.value = "";
  noticeError.value = false;
  try {
    const payload = await apiRequest<{ freedBytes?: number; removedEntries?: number }>(
      "/api/v2/admin/cache/clear",
      { method: "POST", json: { categories } },
    );
    await refreshStats();
    const freed = formatCacheBytes(Number(payload?.freedBytes) || 0);
    const removed = Number(payload?.removedEntries) || 0;
    notice.value = `已清理服务端${label}（释放 ${freed}，共 ${removed} 项）。`;
    noticeError.value = false;
  } catch (err) {
    notice.value = `清理服务端缓存失败：${describeUserFacingError(err)}`;
    noticeError.value = true;
  } finally {
    clearingServer.value = false;
  }
}

const cacheChartSegments = computed(() =>
  ISLE_WEB_CACHE_CATEGORIES.map((meta) => {
    const used = catBytes(meta.id);
    return {
      key: meta.id,
      label: meta.label,
      value: used,
      color: meta.color,
      displayValue: formatCacheBytes(used),
      hint: `${meta.label} · ${catCount(meta.id)} 项`,
    };
  }),
);

onMounted(() => {
  void refreshStats();
});

watch(
  () => props.active,
  (isActive) => {
    if (isActive) void refreshStats();
  },
);

watch(cacheEpochVersion, () => {
  void refreshStats();
});
</script>

<template>
  <IsleCard
    class="cache-mgmt-panel"
    data-testid="cache-management-panel"
    title="缓存与本地存储管理"
    subtitle="系统自动缓存缩略图、海报与地图瓦片以加速浏览；清理缓存绝不会删除原片或文件。"
  >
    <template #icon><HardDrive :size="18" /></template>
    <template #actions>
      <span v-if="updatedLabel" class="cache-updated-at">{{ updatedLabel }}</span>
      <IsleHelpButton
        title="缓存加速与原片安全"
        :items="[
          { title: '清理缓存不删原片', body: '系统会自动缓存缩略图、海报、地图瓦片与页面状态以加速浏览；清理浏览器或服务端派生缓存绝不会删除任何原始照片、视频或文件。' },
        ]"
      />
      <IsleButton
        variant="ghost"
        size="sm"
        :loading="loading"
        aria-label="刷新缓存统计"
        title="刷新缓存统计"
        @click="refreshStats"
      >
        <template #icon><RefreshCw :size="14" /></template>
      </IsleButton>
    </template>

    <div class="cache-storage-summary" aria-label="浏览器缓存分类占比">
      <div class="cache-storage-head">
        <span class="cache-storage-title">浏览器本地缓存占用</span>
        <strong class="cache-storage-total">
          {{ formatCacheBytes(localReport?.totalBytes || 0) }}
          <span>· {{ localReport?.totalEntries || 0 }} 项</span>
        </strong>
      </div>
      <IsleCharts
        kind="segmented"
        :segments="cacheChartSegments"
        :total="localReport?.totalBytes || 0"
        :bar-height="11"
        aria-label="浏览器缓存 4 分类占比条"
      />
    </div>

    <IsleGroupedList
      title="浏览器本地缓存分类"
      subtitle="按类别查看占用空间，可单独或一键清理"
      variant="item"
      flush
    >
      <template #actions>
        <IsleButton
          variant="primary"
          size="sm"
          :disabled="clearingLocal || !hasLocalCache"
          :loading="clearingLocal"
          data-testid="clear-all-local-cache"
          @click="handleClearLocal(ISLE_WEB_CACHE_CATEGORIES.map((item) => item.id))"
        >
          {{ clearingLocal ? "正在清理…" : "清理全部可回收缓存" }}
        </IsleButton>
      </template>

      <div class="cache-grouped-rows">
        <div
          v-for="meta in ISLE_WEB_CACHE_CATEGORIES"
          :key="meta.id"
          class="cache-category-row"
        >
          <div class="cache-category-lead">
            <span class="cache-dot" :class="`is-${meta.id}`" aria-hidden="true" />
            <div class="cache-category-text">
              <strong>{{ meta.label }}</strong>
              <small>{{ meta.subtitle }}</small>
            </div>
          </div>
          <div class="cache-row-right">
            <div class="cache-size-metric">
              <strong>{{ formatCacheBytes(catBytes(meta.id)) }}</strong>
              <span class="cache-size-count">{{ catCount(meta.id) }} 项</span>
            </div>
            <IsleButton
              variant="glass"
              size="sm"
              :disabled="clearingLocal || (catBytes(meta.id) === 0 && catCount(meta.id) === 0)"
              :data-testid="`clear-local-${meta.id}`"
              @click="handleClearLocal([meta.id])"
            >
              清理
            </IsleButton>
          </div>
        </div>
      </div>

      <template v-if="notice && noticeScope === 'local'" #footnote>
        <IsleBanner :type="noticeError ? 'error' : 'success'" compact role="status">{{ notice }}</IsleBanner>
      </template>
    </IsleGroupedList>

    <IsleBanner v-if="serverStatusError" type="warning" compact :message="serverStatusError" />

    <IsleGroupedList
      v-if="serverStatus"
      title="NAS 服务端派生缓存"
      subtitle="全家设备共享加速 · 仅清理缩略图与瓦片副本，不影响原片"
      variant="item"
      flush
    >
      <template #actions>
        <IsleButton
          v-if="isAdmin"
          variant="glass"
          size="sm"
          :disabled="clearingServer || !hasServerCache"
          :loading="clearingServer"
          data-testid="clear-server-all"
          @click="handleClearServer(['all'], '全部派生缓存')"
        >
          {{ clearingServer ? "正在清理…" : "清理全部服务端缓存" }}
        </IsleButton>
      </template>

      <div class="cache-grouped-rows">
        <div class="cache-category-row">
          <div class="cache-category-lead">
            <span class="cache-dot is-thumbnails" aria-hidden="true" />
            <div class="cache-category-text">
              <strong>服务端缩略图与海报磁盘缓存</strong>
              <small>所有家庭设备共用，清理后按需重新生成</small>
            </div>
          </div>
          <div class="cache-row-right">
            <div class="cache-size-metric">
              <strong>
                {{ formatCacheBytes(serverStatus.thumbnails.usedBytes) }}
                <template v-if="serverStatus.thumbnails.maxBytes > 0">
                  / {{ formatCacheBytes(serverStatus.thumbnails.maxBytes) }}
                </template>
              </strong>
              <span class="cache-size-count">{{ serverStatus.thumbnails.entryCount }} 项</span>
            </div>
            <IsleButton
              v-if="isAdmin"
              variant="glass"
              size="sm"
              :disabled="clearingServer || (serverStatus.thumbnails.usedBytes === 0 && serverStatus.thumbnails.entryCount === 0)"
              data-testid="clear-server-thumbnails"
              @click="handleClearServer(['thumbnails'], '缩略图缓存')"
            >
              清理
            </IsleButton>
          </div>
        </div>

        <div class="cache-category-row">
          <div class="cache-category-lead">
            <span class="cache-dot is-map_tiles" aria-hidden="true" />
            <div class="cache-category-text">
              <strong>服务端天地图瓦片代理缓存</strong>
              <small>减少足迹地图重复拉取外网瓦片流量</small>
            </div>
          </div>
          <div class="cache-row-right">
            <div class="cache-size-metric">
              <strong>
                {{ formatCacheBytes(serverStatus.mapTiles.usedBytes) }}
                <template v-if="serverStatus.mapTiles.maxBytes > 0">
                  / {{ formatCacheBytes(serverStatus.mapTiles.maxBytes) }}
                </template>
              </strong>
              <span class="cache-size-count">{{ serverStatus.mapTiles.entryCount }} 项</span>
            </div>
            <IsleButton
              v-if="isAdmin"
              variant="glass"
              size="sm"
              :disabled="clearingServer || (serverStatus.mapTiles.usedBytes === 0 && serverStatus.mapTiles.entryCount === 0)"
              data-testid="clear-server-map-tiles"
              @click="handleClearServer(['map_tiles'], '地图瓦片缓存')"
            >
              清理
            </IsleButton>
          </div>
        </div>
      </div>

      <template v-if="notice && noticeScope === 'server'" #footnote>
        <IsleBanner :type="noticeError ? 'error' : 'success'" compact role="status">{{ notice }}</IsleBanner>
      </template>
    </IsleGroupedList>
  </IsleCard>
</template>

<style scoped>
.cache-mgmt-panel :deep(.isle-card-body) {
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.cache-updated-at {
  font-size: 11.5px;
  color: var(--text-tertiary);
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.cache-storage-summary {
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 13px 16px;
  border-radius: 14px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
}

.cache-storage-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
}

.cache-storage-title {
  font-size: 13px;
  font-weight: 650;
  color: var(--text-primary);
}

.cache-storage-total {
  font-size: 15px;
  font-weight: 700;
  color: var(--text-primary);
  font-variant-numeric: tabular-nums;
}

.cache-storage-total span {
  font-size: 12px;
  font-weight: 500;
  color: var(--text-secondary);
}

.cache-grouped-rows {
  display: flex;
  flex-direction: column;
}

.cache-category-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 12px 16px;
  flex-wrap: wrap;
}

.cache-category-row + .cache-category-row {
  border-top: 1px solid var(--fluid-divider, rgba(20, 19, 17, 0.06));
}

.cache-category-lead {
  display: flex;
  align-items: center;
  gap: 11px;
  min-width: 0;
  flex: 1 1 220px;
}

.cache-dot {
  width: 10px;
  height: 10px;
  border-radius: 999px;
  flex-shrink: 0;
}

.cache-dot.is-thumbnails {
  background: #007aff;
}
.cache-dot.is-posters {
  background: #af52de;
}
.cache-dot.is-map_tiles {
  background: #10b981;
}
.cache-dot.is-metadata {
  background: #ff9500;
}

.cache-category-text {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
  flex: 1;
  overflow-wrap: anywhere;
}

.cache-category-text strong {
  font-size: 13px;
  font-weight: 620;
  color: var(--text-primary);
}

.cache-category-text small {
  font-size: 12px;
  color: var(--text-secondary);
  line-height: 1.4;
}

.cache-row-right {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-shrink: 0;
}

.cache-size-metric {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 1px;
  font-variant-numeric: tabular-nums;
}

.cache-size-metric strong {
  font-size: 13px;
  font-weight: 650;
  color: var(--text-primary);
}

.cache-size-count {
  font-size: 11.5px;
  color: var(--text-tertiary);
}
</style>
