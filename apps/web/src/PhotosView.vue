<script setup lang="ts">
import { createVisibleMediaPolling } from "./visibleMediaPolling.ts";
import { usePhotoPersonalFavorite } from "./usePhotoPersonalFavorite.ts";
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import { describeUserFacingError } from "./userFacingError.ts";
import { createScopedRootApi } from "./apiClient.ts";
import {
  Heart, Star, RefreshCw, Images, Film, X,
  Pencil, Trash2, Sparkles, Search, LayoutList,
  Map as MapIcon, Grid2x2, Grid3x3, Check, Users, FolderPlus,
} from "lucide-vue-next";
import { createLatestRequestGate } from "./latestRequestGate.ts";
import { mediaQueryKey } from "./mediaQueryContext.ts";
import { rootApiPath, rootMediaPath } from "./rootApi.ts";
import PhotoMapView from "./PhotoMapView.vue";
import PhotoPeopleView from "./PhotoPeopleView.vue";
import PhotoSimilarCleanupView from "./PhotoSimilarCleanupView.vue";
import PhotoAlbumOverviewSection from "./PhotoAlbumOverviewSection.vue";
import PhotosBatchBar from "./PhotosBatchBar.vue";
import PhotosTimelineToolbar from "./PhotosTimelineToolbar.vue";
import PhotoViewerModal from "./PhotoViewerModal.vue";
import IsleButton from "./IsleButton.vue";
import IsleEmpty from "./IsleEmpty.vue";
import IsleCharts from "./IsleCharts.vue";
import { ISLE_CHART_COLORS } from "./isleChartsMath.ts";
import { usePhotoViewer } from "./usePhotoViewer.ts";
import { dateLabel, formatDuration } from "./photoPresentation.ts";
import { usePhotoFilterAndSharing } from "./usePhotoFilterAndSharing.ts";
import { usePhotoBatchActions, type BatchAsset } from "./usePhotoBatchActions.ts";
import { usePhotoAlbums } from "./usePhotoAlbums.ts";
import { usePhotoTimelineScrubber } from "./usePhotoTimelineScrubber.ts";
import { usePhotoGridAndModal } from "./usePhotoGridAndModal.ts";
import { usePhotoAISearchAndPeople, type PhotoViewMode } from "./usePhotoAISearchAndPeople.ts";
import { usePhotosCatalogLoader } from "./composables/usePhotosCatalogLoader.ts";
import { usePhotoMemories, type SmartMemoryItem } from "./usePhotoMemories.ts";

type Asset = BatchAsset;

const props = defineProps<{
  active?: boolean;
  admin: boolean;
  rootId?: string;
  rootGeneration?: number;
  rootName?: string;
  hasOtherRoots?: boolean;
  jumpTarget?: { view: "similar" | "map" | "people"; seq: number } | null;
}>();
const assets = ref<Asset[]>([]);
const favoritesOnly = ref(false);
const personalOnly = ref(false);
const onThisDayOnly = ref(false);
const typeFilter = ref<"" | "photo" | "video" | "live">("");
const searchInput = ref("");
const searchApplied = ref("");
const searchComposing = ref(false);
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
const privateAlbumInputRef = ref<HTMLInputElement | null>(null);
const sharedAlbumInputRef = ref<HTMLInputElement | null>(null);
const albumOrganizerOpen = ref(false);
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
} = usePhotoAlbums<Asset>({
  isAdmin: () => props.admin, assets, selected, selectedIndex, focusedIndex,
  favoritesOnly, personalOnly, onThisDayOnly, searchInput, searchApplied, viewMode,
  photosPage, shareTargets, message,
  getRootEpoch: () => rootEpoch, getViewGeneration: () => viewGeneration, bumpViewGeneration: () => ++viewGeneration,
  getSelectionGeneration: () => selectionGeneration, bumpSelectionGeneration: () => ++selectionGeneration,
  isDisposed: () => disposed, canWriteAsset, api, apiPath,
  load: (reset?: boolean): Promise<void> => load(reset),
  showAssetAt: (index: number): void => showAssetAt(index),
  closeModal: (restore?: boolean): void => { closeModal(Boolean(restore)); },
  focusTile: (index: number): Promise<void> => focusTile(index),
  changeView: (album: number, favorites: boolean, mine?: boolean, privateID?: number): void => { changeView(album, favorites, mine, privateID); },
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
  albumOrganizerOpen,
  onShortcutFavorite: (asset) => {
    if (canWriteAsset(asset)) void toggleFavorite(asset);
    else void togglePersonalFavorite(asset);
  },
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
    void refreshAlbums(); void refreshPrivateAlbums(); void refreshTimelineIndex(); void refreshFacets(); void refreshSmartMemories();
  },
});

