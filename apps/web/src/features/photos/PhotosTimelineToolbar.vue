<script setup lang="ts">
import { computed, inject, onBeforeUnmount, onMounted, ref } from "vue";
import {
  Check, ChevronDown, FileSearch, Film, FolderPlus, Grid2x2, Grid3x3, Heart, Images,
  Lock, Monitor, Plus, SlidersHorizontal, Sparkles, Star, Users, X,
} from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleChip from "../../components/ui/IsleChip.vue";
import IsleSearchInput from "../../components/ui/IsleSearchInput.vue";
import PhotoMemoriesStrip from "./PhotoMemoriesStrip.vue";
import { PHOTO_SEARCH_MODES } from "./usePhotoAISearchAndPeople.ts";
import { PHOTO_TIMELINE_CTX } from "../../contexts/photosContext.ts";
import { PHOTO_STAGE_EXT_CTX } from "./photoStageContext.ts";

const ctx = inject(PHOTO_TIMELINE_CTX);
if (!ctx) throw new Error("PhotosTimelineToolbar requires PHOTO_TIMELINE_CTX");
const stageExt = inject(PHOTO_STAGE_EXT_CTX, null);

const {
  activeAlbum, activePrivateAlbum, activeFolderAlbum, currentPrivateAlbum, currentAlbum,
  favoritesOnly, personalOnly, isOnThisDay, albums, privateAlbums, folderAlbums,
  typeFilter, exifFilterOpen, hasActiveExif, hasAssets,
  searchInput, searchPlaceholder, searchApplied, searchMode, activePersonName,
  cameraFilter, cameraOptions, locationFilter, locationOptions, yearFilter, filterYearOptions,
  showMemoriesStrip, smartMemories, compactGrid, trashSelecting, trashBusy,
  selectAll, selectOnThisDay, selectPersonal, selectFavorites, openFolderAlbum,
  openSharedAlbum, openPrivateAlbum, goCreateFolderAlbum, setTypeFilter, selectSmartMemory,
  toggleExifFilter, onSearchSubmit, onSearchClear, toggleCompactGrid, toggleTrashSelecting,
  selectSearchMode, clearPerson, onExifFilterChange, resetExifFiltersAndReload,
  clearAllFilters, openPhotoFrame,
} = ctx;

const albumMenuRef = ref<HTMLDetailsElement | null>(null);

const advancedDrawerOpen = computed(() =>
  Boolean(
    exifFilterOpen.value ||
    hasActiveExif.value ||
    searchInput.value ||
    searchApplied.value ||
    activePersonName.value,
  ),
);

const hasActiveSummary = computed(() =>
  Boolean(searchApplied.value || hasActiveExif.value || activePersonName.value || typeFilter.value),
);

const totalAlbumsCount = computed(() =>
  albums.value.length + privateAlbums.value.length + folderAlbums.value.length,
);

function closeAlbumMenu() {
  if (albumMenuRef.value) albumMenuRef.value.open = false;
}

function handleOutsidePointerDown(event: PointerEvent) {
  const menu = albumMenuRef.value;
  if (!menu?.open) return;
  if (event.target instanceof Node && !menu.contains(event.target)) {
    menu.open = false;
  }
}

function handleMenuEscape(event: KeyboardEvent) {
  const menu = albumMenuRef.value;
  if (event.key !== "Escape" || !menu?.open) return;
  event.preventDefault();
  event.stopPropagation();
  menu.open = false;
  menu.querySelector("summary")?.focus();
}

onMounted(() => {
  document.addEventListener("pointerdown", handleOutsidePointerDown, true);
  document.addEventListener("keydown", handleMenuEscape);
});

onBeforeUnmount(() => {
  document.removeEventListener("pointerdown", handleOutsidePointerDown, true);
  document.removeEventListener("keydown", handleMenuEscape);
});
</script>

