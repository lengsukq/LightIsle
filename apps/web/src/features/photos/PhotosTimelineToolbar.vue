<script setup lang="ts">
import { inject } from "vue";
import { ArrowUp, Check, ChevronDown, Film, FolderPlus, Grid2x2, Grid3x3, Heart, Images, Lock, Plus, SlidersHorizontal, Sparkles, Star, Users, X } from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleChip from "../../components/ui/IsleChip.vue";
import IsleSearchInput from "../../components/ui/IsleSearchInput.vue";
import { PHOTO_SEARCH_MODES } from "./usePhotoAISearchAndPeople.ts";
import { PHOTO_TIMELINE_CTX } from "../../contexts/photosContext.ts";

const ctx = inject(PHOTO_TIMELINE_CTX);
if (!ctx) throw new Error("PhotosTimelineToolbar requires PHOTO_TIMELINE_CTX");

const {
  activeAlbum, activePrivateAlbum, activeFolderAlbum, currentPrivateAlbum, currentAlbum,
  favoritesOnly, personalOnly, isOnThisDay, albums, privateAlbums, folderAlbums,
  typeFilter, exifFilterOpen, hasActiveExif, hasAssets, hasTimelineYears,
  jumpYear, jumpMonth, hasJumpMonths, yearOptions, monthOptions,
  searchInput, searchPlaceholder, searchApplied, searchMode, activePersonName,
  cameraFilter, cameraOptions, locationFilter, locationOptions, yearFilter, filterYearOptions,
  showMemoriesStrip, smartMemories, compactGrid, trashSelecting, trashBusy,
  selectAll, selectOnThisDay, selectPersonal, selectFavorites, openFolderAlbum,
  openSharedAlbum, openPrivateAlbum, goCreateFolderAlbum, setTypeFilter, selectSmartMemory,
  toggleExifFilter, onJumpYearChange, jumpToTimeline, scrollToTop, onSearchSubmit,
  onSearchClear, toggleCompactGrid, toggleTrashSelecting, selectSearchMode, clearPerson,
  onExifFilterChange, resetExifFiltersAndReload, clearAllFilters,
} = ctx;

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
          @select="selectAll()"
        >
          <template #icon><Images :size="15" /></template>全部照片
        </IsleChip>
        <IsleChip :selected="isOnThisDay" @select="selectOnThisDay()">
          <template #icon><Sparkles :size="15" /></template>那年今天
        </IsleChip>
        <IsleChip
          :selected="personalOnly"
          title="仅当前账号可见的个人收藏"
          @select="selectPersonal()"
        >
          <template #icon><Star :size="15" /></template>我的收藏
        </IsleChip>
        <IsleChip
          :selected="favoritesOnly"
          title="共享目录成员均可见的家庭共享收藏"
          @select="selectFavorites()"
        >
          <template #icon><Heart :size="15" /></template>共享收藏
        </IsleChip>
        <details class="photo-albums-menu">
          <summary :aria-label="'浏览相册，共 ' + (albums.length + privateAlbums.length + folderAlbums.length) + ' 个'">
            <FolderPlus :size="15" />
            {{ activeFolderAlbum?.name || currentPrivateAlbum?.name || currentAlbum?.name || "相册筛选" }}
            <small>({{ albums.length + privateAlbums.length + folderAlbums.length }})</small>
            <ChevronDown :size="14" class="photo-albums-chevron" />
          </summary>
          <div class="photo-albums-menu-panel">
            <div class="album-tabs">
              <template v-if="folderAlbums.length">
                <span class="photo-albums-group-label">文件夹相册</span>
                <button
                  v-for="album in folderAlbums"
                  :key="album.path"
                  type="button"
                  :class="{ chosen: activeFolderAlbum?.path === album.path }"
                  @click="closeAlbumMenu($event); openFolderAlbum(album)"
                >
                  <FolderPlus :size="14" /> {{ album.name }}
                </button>
              </template>
              <template v-if="albums.length">
                <span class="photo-albums-group-label">旧版共享相册</span>
                <button
                  v-for="album in albums"
                  :key="album.id"
                  type="button"
                  :class="{ chosen: activeAlbum === album.id }"
                  @click="closeAlbumMenu($event); openSharedAlbum(album.id)"
                >
                  <Users :size="14" /> {{ album.name }} <small>{{ album.count }}</small>
                </button>
              </template>
              <template v-if="privateAlbums.length">
                <span class="photo-albums-group-label">旧版私人相册（仅自己可见）</span>
                <button
                  v-for="album in privateAlbums"
                  :key="'private-' + album.id"
                  :data-private-album-filter="album.id"
                  type="button"
                  :class="{ chosen: activePrivateAlbum === album.id }"
                  @click="closeAlbumMenu($event); openPrivateAlbum(album.id)"
                >
                  <Lock :size="14" /> {{ album.name }} <small>{{ album.count }}</small>
                </button>
              </template>
            </div>
            <div class="photo-albums-menu-create">
              <button type="button" class="album-create" @click="closeAlbumMenu($event); goCreateFolderAlbum()">
                <Plus :size="17" /> 新建文件夹相册
              </button>
            </div>
          </div>
        </details>
      </div>

      <div class="photos-nav-tools">
        <IsleSearchInput
          v-model="searchInput"
          :placeholder="searchPlaceholder || '搜索照片、文字、地点…'"
          aria-label="搜索照片和视频"
          @submit="onSearchSubmit()"
          @clear="onSearchClear()"
        />
        <button
          type="button"
          class="photo-tool-btn"
          :class="{ chosen: compactGrid }"
          :title="compactGrid ? '当前：紧凑网格（点击切舒适）' : '当前：舒适网格（点击切紧凑）'"
          :aria-label="compactGrid ? '切换舒适视图' : '切换紧凑视图'"
          @click="toggleCompactGrid()"
        >
          <Grid3x3 v-if="compactGrid" :size="14" /><Grid2x2 v-else :size="14" />
          <span>{{ compactGrid ? "紧凑" : "舒适" }}</span>
        </button>
        <button
          type="button"
          class="photo-tool-btn"
          :class="{ chosen: trashSelecting }"
          :disabled="trashBusy"
          :title="trashSelecting ? '退出批量选择' : '多选照片（支持 Shift 区间连选）'"
          :aria-label="trashSelecting ? '退出批量选择' : '批量多选'"
          @click="toggleTrashSelecting()"
        >
          <Check :size="14" /> {{ trashSelecting ? "退出多选" : "多选" }}
        </button>
      </div>
    </div>

    <div class="photos-nav-bottom">
      <div class="photos-nav-filters">
        <div class="type-tabs" role="group" aria-label="媒体类型">
          <IsleChip small :selected="!typeFilter" @select="setTypeFilter('')">全部</IsleChip>
          <IsleChip small :selected="typeFilter === 'photo'" @select="setTypeFilter('photo')">
            <template #icon><Images :size="13" /></template>照片
          </IsleChip>
          <IsleChip small :selected="typeFilter === 'live'" @select="setTypeFilter('live')">
            <template #icon><Sparkles :size="13" /></template>实况
          </IsleChip>
          <IsleChip small :selected="typeFilter === 'video'" @select="setTypeFilter('video')">
            <template #icon><Film :size="13" /></template>视频
          </IsleChip>
        </div>
        <button
          type="button"
          class="photo-tool-btn"
          :class="{ chosen: exifFilterOpen || hasActiveExif }"
          @click="toggleExifFilter()"
        >
          <SlidersHorizontal :size="14" /> 参数筛选
        </button>
      </div>
      <div v-if="hasAssets && hasTimelineYears && !isOnThisDay" class="timeline-jump">
        <AppleSelect
          v-model="jumpYear"
          :options="yearOptions"
          placeholder="年份"
          size="sm"
          aria-label="选择年份"
          @change="onJumpYearChange()"
        />
        <AppleSelect
          v-model="jumpMonth"
          :options="monthOptions"
          placeholder="月份"
          :disabled="!hasJumpMonths"
          size="sm"
          aria-label="选择月份"
          @change="jumpToTimeline()"
        />
        <button type="button" class="timeline-jump-top" title="回到最新照片" @click="scrollToTop()">
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
      @select="selectSearchMode(m.value)"
    >
      {{ m.label }}
    </IsleChip>
    <button v-if="activePersonName" type="button" class="refresh" @click="clearPerson()">
      人物：{{ activePersonName }} ×
    </button>
  </div>

  <div v-if="exifFilterOpen || hasActiveExif" class="photos-filter-drawer">
    <AppleSelect
      v-if="cameraOptions.length > 1"
      v-model="cameraFilter"
      :options="cameraOptions"
      size="sm"
      aria-label="按相机型号筛选"
      @change="onExifFilterChange()"
    />
    <AppleSelect
      v-model="locationFilter"
      :options="locationOptions"
      size="sm"
      aria-label="按定位信息筛选"
      @change="onExifFilterChange()"
    />
    <AppleSelect
      v-if="filterYearOptions.length > 1"
      v-model="yearFilter"
      :options="filterYearOptions"
      size="sm"
      aria-label="按拍摄年份筛选"
      @change="onExifFilterChange()"
    />
    <button v-if="hasActiveExif" type="button" class="refresh" @click="resetExifFiltersAndReload()">清除筛选</button>
  </div>

  <div v-if="searchApplied || hasActiveExif || activePersonName || typeFilter" class="photos-filter-summary" role="region" aria-label="当前生效筛选条件">
    <span class="filter-summary-label">已生效条件：</span>
    <span v-if="searchApplied" class="filter-summary-chip">关键词「{{ searchApplied }}」</span>
    <span v-if="typeFilter" class="filter-summary-chip">类型：{{ typeFilter === "video" ? "视频" : typeFilter === "live" ? "实况照片" : "照片" }}</span>
    <span v-if="activePersonName" class="filter-summary-chip">人物：{{ activePersonName }}</span>
    <span v-if="cameraFilter" class="filter-summary-chip">相机：{{ cameraFilter }}</span>
    <span v-if="locationFilter" class="filter-summary-chip">定位：{{ locationFilter === "yes" || locationFilter === "1" ? "含定位" : locationFilter === "no" || locationFilter === "0" ? "无定位" : locationFilter }}</span>
    <span v-if="yearFilter" class="filter-summary-chip">年份：{{ yearFilter }}</span>
    <button type="button" class="filter-summary-clear" @click="clearAllFilters()">
      <X :size="12" /> 清除全部条件
    </button>
  </div>

  <div v-if="showMemoriesStrip && smartMemories.length > 0" class="photos-memories-strip" aria-label="智能回忆与精选">
    <button
      v-for="mem in smartMemories.slice(0, 4)"
      :key="mem.id"
      type="button"
      class="memory-card"
      @click="selectSmartMemory(mem)"
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
