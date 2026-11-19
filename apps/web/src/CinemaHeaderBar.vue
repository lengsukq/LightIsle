<script setup lang="ts">
import { Clapperboard, Film, ListChecks, MonitorPlay, Play, RefreshCcw, SlidersHorizontal, Tv, Wand2 } from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";
import IsleButton from "./IsleButton.vue";
import IsleChip from "./IsleChip.vue";
import IsleHelpButton from "./IsleHelpButton.vue";
import IsleActionMenu from "./IsleActionMenu.vue";
import IslePageHeader from "./IslePageHeader.vue";
import IsleSearchInput from "./IsleSearchInput.vue";

defineProps<{
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

const cinemaHelpItems = [
  {
    title: "播放兼容性与原画直出",
    body: "默认优先原画直出由本机硬件解码；遇到浏览器暂不支持的封装或音轨时，可一键开启服务端实时转码（需 FFmpeg，绝不改动原片）或下载后使用 IINA / VLC 打开。",
  },
  {
    title: "大屏与外部播放器接入",
    body: "可通过右上角菜单获取 WebDAV 独立连接参数，在 Apple TV、Infuse 或 VidHub 上满速直连播放 4K 原盘与杜比视界影片。",
  },
];
</script>

<template>
  <IslePageHeader title="私人影院" class="cinema-header-bar">
    <template #title-extra>
      <IsleHelpButton title="影院播放与接入说明" :items="cinemaHelpItems" />
    </template>
    <template #actions>
      <IsleSearchInput
        :model-value="query"
        placeholder="搜索电影、剧集或单集…"
        aria-label="搜索电影、剧集或单集"
        @update:model-value="emit('update:query', $event)"
      />
      <IsleButton
        v-if="canBatchTrash && view === 'films' && mode !== 'history'"
        :variant="choosingTrash ? 'tonal' : 'glass'"
        size="sm"
        :disabled="deleting"
        :title="choosingTrash ? '退出批量选择' : '多选管理影片'"
        :aria-label="choosingTrash ? '退出批量选择' : '多选管理影片'"
        @click="emit('toggle-trash-mode')"
      >
        <template #icon><ListChecks :size="15" /></template>
        {{ choosingTrash ? "退出多选" : "多选" }}
      </IsleButton>
      <IsleButton
        v-if="admin"
        variant="glass"
        size="sm"
        :disabled="scanRunning && !scanStatusError"
        title="扫描影视库新增或变更影片"
        aria-label="扫描影视库"
        @click="emit('start-scan')"
      >
        <template #icon>
          <RefreshCcw :size="15" :class="{ spinning: scanRunning && !scanStatusError }" />
        </template>
        {{ scanRunning && !scanStatusError ? "扫描中…" : "扫描影视库" }}
      </IsleButton>
      <IsleActionMenu aria-label="更多影院工具与连接">
        <button type="button" role="menuitem" @click="emit('open-mount-guide')">
          <MonitorPlay :size="15" /> Apple TV / Infuse 大屏接入
        </button>
        <button v-if="admin" type="button" role="menuitem" @click="emit('open-scraping-settings')">
          <SlidersHorizontal :size="15" /> TMDB 与刮削设置
        </button>
      </IsleActionMenu>
    </template>
  </IslePageHeader>

  <div class="cinema-tools cinema-navigation">
    <div class="cinema-tabs" role="group" aria-label="影视分类与观看记录">
      <IsleChip :selected="view==='films'&&mode==='all'" @select="emit('filter', 'all')"><template #icon><Clapperboard :size="15" /></template>首页</IsleChip>
      <IsleChip :selected="view==='films'&&mode==='movie'" @select="emit('filter', 'movie')"><template #icon><Film :size="15" /></template>电影</IsleChip>
      <IsleChip :selected="view==='series'" @select="emit('switch-view', 'series')"><template #icon><Tv :size="15" /></template>剧集</IsleChip>
      <IsleChip :selected="mode==='continue'&&view==='films'" @select="emit('filter', 'continue')"><template #icon><Play :size="15" /></template>继续观看</IsleChip>
      <IsleChip :selected="mode==='history'&&view==='films'" @select="emit('filter', 'history')">观看历史</IsleChip>
      <IsleChip :selected="view==='films'&&mode==='unmatched'" @select="emit('filter', 'unmatched')"><template #icon><Wand2 :size="15" /></template>待匹配</IsleChip>
    </div>
    <div v-if="mode !== 'history'" class="cinema-nav-right">
      <div class="cinema-filter-controls" role="group" aria-label="筛选与排序">
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
    </div>
  </div>
</template>