<template>
  <div class="photos-nav-bar">
    <div class="photos-nav-primary">
      <div class="photos-tabs-row">
        <div class="album-tabs album-primary-tabs">
          <IsleChip
            small
            :selected="activeAlbum === 0 && !activePrivateAlbum && !activeFolderAlbum && !favoritesOnly && !personalOnly && !isOnThisDay"
            @select="selectAll()"
          >
            <template #icon><Images :size="14" /></template>全部照片
          </IsleChip>
          <IsleChip small :selected="isOnThisDay" @select="selectOnThisDay()">
            <template #icon><Sparkles :size="14" /></template>那年今天
          </IsleChip>
          <IsleChip
            small
            :selected="personalOnly"
            title="仅当前账号可见的个人收藏"
            @select="selectPersonal()"
          >
            <template #icon><Star :size="14" /></template>我的收藏
          </IsleChip>
          <IsleChip
            small
            :selected="favoritesOnly"
            title="共享目录成员均可见的家庭共享收藏"
            @select="selectFavorites()"
          >
            <template #icon><Heart :size="14" /></template>共享收藏
          </IsleChip>
          <IsleChip
            small
            :selected="false"
            title="进入家庭档案，按票据/证件分类进行离线 OCR 秒搜"
            @select="stageExt?.openDocsArchive?.()"
          >
            <template #icon><FileSearch :size="14" /></template>家庭档案
          </IsleChip>
        </div>

        <details ref="albumMenuRef" class="photo-albums-menu">
          <summary :aria-label="'浏览相册，共 ' + totalAlbumsCount + ' 个'">
            <FolderPlus :size="14" />
            <span>{{ activeFolderAlbum?.name || currentPrivateAlbum?.name || currentAlbum?.name || "相册" }}</span>
            <small class="photo-albums-count">{{ totalAlbumsCount }}</small>
            <ChevronDown :size="13" class="photo-albums-chevron" />
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
                  @click="closeAlbumMenu(); openFolderAlbum(album)"
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
                  @click="closeAlbumMenu(); openSharedAlbum(album.id)"
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
                  @click="closeAlbumMenu(); openPrivateAlbum(album.id)"
                >
                  <Lock :size="14" /> {{ album.name }} <small>{{ album.count }}</small>
                </button>
              </template>
            </div>
            <div class="photo-albums-menu-create">
              <button type="button" class="album-create" @click="closeAlbumMenu(); goCreateFolderAlbum()">
                <Plus :size="16" /> 新建文件夹相册
              </button>
            </div>
          </div>
        </details>

        <span class="photos-bar-divider" aria-hidden="true" />

        <div class="type-tabs" role="group" aria-label="媒体类型">
          <IsleChip small :selected="!typeFilter" @select="setTypeFilter('')">全部</IsleChip>
          <IsleChip small :selected="typeFilter === 'photo'" @select="setTypeFilter('photo')">
            <template #icon><Images :size="12" /></template>照片
          </IsleChip>
          <IsleChip small :selected="typeFilter === 'live'" @select="setTypeFilter('live')">
            <template #icon><Sparkles :size="12" /></template>实况
          </IsleChip>
          <IsleChip small :selected="typeFilter === 'video'" @select="setTypeFilter('video')">
            <template #icon><Film :size="12" /></template>视频
          </IsleChip>
        </div>
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
          :class="{ chosen: exifFilterOpen || hasActiveExif }"
          :aria-expanded="advancedDrawerOpen"
          title="展开智能搜索范围与拍摄参数筛选"
          @click="toggleExifFilter()"
        >
          <SlidersHorizontal :size="14" />
          <span>筛选</span>
        </button>
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
          v-if="hasAssets"
          type="button"
          class="photo-tool-btn"
          title="全屏电子相框轮播当前照片"
          aria-label="开启电子相框"
          @click="openPhotoFrame()"
        >
          <Monitor :size="14" />
          <span>相框</span>
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
          <Check :size="14" />
          <span>{{ trashSelecting ? "退出" : "多选" }}</span>
        </button>
      </div>
    </div>

    <div
      class="photos-advanced-disclosure"
      :class="{ 'is-open': advancedDrawerOpen }"
      :aria-hidden="advancedDrawerOpen ? 'false' : 'true'"
    >
      <div class="photos-advanced-inner">
        <div class="photos-advanced-body">
          <div
            v-if="searchInput || searchApplied || activePersonName || exifFilterOpen"
            class="photos-advanced-row"
            role="group"
            aria-label="智能搜索范围"
          >
            <span class="photos-advanced-label">搜索维度</span>
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

          <div v-if="exifFilterOpen || hasActiveExif" class="photos-advanced-row">
            <span class="photos-advanced-label">拍摄参数</span>
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
            <button v-if="hasActiveExif" type="button" class="refresh" @click="resetExifFiltersAndReload()">清除参数</button>
          </div>

          <div v-if="hasActiveSummary" class="photos-filter-summary" role="region" aria-label="当前生效筛选条件">
            <span class="filter-summary-label">已生效</span>
            <span v-if="searchApplied" class="filter-summary-chip">关键词「{{ searchApplied }}」</span>
            <span v-if="typeFilter" class="filter-summary-chip">类型：{{ typeFilter === "video" ? "视频" : typeFilter === "live" ? "实况照片" : "照片" }}</span>
            <span v-if="activePersonName" class="filter-summary-chip">人物：{{ activePersonName }}</span>
            <span v-if="cameraFilter" class="filter-summary-chip">相机：{{ cameraFilter }}</span>
            <span v-if="locationFilter" class="filter-summary-chip">定位：{{ locationFilter === "yes" || locationFilter === "1" ? "含定位" : locationFilter === "no" || locationFilter === "0" ? "无定位" : locationFilter }}</span>
            <span v-if="yearFilter" class="filter-summary-chip">年份：{{ yearFilter }}</span>
            <button type="button" class="filter-summary-clear" @click="clearAllFilters()">
              <X :size="12" /> 清除全部
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>

  <PhotoMemoriesStrip
    v-if="showMemoriesStrip && smartMemories.length > 0"
    :memories="smartMemories"
    :media-path="stageExt?.mediaPath ?? ((p: string) => p)"
    @select="selectSmartMemory($event)"
  />
