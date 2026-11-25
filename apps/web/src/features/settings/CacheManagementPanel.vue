<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import IsleButton from '../../components/ui/IsleButton.vue'
import IsleBanner from '../../components/ui/IsleBanner.vue'
import IsleBadge from '../../components/ui/IsleBadge.vue'
import IsleCharts from '../../components/ui/IsleCharts.vue'
import IsleHelpButton from '../../components/ui/IsleHelpButton.vue'
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
} from './useIsleCache.ts'
import { describeUserFacingError } from '../../api/userFacingError.ts'
import { apiRequest } from '../../api/apiClient.ts'

const props = defineProps<{
  isAdmin?: boolean
  active?: boolean
}>()

const { cacheEpochVersion } = useIsleCache()

const selected = ref<IsleWebCacheCategory[]>(
  ISLE_WEB_CACHE_CATEGORIES.map((c) => c.id),
)
const localReport = ref<IsleWebCacheReport | null>(null)
const serverStatus = ref<IsleServerCacheStatus | null>(null)
const serverStatusError = ref('')
const loading = ref(false)
const clearingLocal = ref(false)
const clearingServer = ref(false)
const notice = ref('')
const noticeError = ref(false)

const allSelected = computed(
  () => selected.value.length === ISLE_WEB_CACHE_CATEGORIES.length,
)

function toggleSelectAll() {
  if (allSelected.value) {
    selected.value = []
  } else {
    selected.value = ISLE_WEB_CACHE_CATEGORIES.map((c) => c.id)
  }
}

function toggleCategory(cat: IsleWebCacheCategory) {
  const idx = selected.value.indexOf(cat)
  if (idx >= 0) {
    selected.value.splice(idx, 1)
  } else {
    selected.value.push(cat)
  }
}

async function refreshStats() {
  loading.value = true
  try {
    localReport.value = await inspectLocalCache()
  } catch {
    // Ignore local inspection error
  }
  serverStatusError.value = ''
  if (!props.isAdmin) {
    serverStatus.value = null
    loading.value = false
    return
  }
  try {
    const data = await apiRequest<{
      thumbnails?: Partial<IsleServerCacheBucket>
      mapTiles?: Partial<IsleServerCacheBucket>
    }>('/api/v2/cache/status')
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
    }
  } catch (err) {
    serverStatusError.value = `服务端缓存统计暂时无法读取：${describeUserFacingError(err)}`
  } finally {
    loading.value = false
  }
}

async function handleClearLocal(categories: IsleWebCacheCategory[]) {
  if (!categories.length || clearingLocal.value) return
  clearingLocal.value = true
  notice.value = ''
  noticeError.value = false
  try {
    await clearLocalCache(categories)
    await refreshStats()
    const labels = ISLE_WEB_CACHE_CATEGORIES.filter((c) =>
      categories.includes(c.id),
    )
      .map((c) => c.label)
      .join('、')
    notice.value = `已清理浏览器缓存：${labels}。`
    noticeError.value = false
  } catch (err) {
    notice.value = `清理浏览器缓存失败：${describeUserFacingError(err)}`
    noticeError.value = true
  } finally {
    clearingLocal.value = false
  }
}

async function handleClearServer(categories: string[], label: string) {
  if (clearingServer.value) return
  clearingServer.value = true
  notice.value = ''
  noticeError.value = false
  try {
    const payload = await apiRequest<{ freedBytes?: number; removedEntries?: number }>(
      '/api/v2/admin/cache/clear',
      {
        method: 'POST',
        json: { categories },
      },
    )
    await refreshStats()
    const freed = formatCacheBytes(Number(payload?.freedBytes) || 0)
    const removed = Number(payload?.removedEntries) || 0
    notice.value = `已清理服务端${label}（释放 ${freed}，共 ${removed} 项）。`
    noticeError.value = false
  } catch (err) {
    notice.value = `清理服务端缓存失败：${describeUserFacingError(err)}`
    noticeError.value = true
  } finally {
    clearingServer.value = false
  }
}

const cacheChartSegments = computed(() =>
  ISLE_WEB_CACHE_CATEGORIES.map((meta) => {
    const used = localReport.value?.categories?.[meta.id]?.usedBytes || 0
    return {
      key: meta.id,
      label: meta.label,
      value: used,
      color: meta.color,
      displayValue: formatCacheBytes(used),
      hint: `${meta.label} · ${localReport.value?.categories?.[meta.id]?.entryCount || 0} 项`,
    }
  }),
)

onMounted(() => {
  void refreshStats()
})

watch(
  () => props.active,
  (isActive) => {
    if (isActive) {
      void refreshStats()
    }
  },
)

watch(cacheEpochVersion, () => {
  void refreshStats()
})
</script>

