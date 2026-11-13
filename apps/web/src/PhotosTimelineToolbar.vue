<script setup lang="ts">
import { ArrowUp, ChevronDown, Film, FolderPlus, Heart, Images, Plus, SlidersHorizontal, Sparkles, Star, X } from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";
import IsleChip from "./IsleChip.vue";
import { PHOTO_SEARCH_MODES, type PhotoSearchMode } from "./usePhotoAISearchAndPeople.ts";
import type { SmartMemoryItem } from "./usePhotoMemories.ts";

type AlbumItem = { id: number; name: string; count: number };
type FolderAlbumItem = { path: string; name: string };
type SelectOption<T extends string | number = string | number> = { value: T; label: string };

defineProps<{
  activeAlbum: number;
  activePrivateAlbum: number;
  activeFolderAlbum: FolderAlbumItem | null;
  currentPrivateAlbum: AlbumItem | null | undefined;
  currentAlbum: AlbumItem | null | undefined;
  favoritesOnly: boolean;
  personalOnly: boolean;
  isOnThisDay: boolean;
  albums: AlbumItem[];
  privateAlbums: AlbumItem[];
  folderAlbums: FolderAlbumItem[];
  typeFilter: "" | "photo" | "video" | "live";
  exifFilterOpen: boolean;
  hasActiveExif: boolean;
  hasAssets: boolean;
  hasTimelineYears: boolean;
  jumpYear: number;
  jumpMonth: number;
  hasJumpMonths: boolean;
  yearOptions: SelectOption<number>[];
  monthOptions: SelectOption<number>[];
  searchInput: string;
  searchApplied: string;
  searchMode: PhotoSearchMode;
  activePersonName: string;
  cameraFilter: string;
  cameraOptions: SelectOption<string>[];
  locationFilter: string;
  locationOptions: SelectOption<string>[];
  yearFilter: number;
  filterYearOptions: SelectOption<number>[];
  showMemoriesStrip: boolean;
  smartMemories?: SmartMemoryItem[];
}>();

const emit = defineEmits<{
  (e: "select-all"): void;
  (e: "select-on-this-day"): void;
  (e: "select-personal"): void;
  (e: "select-favorites"): void;
  (e: "open-folder-album", album: FolderAlbumItem): void;
  (e: "open-shared-album", albumId: number): void;
  (e: "open-private-album", albumId: number): void;
  (e: "go-create-folder-album"): void;
  (e: "set-type-filter", kind: "" | "photo" | "video" | "live"): void;
  (e: "select-smart-memory", item: SmartMemoryItem): void;
  (e: "toggle-exif-filter"): void;
  (e: "update:jumpYear", year: number): void;
  (e: "jump-year-change"): void;
  (e: "update:jumpMonth", month: number): void;
  (e: "jump-timeline"): void;
  (e: "scroll-top"): void;
  (e: "select-search-mode", mode: PhotoSearchMode): void;
  (e: "clear-person"): void;
  (e: "update:cameraFilter", val: string): void;
  (e: "update:locationFilter", val: string): void;
  (e: "update:yearFilter", val: number): void;
  (e: "exif-filter-change"): void;
  (e: "reset-exif-filters"): void;
  (e: "clear-all-filters"): void;
  (e: "open-map-view"): void;
}>();

function closeAlbumMenu(event: Event) {
  const menu = (event.target as HTMLElement)?.closest("details.photo-albums-menu");
  if (menu instanceof HTMLDetailsElement) menu.open = false;
}
</script>

