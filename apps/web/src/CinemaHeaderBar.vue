<script setup lang="ts">
import { ref } from "vue";
import { Clapperboard, Film, ListChecks, MonitorPlay, Play, RefreshCcw, Search, SlidersHorizontal, Tv, Wand2, X } from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";
import IsleChip from "./IsleChip.vue";

const props = defineProps<{
  admin: boolean;
  query: string;
  view: "films" | "series";
  mode: string;
  watchedFilter: "all" | "unwatched" | "watched";
  sortBy: "recent" | "rating" | "year" | "title";
  canBatchTrash: boolean;
  choosingTrash: boolean;
  deleting: boolean;
  scanRunning: boolean;
  scanStatusError: string;
}>();

const emit = defineEmits<{
  (e: "update:query", val: string): void;
  (e: "update:watchedFilter", val: "all" | "unwatched" | "watched"): void;
  (e: "update:sortBy", val: "recent" | "rating" | "year" | "title"): void;
  (e: "toggle-trash-mode"): void;
  (e: "start-scan"): void;
  (e: "filter", mode: string): void;
  (e: "switch-view", view: "films" | "series"): void;
  (e: "open-mount-guide"): void;
  (e: "open-scraping-settings"): void;
}>();

const searchComposing = ref(false);

const watchedOptions = [
  { value: "all", label: "全部状态" },
  { value: "unwatched", label: "只看未看" },
  { value: "watched", label: "只看已看" },
];

const sortOptions = [
  { value: "recent", label: "最近添加" },
  { value: "rating", label: "评分优先" },
  { value: "year", label: "年份优先" },
  { value: "title", label: "名称排序" },
];

function onSearchInput(event: Event) {
  if (searchComposing.value) return;
  emit("update:query", (event.target as HTMLInputElement).value);
}

function onSearchEsc(event: KeyboardEvent) {
  if (searchComposing.value || !props.query) return;
  event.stopPropagation();
  emit("update:query", "");
}
</script>

<template>
  <div class="section-heading cinema-header-bar">
    <div><h2>私人影院</h2><p>选择想看的作品，或者从上次的位置继续观看。</p></div>
    <div class="cinema-header-actions">
      <label class="cinema-search">
        <Search :size="15" />
        <input
          :value="query"
          maxlength="120"
          type="search"
          placeholder="搜索电影、剧集或单集…"
          aria-label="搜索电影、剧集或单集"
          @compositionstart="searchComposing = true"
          @compositionend="searchComposing = false; emit('update:query', ($event.target as HTMLInputElement).value)"
          @input="onSearchInput"
          @keydown.esc="onSearchEsc"
        />
        <button v-if="query" type="button" title="清除搜索" aria-label="清除搜索" @click="emit('update:query', '')"><X :size="14" /></button>
      </label>
      <button
        v-if="canBatchTrash && view === 'films' && mode !== 'history'"
        type="button"
        class="dl-btn"
        :class="{ chosen: choosingTrash }"
        :disabled="deleting"
        :title="choosingTrash ? '退出批量选择' : '多选管理影片'"
        :aria-label="choosingTrash ? '退出批量选择' : '多选管理影片'"
        @click="emit('toggle-trash-mode')"
      >
        <ListChecks :size="15" />{{ choosingTrash ? "退出多选" : "多选" }}
      </button>
      <button
        v-if="admin"
        class="refresh"
        :disabled="scanRunning && !scanStatusError"
        title="扫描影视库新增或变更影片"
        aria-label="扫描影视库"
        @click="emit('start-scan')"
      >
        <RefreshCcw :size="15" :class="{ spinning: scanRunning && !scanStatusError }" />{{ scanRunning && !scanStatusError ? "扫描中…" : "扫描影视库" }}
      </button>
    </div>
  </div>

  <div class="cinema-tools cinema-navigation">
    <div class="cinema-tabs" role="group" aria-label="影视分类与观看记录">
      <IsleChip :selected="view==='films'&&mode==='all'" @select="emit('filter', 'all')"><template #icon><Clapperboard :size="15" /></template>首页</IsleChip>
      <IsleChip :selected="view==='films'&&mode==='movie'" @select="emit('filter', 'movie')"><template #icon><Film :size="15" /></template>电影</IsleChip>
      <IsleChip :selected="view==='series'" @select="emit('switch-view', 'series')"><template #icon><Tv :size="15" /></template>剧集</IsleChip>
      <IsleChip :selected="mode==='continue'&&view==='films'" @select="emit('filter', 'continue')"><template #icon><Play :size="15" /></template>继续观看</IsleChip>
      <IsleChip :selected="mode==='history'&&view==='films'" @select="emit('filter', 'history')">观看历史</IsleChip>
      <IsleChip :selected="view==='films'&&mode==='unmatched'" @select="emit('filter', 'unmatched')"><template #icon><Wand2 :size="15" /></template>待匹配</IsleChip>
    </div>
    <div class="cinema-nav-right">
      <div v-if="mode !== 'history'" class="cinema-filter-controls" role="group" aria-label="筛选与排序">
        <AppleSelect
          :model-value="watchedFilter"
          :options="watchedOptions"
          size="sm"
          aria-label="观看状态筛选"
          @update:model-value="emit('update:watchedFilter', $event as 'all' | 'unwatched' | 'watched')"
        />
        <AppleSelect
          :model-value="sortBy"
          :options="sortOptions"
          size="sm"
          aria-label="影视排序方式"
          @update:model-value="emit('update:sortBy', $event as 'recent' | 'rating' | 'year' | 'title')"
        />
      </div>
      <div class="cinema-bridge-inline" role="group" aria-label="大屏连接与管理快捷入口">
        <button type="button" class="cinema-bridge-link" title="在 Apple TV / Infuse / Mac 上通过 WebDAV 播放" @click="emit('open-mount-guide')">
          <MonitorPlay :size="14" /> Apple TV / Infuse 大屏接入
        </button>
        <button v-if="admin" type="button" class="cinema-bridge-link" title="前往设置中的 TMDB 与刮削服务配置" @click="emit('open-scraping-settings')">
          <SlidersHorizontal :size="14" /> TMDB 与刮削设置
        </button>
      </div>
    </div>
  </div>
</template>
