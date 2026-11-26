<script setup lang="ts">
import { computed } from "vue";
import IsleCharts from "../../components/ui/IsleCharts.vue";
import { ISLE_CHART_COLORS } from "../../components/ui/isleChartsMath.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import type { PhotosScanStatus } from "./usePhotosCatalogLoader.ts";

const props = defineProps<{
  admin: boolean;
  hasAssets: boolean;
  scan: PhotosScanStatus;
  scanStatusLoaded: boolean;
  scanStatusLoading: boolean;
  scanStatusError: string;
  scanActionError: string;
  aiPauseBusy: boolean;
  message: string;
  previousRootShareWarning: string;
}>();

const emit = defineEmits<{
  (e: "dismiss-share-warning"): void;
  (e: "toggle-ai-pause", paused: boolean): void;
  (e: "retry-status"): void;
}>();

const aiProgressPercent = computed<number | null>(() => {
  const ai = props.scan.aiIndexing;
  if (!ai || !ai.total || ai.total <= 0 || ai.remaining == null) return null;
  const done = Math.max(0, ai.total - ai.remaining);
  return Math.min(100, Math.max(0, Math.round((done / ai.total) * 100)));
});
</script>

<template>
  <p v-if="previousRootShareWarning" class="form-error" role="alert">
    {{ previousRootShareWarning }}
    <button type="button" class="refresh" @click="emit('dismiss-share-warning')">知道了</button>
  </p>
  <div v-if="scan.running && !scanStatusError" class="scan-banner">
    正在后台整理媒体 · 已检查 {{ scan.scanned }} 项 · 发现 {{ scan.found }} 项
  </div>
  <div
    v-else-if="scan.aiIndexing && (scan.aiIndexing.running || scan.aiIndexing.paused || (scan.aiIndexing.remaining ?? 0) > 0)"
    class="scan-banner scan-banner--ai"
  >
    <IsleCharts
      v-if="aiProgressPercent !== null"
      kind="donut"
      :size="36"
      :stroke-width="4"
      :percent="aiProgressPercent"
      :color="scan.aiIndexing.paused ? ISLE_CHART_COLORS.amber : ISLE_CHART_COLORS.blue"
      aria-label="智能识图索引完成度"
    />
    <span>
      {{ scan.aiIndexing.paused ? "智能识图与 OCR 索引已暂停" : "正在后台建立智能识图与离线 OCR 索引" }}
      <template v-if="scan.aiIndexing.total && scan.aiIndexing.remaining != null">
        · 已索引 {{ Math.max(0, scan.aiIndexing.total - scan.aiIndexing.remaining) }}/{{ scan.aiIndexing.total }} 张
      </template>
      <template v-else-if="scan.aiIndexing.remaining != null">
        · 待处理 {{ scan.aiIndexing.remaining }} 张
      </template>
    </span>
    <button
      v-if="admin"
      type="button"
      class="refresh scan-banner-action"
      :disabled="aiPauseBusy"
      @click="emit('toggle-ai-pause', scan.aiIndexing.paused)"
    >
      {{ scan.aiIndexing.paused ? "恢复索引" : "暂停索引" }}
    </button>
  </div>
  <div v-if="scanStatusError && hasAssets" class="form-error" role="alert">
    扫描状态读取失败：{{ scanStatusError }}
    <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span>
    <button type="button" class="refresh" :disabled="scanStatusLoading" @click="emit('retry-status')">
      {{ scanStatusLoading ? "正在重试…" : "重试状态" }}
    </button>
  </div>
  <p v-if="scanStatusLoaded && scan.lastError && hasAssets" class="form-error">
    上次扫描：{{ describeUserFacingError(scan.lastError) }}
  </p>
  <p v-if="message" class="gallery-message">{{ message }}</p>
  <p v-if="scanActionError && hasAssets" class="gallery-message" role="alert">{{ scanActionError }}</p>
</template>
