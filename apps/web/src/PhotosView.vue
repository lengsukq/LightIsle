<script setup lang="ts">
import { createVisibleMediaPolling } from "./visibleMediaPolling.ts";
import { usePhotoPersonalFavorite } from "./usePhotoPersonalFavorite.ts";
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import { describeUserFacingError } from "./userFacingError.ts";
import { createScopedRootApi } from "./apiClient.ts";
import {
  Heart, Star, RefreshCw, Images, Film, X, FolderPlus, ChevronDown,
  ChevronLeft, ChevronRight, Info, Pencil, Trash2, Sparkles,
  Search, LayoutList, Map as MapIcon, Grid2x2, Grid3x3, Check, Users,
} from "lucide-vue-next";
import { createLatestRequestGate } from "./latestRequestGate.ts";
import { mediaQueryKey } from "./mediaQueryContext.ts";
import { rootApiPath, rootMediaPath } from "./rootApi.ts";
import PhotoMapView from "./PhotoMapView.vue";
import PhotoPeopleView from "./PhotoPeopleView.vue";
import PhotoSimilarCleanupView from "./PhotoSimilarCleanupView.vue";
import PhotoViewerInfoSidebar from "./PhotoViewerInfoSidebar.vue";
import PhotoAlbumOverviewSection from "./PhotoAlbumOverviewSection.vue";
import PhotosBatchBar from "./PhotosBatchBar.vue";
import PhotosTimelineToolbar from "./PhotosTimelineToolbar.vue";
import AppleSelect from "./AppleSelect.vue";
import IsleButton from "./IsleButton.vue";
import IsleEmpty from "./IsleEmpty.vue";
import IsleVideoPlayer from "./IsleVideoPlayer.vue";
import { usePhotoViewer } from "./usePhotoViewer.ts";
import { dateLabel } from "./photoPresentation.ts";
import { usePhotoFilterAndSharing } from "./usePhotoFilterAndSharing.ts";
import { usePhotoBatchActions, type BatchAsset } from "./usePhotoBatchActions.ts";
import { usePhotoAlbums } from "./usePhotoAlbums.ts";
import { usePhotoTimelineScrubber } from "./usePhotoTimelineScrubber.ts";
import { usePhotoGridAndModal } from "./usePhotoGridAndModal.ts";
import { usePhotoAISearchAndPeople, type PhotoViewMode } from "./usePhotoAISearchAndPeople.ts";
import { usePhotosCatalogLoader } from "./composables/usePhotosCatalogLoader.ts";

type Asset = BatchAsset;

const props = defineProps<{ active?: boolean; admin: boolean; rootId?: string; rootGeneration?: number; rootName?: string; hasOtherRoots?: boolean }>();
const assets = ref<Asset[]>([]);
const favoritesOnly = ref(false);
const personalOnly = ref(false);
const onThisDayOnly = ref(false);
const typeFilter = ref<"" | "photo" | "video">("");
const searchInput = ref("");
const searchApplied = ref("");
let searchTimer: number | undefined;

const loading = ref(false);
const galleryLoaded = ref(false);
const loadError = ref("");
const message = ref("");
const selected = ref<Asset | null>(null);
const selectedIndex = ref(-1);
const thumbnailFailed = ref<Record<number, boolean>>({});
const pendingFavorites = ref<Record<number, boolean>>({});
const photosPage = ref<HTMLElement | null>(null);
const focusedIndex = ref(0);
const nextCursor = ref(0);
const viewMode = ref<PhotoViewMode>("timeline");
watch(viewMode, (mode) => {
  void nextTick(() => {
    window.dispatchEvent(new Event("resize"));
    if (mode === "timeline") updateViewport();
  });
});

let rootEpoch = 0;
let disposed = false;
let rootScopeAbort = new AbortController();
const listRequests = createLatestRequestGate();
let viewGeneration = 0;
let selectionGeneration = 0;

function apiPath(path: string) { return rootApiPath(props.rootId, path); }
function mediaPath(path: string) { return rootMediaPath(props.rootId, props.rootGeneration ?? 0, path); }
const { api } = createScopedRootApi({
  getRootId: () => props.rootId,
  getRootGeneration: () => props.rootGeneration ?? 0,
  getEpoch: () => rootEpoch,
  getSignal: () => rootScopeAbort.signal,
});
function canWriteAsset(asset: Asset) { return props.admin || asset.canWrite === true; }
function thumb(asset: Asset) { return mediaPath("/api/v2/photos/" + asset.id + "/thumbnail"); }
function original(asset: Asset) { return mediaPath("/api/v2/files/preview?path=" + encodeURIComponent(asset.path)); }

const {
  cameraFilter, locationFilter, yearFilter, shareTargets, sharingAlbum, shareMemberId, shareCanWrite,
  cameraOptions, locationOptions, filterYearOptions, shareTargetOptions, hasActiveExifFilter,
  resetExifFilters, appendExifFilterParams, refreshFacets, openSharePanel, submitFolderAlbumShare,
  removeFolderAlbumShare, onExifFilterChange,
} = usePhotoFilterAndSharing({
  api: (url, method, body, signal) => api(url, method, body, signal),
  apiPath: (path) => apiPath(path),
  albumBusy: computed({ get: () => albumBusy.value, set: (v) => { albumBusy.value = v; } }),
  message: computed({ get: () => message.value, set: (v) => { message.value = v; } }),
  refreshFolderAlbums: (more) => refreshFolderAlbums(more),
  onFilterChanged: () => { void load(true); },
});

