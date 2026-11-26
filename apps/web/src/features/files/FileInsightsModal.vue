<script setup lang="ts">
import { computed } from "vue";
import { Clock, Eye, FolderOpen, HardDrive, RefreshCcw, Trash2 } from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import { formatBinaryBytes } from "../../utils/format.ts";
import {
  LARGE_FILE_MIN_OPTIONS,
  RECENT_DAYS_OPTIONS,
  type FileInsightItem,
  type FileInsightMode,
  type FileInsightResult,
} from "./filePinsAndInsights.ts";

const props = defineProps<{
  open: boolean;
  mode: FileInsightMode;
  scopePath: string;
  currentFolderPath: string;
  minBytes: number;
  recentDays: number;
  result: FileInsightResult | null;
  loading: boolean;
  error: string;
  trashingPath: string;
}>();

const emit = defineEmits<{
  close: [];
  reload: [opts: { mode?: FileInsightMode; path?: string; minBytes?: number; days?: number }];
  openFolder: [item: FileInsightItem];
  preview: [item: FileInsightItem];
  trash: [item: FileInsightItem];
}>();

const scopeOptions = computed(() => {
  const opts = [{ value: ".", label: "整个共享目录" }];
  if (props.currentFolderPath && props.currentFolderPath !== ".") {
    opts.push({ value: props.currentFolderPath, label: `当前目录 (${props.currentFolderPath})` });
  }
  return opts;
});

const modalTitle = computed(() => (props.mode === "large" ? "大文件快筛" : "近期新增文件"));

function onModeChange(nextMode: FileInsightMode) {
  if (nextMode === props.mode && props.result) return;
  emit("reload", { mode: nextMode });
}
</script>