const aiProgressPercent = computed<number | null>(() => {
  const ai = scan.value.aiIndexing;
  if (!ai || !ai.total || ai.total <= 0 || ai.remaining == null) return null;
  const done = Math.max(0, ai.total - ai.remaining);
  return Math.min(100, Math.max(0, Math.round((done / ai.total) * 100)));
});

const { smartMemories, refreshSmartMemories, resetSmartMemories } = usePhotoMemories({
  api, apiPath, getRootEpoch: () => rootEpoch, isDisposed: () => disposed,
});

const {
  trashSelecting, trashBusy, trashIDs, batchFolderTarget, batchPrivateAlbum,
  batchShareLinks, batchShareNotice, previousRootShareWarning, toggleTrashID,
  isMonthSelected, toggleMonthSelection,
  trashPhotos, trashSelectedPhotos, batchToFolder, batchToPrivateAlbum,
  batchShare, batchDownload, copyBatchShareLinks, resetBatchForRootChange,
  notifyBatchOnUnmount,
} = usePhotoBatchActions({
  assets, selected, selectedIndex, folderAlbums, privateAlbums, message, photoQueryKey,
  getRootEpoch: () => rootEpoch, getViewGeneration: () => viewGeneration, isDisposed: () => disposed,
  getRootId: () => props.rootId, getRootGeneration: () => props.rootGeneration ?? 0,
  canWriteAsset, api, apiPath, mediaPath,
  showAssetAt: (index) => showAssetAt(index),
  closeModal: (restore) => closeModal(restore),
  load: (reset) => load(reset), refreshPrivateAlbums,
});

function setTypeFilter(kind: "" | "photo" | "video" | "live") {
  if (typeFilter.value === kind) return;
  typeFilter.value = kind;
  void load(true);
}
function openSmartMemory(mem: SmartMemoryItem) {
  if (mem.kind === "live") { setTypeFilter("live"); return; }
  if (mem.takenFrom) {
    const yr = new Date(mem.takenFrom * 1000).getFullYear();
    if (yr > 1970) { yearFilter.value = yr; onExifFilterChange(); }
  }
}

watch(creatingPrivate, (openState) => {
  if (openState) void nextTick(() => { privateAlbumInputRef.value?.focus(); privateAlbumInputRef.value?.select(); });
});
watch(creating, (openState) => {
  if (openState) void nextTick(() => { sharedAlbumInputRef.value?.focus(); sharedAlbumInputRef.value?.select(); });
});
watch(selected, (asset) => {
  if (!asset) albumOrganizerOpen.value = false;
  else if (activeAlbum.value || activePrivateAlbum.value) albumOrganizerOpen.value = true;
});

watch(searchInput, (value) => {
  if (searchComposing.value) return;
  if (searchTimer) clearTimeout(searchTimer);
  searchTimer = window.setTimeout(() => {
    const term = value.trim();
    if (term === searchApplied.value) return;
    searchApplied.value = term;
    void load(true);
  }, 400);
});

function onSearchCompositionEnd() {
  searchComposing.value = false;
  if (searchTimer) clearTimeout(searchTimer);
  searchTimer = window.setTimeout(() => {
    const term = searchInput.value.trim();
    if (term === searchApplied.value) return;
    searchApplied.value = term;
    void load(true);
  }, 150);
}