const {
  albums, privateAlbums, activeAlbum, activePrivateAlbum, folderAlbums, folderCursor,
  folderError, folderLoading, folderName, folderTarget, activeFolderAlbum, sharedAlbumsError,
  privateAlbumsError, sharedAlbumsLoading, privateAlbumsLoading, creating, albumName,
  addAlbum, addPrivateAlbum, creatingPrivate, editingPrivate, privateAlbumName, albumBusy,
  failedAlbumCovers, editingAlbum, folderAlbumOptions, albumOptions, privateAlbumOptions,
  currentPrivateAlbum, currentAlbum, refreshAlbums, refreshPrivateAlbums, refreshFolderAlbums,
  createFolderAlbum, deleteFolderAlbum, openFolderAlbum, addSelectedToFolder, editPrivateAlbum,
  cancelPrivateAlbum, savePrivateAlbum, deletePrivateAlbum, addSelectedPrivate,
  removeSelectedPrivate, beginAlbumRename, cancelAlbumForm, createAlbum, deleteCurrentAlbum,
  addSelected, removeSelectedFromAlbum, openAlbumFromOverview, cancelAlbumRequests,
  resetAlbumsForRootChange,
} = usePhotoAlbums({
  isAdmin: () => props.admin, assets, selected, selectedIndex, focusedIndex,
  favoritesOnly, personalOnly, onThisDayOnly, searchInput, searchApplied, viewMode,
  photosPage, shareTargets, message,
  getRootEpoch: () => rootEpoch, getViewGeneration: () => viewGeneration, bumpViewGeneration: () => ++viewGeneration,
  getSelectionGeneration: () => selectionGeneration, bumpSelectionGeneration: () => ++selectionGeneration,
  isDisposed: () => disposed, canWriteAsset, api, apiPath,
  load: (reset) => load(reset), closeModal: (restore) => { closeModal(restore); },
  focusTile: (index): Promise<void> => focusTile(index), changeView: (album, fav, mine, priv) => { changeView(album, fav, mine, priv); },
});

const {
  viewerStage, viewerScale, viewerOffset, viewerTransform, viewerAnimate, viewerPointers,
  viewerPreviewLoading, viewerPreviewError, viewerOriginalLoading, viewerOriginalError,
  browserDecodable, cancelViewerLoads, startViewerStages, requestViewerOriginal, viewerSrc,
  toggleViewerZoom, viewerPointerDown, viewerPointerMove, viewerPointerUp, viewerWheel,
} = usePhotoViewer({
  selected, mediaPath, original, thumb,
  move(delta) {
    const index = selectedIndex.value + delta;
    if (index < 0 || index >= modalAssets.value.length) return false;
    showAssetAt(index);
    return true;
  },
});

const {
  gridElement, loadMarker, galleryDialog, modalCloseButton, scrubberInView, viewerInfo,
  compactGrid, exifFilterOpen, toggleCompactGrid,
  photoMap, modalAssets, timelineLayout, virtualWindow, visibleAssets, visibleHeaders,
  mapTransport, slideshow, toggleSlideshow, showAssetAt, openAsset, openMapAsset, showOnMap,
  tileStyle, updateViewport, measureViewport, focusTile, onTileKeydown, closeModal,
  setGridActive, mountGridAndModal, unmountGridAndModal, resetBackstackForRootChange,
} = usePhotoGridAndModal({
  assets, selected, selectedIndex, focusedIndex, nextCursor, loading, loadError,
  viewMode, addAlbum, addPrivateAlbum, message, viewerAnimate, viewerScale, viewerOffset,
  bumpSelectionGeneration: () => ++selectionGeneration, startViewerStages, cancelViewerLoads,
  api, apiPath, mediaPath, load: (reset) => load(reset), isActive: () => props.active !== false,
});

const {
  searchMode, activePerson, viewerAIDetail, viewerAILoading, aiPauseBusy,
  currentSearchPlaceholder, setSearchMode, filterByPerson, clearPersonFilter,
  resetAIStateForRootChange, toggleAIPause, disposeAISearch,
} = usePhotoAISearchAndPeople({
  selected, viewMode, message, api, apiPath,
  onFilterChanged: () => { void load(true); },
  onStatusRefresh: () => status(),
});

function photoQueryKey() {
  return mediaQueryKey({
    root: props.rootId ?? "", generation: props.rootGeneration ?? 0,
    album: activeAlbum.value, privateAlbum: activePrivateAlbum.value,
    directory: activeFolderAlbum.value?.path ?? "", favorites: favoritesOnly.value,
    personal: personalOnly.value, onThisDay: onThisDayOnly.value, type: typeFilter.value,
    q: searchApplied.value, searchMode: searchApplied.value ? searchMode.value : "",
    person: activePerson.value?.id ?? 0,
    camera: cameraFilter.value, loc: locationFilter.value, year: yearFilter.value,
  });
}

function isFullTimelineView() {
  return !activeAlbum.value && !activePrivateAlbum.value && !activeFolderAlbum.value && !favoritesOnly.value &&
    !personalOnly.value && !onThisDayOnly.value && !typeFilter.value && !searchApplied.value && !activePerson.value && !hasActiveExifFilter();
}

const {
  timelineCursorStart, fullTimelineMonths, timelineYears, jumpYear, jumpMonth,
  jumpMonths, yearOptions, monthOptions, browseTitle, scrubMonths, scrubbing,
  scrubPreview, scrubCurrentIndex, refreshTimelineIndex, jumpToTimeline,
  onJumpYearChange, startScrub, moveScrub, stopScrub, scrubKeydown, scrollToTop,
  resetScrubberForRootChange,
} = usePhotoTimelineScrubber({
  assets, nextCursor, loading, loadError, galleryLoaded, focusedIndex,
  gridElement, scrubberInView, timelineLayout, virtualWindow, isFullTimelineView,
  beginListRequest: () => listRequests.begin(), getRootEpoch: () => rootEpoch,
  isDisposed: () => disposed, api, apiPath, load: (reset) => load(reset),
  updateViewport, measureViewport,
});