<template>
  <IsleModal
    :open="open"
    :title="modalTitle"
    size="wide"
    role="dialog"
    :aria-label="modalTitle"
    @close="emit('close')"
  >
    <template #icon>
      <HardDrive v-if="mode === 'large'" :size="17" />
      <Clock v-else :size="17" />
    </template>

    <div class="insights-controls">
      <div class="insights-tabs" role="tablist" aria-label="文件快筛模式">
        <button
          type="button"
          role="tab"
          :aria-selected="mode === 'large' ? 'true' : 'false'"
          class="insights-tab-btn"
          :class="{ 'is-active': mode === 'large' }"
          @click="onModeChange('large')"
        >
          <HardDrive :size="14" /> 大文件
        </button>
        <button
          type="button"
          role="tab"
          :aria-selected="mode === 'recent' ? 'true' : 'false'"
          class="insights-tab-btn"
          :class="{ 'is-active': mode === 'recent' }"
          @click="onModeChange('recent')"
        >
          <Clock :size="14" /> 近期新增
        </button>
      </div>

      <div class="insights-filters">
        <AppleSelect
          v-if="mode === 'large'"
          :model-value="minBytes"
          :options="LARGE_FILE_MIN_OPTIONS"
          :disabled="loading"
          size="sm"
          aria-label="大文件体积阈值"
          @change="emit('reload', { minBytes: Number($event) })"
        />
        <AppleSelect
          v-else
          :model-value="recentDays"
          :options="RECENT_DAYS_OPTIONS"
          :disabled="loading"
          size="sm"
          aria-label="近期时间范围"
          @change="emit('reload', { days: Number($event) })"
        />

        <AppleSelect
          v-if="scopeOptions.length > 1"
          :model-value="scopePath"
          :options="scopeOptions"
          :disabled="loading"
          size="sm"
          aria-label="扫描范围"
          @change="emit('reload', { path: String($event) })"
        />

        <IsleButton type="button" variant="glass" size="sm" :disabled="loading" @click="emit('reload', {})">
          <template #icon><RefreshCcw :size="13" :class="{ spinning: loading }" /></template>
          重新扫描
        </IsleButton>
      </div>
    </div>

    <div v-if="result" class="insights-summary" role="status">
      <span>已扫描 <strong>{{ result.scannedFiles.toLocaleString() }}</strong> 个文件</span>
      <span>命中 <strong>{{ result.matchedFiles.toLocaleString() }}</strong> 项</span>
      <span>累计 <strong>{{ formatBinaryBytes(result.totalBytes) }}</strong></span>
      <span v-if="result.timedOut" class="insights-warn-pill">扫描触达超时保护，仅展示已收集结果</span>
      <span v-else-if="result.truncated" class="insights-warn-pill">已按 Top {{ result.items.length }} 截断展示</span>
    </div>

    <IsleBanner v-if="error" type="error" compact :message="error" />

    <div v-if="loading && !result?.items.length" class="insights-loading" role="status">
      正在扫描{{ mode === "large" ? "大文件" : "近期修改文件" }}…
    </div>
    <IsleEmpty
      v-else-if="!loading && result && !result.items.length"
      compact
      :icon="mode === 'large' ? HardDrive : Clock"
      :title="mode === 'large' ? '未发现超过阈值的大文件' : '该时间段内没有新增或修改文件'"
      :description="mode === 'large' ? '可以尝试调低体积阈值或切换扫描范围。' : '可以尝试扩大天数范围后重新扫描。'"
    />
    <div v-else-if="result?.items.length" class="insights-list">
      <article v-for="item in result.items" :key="item.path" class="insights-row">
        <div class="insights-row-main">
          <strong class="insights-name" :title="item.name">{{ item.name }}</strong>
          <small class="insights-meta">
            <span>{{ item.parentDir === "." ? "根目录" : item.parentDir }}</span>
            <span>·</span>
            <span class="insights-size">{{ formatBinaryBytes(item.size) }}</span>
            <span>·</span>
            <span>{{ formatDateTime(item.modified) }}</span>
          </small>
        </div>
        <div class="insights-row-actions">
          <IsleButton type="button" variant="glass" size="sm" @click="emit('preview', item)">
            <template #icon><Eye :size="13" /></template>
            预览
          </IsleButton>
          <IsleButton type="button" variant="tonal" size="sm" @click="emit('openFolder', item)">
            <template #icon><FolderOpen :size="13" /></template>
            打开所在目录
          </IsleButton>
          <IsleButton
            v-if="item.canWrite"
            type="button"
            variant="danger"
            size="sm"
            :loading="trashingPath === item.path"
            :disabled="Boolean(trashingPath && trashingPath !== item.path)"
            @click="emit('trash', item)"
          >
            <template #icon><Trash2 :size="13" /></template>
            移入回收站
          </IsleButton>
        </div>
      </article>
    </div>

    <template #footer>
      <div class="insights-footer">
        <IsleButton variant="glass" @click="emit('close')">关闭</IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.insights-controls {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
  margin-bottom: 12px;
}
.insights-tabs {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 4px;
  border-radius: 11px;
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
}
.insights-tab-btn {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 6px 11px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: var(--text-secondary);
  font-size: 12.5px;
  font-weight: 600;
  cursor: pointer;
}
.insights-tab-btn.is-active {
  background: var(--fluid-card-top);
  color: var(--text-primary);
  box-shadow: var(--fluid-item-card-shadow);
}
.insights-filters {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.insights-summary {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px 14px;
  padding: 8px 12px;
  margin-bottom: 10px;
  border-radius: 10px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  font-size: 12px;
  color: var(--text-secondary);
  font-variant-numeric: tabular-nums;
}
.insights-summary strong {
  color: var(--text-primary);
}
.insights-warn-pill {
  font-size: 11px;
  font-weight: 600;
  padding: 2px 8px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--warning) 15%, transparent);
  color: var(--warning);
}
.insights-loading {
  padding: 32px 12px;
  text-align: center;
  font-size: 13px;
  color: var(--text-secondary);
}
.insights-list {
  display: grid;
  gap: 7px;
  max-height: 55vh;
  overflow-y: auto;
}
.insights-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 10px 12px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
}
.insights-row-main {
  min-width: 0;
  display: grid;
  gap: 3px;
}
.insights-name {
  font-size: 13px;
  font-weight: 620;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.insights-meta {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  font-size: 11.5px;
  color: var(--text-secondary);
  font-variant-numeric: tabular-nums;
}
.insights-size {
  font-weight: 650;
  color: var(--text-primary);
}
.insights-row-actions {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex-shrink: 0;
  flex-wrap: wrap;
}
.insights-footer {
  display: flex;
  justify-content: flex-end;
  width: 100%;
}
@media (max-width: 680px) {
  .insights-row {
    flex-direction: column;
    align-items: stretch;
  }
}
</style>