function onSearchEnter(event: KeyboardEvent) {
  if (searchComposing.value || event.isComposing) {
    event.preventDefault();
    return;
  }
  if (searchTimer) clearTimeout(searchTimer);
  const term = searchInput.value.trim();
  if (term !== searchApplied.value) {
    searchApplied.value = term;
    void load(true);
  }
}

function onSearchEsc() {
  if (searchComposing.value) return;
  if (searchTimer) clearTimeout(searchTimer);
  searchInput.value = "";
  if (searchApplied.value) {
    searchApplied.value = "";
    void load(true);
  }
}

function clearAllFilters() {
  if (searchTimer) clearTimeout(searchTimer);
  searchInput.value = "";
  searchApplied.value = "";
  typeFilter.value = "";
  activePerson.value = null;
  resetExifFilters();
  void load(true);
}

watch(
  () => props.jumpTarget,
  (target) => {
    if (!target) return;
    viewMode.value = target.view === "similar" ? "cleanup" : target.view;
  },
  { immediate: true },
);

const togglePersonalFavorite = usePhotoPersonalFavorite({
  pendingFavorites, assets, selected, selectedIndex, personalOnly, message,
  generation: () => selectionGeneration,
  save: (id, favorite) => api(apiPath("/api/v2/photos/" + id + "/personal-favorite"), "POST", { favorite }),
  reload: () => load(true), showAssetAt: (index) => showAssetAt(index), closeModal, focusTile,
});

