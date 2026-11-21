<script setup lang="ts">
import { computed, ref } from "vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleCharts from "../../components/ui/IsleCharts.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import { ISLE_CHART_COLORS } from "../../components/ui/isleChartsMath.ts";
import type { BatchCandidate } from "./cinemaTypes.ts";

const props = defineProps<{
  batchToken: string;
  batchBusy: boolean;
  batchProgress: string;
  batchError: string;
  batchCandidates: BatchCandidate[];
  scrapeState: { running: boolean; processed: number; matched: number; tmdbConfigured?: boolean } | null;
  scrapeBusy: boolean;
  scrapeNotice: string;
  scrapeError: string;
}>();

const showOverrideToken = ref(false);

const scrapeChartStats = computed(() => {
  const s = props.scrapeState;
  if (!s || s.processed <= 0) return null;
  const matched = Math.max(0, Math.min(s.processed, s.matched));
  const missed = Math.max(0, s.processed - matched);
  const matchRate = Math.round((matched / s.processed) * 100);
  return {
    total: s.processed,
    matchRate,
    segments: [
      { key: "matched", label: "自动命中匹配", value: matched, color: ISLE_CHART_COLORS.green, displayValue: `${matched} 项` },
      { key: "missed", label: "待人工核对", value: missed, color: ISLE_CHART_COLORS.amber, displayValue: `${missed} 项` },
    ],
  };
});

const tmdbHelpItems = [
  {
    title: "批量候选建议（人工确认）",
    body: "每次为当前最多 8 部未匹配影片生成 TMDB 候选，仅在你点击「确认此条」后才写入海报与简介；已配置 Mac 端 Token 时默认直接复用钥匙串凭据。",
  },
  {
    title: "后台自动刮削",
    body: "在 Mac 端「设置 → 媒体服务」配置 Token 后自动开启（仅 Mac 端可关闭）；此处支持一键重试此前未命中的条目。",
  },
];

const emit = defineEmits<{
  (e: "update:batchToken", value: string): void;
  (e: "suggestBatch"): void;
  (e: "cancelBatch"): void;
  (e: "acceptCandidate", item: BatchCandidate): void;
  (e: "startScrape"): void;
}>();
</script>

<template>
  <div class="cinema-admin-scrape-zone cinema-tmdb-card">
    <div class="cinema-tmdb-head">
      <div class="cinema-tmdb-title-row">
        <strong>待匹配影片刮削与海报补全</strong>
        <IsleHelpButton title="TMDB 刮削与候选规则" :items="tmdbHelpItems" />
      </div>
      <div class="cinema-tmdb-head-actions">
        <IsleButton
          v-if="scrapeState?.tmdbConfigured"
          type="button"
          variant="ghost"
          size="sm"
          @click="showOverrideToken = !showOverrideToken"
        >
          {{ showOverrideToken ? "收起临时 Token" : "临时 Token" }}
        </IsleButton>
        <IsleButton
          type="button"
          variant="tonal"
          size="sm"
          :loading="scrapeBusy"
          :disabled="scrapeBusy || (scrapeState?.running ?? false) || scrapeState?.tmdbConfigured === false"
          @click="emit('startScrape')"
        >
          {{ scrapeState?.running ? "自动刮削中…" : scrapeBusy ? "正在重试…" : "重试自动刮削" }}
        </IsleButton>
      </div>
    </div>

    <IsleBanner v-if="scrapeState && !scrapeState.tmdbConfigured" type="warning" compact role="status">
      尚未配置 TMDB Token：请在 Mac 端「设置 → 媒体服务」配置，或在下方填入临时 Token 生成候选。
    </IsleBanner>
    <IsleBanner v-else-if="scrapeState && scrapeState.running" type="info" compact role="status">
      自动刮削进行中：已处理 {{ scrapeState.processed }} 项，匹配 {{ scrapeState.matched }} 项…
    </IsleBanner>

    <div v-if="scrapeChartStats" class="cinema-tmdb-stats">
      <IsleCharts
        kind="donut"
        :size="42"
        :stroke-width="4"
        :percent="scrapeChartStats.matchRate"
        :color="ISLE_CHART_COLORS.green"
        aria-label="自动刮削海报匹配命中率"
      />
      <IsleCharts
        kind="segmented"
        :segments="scrapeChartStats.segments"
        :total="scrapeChartStats.total"
        :bar-height="8"
        compact-legend
        aria-label="刮削匹配成功与待核对数量比例"
      />
    </div>

    <form class="cinema-tmdb-form" @submit.prevent="emit('suggestBatch')">
      <input
        v-if="!scrapeState?.tmdbConfigured || showOverrideToken"
        :value="batchToken"
        type="password"
        autocomplete="off"
        :placeholder="scrapeState?.tmdbConfigured ? '临时覆盖 Token（留空复用 Mac 凭据）' : '输入 TMDB Read Access Token'"
        :disabled="batchBusy"
        @input="emit('update:batchToken', ($event.target as HTMLInputElement).value)"
      />
      <IsleButton type="submit" variant="primary" size="sm" :loading="batchBusy" :disabled="batchBusy">
        {{ batchBusy ? "正在查找…" : "生成批量候选" }}
      </IsleButton>
      <IsleButton v-if="batchCandidates.length" type="button" variant="glass" size="sm" :disabled="batchBusy" @click="emit('cancelBatch')">
        清空候选
      </IsleButton>
    </form>

    <IsleBanner v-if="batchProgress" type="info" compact role="status">{{ batchProgress }}</IsleBanner>
    <IsleBanner v-if="batchError" type="error" compact role="alert">{{ batchError }}</IsleBanner>
    <IsleBanner v-if="scrapeNotice" type="info" compact role="status">{{ scrapeNotice }}</IsleBanner>
    <IsleBanner v-if="scrapeError" type="error" compact role="alert">{{ scrapeError }}</IsleBanner>

    <div v-for="item in batchCandidates" :key="item.filmId" class="cinema-tmdb-match">
      <div class="cinema-tmdb-match-text">
        <strong>{{ item.filmTitle }} → {{ item.match.title }} {{ item.match.year ? "(" + item.match.year + ")" : "" }}</strong>
        <small>匹配度 {{ item.score }} / 100</small>
      </div>
      <IsleButton type="button" variant="tonal" size="sm" :disabled="batchBusy" @click="emit('acceptCandidate', item)">
        确认此条
      </IsleButton>
    </div>
  </div>
</template>

<style scoped>
.cinema-tmdb-card {
  padding: 13px 16px;
  border-radius: 16px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  box-shadow: var(--fluid-card-shadow);
  margin-bottom: 12px;
}
.cinema-tmdb-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
}
.cinema-tmdb-title-row {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  font-size: 13.5px;
  color: var(--text-primary);
}
.cinema-tmdb-head-actions {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}
.cinema-tmdb-stats {
  display: flex;
  align-items: center;
  gap: 12px;
  margin: 4px 0;
}
</style>