</template>

<style scoped>
.photos-nav-primary {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px 14px;
  flex-wrap: wrap;
  min-width: 0;
}
.photos-bar-divider {
  width: 1px;
  height: 16px;
  background: var(--fluid-divider, var(--stroke-subtle));
  flex-shrink: 0;
}
.photo-albums-count {
  font-variant-numeric: tabular-nums;
  opacity: 0.72;
}
.photos-advanced-disclosure {
  display: grid;
  grid-template-rows: 0fr;
  opacity: 0;
  transition:
    grid-template-rows 240ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    opacity 180ms ease;
}
.photos-advanced-disclosure.is-open {
  grid-template-rows: 1fr;
  opacity: 1;
}
.photos-advanced-inner {
  min-height: 0;
  overflow: hidden;
}
.photos-advanced-body {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding-top: 10px;
}
.photos-advanced-row {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  min-width: 0;
}
.photos-advanced-label {
  font-size: 11.5px;
  font-weight: 650;
  color: var(--text-tertiary);
  margin-right: 2px;
  white-space: nowrap;
}
.photos-filter-summary {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
  padding: 6px 0 2px;
  font-size: 12px;
}
.filter-summary-label {
  font-weight: 650;
  color: var(--text-secondary);
}
.filter-summary-chip {
  padding: 2px 9px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--accent-primary) 10%, transparent);
  color: var(--text-primary);
  font-weight: 550;
  font-variant-numeric: tabular-nums;
}
.filter-summary-clear {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  margin-left: auto;
  padding: 3px 10px;
  border-radius: 999px;
  border: 1px solid color-mix(in srgb, var(--accent-primary) 34%, transparent);
  background: transparent;
  color: var(--accent-primary);
  font-size: 12px;
  font-weight: 650;
  cursor: pointer;
}
.filter-summary-clear:hover {
  background: color-mix(in srgb, var(--accent-primary) 12%, transparent);
}
@media (max-width: 767px) {
  .photos-bar-divider {
    display: none;
  }
}
@media (prefers-reduced-motion: reduce) {
  .photos-advanced-disclosure {
    transition: none;
  }
}
</style>