const setScanPolling = createVisibleMediaPolling(status, 4500);
onMounted(() => {
  disposed = false;
  mountGridAndModal();
  void load(true); void refreshAlbums(); void refreshPrivateAlbums(); void refreshFolderAlbums();
  void refreshTimelineIndex(); void refreshFacets(); void refreshSmartMemories(); void status();
  setScanPolling(props.active !== false);
});
watch([() => props.rootId, () => props.rootGeneration], () => {
  resetBackstackForRootChange();
  resetBatchForRootChange();
  rootScopeAbort.abort(); rootScopeAbort = new AbortController();
  rootEpoch += 1; viewGeneration += 1; selectionGeneration += 1;
  listRequests.cancel(); resetAlbumsForRootChange(); resetScrubberForRootChange(); resetSmartMemories();
  assets.value = []; favoritesOnly.value = false; personalOnly.value = false; nextCursor.value = 0;
  loading.value = false; galleryLoaded.value = false; viewMode.value = "timeline"; onThisDayOnly.value = false;
  typeFilter.value = ""; searchInput.value = ""; searchApplied.value = ""; resetExifFilters(); resetAIStateForRootChange(); sharingAlbum.value = null;
  if (searchTimer) clearTimeout(searchTimer);
  resetCatalogForRootChange();
  selected.value = null; selectedIndex.value = -1; message.value = ""; focusedIndex.value = 0;
  void load(true); void refreshAlbums(); void refreshPrivateAlbums(); void refreshFolderAlbums();
  void refreshTimelineIndex(); void refreshFacets(); void refreshSmartMemories(); void status();
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
            <input
              v-model="searchInput"
              :placeholder="currentSearchPlaceholder()"
              aria-label="搜索照片和视频"
              enterkeyhint="search"
              @compositionstart="searchComposing = true"
              @compositionend="onSearchCompositionEnd"
              @keydown.enter="onSearchEnter"
              @keydown.esc.stop.prevent="onSearchEsc"
            >
            <button v-if="searchInput || searchApplied" type="button" title="清除搜索（Esc）" aria-label="清除搜索" @click="onSearchEsc"><X :size="13"/></button>
          </label>
          <button type="button" class="photo-tool-btn" :class="{chosen:compactGrid}" :title="compactGrid?'当前：紧凑视图（点击切舒适）':'当前：舒适视图（点击切紧凑）'" :aria-label="compactGrid?'切换舒适视图':'切换紧凑视图'" @click="toggleCompactGrid">
            <Grid3x3 v-if="compactGrid" :size="15"/><Grid2x2 v-else :size="15"/>
          </button>
          <button type="button" class="photo-tool-btn" :class="{chosen:trashSelecting}" :disabled="trashBusy" :title="trashSelecting?'退出批量选择':'多选照片（支持 Shift 区间连选）'" :aria-label="trashSelecting?'退出批量选择':'批量多选'" @click="trashSelecting=!trashSelecting;trashIDs=new Set()">
            <Check :size="15"/> {{ trashSelecting ? "退出" : "多选" }}
          </button>
        </template>
        <button v-if="admin" type="button" class="refresh" @click="startScan" :disabled="scan.running&&!scanStatusError">
          <RefreshCw :size="15" :class="{spinning:scan.running&&!scanStatusError}" /> {{scan.running&&!scanStatusError?"扫描中…":"扫描媒体"}}
        </button>
      </div>
    </div>

    <p v-if="previousRootShareWarning" class="form-error" role="alert">{{previousRootShareWarning}} <button type="button" class="refresh" @click="previousRootShareWarning=''">知道了</button></p>
    <div v-if="scan.running&&!scanStatusError" class="scan-banner">正在后台整理媒体 · 已检查 {{scan.scanned}} 项 · 发现 {{scan.found}} 项</div>
    <div v-else-if="scan.aiIndexing&&(scan.aiIndexing.running||scan.aiIndexing.paused||(scan.aiIndexing.remaining??0)>0)" class="scan-banner" style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
      <IsleCharts
        v-if="aiProgressPercent !== null"
        kind="donut"
        :size="36"
        :stroke-width="4"
        :percent="aiProgressPercent"
        :color="scan.aiIndexing.paused ? ISLE_CHART_COLORS.amber : ISLE_CHART_COLORS.blue"
        aria-label="智能识图索引完成度"
      />
      <span>{{ scan.aiIndexing.paused ? "智能识图与 OCR 索引已暂停" : "正在后台建立智能识图与离线 OCR 索引" }}<template v-if="scan.aiIndexing.total && scan.aiIndexing.remaining != null"> · 已索引 {{ Math.max(0, scan.aiIndexing.total - scan.aiIndexing.remaining) }}/{{ scan.aiIndexing.total }} 张</template><template v-else-if="scan.aiIndexing.remaining != null"> · 待处理 {{ scan.aiIndexing.remaining }} 张</template></span>
      <button v-if="admin" type="button" class="refresh" style="margin-left:auto" :disabled="aiPauseBusy" @click="toggleAIPause(scan.aiIndexing.paused)">{{ scan.aiIndexing.paused ? "恢复索引" : "暂停索引" }}</button>
    </div>
    <div v-if="scanStatusError&&assets.length" class="form-error" role="alert">扫描状态读取失败：{{scanStatusError}} <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span><button type="button" class="refresh" :disabled="scanStatusLoading" @click="status">{{scanStatusLoading?"正在重试…":"重试状态"}}</button></div>
    <p v-if="scanStatusLoaded&&scan.lastError&&assets.length" class="form-error">上次扫描：{{describeUserFacingError(scan.lastError)}}</p>
    <p v-if="message" class="gallery-message">{{message}}</p>
    <p v-if="scanActionError&&assets.length" class="gallery-message" role="alert">{{scanActionError}}</p>
    <PhotoMapView v-if="props.active !== false && viewMode === 'map'" class="isle-subview-pane" :key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :root-id="props.rootId" :root-generation="props.rootGeneration" ref="photoMap" :transport="mapTransport" @open-asset="openMapAsset"/>
    <PhotoPeopleView v-if="props.active !== false && viewMode === 'people'" class="isle-subview-pane" :active="viewMode === 'people'" :root-key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :api="api" :api-path="apiPath" :media-path="mediaPath" @select-person="filterByPerson" />
    <PhotoSimilarCleanupView v-if="props.active !== false && viewMode === 'cleanup'" class="isle-subview-pane" :active="viewMode === 'cleanup'" :root-key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :api="api" :api-path="apiPath" :media-path="mediaPath" @trashed="load(true); status()" />
    <PhotoAlbumOverviewSection
      v-show="viewMode==='albums'"
      class="isle-subview-pane"
      :folder-albums="folderAlbums" :folder-cursor="folderCursor" :folder-error="folderError"
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
      @jump-mode="viewMode = $event"
    />
    <div v-show="viewMode==='timeline'" class="isle-subview-pane">
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
        :smart-memories="smartMemories"
        @select-all="changeView(0, false)"
        @select-on-this-day="showOnThisDay()"
        @select-personal="changeView(0, false, true)"
        @select-favorites="changeView(0, true)"
        @open-folder-album="openFolderAlbum"
        @open-shared-album="(id) => changeView(id, false)"
        @open-private-album="(id) => changeView(0, false, false, id)"
        @go-create-folder-album="viewMode = 'albums'; refreshFolderAlbums()"
        @set-type-filter="setTypeFilter"
        @select-smart-memory="openSmartMemory"
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
        @clear-all-filters="clearAllFilters"
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
    <form v-if="creatingPrivate" class="album-new" @submit.prevent="savePrivateAlbum" @keydown.esc.stop="cancelPrivateAlbum">
      <FolderPlus :size="18"/>
      <input ref="privateAlbumInputRef" v-model="privateAlbumName" maxlength="120" aria-label="私人相册名称" placeholder="私人相册名称（最多60个字符）" required/>
      <button type="submit" :disabled="albumBusy">{{albumBusy?"保存中…":editingPrivate?"保存修改":"创建私人相册"}}</button>
      <button type="button" class="album-cancel" :disabled="albumBusy" @click="cancelPrivateAlbum">取消</button>
    </form>
    <div v-if="admin&&currentAlbum" class="album-management">
      <span>当前相册：{{currentAlbum.name}}</span>
      <button type="button" :disabled="albumBusy" @click="beginAlbumRename(currentAlbum)"><Pencil :size="14"/>改名</button>
      <button type="button" class="album-delete" :disabled="albumBusy" @click="deleteCurrentAlbum"><Trash2 :size="14"/>删除相册</button>
    </div>
    <form v-if="admin&&creating" class="album-new" @submit.prevent="createAlbum" @keydown.esc.stop="cancelAlbumForm">
      <FolderPlus :size="18"/><input ref="sharedAlbumInputRef" v-model="albumName" maxlength="120" aria-label="相册名称，最多60个字符" placeholder="相册名称（最多60个字符）" required/>
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
      :title="searchApplied ? '没有匹配「' + searchApplied + '」的媒体' : activeFolderAlbum ? '文件夹相册还没有照片' : currentPrivateAlbum ? '私人相册还没有照片' : currentAlbum ? '此相册还没有照片' : onThisDayOnly ? '今天还没有那年今天的回忆' : personalOnly ? '还没有个人收藏' : favoritesOnly ? '还没有共享收藏' : typeFilter === 'live' ? '这里还没有实况照片' : typeFilter === 'video' ? '这里还没有视频' : typeFilter === 'photo' ? '这里还没有照片' : rootName ? `当前目录「${rootName}」还没有照片或视频` : '这里还没有照片或视频'"
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
        @click="trashSelecting?toggleTrashID(asset.id,$event.shiftKey):openAsset(asset,virtualWindow.startIndex+visibleIndex)">
        <img v-if="!thumbnailFailed[asset.id]" :src="thumb(asset)" loading="lazy" decoding="async" :alt="asset.name" @error="thumbnailFailed[asset.id]=true"/>
        <div v-else class="video-placeholder"><Film v-if="asset.type==='video'" :size="26"/><Images v-else :size="26"/><small>{{asset.type==='video'?"视频":"预览暂不可用"}}</small></div>
        <span v-if="(asset.liveVideoAssetId ?? 0) > 0 && !trashSelecting" class="photo-live-chip" title="Apple 实况照片">实况</span>
        <span v-if="asset.favorite" class="photo-liked" title="共享收藏"><Heart :size="16" fill="currentColor"/></span>
        <span v-if="asset.personalFavorite" class="photo-private-liked" title="我的收藏"><Star :size="14" fill="currentColor"/></span>
        <span v-if="asset.type==='video' && !trashSelecting" class="photo-duration-chip" :title="(asset.durationSeconds ?? 0) > 0 ? '视频时长 ' + formatDuration(asset.durationSeconds!) : '视频'">
          <Film :size="11"/>
          <template v-if="(asset.durationSeconds ?? 0) > 0">{{ formatDuration(asset.durationSeconds!) }}</template>
        </span>
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

    <PhotoViewerModal
      :selected="selected"
      :active="props.active !== false"
      :selected-index="selectedIndex"
      :modal-assets="modalAssets"
      :viewer-info="viewerInfo"
      :album-organizer-open="albumOrganizerOpen"
      :admin="admin"
      :can-write="selected ? canWriteAsset(selected) : false"
      :pending-favorite="selected ? Boolean(pendingFavorites[selected.id]) : false"
      :trash-busy="trashBusy"
      :slideshow="slideshow"
      :viewer-a-i-detail="viewerAIDetail"
      :viewer-a-i-loading="viewerAILoading"
      :viewer-src="selected ? viewerSrc(selected) : ''"
      :viewer-stage="viewerStage"
      :viewer-preview-loading="viewerPreviewLoading"
      :viewer-preview-error="viewerPreviewError"
      :viewer-original-loading="viewerOriginalLoading"
      :viewer-original-error="viewerOriginalError"
      :viewer-scale="viewerScale"
      :viewer-transform="viewerTransform"
      :viewer-animate="viewerAnimate"
      :viewer-pointers-size="viewerPointers.size"
      :browser-decodable="selected ? browserDecodable(selected) : false"
      :media-path="mediaPath"
      :original-url="selected ? original(selected) : ''"
      :thumb-for="thumb"
      :folder-albums="folderAlbums"
      :folder-album-options="folderAlbumOptions"
      :folder-target="folderTarget"
      :albums="albums"
      :album-options="albumOptions"
      :add-album="addAlbum"
      :active-album="activeAlbum"
      :shared-albums-error="sharedAlbumsError"
      :shared-albums-loading="sharedAlbumsLoading"
      :private-albums="privateAlbums"
      :private-album-options="privateAlbumOptions"
      :add-private-album="addPrivateAlbum"
      :active-private-album="activePrivateAlbum"
      :private-albums-error="privateAlbumsError"
      :private-albums-loading="privateAlbumsLoading"
      :album-busy="albumBusy"
      :message="message"
      :set-dialog-ref="(el) => { galleryDialog = el; }"
      :set-close-button-ref="(el) => { modalCloseButton = el; }"
      @close="closeModal()"
      @show-at="showAssetAt"
      @toggle-favorite="selected && toggleFavorite(selected)"
      @toggle-personal-favorite="selected && togglePersonalFavorite(selected)"
      @toggle-album-organizer="albumOrganizerOpen = !albumOrganizerOpen"
      @toggle-slideshow="toggleSlideshow"
      @toggle-info="viewerInfo = !viewerInfo"
      @trash-selected="selected && trashPhotos([selected])"
      @toggle-zoom="toggleViewerZoom"
      @request-original="requestViewerOriginal"
      @pointer-down="viewerPointerDown"
      @pointer-move="viewerPointerMove"
      @pointer-up="viewerPointerUp"
      @wheel="viewerWheel"
      @show-on-map="showOnMap"
      @select-person="closeModal(false); filterByPerson($event)"
      @search-tag="closeModal(false); searchMode = 'scene'; searchInput = $event; searchApplied = $event; load(true)"
      @update:folder-target="folderTarget = $event"
      @folder-action="addSelectedToFolder($event)"
      @update:add-album="addAlbum = $event"
      @add-shared="addSelected"
      @remove-shared="removeSelectedFromAlbum"
      @retry-shared="refreshAlbums"
      @update:add-private-album="addPrivateAlbum = $event"
      @add-private="addSelectedPrivate"
      @remove-private="removeSelectedPrivate"
      @retry-private="refreshPrivateAlbums()"
    />
  </div>
</template>