<template>
  <div class="photos-nav-bar">
    <div class="photos-nav-top">
      <div class="album-tabs album-primary-tabs">
        <IsleChip
          :selected="activeAlbum === 0 && !activePrivateAlbum && !activeFolderAlbum && !favoritesOnly && !personalOnly && !isOnThisDay"
          @select="emit('select-all')"
        >
          <template #icon><Images :size="15" /></template>全部照片
        </IsleChip>
        <IsleChip :selected="isOnThisDay" @select="emit('select-on-this-day')">
          <template #icon><Sparkles :size="15" /></template>那年今天
        </IsleChip>
        <IsleChip :selected="personalOnly" @select="emit('select-personal')">
          <template #icon><Star :size="15" /></template>我的收藏
        </IsleChip>
        <IsleChip :selected="favoritesOnly" @select="emit('select-favorites')">
          <template #icon><Heart :size="15" /></template>共享收藏
        </IsleChip>
      </div>
      <details class="photo-albums-menu">
        <summary :aria-label="'浏览相册，共 ' + (albums.length + privateAlbums.length + folderAlbums.length) + ' 个'">
          <FolderPlus :size="15" />
          {{ activeFolderAlbum?.name || currentPrivateAlbum?.name || currentAlbum?.name || "相册" }}
          <small>({{ albums.length + privateAlbums.length + folderAlbums.length }})</small>
          <ChevronDown :size="14" class="photo-albums-chevron" />
        </summary>
        <div class="photo-albums-menu-panel">
          <div class="album-tabs">
            <button
              v-for="album in folderAlbums"
              :key="album.path"
              type="button"
              :class="{ chosen: activeFolderAlbum?.path === album.path }"
              @click="closeAlbumMenu($event); emit('open-folder-album', album)"
            >
              <FolderPlus :size="14" /> {{ album.name }}
            </button>
            <button
              v-for="album in albums"
              :key="album.id"
              type="button"
              :class="{ chosen: activeAlbum === album.id }"
              @click="closeAlbumMenu($event); emit('open-shared-album', album.id)"
            >
              {{ album.name }} <small>{{ album.count }}</small>
            </button>
            <button
              v-for="album in privateAlbums"
              :key="'private-' + album.id"
              :data-private-album-filter="album.id"
              type="button"
              :class="{ chosen: activePrivateAlbum === album.id }"
              @click="closeAlbumMenu($event); emit('open-private-album', album.id)"
            >
              <FolderPlus :size="14" /> {{ album.name }} <small>{{ album.count }}</small>
            </button>
          </div>
          <div class="photo-albums-menu-create">
            <button type="button" class="album-create" @click="closeAlbumMenu($event); emit('go-create-folder-album')">
              <Plus :size="17" /> 新建文件夹相册
            </button>
          </div>
        </div>
      </details>
    </div>

    <div class="photos-nav-bottom">
      <div class="photos-nav-filters">
        <div class="type-tabs" role="group" aria-label="媒体类型">
          <IsleChip small :selected="!typeFilter" @select="emit('set-type-filter', '')">全部</IsleChip>
          <IsleChip small :selected="typeFilter === 'photo'" @select="emit('set-type-filter', 'photo')">
            <template #icon><Images :size="13" /></template>照片
          </IsleChip>
          <IsleChip small :selected="typeFilter === 'live'" @select="emit('set-type-filter', 'live')">
            <template #icon><Sparkles :size="13" /></template>实况
          </IsleChip>
          <IsleChip small :selected="typeFilter === 'video'" @select="emit('set-type-filter', 'video')">
            <template #icon><Film :size="13" /></template>视频
          </IsleChip>
        </div>
        <button
          type="button"
          class="photo-tool-btn"
          :class="{ chosen: exifFilterOpen || hasActiveExif }"
          @click="emit('toggle-exif-filter')"
        >
          <SlidersHorizontal :size="14" /> 筛选
        </button>
      </div>
      <div v-if="hasAssets && hasTimelineYears && !isOnThisDay" class="timeline-jump">
        <AppleSelect
          :model-value="jumpYear"
          :options="yearOptions"
          placeholder="年份"
          size="sm"
          aria-label="选择年份"
          @update:model-value="emit('update:jumpYear', $event)"
          @change="emit('jump-year-change')"
        />
        <AppleSelect
          :model-value="jumpMonth"
          :options="monthOptions"
          placeholder="月份"
          :disabled="!hasJumpMonths"
          size="sm"
          aria-label="选择月份"
          @update:model-value="emit('update:jumpMonth', $event)"
          @change="emit('jump-timeline')"
        />
        <button type="button" class="timeline-jump-top" title="回到最新照片" @click="emit('scroll-top')">
          <ArrowUp :size="14" /> 最新
        </button>
      </div>
    </div>
  </div>

  <div v-if="searchInput || searchApplied || activePersonName" class="photos-filter-drawer" role="group" aria-label="智能搜索范围">
    <IsleChip
      v-for="m in PHOTO_SEARCH_MODES"
      :key="m.value"
      small
      :selected="searchMode === m.value"
      @select="emit('select-search-mode', m.value)"
    >
      {{ m.label }}
    </IsleChip>
    <button v-if="activePersonName" type="button" class="refresh" @click="emit('clear-person')">
      人物：{{ activePersonName }} ×
    </button>
  </div>

  <div v-if="exifFilterOpen || hasActiveExif" class="photos-filter-drawer">
    <AppleSelect
      v-if="cameraOptions.length > 1"
      :model-value="cameraFilter"
      :options="cameraOptions"
      size="sm"
      aria-label="按相机型号筛选"
      @update:model-value="emit('update:cameraFilter', $event)"
      @change="emit('exif-filter-change')"
    />
    <AppleSelect
      :model-value="locationFilter"
      :options="locationOptions"
      size="sm"
      aria-label="按定位信息筛选"
      @update:model-value="emit('update:locationFilter', $event)"
      @change="emit('exif-filter-change')"
    />
    <AppleSelect
      v-if="filterYearOptions.length > 1"
      :model-value="yearFilter"
      :options="filterYearOptions"
      size="sm"
      aria-label="按拍摄年份筛选"
      @update:model-value="emit('update:yearFilter', $event)"
      @change="emit('exif-filter-change')"
    />
    <button v-if="hasActiveExif" type="button" class="refresh" @click="emit('reset-exif-filters')">清除筛选</button>
  </div>

  <div v-if="searchApplied || hasActiveExif || activePersonName || typeFilter" class="photos-filter-summary" role="region" aria-label="当前生效筛选条件">
    <span class="filter-summary-label">已生效条件：</span>
    <span v-if="searchApplied" class="filter-summary-chip">关键词「{{ searchApplied }}」</span>
    <span v-if="typeFilter" class="filter-summary-chip">类型：{{ typeFilter === "video" ? "视频" : typeFilter === "live" ? "实况照片" : "照片" }}</span>
    <span v-if="activePersonName" class="filter-summary-chip">人物：{{ activePersonName }}</span>
    <span v-if="cameraFilter" class="filter-summary-chip">相机：{{ cameraFilter }}</span>
    <span v-if="locationFilter" class="filter-summary-chip">定位：{{ locationFilter === "yes" ? "有定位" : locationFilter === "no" ? "无定位" : locationFilter }}</span>
    <span v-if="yearFilter" class="filter-summary-chip">年份：{{ yearFilter }}</span>
    <button type="button" class="filter-summary-clear" @click="emit('clear-all-filters')">
      <X :size="12" /> 清除全部条件
    </button>
  </div>

  <div v-if="showMemoriesStrip && (smartMemories?.length ?? 0) > 0" class="photos-memories-strip" aria-label="智能回忆与精选">
    <button
      v-for="mem in (smartMemories ?? []).slice(0, 4)"
      :key="mem.id"
      type="button"
      class="memory-card"
      @click="emit('select-smart-memory', mem)"
    >
      <span class="memory-card-icon" :class="mem.kind === 'live' ? 'amber' : mem.kind === 'trip' ? 'green' : 'pink'">
        <Sparkles :size="18" />
      </span>
      <div><strong>{{ mem.title }}</strong><small>{{ mem.subtitle }}</small></div>
    </button>
  </div>
</template>

<style scoped>
.photos-filter-summary {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px 8px;
  margin: 0 0 12px;
  padding: 8px 12px;
  border-radius: 12px;
  border: 1px solid color-mix(in srgb, var(--accent-primary) 28%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--accent-primary) 8%, var(--fluid-card-fill));
  font-size: 12px;
}
.filter-summary-label {
  font-weight: 650;
  color: var(--text-secondary);
}
.filter-summary-chip {
  padding: 2px 9px;
  border-radius: 999px;
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-primary);
  font-weight: 550;
}
.filter-summary-clear {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  margin-left: auto;
  padding: 3px 10px;
  border-radius: 999px;
  border: 1px solid color-mix(in srgb, var(--accent-primary) 38%, var(--fluid-card-border));
  background: var(--fluid-card-fill);
  color: var(--accent-primary);
  font-size: 12px;
  font-weight: 650;
  cursor: pointer;
}
.filter-summary-clear:hover {
  background: color-mix(in srgb, var(--accent-primary) 12%, var(--fluid-card-fill));
}
</style>