const {
  scanActionError, scanStatusLoading, scanStatusLoaded, scanStatusError, scan,
  status, load, retryLoad, startScan, toggleFavorite, changeView, showOnThisDay,
  resetCatalogForRootChange, disposeCatalogLoader,
} = usePhotosCatalogLoader({
  props, assets, nextCursor, loading, galleryLoaded, loadError, focusedIndex, timelineCursorStart,
  activeAlbum, activePrivateAlbum, activeFolderAlbum, favoritesOnly, personalOnly, onThisDayOnly,
  typeFilter, searchInput, searchApplied, searchMode, activePerson, selected, selectedIndex,
  pendingFavorites, message, photosPage, loadMarker, photoQueryKey,
  beginListRequest: () => listRequests.begin(),
  getRootEpoch: () => rootEpoch,
  getSelectionGeneration: () => selectionGeneration,
  bumpViewGeneration: () => { viewGeneration += 1; },
  bumpSelectionGeneration: () => { selectionGeneration += 1; },
  isDisposed: () => disposed,
  api, apiPath, appendExifFilterParams, updateViewport,
  onScanCompleted: () => {
    void refreshAlbums(); void refreshPrivateAlbums(); void refreshTimelineIndex(); void refreshFacets();
  },
});

const {
  trashSelecting, trashBusy, trashIDs, batchFolderTarget, batchPrivateAlbum,
  batchShareLinks, batchShareNotice, previousRootShareWarning, toggleTrashID,
  isMonthSelected, toggleMonthSelection,
  trashPhotos, trashSelectedPhotos, batchToFolder, batchToPrivateAlbum,
  batchShare, batchDownload, copyBatchShareLinks, resetBatchForRootChange,
  notifyBatchOnUnmount,
} = usePhotoBatchActions({
  assets, selected, folderAlbums, privateAlbums, message, photoQueryKey,
  getRootEpoch: () => rootEpoch, getViewGeneration: () => viewGeneration, isDisposed: () => disposed,
  getRootId: () => props.rootId, getRootGeneration: () => props.rootGeneration ?? 0,
  canWriteAsset, api, apiPath, mediaPath, closeModal: (restore) => closeModal(restore),
  load: (reset) => load(reset), refreshPrivateAlbums,
});

function setTypeFilter(kind: "" | "photo" | "video") {
  if (typeFilter.value === kind) return;
  typeFilter.value = kind;
  void load(true);
}

watch(searchInput, (value) => {
  if (searchTimer) clearTimeout(searchTimer);
  searchTimer = window.setTimeout(() => {
    const term = value.trim();
    if (term === searchApplied.value) return;
    searchApplied.value = term;
    void load(true);
  }, 400);
});

const togglePersonalFavorite = usePhotoPersonalFavorite({
  pendingFavorites, assets, selected, selectedIndex, personalOnly, message,
  generation: () => selectionGeneration,
  save: (id, favorite) => api(apiPath("/api/v2/photos/" + id + "/personal-favorite"), "POST", { favorite }),
  reload: () => load(true), closeModal, focusTile,
});

const setScanPolling = createVisibleMediaPolling(status, 4500);
onMounted(() => {
  disposed = false;
  mountGridAndModal();
  void load(true); void refreshAlbums(); void refreshPrivateAlbums(); void refreshFolderAlbums();
  void refreshTimelineIndex(); void refreshFacets(); void status();
  setScanPolling(props.active !== false);
});
watch([() => props.rootId, () => props.rootGeneration], () => {
  resetBackstackForRootChange();
  resetBatchForRootChange();
  rootScopeAbort.abort(); rootScopeAbort = new AbortController();
  rootEpoch += 1; viewGeneration += 1; selectionGeneration += 1;
  listRequests.cancel(); resetAlbumsForRootChange(); resetScrubberForRootChange();
  assets.value = []; favoritesOnly.value = false; personalOnly.value = false; nextCursor.value = 0;
  loading.value = false; galleryLoaded.value = false; viewMode.value = "timeline"; onThisDayOnly.value = false;
  typeFilter.value = ""; searchInput.value = ""; searchApplied.value = ""; resetExifFilters(); resetAIStateForRootChange(); sharingAlbum.value = null;
  if (searchTimer) clearTimeout(searchTimer);
  resetCatalogForRootChange();
  selected.value = null; selectedIndex.value = -1; message.value = ""; focusedIndex.value = 0;
  void load(true); void refreshAlbums(); void refreshPrivateAlbums(); void refreshFolderAlbums();
  void refreshTimelineIndex(); void refreshFacets(); void status();
}, { flush: "sync" });
watch(() => props.active, (val) => {
  const isActive = val !== false;
  setGridActive(isActive);
  if (!isActive) {
    setScanPolling(false);
    if (selected.value) closeModal(false);
  } else {
    setScanPolling(props.active !== false);
    if (!document.hidden) void status();
  }
});
onUnmounted(() => {
  notifyBatchOnUnmount();
  disposed = true;
  rootEpoch += 1;
  rootScopeAbort.abort();
  unmountGridAndModal();
  cancelViewerLoads();
  setScanPolling(false);
  if (searchTimer) clearTimeout(searchTimer);
  listRequests.cancel();
  cancelAlbumRequests();
  disposeAISearch();
  disposeCatalogLoader();
});
</script>

