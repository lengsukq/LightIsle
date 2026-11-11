<script setup lang="ts">
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
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
      <p>为当前最多 8 部未匹配影片生成候选，需逐条人工确认后才写入；已配置 Mac 端 Token 时默认直接复用钥匙串凭据。</p>
      <form class="cinema-tmdb-form" @submit.prevent="emit('suggestBatch')">
        <input
          v-if="!scrapeState?.tmdbConfigured"
          :value="batchToken"
          type="password"
          autocomplete="off"
          placeholder="TMDB Read Access Token（推荐在 Mac 端「设置 → 媒体服务」配置）"
          :disabled="batchBusy"
          @input="emit('update:batchToken', ($event.target as HTMLInputElement).value)"
        />
        <IsleButton type="submit" variant="primary" size="sm" :loading="batchBusy" :disabled="batchBusy">
          {{ batchBusy ? "正在查找…" : "生成候选" }}
        </IsleButton>
        <IsleButton type="button" variant="ghost" size="sm" :disabled="batchBusy" @click="emit('cancelBatch')">
          清空候选
        </IsleButton>
      </form>
      <details v-if="scrapeState?.tmdbConfigured" style="margin-top: 8px; font-size: 12px; color: var(--text-secondary)">
        <summary style="cursor: pointer">临时覆盖 Mac 钥匙串 Token（可选）</summary>
        <div class="cinema-tmdb-form" style="margin-top: 6px">
          <input
            :value="batchToken"
            type="password"
            autocomplete="off"
            placeholder="留空则默认复用 Mac 配置"
            :disabled="batchBusy"
            @input="emit('update:batchToken', ($event.target as HTMLInputElement).value)"
          />
        </div>
      </details>
      <IsleBanner v-if="batchProgress" type="info" compact role="status">{{ batchProgress }}</IsleBanner>
      <IsleBanner v-if="batchError" type="error" compact role="alert">{{ batchError }}</IsleBanner>
      <div v-for="item in batchCandidates" :key="item.filmId" class="cinema-tmdb-match">
        <div class="cinema-tmdb-match-text">
          <strong>{{ item.filmTitle }} → {{ item.match.title }} {{ item.match.year ? "(" + item.match.year + ")" : "" }}</strong>
          <small>候选评分 {{ item.score }} / 100 · 请核对后确认</small>
        </div>
        <IsleButton type="button" variant="tonal" size="sm" :disabled="batchBusy" @click="emit('acceptCandidate', item)">
          确认此条
        </IsleButton>
      </div>
    </details>
    <details class="cinema-tmdb-panel">
      <summary>自动刮削 · 后台 TMDB 补全</summary>
      <p>在 Mac 端「设置 → 媒体服务」配置 Token 后自动开启（仅 Mac 端可关闭）；此处可重试未命中条目。</p>
      <IsleBanner v-if="scrapeState && !scrapeState.tmdbConfigured" type="warning" compact role="status">
        尚未配置 TMDB Token：请在 Mac App「设置 → 媒体服务」中填写后自动启用。
      </IsleBanner>
      <IsleBanner v-else-if="scrapeState && scrapeState.running" type="info" compact role="status">
        自动刮削进行中：已处理 {{ scrapeState.processed }} 项，成功匹配 {{ scrapeState.matched }} 项…
      </IsleBanner>
      <IsleBanner v-else-if="scrapeState?.tmdbConfigured" type="info" compact role="status">
        已在 Mac 端配置 TMDB Token，自动刮削已默认开启（仅 Mac 端可关闭）。
      </IsleBanner>
      <IsleBanner v-if="scrapeNotice" type="info" compact role="status">{{ scrapeNotice }}</IsleBanner>
      <IsleBanner v-if="scrapeError" type="error" compact role="alert">{{ scrapeError }}</IsleBanner>
      <form class="cinema-tmdb-form" style="margin-top: 10px;" @submit.prevent="emit('startScrape')">
        <IsleButton
          type="submit"
          variant="tonal"
          size="sm"
          :loading="scrapeBusy"
          :disabled="scrapeBusy || (scrapeState?.running ?? false) || scrapeState?.tmdbConfigured === false"
        >
          {{ scrapeState?.running ? "刮削进行中…" : scrapeBusy ? "正在重试…" : "重试此前未匹配的条目" }}
        </IsleButton>
      </form>
    </details>
  </div>
</template>