<template>
  <section class="panel settings-card cache-mgmt-panel" data-testid="cache-management-panel">
    <div class="section-head">
      <div>
        <h3>缓存与本地存储管理</h3>
      </div>
      <div class="row-actions">
        <IsleBadge variant="accent" size="sm">
          浏览器缓存 {{ formatCacheBytes(localReport?.totalBytes || 0) }} ·
          {{ localReport?.totalEntries || 0 }} 项
        </IsleBadge>
        <IsleHelpButton
          title="缓存加速与原片安全"
          :items="[
            { title: '清理缓存不删原片', body: '系统会自动缓存缩略图、海报、地图瓦片与页面状态以加速浏览；清理浏览器或服务端派生缓存绝不会删除任何原始照片、视频或文件。' },
          ]"
        />
        <IsleButton
          variant="glass"
          size="sm"
          :loading="loading"
          @click="refreshStats"
        >
          {{ loading ? '统计中…' : '刷新统计' }}
        </IsleButton>
      </div>
    </div>

    <IsleBanner
      v-if="notice"
      :type="noticeError ? 'error' : 'success'"
      compact
      role="status"
    >
      {{ notice }}
    </IsleBanner>

    <div class="cache-chart-summary" aria-label="浏览器缓存分类占比">
      <div class="cache-donut-block">
        <IsleCharts
          kind="donut"
          :size="56"
          :stroke-width="6"
          :segments="cacheChartSegments"
          :total="localReport?.totalBytes || 0"
          :show-legend="false"
          :center-label="formatCacheBytes(localReport?.totalBytes || 0)"
          aria-label="浏览器缓存总览环形图"
        />
        <div class="cache-donut-meta">
          <span class="cache-donut-kicker">本地总缓存</span>
          <strong class="cache-donut-total">{{ formatCacheBytes(localReport?.totalBytes || 0) }}</strong>
          <small class="muted">{{ localReport?.totalEntries || 0 }} 项记录</small>
        </div>
      </div>
      <IsleCharts
        kind="segmented"
        :segments="cacheChartSegments"
        :total="localReport?.totalBytes || 0"
        :bar-height="8"
        aria-label="浏览器缓存 4 分类占比条"
      />
    </div>

    <div class="cache-subcard">
      <div class="cache-subcard-head">
        <strong>浏览器本地缓存分类</strong>
        <IsleButton variant="glass" size="sm" @click="toggleSelectAll">
          {{ allSelected ? '取消全选' : '全选' }}
        </IsleButton>
      </div>

      <div class="cache-category-list">
        <div
          v-for="meta in ISLE_WEB_CACHE_CATEGORIES"
          :key="meta.id"
          class="cache-category-row"
        >
          <label class="cache-category-label">
            <input
              type="checkbox"
              :checked="selected.includes(meta.id)"
              :data-testid="`cache-check-${meta.id}`"
              @change="toggleCategory(meta.id)"
            />
            <span class="cache-dot-lg" :style="{ background: meta.color }" />
            <span class="cache-category-text">
              <strong>{{ meta.label }}</strong>
              <small class="muted">
                {{
                  formatCacheBytes(
                    localReport?.categories?.[meta.id]?.usedBytes || 0,
                  )
                }}
                · {{ localReport?.categories?.[meta.id]?.entryCount || 0 }} 项 ·
                {{ meta.subtitle }}
              </small>
            </span>
          </label>
          <IsleButton
            variant="glass"
            size="sm"
            :disabled="clearingLocal"
            :data-testid="`clear-local-${meta.id}`"
            @click="handleClearLocal([meta.id])"
          >
            清理
          </IsleButton>
        </div>
      </div>

      <div class="row-actions cache-bulk-actions">
        <IsleButton
          variant="primary"
          size="sm"
          :disabled="clearingLocal || selected.length === 0"
          :loading="clearingLocal"
          data-testid="clear-selected-local-cache"
          @click="handleClearLocal([...selected])"
        >
          {{
            clearingLocal
              ? '正在清理…'
              : `清理所选缓存 (${selected.length})`
          }}
        </IsleButton>
        <IsleButton
          variant="glass"
          size="sm"
          :disabled="clearingLocal"
          data-testid="clear-all-local-cache"
          @click="
            handleClearLocal(ISLE_WEB_CACHE_CATEGORIES.map((item) => item.id))
          "
        >
          一键清空全部浏览器缓存
        </IsleButton>
      </div>
    </div>

    <IsleBanner
      v-if="serverStatusError"
      type="warning"
      compact
      :message="serverStatusError"
    />

    <div v-if="serverStatus" class="cache-subcard">
      <div class="cache-subcard-head">
        <strong>NAS 服务端派生缓存（全家设备共享加速）</strong>
        <span class="muted small-text">仅清理缩略图与瓦片副本，不影响原片</span>
      </div>

      <div class="cache-category-list">
        <div class="cache-category-row">
          <div class="cache-category-text">
            <strong>服务端缩略图与海报磁盘缓存</strong>
            <small class="muted">
              已用 {{ formatCacheBytes(serverStatus.thumbnails.usedBytes) }}
              <template v-if="serverStatus.thumbnails.maxBytes > 0">
                / 上限 {{ formatCacheBytes(serverStatus.thumbnails.maxBytes) }}
              </template>
              · {{ serverStatus.thumbnails.entryCount }} 项
            </small>
          </div>
          <IsleButton
            v-if="isAdmin"
            variant="glass"
            size="sm"
            :disabled="clearingServer"
            data-testid="clear-server-thumbnails"
            @click="handleClearServer(['thumbnails'], '缩略图缓存')"
          >
            清理
          </IsleButton>
        </div>

        <div class="cache-category-row">
          <div class="cache-category-text">
            <strong>服务端天地图瓦片代理缓存</strong>
            <small class="muted">
              已用 {{ formatCacheBytes(serverStatus.mapTiles.usedBytes) }}
              <template v-if="serverStatus.mapTiles.maxBytes > 0">
                / 上限 {{ formatCacheBytes(serverStatus.mapTiles.maxBytes) }}
              </template>
              · {{ serverStatus.mapTiles.entryCount }} 项
            </small>
          </div>
          <IsleButton
            v-if="isAdmin"
            variant="glass"
            size="sm"
            :disabled="clearingServer"
            data-testid="clear-server-map-tiles"
            @click="handleClearServer(['map_tiles'], '地图瓦片缓存')"
          >
            清理
          </IsleButton>
        </div>
      </div>

      <div v-if="isAdmin" class="row-actions cache-bulk-actions">
        <IsleButton
          variant="glass"
          size="sm"
          :disabled="clearingServer"
          :loading="clearingServer"
          data-testid="clear-server-all"
          @click="handleClearServer(['all'], '全部派生缓存')"
        >
          {{ clearingServer ? '正在清理服务端缓存…' : '清空全部服务端派生缓存' }}
        </IsleButton>
      </div>
    </div>
  </section>
