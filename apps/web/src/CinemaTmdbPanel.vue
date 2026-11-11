<script setup lang="ts">
import type { BatchCandidate } from "./cinemaTypes.ts";

defineProps<{
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

const emit = defineEmits<{
  (e: "update:batchToken", value: string): void;
  (e: "suggestBatch"): void;
  (e: "cancelBatch"): void;
  (e: "acceptCandidate", item: BatchCandidate): void;
  (e: "startScrape"): void;
}>();
</script>

<template>
  <div class="cinema-admin-scrape-zone">
    <details class="cinema-tmdb-panel">
      <summary>批量整理 · TMDB 候选建议（逐条确认）</summary>
      <p>为当前最多 8 部未匹配影片生成候选，需逐条人工确认后才写入；已配置 Mac 端 Token 时可留空。</p>
      <form class="cinema-tmdb-form" @submit.prevent="emit('suggestBatch')">
        <input
          :value="batchToken"
          type="password"
          autocomplete="off"
          placeholder="TMDB Read Access Token（可选，默认复用 Mac 配置）"
          :disabled="batchBusy"
          @input="emit('update:batchToken', ($event.target as HTMLInputElement).value)"
        />
        <button type="submit" :disabled="batchBusy">{{ batchBusy ? "正在查找…" : "生成候选" }}</button>
        <button type="button" :disabled="batchBusy" @click="emit('cancelBatch')">清空候选</button>
      </form>
      <p v-if="batchProgress" class="cinema-hint" role="status">{{ batchProgress }}</p>
      <p v-if="batchError" class="cinema-alert" role="alert">{{ batchError }}</p>
      <div v-for="item in batchCandidates" :key="item.filmId" class="cinema-tmdb-match">
        <div class="cinema-tmdb-match-text">
          <strong>{{ item.filmTitle }} → {{ item.match.title }} {{ item.match.year ? "(" + item.match.year + ")" : "" }}</strong>
          <small>候选评分 {{ item.score }} / 100 · 请核对后确认</small>
        </div>
        <button type="button" :disabled="batchBusy" @click="emit('acceptCandidate', item)">确认此条</button>
      </div>
    </details>
    <details class="cinema-tmdb-panel">
      <summary>自动刮削 · 后台 TMDB 补全</summary>
      <p>在 Mac 端「设置 → 媒体服务」配置 Token 后自动开启（仅 Mac 端可关闭）；此处可重试未命中条目。</p>
      <p v-if="scrapeState && !scrapeState.tmdbConfigured" class="cinema-alert" role="status">尚未配置 TMDB Token：请在 Mac App「设置 → 媒体服务」中填写后自动启用。</p>
      <p v-else-if="scrapeState && scrapeState.running" class="cinema-hint" role="status">自动刮削进行中：已处理 {{ scrapeState.processed }} 项，成功匹配 {{ scrapeState.matched }} 项…</p>
      <p v-else-if="scrapeState?.tmdbConfigured" class="cinema-hint" role="status">已在 Mac 端配置 TMDB Token，自动刮削已默认开启（仅 Mac 端可关闭）。</p>
      <p v-if="scrapeNotice" class="cinema-hint" role="status">{{ scrapeNotice }}</p>
      <p v-if="scrapeError" class="cinema-alert" role="alert">{{ scrapeError }}</p>
      <form class="cinema-tmdb-form" @submit.prevent="emit('startScrape')">
        <button type="submit" :disabled="scrapeBusy || (scrapeState?.running ?? false) || scrapeState?.tmdbConfigured === false">
          {{ scrapeState?.running ? "刮削进行中…" : scrapeBusy ? "正在重试…" : "重试此前未匹配的条目" }}
        </button>
      </form>
    </details>
  </div>
</template>