<template>
  <div ref="photosPage" class="content photos-page">
    <div class="section-heading photos-header-bar">
      <div>
        <h2>时光相册</h2>
        <p>{{ activePerson ? "人物筛选 · " + activePerson.name : activeFolderAlbum ? "文件夹相册 · " + activeFolderAlbum.name : currentPrivateAlbum ? "私人相册 · " + currentPrivateAlbum.name : currentAlbum ? "共享相册 · " + currentAlbum.name : onThisDayOnly ? "那年今天" : personalOnly ? "我的收藏" : favoritesOnly ? "共享收藏" : browseTitle ? "正在浏览 " + browseTitle : "按时间线、相册、人物与智能语义浏览原片。" }}</p>
      </div>
      <div class="photos-header-actions">
        <div class="photo-mode-tabs" role="tablist" aria-label="照片浏览方式">
          <button type="button" role="tab" :aria-selected="viewMode==='timeline'" :class="{chosen:viewMode==='timeline'}" @click="viewMode='timeline'"><LayoutList :size="15"/> 时间线</button>
          <button type="button" role="tab" :aria-selected="viewMode==='people'" :class="{chosen:viewMode==='people'}" @click="viewMode='people'"><Users :size="15"/> 人物</button>
          <button type="button" role="tab" :aria-selected="viewMode==='cleanup'" :class="{chosen:viewMode==='cleanup'}" @click="viewMode='cleanup'"><Sparkles :size="15"/> 相似清理</button>
          <button type="button" role="tab" :aria-selected="viewMode==='albums'" :class="{chosen:viewMode==='albums'}" @click="viewMode='albums';refreshFolderAlbums()"><Images :size="15"/> 相册</button>
          <button type="button" role="tab" :aria-selected="viewMode==='map'" :class="{chosen:viewMode==='map'}" @click="viewMode='map'"><MapIcon :size="15"/> 地图回溯</button>
        </div>
        <template v-if="viewMode==='timeline'">
          <label class="timeline-search">
            <Search :size="14"/>
            <input v-model="searchInput" :placeholder="currentSearchPlaceholder()" aria-label="搜索照片和视频" enterkeyhint="search">
            <button v-if="searchInput" type="button" title="清除搜索" @click="searchInput=''"><X :size="13"/></button>
          </label>
          <button type="button" class="photo-tool-btn" :class="{chosen:compactGrid}" :title="compactGrid?'切换舒适视图':'切换紧凑视图'" :aria-label="compactGrid?'切换舒适视图':'切换紧凑视图'" @click="toggleCompactGrid">
            <Grid3x3 v-if="compactGrid" :size="15"/><Grid2x2 v-else :size="15"/>
            <span>{{ compactGrid ? "紧凑" : "舒适" }}</span>
          </button>
          <button type="button" class="photo-tool-btn" :class="{chosen:trashSelecting}" :disabled="trashBusy" @click="trashSelecting=!trashSelecting;trashIDs=new Set()">
            <Check :size="15"/> {{ trashSelecting ? "退出多选" : "多选" }}
          </button>
        </template>
        <button v-if="admin" type="button" class="refresh" @click="startScan" :disabled="scan.running&&!scanStatusError">
          <RefreshCw :size="15" :class="{spinning:scan.running&&!scanStatusError}" /> {{scan.running&&!scanStatusError?"扫描中…":"扫描媒体"}}
        </button>
      </div>
    </div>

    <p v-if="previousRootShareWarning" class="form-error" role="alert">{{previousRootShareWarning}} <button type="button" class="refresh" @click="previousRootShareWarning=''">知道了</button></p>
    <div v-if="scan.running&&!scanStatusError" class="scan-banner">正在后台整理媒体 · 已检查 {{scan.scanned}} 项 · 发现 {{scan.found}} 项</div>
    <div v-else-if="scan.aiIndexing&&(scan.aiIndexing.running||scan.aiIndexing.paused||(scan.aiIndexing.remaining??0)>0)" class="scan-banner">
      <span>{{ scan.aiIndexing.paused ? "智能识图与 OCR 索引已暂停" : "正在后台建立智能识图与离线 OCR 索引" }}<template v-if="scan.aiIndexing.remaining != null"> · 待处理 {{ scan.aiIndexing.remaining }} 张</template></span>
      <button v-if="admin" type="button" class="refresh" style="margin-left:10px" :disabled="aiPauseBusy" @click="toggleAIPause(scan.aiIndexing.paused)">{{ scan.aiIndexing.paused ? "恢复索引" : "暂停索引" }}</button>
    </div>
    <div v-if="scanStatusError&&assets.length" class="form-error" role="alert">扫描状态读取失败：{{scanStatusError}} <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span><button type="button" class="refresh" :disabled="scanStatusLoading" @click="status">{{scanStatusLoading?"正在重试…":"重试状态"}}</button></div>
    <p v-if="scanStatusLoaded&&scan.lastError&&assets.length" class="form-error">上次扫描：{{describeUserFacingError(scan.lastError)}}</p>
    <p v-if="message" class="gallery-message">{{message}}</p>
    <p v-if="scanActionError&&assets.length" class="gallery-message" role="alert">{{scanActionError}}</p>
    <PhotoMapView v-if="props.active !== false && viewMode === 'map'" :key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :root-id="props.rootId" :root-generation="props.rootGeneration" ref="photoMap" :transport="mapTransport" @open-asset="openMapAsset"/>
    <PhotoPeopleView v-if="props.active !== false && viewMode === 'people'" :active="viewMode === 'people'" :root-key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :api="api" :api-path="apiPath" :media-path="mediaPath" @select-person="filterByPerson" />
    <PhotoSimilarCleanupView v-if="props.active !== false && viewMode === 'cleanup'" :active="viewMode === 'cleanup'" :root-key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :api="api" :api-path="apiPath" :media-path="mediaPath" @trashed="load(true); status()" />
    <PhotoAlbumOverviewSection
      v-show="viewMode==='albums'"
      :admin="admin" :folder-albums="folderAlbums" :folder-cursor="folderCursor" :folder-error="folderError"
      :folder-loading="folderLoading" :folder-name="folderName" :album-busy="albumBusy"
      :share-targets-count="shareTargets.length" :sharing-album-path="sharingAlbum?.path ?? ''"
      :share-member-id="shareMemberId" :share-can-write="shareCanWrite" :share-target-options="shareTargetOptions"
      :private-albums="privateAlbums" :private-albums-error="privateAlbumsError" :private-albums-loading="privateAlbumsLoading"
      :albums="albums" :shared-albums-error="sharedAlbumsError" :shared-albums-loading="sharedAlbumsLoading"
      :failed-album-covers="failedAlbumCovers" :media-path="mediaPath"
      @update:folder-name="folderName = $event" @update:share-member-id="shareMemberId = $event" @update:share-can-write="shareCanWrite = $event"
      @refresh-folders="refreshFolderAlbums($event)" @create-folder="createFolderAlbum" @open-folder="openFolderAlbum"
      @open-share="openSharePanel" @delete-folder="deleteFolderAlbum" @submit-share="submitFolderAlbumShare"
      @remove-share="removeFolderAlbumShare" @refresh-private="refreshPrivateAlbums()" @refresh-shared="refreshAlbums"
      @open-legacy="openAlbumFromOverview" @cover-error="failedAlbumCovers[$event] = true"
    />
    <div v-show="viewMode==='timeline'">
      <PhotosTimelineToolbar
        :active-album="activeAlbum"
        :active-private-album="activePrivateAlbum"
        :active-folder-album="activeFolderAlbum"
        :current-private-album="currentPrivateAlbum"
        :current-album="currentAlbum"
        :favorites-only="favoritesOnly"
        :personal-only="personalOnly"
        :is-on-this-day="onThisDayOnly"
        :albums="albums"
        :private-albums="privateAlbums"
        :folder-albums="folderAlbums"
        :type-filter="typeFilter"
        :exif-filter-open="exifFilterOpen"
        :has-active-exif="hasActiveExifFilter()"
        :has-assets="assets.length > 0"
        :has-timeline-years="timelineYears.length > 0"
        :jump-year="jumpYear"
        :jump-month="jumpMonth"
        :has-jump-months="jumpMonths.length > 0"
        :year-options="yearOptions"
        :month-options="monthOptions"
        :search-input="searchInput"
        :search-applied="searchApplied"
        :search-mode="searchMode"
        :active-person-name="activePerson?.name ?? ''"
        :camera-filter="cameraFilter"
        :camera-options="cameraOptions"
        :location-filter="locationFilter"
        :location-options="locationOptions"
        :year-filter="yearFilter"
        :filter-year-options="filterYearOptions"
        :show-memories-strip="isFullTimelineView() && assets.length > 0"
        @select-all="changeView(0, false)"
        @select-on-this-day="showOnThisDay()"
        @select-personal="changeView(0, false, true)"
        @select-favorites="changeView(0, true)"
        @open-folder-album="openFolderAlbum"
        @open-shared-album="(id) => changeView(id, false)"
        @open-private-album="(id) => changeView(0, false, false, id)"
        @go-create-folder-album="viewMode = 'albums'; refreshFolderAlbums()"
        @set-type-filter="setTypeFilter"
        @toggle-exif-filter="exifFilterOpen = !exifFilterOpen"
        @update:jump-year="jumpYear = $event"
        @jump-year-change="onJumpYearChange"
        @update:jump-month="jumpMonth = $event"
        @jump-timeline="jumpToTimeline"
        @scroll-top="scrollToTop"
        @select-search-mode="(m) => setSearchMode(m, Boolean(searchApplied))"
        @clear-person="clearPersonFilter"
        @update:camera-filter="cameraFilter = $event"
        @update:location-filter="locationFilter = $event"
        @update:year-filter="yearFilter = $event"
        @exif-filter-change="onExifFilterChange"
        @reset-exif-filters="resetExifFilters(); onExifFilterChange()"
        @open-map-view="viewMode = 'map'"
      />

    <div v-if="sharedAlbumsError&&!selected" class="gallery-message" role="alert">共享相册读取失败：{{sharedAlbumsError}} <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="refreshAlbums">{{sharedAlbumsLoading?"正在重试…":"重试共享相册"}}</button></div>
    <div v-if="privateAlbumsError&&!selected" class="gallery-message" role="alert">私人相册读取失败：{{privateAlbumsError}} <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="refreshPrivateAlbums()">{{privateAlbumsLoading?"正在重试…":"重试私人相册"}}</button></div>
    <div v-if="activeFolderAlbum" class="album-management"><span>文件夹相册：{{activeFolderAlbum.name}}</span><button type="button" class="refresh" @click="viewMode='albums';refreshFolderAlbums()">返回相册</button></div>
    <div v-if="currentPrivateAlbum" class="album-management">
      <span>我的私人相册：{{currentPrivateAlbum.name}}（只有当前账号可查看）</span>
      <button type="button" :disabled="albumBusy" @click="editPrivateAlbum(currentPrivateAlbum)"><Pencil :size="14"/> 改名</button>
      <button type="button" :disabled="albumBusy" class="album-delete" @click="deletePrivateAlbum"><Trash2 :size="14"/> 删除</button>
    </div>
    <form v-if="creatingPrivate" class="album-new" @submit.prevent="savePrivateAlbum">
      <FolderPlus :size="18"/>
      <input v-model="privateAlbumName" maxlength="120" aria-label="私人相册名称" placeholder="私人相册名称（最多60个字符）" required/>
      <button type="submit" :disabled="albumBusy">{{albumBusy?"保存中…":editingPrivate?"保存修改":"创建私人相册"}}</button>
      <button type="button" class="album-cancel" :disabled="albumBusy" @click="cancelPrivateAlbum">取消</button>
    </form>
    <div v-if="admin&&currentAlbum" class="album-management">
      <span>当前相册：{{currentAlbum.name}}</span>
      <button type="button" :disabled="albumBusy" @click="beginAlbumRename(currentAlbum)"><Pencil :size="14"/>改名</button>
      <button type="button" class="album-delete" :disabled="albumBusy" @click="deleteCurrentAlbum"><Trash2 :size="14"/>删除相册</button>
    </div>
    <form v-if="admin&&creating" class="album-new" @submit.prevent="createAlbum">
      <FolderPlus :size="18"/><input v-model="albumName" maxlength="120" aria-label="相册名称，最多60个字符" placeholder="相册名称（最多60个字符）" required/>
      <button type="submit" :disabled="albumBusy">{{albumBusy?"保存中…":editingAlbum?"保存修改":"创建"}}</button>
      <button type="button" class="album-cancel" :disabled="albumBusy" @click="cancelAlbumForm">取消</button>
    </form>
    <IsleEmpty
      v-if="!assets.length && (loadError || scanActionError || scanStatusError || scanStatusLoaded&&scan.lastError)"
      :icon="Images"
      :icon-size="44"
      :title="loadError ? '暂时无法读取图库' : scanActionError ? '扫描无法启动' : scanStatusError ? '无法确认扫描状态' : '上次扫描未完成'"
      :description="loadError || scanActionError || (scanStatusError ? '扫描状态暂不可用：' + scanStatusError : '上次扫描未完成：' + describeUserFacingError(scan.lastError))"
      role="alert"
    >
      <template #action>
        <IsleButton v-if="loadError" variant="tonal" size="sm" :disabled="loading" @click="retryLoad">重试读取图库</IsleButton>
        <IsleButton v-if="scanStatusError" variant="tonal" size="sm" :disabled="scanStatusLoading" @click="status">重试读取扫描状态</IsleButton>
        <IsleButton v-if="admin && (!loadError || scanActionError || scan.lastError)" variant="tonal" size="sm" :disabled="scan.running && !scanStatusError" @click="startScan">重新扫描</IsleButton>
      </template>
    </IsleEmpty>
    <IsleEmpty
      v-else-if="!assets.length && (loading || !galleryLoaded || (!scanStatusLoaded && !scanStatusError) || scan.running && !scanStatusError)"
      :icon="Images"
      :icon-size="44"
      :title="scan.running && !scanStatusError ? '正在扫描媒体…' : !scanStatusLoaded && !scanStatusError ? '正在确认媒体扫描状态…' : '正在读取媒体索引…'"
    />
    <IsleEmpty
      v-else-if="!assets.length"
      :icon="Images"
      :icon-size="44"
      :title="searchApplied ? '没有匹配「' + searchApplied + '」的媒体' : activeFolderAlbum ? '文件夹相册还没有照片' : currentPrivateAlbum ? '私人相册还没有照片' : currentAlbum ? '此相册还没有照片' : onThisDayOnly ? '今天还没有那年今天的回忆' : personalOnly ? '还没有个人收藏' : favoritesOnly ? '还没有共享收藏' : typeFilter === 'video' ? '这里还没有视频' : typeFilter === 'photo' ? '这里还没有照片' : rootName ? `当前目录「${rootName}」还没有照片或视频` : '这里还没有照片或视频'"
    >
      <p v-if="activeFolderAlbum">可在文件页放入照片，或在照片预览中复制/移动到此相册。</p>
      <p v-else-if="currentPrivateAlbum">在全部照片中打开预览，选择「加入我的相册」（仅自己可见）。</p>
      <p v-else-if="currentAlbum">在全部照片中打开预览，选择此相册并点击「加入相册」。</p>
      <p v-else-if="onThisDayOnly">带拍摄时间的往年同日照片与视频会自动显示在这里。</p>
      <p v-else-if="favoritesOnly">在预览中点击心形收藏，已授权成员可共同浏览。</p>
      <p v-else-if="personalOnly">在预览中点击星标收藏，仅自己可见。</p>
      <p v-else>上传照片或视频后点击「扫描媒体」即可显示。<span v-if="!admin">请联系管理员执行扫描。</span><template v-if="hasOtherRoots"> 若迁移前的照片或相册保存在原存储目录（如旧盘根层或「图库 / PhonePhotos」），原数据未丢失：可在右上角切换存储目录查看，或在 Mac 访达中将原照片放入当前个人相册目录后重新扫描。</template></p>
      <template v-if="activeFolderAlbum || currentAlbum || currentPrivateAlbum || favoritesOnly || personalOnly || onThisDayOnly" #action>
        <IsleButton variant="tonal" size="sm" @click="changeView(0, false)">浏览全部照片</IsleButton>
      </template>
    </IsleEmpty>
    <p v-if="loadError&&assets.length" class="form-error" role="alert">{{loadError}} 当前仍显示上次成功读取的内容。 <button type="button" class="refresh" :disabled="loading" @click="retryLoad">重试加载</button></p>
    <div v-if="assets.length" ref="gridElement" class="photo-grid" :class="{'photo-grid-compact':compactGrid}" role="group" aria-label="按年月排列的照片和视频" :style="{height:timelineLayout.totalHeight+'px'}">
      <div v-for="header in visibleHeaders" :key="header.startIndex" class="photo-month-heading" :style="{top:header.top+'px'}" role="heading" aria-level="3">
        <div class="photo-month-title">{{header.title}} <small>{{header.count}} 项<span v-if="nextCursor"> · 已加载</span></small></div>
        <button type="button" class="photo-month-select" :class="{chosen:isMonthSelected(header)}" :disabled="trashBusy" :title="isMonthSelected(header)?'取消选择当月':'全选当月照片'" @click.stop="toggleMonthSelection(header)">
          <span>{{ isMonthSelected(header) ? "✓ 已选当月" : "全选当月" }}</span>
        </button>
      </div>
      <button v-for="(asset,visibleIndex) in visibleAssets" :key="asset.id" type="button" class="photo-tile"
        :aria-pressed="trashSelecting?trashIDs.has(asset.id):undefined"
        :class="{ 'photo-trash-selected': trashSelecting&&trashIDs.has(asset.id) }"
        :data-photo-index="virtualWindow.startIndex+visibleIndex"
        :tabindex="virtualWindow.startIndex+visibleIndex===focusedIndex?0:-1"
        :style="tileStyle(virtualWindow.startIndex+visibleIndex)"
        @focus="focusedIndex=virtualWindow.startIndex+visibleIndex"
        @keydown="onTileKeydown($event,virtualWindow.startIndex+visibleIndex)"
        @click="trashSelecting?toggleTrashID(asset.id):openAsset(asset,virtualWindow.startIndex+visibleIndex)">
        <img v-if="!thumbnailFailed[asset.id]" :src="thumb(asset)" loading="lazy" :alt="asset.name" @error="thumbnailFailed[asset.id]=true"/>
        <div v-else class="video-placeholder"><Film v-if="asset.type==='video'" :size="26"/><Images v-else :size="26"/><small>{{asset.type==='video'?"视频":"预览暂不可用"}}</small></div>
        <span v-if="asset.favorite" class="photo-liked"><Heart :size="16" fill="currentColor"/></span>
        <span v-if="asset.personalFavorite" class="photo-private-liked" title="我的收藏"><Star :size="14" fill="currentColor"/></span>
        <span v-if="trashSelecting" class="photo-trash-indicator">{{trashIDs.has(asset.id)?"✓":"○"}}</span>
        <small class="photo-date">{{dateLabel(asset.takenAt)}}</small>
      </button>
    </div>
    <div v-if="scrubberInView&&isFullTimelineView()&&viewMode==='timeline'&&!selected&&fullTimelineMonths.length>1&&scrubMonths.length>1"
      class="photo-timeline-scrubber" :class="{'is-dragging':scrubbing}">
      <div v-if="scrubbing" class="photo-scrubber-preview" aria-live="off"
        :style="{top:(scrubPreview+.5)/scrubMonths.length*100+'%'}">{{scrubMonths[scrubPreview]?.title}}</div>
      <div class="photo-scrubber-track" role="slider" tabindex="0" aria-label="按年月快速浏览照片"
        aria-orientation="vertical" :aria-valuemin="0" :aria-valuemax="scrubMonths.length-1"
        :aria-valuenow="scrubCurrentIndex" :aria-valuetext="scrubMonths[scrubCurrentIndex]?.title"
        title="拖动选择年月，松手跳转" @pointerdown="startScrub" @pointermove="moveScrub"
        @pointerup="stopScrub($event)" @pointercancel="stopScrub($event,false)"
        @keydown="scrubKeydown">
        <span class="photo-scrubber-line"></span>
        <template v-for="(month,i) in scrubMonths" :key="month.year+'-'+month.month">
          <span v-if="i===0||scrubMonths[i-1]?.year!==month.year" class="photo-scrubber-year-tick"
            :style="{top:(i+.5)/scrubMonths.length*100+'%'}"></span>
        </template>
        <span class="photo-scrubber-thumb" :style="{top:(scrubCurrentIndex+.5)/scrubMonths.length*100+'%'}"></span>
      </div>
    </div>
    <div ref="loadMarker" class="gallery-load">
      <button v-if="nextCursor" type="button" @click="load()" :disabled="loading">{{loading?"自动加载中…":"加载更多"}}</button>
      <span v-else-if="assets.length">已显示 {{assets.length}} 项</span>
    </div>
    <p class="footnote">照片和视频缩略图按需生成 JPEG 缓存；图库不修改或复制你的原始媒体。</p>
    </div>

    <PhotosBatchBar
      :selecting="trashSelecting"
      :busy="trashBusy"
      :selected-count="trashIDs.size"
      :total-loaded="assets.length"
      :folder-target="batchFolderTarget"
      :folder-options="folderAlbumOptions"
      :has-folder-albums="folderAlbums.length > 0"
      :folder-cursor="folderCursor"
      :folder-loading="folderLoading"
      :folder-error="folderError"
      :private-album="batchPrivateAlbum"
      :private-album-options="privateAlbumOptions"
      :has-private-albums="privateAlbums.length > 0"
      :share-links="batchShareLinks"
      :share-notice="batchShareNotice"
      @select-top50="trashIDs = new Set(assets.slice(0, 50).map(item => item.id))"
      @clear-selection="trashIDs = new Set()"
      @exit-selecting="trashSelecting = false; trashIDs = new Set()"
      @trash-selected="trashSelectedPhotos"
      @batch-share="batchShare"
      @batch-download="batchDownload"
      @update:folder-target="batchFolderTarget = $event"
      @batch-folder="batchToFolder($event)"
      @load-more-folders="refreshFolderAlbums(true)"
      @retry-folders="refreshFolderAlbums()"
      @update:private-album="batchPrivateAlbum = $event"
      @batch-private-album="batchToPrivateAlbum"
      @copy-share-links="copyBatchShareLinks"
      @close-share-links="batchShareLinks = []; batchShareNotice = ''"
    />

    <Teleport to="body">
      <div v-if="selected && props.active !== false" class="dialog-backdrop" @click.self="closeModal()">
        <div ref="galleryDialog" class="gallery-modal" :class="{'gallery-modal--info':viewerInfo}" role="dialog" aria-modal="true" aria-label="照片详细信息" tabindex="-1">
          <div class="gallery-modal-toolbar">
            <div><strong>{{selected.name}}</strong><small>{{dateLabel(selected.takenAt)}} · {{selected.type==="video"?"视频":"照片"}}</small></div>
            <div class="gallery-modal-actions">
              <button v-if="canWriteAsset(selected)" type="button" :disabled="pendingFavorites[selected.id]" @click="toggleFavorite(selected)" :title="selected.favorite?'取消收藏':'收藏'"><Heart :size="19" :fill="selected.favorite?'currentColor':'none'"/></button>
              <span v-else class="gallery-readonly-favorite">此共享收藏仅可查看</span>
              <button type="button" :disabled="pendingFavorites[selected.id]" @click="togglePersonalFavorite(selected)" :title="selected.personalFavorite?'从我的收藏移除':'加入我的收藏'"><Star :size="19" :fill="selected.personalFavorite?'currentColor':'none'"/></button>
              <button v-if="selected.type==='photo'&&modalAssets.length>1" type="button" @click="toggleSlideshow" :title="slideshow?'暂停幻灯片':'开始幻灯片，每4秒一张'">{{slideshow?'暂停轮播':'幻灯片'}}</button>
              <button type="button" :class="{chosen:viewerInfo}" :aria-expanded="viewerInfo" aria-controls="photo-viewer-info" aria-label="拍摄信息与相册" @click="viewerInfo=!viewerInfo" title="拍摄信息"><Info :size="19"/></button>
              <button v-if="canWriteAsset(selected)" type="button" :disabled="trashBusy" @click="trashPhotos([selected])" title="移入回收站"><Trash2 :size="19"/></button>
              <button ref="modalCloseButton" type="button" @click="closeModal()" title="关闭"><X :size="19"/></button>
            </div>
          </div>
          <div class="gallery-media-layout">
          <PhotoViewerInfoSidebar
            v-if="viewerInfo"
            :asset="selected"
            :ai-detail="viewerAIDetail"
            :ai-loading="viewerAILoading"
            :media-path="mediaPath"
            @close="viewerInfo = false"
            @show-on-map="showOnMap"
            @select-person="closeModal(false); filterByPerson($event)"
            @search-tag="closeModal(false); searchMode = 'scene'; searchInput = $event; searchApplied = $event; load(true)"
          />
          <div class="gallery-stage">
            <button v-if="selectedIndex>0" type="button" class="viewer-nav prev" title="上一张" aria-label="上一张" @click="showAssetAt(selectedIndex-1)"><ChevronLeft :size="26"/></button>
            <div v-if="selected.type==='photo'" class="gallery-viewer" :class="{gesturing:!viewerAnimate}"
              @dblclick="viewerPointers.size===0&&toggleViewerZoom()"
              @pointerdown="viewerPointerDown" @pointermove="viewerPointerMove" @pointerup="viewerPointerUp" @pointercancel="viewerPointerUp"
              @wheel="viewerWheel">
              <img :src="viewerSrc(selected)" :alt="selected.name" class="gallery-modal-image" draggable="false"
                :style="{transform:viewerTransform,cursor:viewerScale>1?'grab':'zoom-in'}"/>
              <button v-if="browserDecodable(selected)&&viewerStage!=='original'" type="button" class="gallery-original-quality" :disabled="viewerOriginalLoading" @dblclick.stop @pointerdown.stop @click.stop="requestViewerOriginal">{{viewerOriginalLoading?"正在加载原图…":viewerOriginalError?"重试原始画质":"原始画质"}}</button>
              <span class="gallery-viewer-hint">{{viewerScale>1?"拖拽平移 · 滚轮或双指缩放":"双击 / 滚轮 / 双指缩放 · 左右滑动翻页"}}{{viewerPreviewLoading?" · 正在加载高清版本…":viewerPreviewError&&viewerStage!=="original"?" · 预览加载失败，可尝试原始画质或下载原件":""}}</span>
            </div>
            <IsleVideoPlayer
              v-else
              :src="original(selected)"
              :title="selected.name"
              :has-prev="selectedIndex > 0"
              :has-next="selectedIndex + 1 < modalAssets.length"
              @prev="showAssetAt(selectedIndex - 1)"
              @next="showAssetAt(selectedIndex + 1)"
              @ended="slideshow && showAssetAt(selectedIndex + 1)"
            />
            <button v-if="selectedIndex+1<modalAssets.length" type="button" class="viewer-nav next" title="下一张" aria-label="下一张" @click="showAssetAt(selectedIndex+1)"><ChevronRight :size="26"/></button>
          </div>
          </div>
          <div class="gallery-modal-footer">
            <div v-if="folderAlbums.length" class="private-album-picker">
              <span>文件夹相册</span><AppleSelect v-model="folderTarget" :options="folderAlbumOptions" size="sm" aria-label="选择文件夹相册" />
              <button type="button" :disabled="!folderTarget||albumBusy" @click="addSelectedToFolder('copy')">复制到相册</button>
              <button type="button" :disabled="!folderTarget||albumBusy||!canWriteAsset(selected)" @click="addSelectedToFolder('move')">移动到相册</button>
            </div>
            <template v-if="admin">
            <AppleSelect v-model="addAlbum" :options="albumOptions" size="sm" aria-label="选择相册" />
            <button type="button" :disabled="!addAlbum||albumBusy" @click="addSelected">加入相册 <ChevronDown :size="14"/></button>
            <button v-if="activeAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="removeSelectedFromAlbum">移出此相册</button>
            </template>
            <div v-if="sharedAlbumsError&&selected" class="gallery-modal-feedback" role="alert">共享相册读取失败：{{sharedAlbumsError}} <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="refreshAlbums">{{sharedAlbumsLoading?"正在重试…":"重试"}}</button></div>
            <div v-if="privateAlbums.length" class="private-album-picker">
              <span>私人相册</span>
              <AppleSelect v-model="addPrivateAlbum" :options="privateAlbumOptions" size="sm" aria-label="选择我的私人相册" />
              <button type="button" :disabled="!addPrivateAlbum||albumBusy" @click="addSelectedPrivate">加入 <ChevronDown :size="14"/></button>
            </div>
            <span v-else-if="privateAlbumsError&&selected" class="private-album-hint" role="alert">私人相册读取失败：{{privateAlbumsError}} <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="refreshPrivateAlbums()">{{privateAlbumsLoading?"正在重试…":"重试"}}</button></span>
            <span v-else-if="!privateAlbumsError" class="private-album-hint">没有旧版私人相册；可在相册页新建文件夹相册。</span>
            <button v-if="activePrivateAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="removeSelectedPrivate">移出此相册</button>
          </div>
          <p v-if="message" class="gallery-modal-feedback" role="status">{{message}}</p>
        </div>
      </div>
    </Teleport>
  </div>
</template>

<style scoped src="./PhotosView.css"></style>