</template>

<style scoped>
.cache-mgmt-panel {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 16px 18px;
  border-radius: 18px;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  box-shadow: var(--fluid-card-shadow);
}
.section-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.eyebrow {
  margin: 0 0 2px;
  font-size: 10.5px;
  font-weight: 700;
  letter-spacing: 0.06em;
  color: var(--text-tertiary);
}
.section-head h3 {
  margin: 0;
  font-size: 15.5px;
  font-weight: 680;
  color: var(--text-primary);
}
.row-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.muted {
  color: var(--text-secondary);
  margin: 0;
  line-height: 1.45;
  font-size: 12.5px;
}
.small-text {
  font-size: 11.5px;
}
.cache-chart-summary {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr);
  align-items: center;
  gap: 14px;
  padding: 11px 14px;
  border-radius: 14px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
}
.cache-donut-block {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
}
.cache-donut-meta {
  display: flex;
  flex-direction: column;
  gap: 1px;
  min-width: 0;
}
.cache-donut-kicker {
  font-size: 11px;
  font-weight: 600;
  color: var(--text-secondary);
}
.cache-donut-total {
  font-size: 14.5px;
  font-weight: 700;
  color: var(--text-primary);
  font-variant-numeric: tabular-nums;
}
@media (max-width: 640px) {
  .cache-chart-summary {
    grid-template-columns: 1fr;
    gap: 10px;
  }
}
.cache-dot-lg {
  width: 9px;
  height: 9px;
  border-radius: 999px;
  flex-shrink: 0;
}
.cache-subcard {
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  border-radius: 14px;
  padding: 11px 14px;
  margin-top: 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.cache-subcard-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: wrap;
  padding-bottom: 6px;
  border-bottom: 1px solid var(--fluid-divider, var(--stroke-subtle));
  font-size: 13px;
}
.cache-category-list {
  display: flex;
  flex-direction: column;
  gap: 0;
}
.cache-category-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 7px 0;
  border-bottom: 1px solid var(--fluid-divider, var(--stroke-subtle));
  flex-wrap: wrap;
}
.cache-category-row:first-child {
  padding-top: 2px;
}
.cache-category-row:last-child {
  border-bottom: none;
  padding-bottom: 2px;
}
.cache-category-label {
  display: flex;
  align-items: center;
  gap: 9px;
  cursor: pointer;
  flex: 1 1 220px;
  min-width: 0;
}
.cache-category-text {
  display: flex;
  flex-direction: column;
  gap: 1px;
  min-width: 0;
}
.cache-category-text strong {
  font-size: 13px;
}
.cache-bulk-actions {
  margin-top: 2px;
  padding-top: 8px;
  border-top: 1px solid var(--fluid-divider, var(--stroke-subtle));
}
@media (max-width: 640px) {
  .cache-mgmt-panel {
    padding: 14px;
    border-radius: 16px;
  }
}
@media (prefers-reduced-motion: reduce) {
  .cache-segment {
    transition: none;
  }
}
</style>
