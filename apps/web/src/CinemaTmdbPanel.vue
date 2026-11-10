<script setup lang="ts">
import type { BatchCandidate } from "./cinemaTypes.js";

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
      <summary>批量整理影片 · TMDB 候选建议（逐条确认）</summary>
      <p>只对当前已加载、尚未手动匹配的最多 8 部影片生成候选。根据片名与年份初步评分，不保证同名电影匹配准确；每部作品必须人工确认才写入。若已在 Mac 端配置 TMDB Token 可直接留空。</p>
      <form class="cinema-tmdb-form" @submit.prevent="emit('suggestBatch')">
        <input
          :value="batchToken"
          type="password"
          autocomplete="off"
          placeholder="你的 TMDB Read Access Token（可选，留空默认使用 Mac 已配置 Token）"
          :disabled="batchBusy"
          @input="emit('update:batchToken', ($event.target as HTMLInputElement).value)"
        />
        <button type="submit" :disabled="batchBusy">{{ batchBusy ? "正在查找…" : "生成候选" }}</button>
        <button type="button" :disabled="batchBusy" @click="emit('cancelBatch')">清除令牌与候选</button>
      </form>
      <p v-if="batchProgress" class="cinema-hint" role="status">{{ batchProgress }}</p>
      <p v-if="batchError" class="cinema-alert" role="alert">{{ batchError }}</p>
      <div v-for="item in batchCandidates" :key="item.filmId" class="cinema-tmdb-match">
        <div class="cinema-tmdb-match-text">
          <strong>{{ item.filmTitle }} → {{ item.match.title }} {{ item.match.year ? "(" + item.match.year + ")" : "" }}</strong>
          <small>自动候选评分 {{ item.score }} / 100 · 请核对是否同一部影片</small>
        </div>
        <button type="button" :disabled="batchBusy" @click="emit('acceptCandidate', item)">确认此条</button>
      </div>
    </details>
    <details class="cinema-tmdb-panel">
      <summary>自动刮削 · 服务器端 TMDB 批量补全（填好 Token 后默认开启，仅 Mac 端可关闭）</summary>
      <p>在 Mac App「设置 → 媒体服务」填好 TMDB Token 后，服务器后台默认自动为待匹配影片与剧集补全 TMDB 信息（海报/简介/评分），仅 Mac 端清除 Token 可关闭。此处仅用于重试此前未命中的条目。</p>
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
