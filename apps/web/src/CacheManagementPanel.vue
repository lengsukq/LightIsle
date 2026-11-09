<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import {
  ISLE_WEB_CACHE_CATEGORIES,
  clearLocalCache,
  formatCacheBytes,
  inspectLocalCache,
  useIsleCache,
  type IsleServerCacheStatus,
  type IsleWebCacheCategory,
  type IsleWebCacheReport,
} from './useIsleCache'
import { describeUserFacingError } from './userFacingError.js'

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
  try {
    const res = await fetch('/api/v2/cache/status', {
      credentials: 'same-origin',
    })
    if (res.ok) {
      const data = await res.json()
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
    }
  } catch {
    // Ignore server cache status fetch error when offline
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
    const res = await fetch('/api/v2/admin/cache/clear', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ categories }),
    })
    if (!res.ok) {
      let msg = '清理服务端缓存失败。'
      try {
        const body = await res.json()
        msg = body?.error?.message || body?.message || msg
      } catch {
        // Ignore
      }
      throw new Error(msg)
    }
    const payload = await res.json()
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

function segmentWidthPercent(cat: IsleWebCacheCategory): string {
  const total = localReport.value?.totalBytes || 0
  if (total <= 0) return '0%'
  const used = localReport.value?.categories?.[cat]?.usedBytes || 0
  if (used <= 0) return '0%'
  return `${Math.max(4, Math.round((used / total) * 100))}%`
}

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
        <p class="eyebrow">CACHE &amp; STORAGE</p>
        <h3>缓存与本地存储管理</h3>
      </div>
      <div class="row-actions">
        <span class="pill info">
          浏览器缓存 {{ formatCacheBytes(localReport?.totalBytes || 0) }} ·
          {{ localReport?.totalEntries || 0 }} 项
        </span>
        <button
          type="button"
          class="ghost small"
          :disabled="loading"
          @click="refreshStats"
        >
          {{ loading ? '统计中…' : '刷新统计' }}
        </button>
      </div>
    </div>

    <p class="muted">
      切换概览、相册、足迹地图、影院与文件页面时，已加载的页面状态、缩略图、海报与地图瓦片会自动驻留加速。您可在此查看各类缓存占用并按需清理；清理缓存绝不会删除 NAS 上的任何原始照片、视频或文件。
    </p>

    <p
      v-if="notice"
      class="status-banner"
      :class="noticeError ? 'error' : 'ok'"
      role="status"
    >
      {{ notice }}
    </p>

    <div class="cache-bar-wrap" aria-label="浏览器缓存分类占比">
      <div class="cache-segmented-bar">
        <template v-if="(localReport?.totalBytes || 0) > 0">
          <div
            v-for="meta in ISLE_WEB_CACHE_CATEGORIES"
            :key="meta.id"
            class="cache-segment"
            :style="{
              width: segmentWidthPercent(meta.id),
              background: meta.color,
            }"
            :title="`${meta.label}: ${formatCacheBytes(localReport?.categories?.[meta.id]?.usedBytes || 0)}`"
          />
        </template>
      </div>
      <div class="cache-legend-row">
        <span
          v-for="meta in ISLE_WEB_CACHE_CATEGORIES"
          :key="meta.id"
          class="cache-legend-item"
        >
          <i class="cache-dot" :style="{ background: meta.color }" />
          {{ meta.label }}
          <strong>{{
            formatCacheBytes(localReport?.categories?.[meta.id]?.usedBytes || 0)
          }}</strong>
        </span>
      </div>
    </div>

    <div class="cache-subcard">
      <div class="cache-subcard-head">
        <strong>浏览器本地缓存分类</strong>
        <button type="button" class="ghost small" @click="toggleSelectAll">
          {{ allSelected ? '取消全选' : '全选' }}
        </button>
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
          <button
            type="button"
            class="ghost small"
            :disabled="clearingLocal"
            :data-testid="`clear-local-${meta.id}`"
            @click="handleClearLocal([meta.id])"
          >
            清理
          </button>
        </div>
      </div>

      <div class="row-actions cache-bulk-actions">
        <button
          type="button"
          class="primary small"
          :disabled="clearingLocal || selected.length === 0"
          data-testid="clear-selected-local-cache"
          @click="handleClearLocal([...selected])"
        >
          {{
            clearingLocal
              ? '正在清理…'
              : `清理所选缓存 (${selected.length})`
          }}
        </button>
        <button
          type="button"
          class="ghost small"
          :disabled="clearingLocal"
          data-testid="clear-all-local-cache"
          @click="
            handleClearLocal(ISLE_WEB_CACHE_CATEGORIES.map((item) => item.id))
          "
        >
          一键清空全部浏览器缓存
        </button>
      </div>
    </div>

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
          <button
            v-if="isAdmin"
            type="button"
            class="ghost small"
            :disabled="clearingServer"
            data-testid="clear-server-thumbnails"
            @click="handleClearServer(['thumbnails'], '缩略图缓存')"
          >
            清理
          </button>
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
          <button
            v-if="isAdmin"
            type="button"
            class="ghost small"
            :disabled="clearingServer"
            data-testid="clear-server-map-tiles"
            @click="handleClearServer(['map_tiles'], '地图瓦片缓存')"
          >
            清理
          </button>
        </div>
      </div>

      <div v-if="isAdmin" class="row-actions cache-bulk-actions">
        <button
          type="button"
          class="ghost small"
          :disabled="clearingServer"
          data-testid="clear-server-all"
          @click="handleClearServer(['all'], '全部派生缓存')"
        >
          {{ clearingServer ? '正在清理服务端缓存…' : '清空全部服务端派生缓存' }}
        </button>
      </div>
    </div>
  </section>
</template>

<style scoped>
.cache-mgmt-panel {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.cache-bar-wrap {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.cache-segmented-bar {
  display: flex;
  height: 10px;
  border-radius: 999px;
  overflow: hidden;
  background: rgba(148, 163, 184, 0.2);
}
.cache-segment {
  height: 100%;
  transition: width 0.25s ease;
}
.cache-legend-row {
  display: flex;
  flex-wrap: wrap;
  gap: 14px;
  font-size: 12.5px;
}
.cache-legend-item {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.cache-dot {
  width: 8px;
  height: 8px;
  border-radius: 999px;
  display: inline-block;
}
.cache-dot-lg {
  width: 10px;
  height: 10px;
  border-radius: 999px;
  flex-shrink: 0;
}
.cache-subcard {
  border: 1px solid rgba(148, 163, 184, 0.18);
  border-radius: 14px;
  padding: 12px 14px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.cache-subcard-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.cache-category-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.cache-category-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 6px 0;
  border-bottom: 1px solid rgba(148, 163, 184, 0.12);
}
.cache-category-row:last-child {
  border-bottom: none;
}
.cache-category-label {
  display: flex;
  align-items: center;
  gap: 10px;
  cursor: pointer;
  flex: 1;
}
.cache-category-text {
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.cache-bulk-actions {
  margin-top: 4px;
}
</style>
