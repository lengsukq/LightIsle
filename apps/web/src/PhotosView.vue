<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import { describeRootOperationFailure } from "./rootDiscovery.js";
import { describeUserFacingError } from "./userFacingError.js";
import { apiErrorFromResponse } from "./apiFailure.js";
import {
  Heart, Star, RefreshCw, Images, Film, Plus, X, FolderPlus, ChevronDown,
  ChevronLeft, ChevronRight, Info, MapPin, Pencil, Trash2, Sparkles, ArrowUp,
  Search, LayoutList, Map as MapIcon,
} from "lucide-vue-next";
import { createLatestRequestGate } from "./latestRequestGate.js";
import { createMediaStatusPoller } from "./mediaStatusPoller.js";
import { mediaQueryKey, transitionMediaQuery } from "./mediaQueryContext.js";
import { rootApiPath, rootMediaPath } from "./rootApi.js";
import PhotoMapView from "./PhotoMapView.vue";
import AppleSelect from "./AppleSelect.vue";
import { usePhotoViewer } from "./usePhotoViewer";
import {
  dateLabel, capturedLabel, formatBytes, formatExposure, formatAperture,
  formatDuration, coordinateLabel,
} from "./photoPresentation";
import { usePhotoFilterAndSharing } from "./usePhotoFilterAndSharing";
import { usePhotoBatchActions, type BatchAsset } from "./usePhotoBatchActions";
import { usePhotoAlbums } from "./usePhotoAlbums";
import { usePhotoTimelineScrubber } from "./usePhotoTimelineScrubber";
import { usePhotoGridAndModal } from "./usePhotoGridAndModal";
import { getMetadata, putMetadata } from "./useIsleCache";

type Asset = BatchAsset;
type Status = { running: boolean; scanned: number; found: number; lastError?: string; lastDone?: number };

const props = defineProps<{ admin: boolean; rootId?: string; rootGeneration?: number }>();
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
const loadErrorReset = ref(true);
const scanActionError = ref("");
const scanStatusLoading = ref(false);
const scanStatusLoaded = ref(false);
const scanStatusError = ref("");
const message = ref("");
const scan = ref<Status>({ running: false, scanned: 0, found: 0 });
const selected = ref<Asset | null>(null);
const selectedIndex = ref(-1);
const thumbnailFailed = ref<Record<number, boolean>>({});
const pendingFavorites = ref<Record<number, boolean>>({});
const photosPage = ref<HTMLElement | null>(null);
const focusedIndex = ref(0);
const nextCursor = ref(0);
const viewMode = ref<"timeline" | "albums" | "map">("timeline");
const mapVisited = ref(false);
watch(viewMode, (mode) => {
  if (mode === "map") mapVisited.value = true;
  void nextTick(() => {
    window.dispatchEvent(new Event("resize"));
    if (mode === "timeline") updateViewport();
  });
});

let timer: number | undefined;
let lastCompletedScan = 0;
let rootEpoch = 0;
let disposed = false;
const listRequests = createLatestRequestGate();
let viewGeneration = 0;
let selectionGeneration = 0;

function apiPath(path: string) { return rootApiPath(props.rootId, path); }
function mediaPath(path: string) { return rootMediaPath(props.rootId, props.rootGeneration ?? 0, path); }
function makeRootAbortError() { const error = new Error("root_context_changed"); error.name = "AbortError"; return error; }

async function api<T>(url: string, method = "GET", body?: object, signal?: AbortSignal): Promise<T> {
  const rootID = props.rootId, rootGeneration = props.rootGeneration ?? 0;
  const headers = new Headers(method === "GET" ? {} : { "Content-Type": "application/json", "X-LightIsle-Request": "1" });
  if (rootID) headers.set("X-LightIsle-Root-Generation", String(rootGeneration));
  const response = await fetch(url, {
    method, credentials: "same-origin", headers,
    body: body ? JSON.stringify(body) : undefined, cache: "no-store", signal,
  });
  if (!response.ok) {
    const data = (await response.json().catch(() => ({ error: "request_failed" }))) as { error?: string };
    if (rootID && (props.rootId !== rootID || props.rootGeneration !== rootGeneration || disposed)) throw makeRootAbortError();
    if (rootID && response.status === 409 && data.error === "root_generation_changed") {
      window.dispatchEvent(new Event("lightisle-root-generation-changed"));
      throw new Error("共享目录已变化，请刷新根列表后重新选择。");
    }
    throw apiErrorFromResponse(response, data);
  }
  const result = (await response.json()) as T;
  if (rootID && (props.rootId !== rootID || props.rootGeneration !== rootGeneration || disposed)) throw makeRootAbortError();
  return result;
}
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
  photoMap, modalAssets, timelineLayout, virtualWindow, visibleAssets, visibleHeaders,
  mapTransport, slideshow, toggleSlideshow, showAssetAt, openAsset, openMapAsset, showOnMap,
  tileStyle, updateViewport, measureViewport, focusTile, onTileKeydown, closeModal,
  mountGridAndModal, unmountGridAndModal, resetBackstackForRootChange,
} = usePhotoGridAndModal({
  assets, selected, selectedIndex, focusedIndex, nextCursor, loading, loadError,
  viewMode, addAlbum, addPrivateAlbum, message, viewerAnimate, viewerScale, viewerOffset,
  bumpSelectionGeneration: () => ++selectionGeneration, startViewerStages, cancelViewerLoads,
  api, apiPath, mediaPath, load: (reset) => load(reset),
});

function photoQueryKey() {
  return mediaQueryKey({
    root: props.rootId ?? "", generation: props.rootGeneration ?? 0,
    album: activeAlbum.value, privateAlbum: activePrivateAlbum.value,
    directory: activeFolderAlbum.value?.path ?? "", favorites: favoritesOnly.value,
    personal: personalOnly.value, onThisDay: onThisDayOnly.value, type: typeFilter.value,
    q: searchApplied.value, camera: cameraFilter.value, loc: locationFilter.value, year: yearFilter.value,
  });
}
let pageQueryKey = photoQueryKey();

function isFullTimelineView() {
  return !activeAlbum.value && !activePrivateAlbum.value && !activeFolderAlbum.value && !favoritesOnly.value &&
    !personalOnly.value && !onThisDayOnly.value && !typeFilter.value && !searchApplied.value && !hasActiveExifFilter();
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
  trashSelecting, trashBusy, trashIDs, batchFolderTarget, batchPrivateAlbum,
  batchShareLinks, batchShareNotice, previousRootShareWarning, toggleTrashID,
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
function closeAlbumMenu(event: Event) {
  const menu = (event.target as HTMLElement)?.closest("details.photo-albums-menu");
  if (menu instanceof HTMLDetailsElement) menu.open = false;
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

async function togglePersonalFavorite(asset: Asset) {
  if (pendingFavorites.value[asset.id]) return;
  const selection = selectionGeneration;
  pendingFavorites.value[asset.id] = true;
  try {
    const next = !asset.personalFavorite;
    await api(apiPath("/api/v2/photos/" + asset.id + "/personal-favorite"), "POST", { favorite: next });
    const current = assets.value.find((item) => item.id === asset.id);
    if (current) current.personalFavorite = next;
    if (selected.value?.id === asset.id) selected.value.personalFavorite = next;
    if (personalOnly.value && !next) {
      const selectedID = selected.value?.id, previousIndex = selectedIndex.value;
      if (selectedID === asset.id) closeModal(false);
      await load(true);
      if (selectedID && selectedID !== asset.id) {
        const nextIndex = assets.value.findIndex((item) => item.id === selectedID);
        if (nextIndex >= 0) selectedIndex.value = nextIndex;
      } else if (selectedID === asset.id && assets.value.length) {
        await focusTile(Math.min(previousIndex, assets.value.length - 1));
      }
    }
  } catch (e) {
    if (selection === selectionGeneration && selected.value?.id === asset.id) {
      message.value = "个人收藏失败：" + describeUserFacingError(e);
    }
  } finally {
    delete pendingFavorites.value[asset.id];
  }
}

const scanStatusPoller = createMediaStatusPoller(
  (signal) => api<{ status: Status; count: number }>(apiPath("/api/v2/photos/status"), "GET", undefined, signal),
  {
    onValue: (result) => {
      const previous = scan.value.lastDone;
      scan.value = result.status; scanStatusLoaded.value = true; scanStatusError.value = ""; scanStatusLoading.value = false;
      if (!scan.value.running && scan.value.lastDone && scan.value.lastDone !== previous && scan.value.lastDone > lastCompletedScan) {
        lastCompletedScan = scan.value.lastDone;
        void load(true); void refreshAlbums(); void refreshPrivateAlbums(); void refreshTimelineIndex(); void refreshFacets();
      }
    },
    onError: (error) => { scanStatusError.value = describeRootOperationFailure(error); scanStatusLoading.value = false; },
  },
);
function status() { scanStatusLoading.value = true; return scanStatusPoller.refresh(); }

async function load(reset = false) {
  if (loading.value && !reset) return;
  const transition = transitionMediaQuery(pageQueryKey, photoQueryKey());
  if (transition.clearContent) {
    pageQueryKey = transition.queryKey; assets.value = []; nextCursor.value = 0; galleryLoaded.value = false;
    focusedIndex.value = 0; timelineCursorStart.value = 0;
  }
  const request = listRequests.begin();
  loading.value = true; loadError.value = "";
  if (reset) { focusedIndex.value = 0; timelineCursorStart.value = 0; }
  if (reset && !assets.value.length) {
    const cached = getMetadata<{ assets: Asset[]; nextCursor: number }>("photos:list:" + photoQueryKey());
    if (cached && Array.isArray(cached.assets) && cached.assets.length) {
      assets.value = cached.assets;
      nextCursor.value = cached.nextCursor || 0;
      galleryLoaded.value = true;
      void nextTick(() => updateViewport());
    }
  }
  try {
    const query = new URLSearchParams({ limit: "48", cursor: String(reset ? 0 : nextCursor.value) });
    if (activeAlbum.value) query.set("album", String(activeAlbum.value));
    if (activePrivateAlbum.value) query.set("privateAlbum", String(activePrivateAlbum.value));
    if (activeFolderAlbum.value) query.set("directory", activeFolderAlbum.value.path);
    if (favoritesOnly.value) query.set("favorites", "1");
    if (personalOnly.value) query.set("personal", "1");
    if (onThisDayOnly.value) query.set("onThisDay", "1");
    if (typeFilter.value) query.set("type", typeFilter.value);
    if (searchApplied.value) query.set("q", searchApplied.value);
    appendExifFilterParams(query);
    const result = await api<{ assets: Asset[]; nextCursor: number }>(
      apiPath("/api/v2/photos") + "?" + query.toString(), "GET", undefined, request.signal,
    );
    if (!request.isCurrent()) return;
    assets.value = reset ? result.assets : [...assets.value, ...result.assets];
    nextCursor.value = result.nextCursor;
    if (reset) {
      galleryLoaded.value = true;
      putMetadata("photos:list:" + photoQueryKey(), { assets: result.assets, nextCursor: result.nextCursor });
    }
    await nextTick();
    if (request.isCurrent()) updateViewport();
  } catch (e) {
    if (request.isCurrent() && !(e instanceof Error && e.name === "AbortError")) {
      loadError.value = "加载照片失败：" + describeRootOperationFailure(e);
      loadErrorReset.value = reset;
    }
  } finally {
    if (request.isCurrent()) {
      loading.value = false;
      if (nextCursor.value && !loadError.value) {
        requestAnimationFrame(() => {
          const marker = loadMarker.value;
          if (!disposed && !loading.value && marker && marker.getBoundingClientRect().top < window.innerHeight + 650) {
            void load(false);
          }
        });
      }
    }
  }
}
function retryLoad() { void load(loadErrorReset.value); }
async function startScan() {
  const context = rootEpoch; scanActionError.value = "";
  try {
    await api(apiPath("/api/v2/photos/scan"), "POST");
    if (context !== rootEpoch) return;
    message.value = "正在后台扫描授权的共享目录";
    scanStatusPoller.invalidate(); await status();
  } catch (e) { if (context === rootEpoch) scanActionError.value = "无法启动扫描：" + describeUserFacingError(e); }
}
async function toggleFavorite(asset: Asset) {
  if (!props.admin && asset.canWrite !== true) return;
  if (pendingFavorites.value[asset.id]) return;
  pendingFavorites.value[asset.id] = true;
  const next = !asset.favorite, selection = selectionGeneration;
  try {
    await api(apiPath("/api/v2/photos/" + asset.id + "/favorite"), "POST", { favorite: next });
    const current = assets.value.find((item) => item.id === asset.id);
    if (current) current.favorite = next;
    if (selected.value?.id === asset.id) selected.value.favorite = next;
  } catch (e) {
    if (selection === selectionGeneration && selected.value?.id === asset.id) {
      message.value = "收藏失败：" + describeUserFacingError(e);
    }
  } finally { delete pendingFavorites.value[asset.id]; }
}
function changeView(album: number, favorites: boolean, mine = false, privateID = 0) {
  if (activeAlbum.value === album && favoritesOnly.value === favorites && personalOnly.value === mine &&
      activePrivateAlbum.value === privateID && !onThisDayOnly.value && !activeFolderAlbum.value) return;
  viewGeneration += 1;
  activeAlbum.value = album; favoritesOnly.value = favorites; personalOnly.value = mine;
  activePrivateAlbum.value = privateID; activeFolderAlbum.value = null; onThisDayOnly.value = false;
  searchInput.value = ""; searchApplied.value = ""; selected.value = null; selectedIndex.value = -1; focusedIndex.value = 0;
  selectionGeneration += 1; void load(true);
  requestAnimationFrame(() => {
    const root = photosPage.value;
    if (root) window.scrollTo({ top: Math.max(0, root.getBoundingClientRect().top + window.scrollY - 100), behavior: "auto" });
  });
}
function showOnThisDay() {
  if (onThisDayOnly.value) return;
  viewGeneration += 1;
  activeAlbum.value = 0; favoritesOnly.value = false; personalOnly.value = false; activePrivateAlbum.value = 0;
  activeFolderAlbum.value = null; onThisDayOnly.value = true; searchInput.value = ""; searchApplied.value = "";
  selected.value = null; selectedIndex.value = -1; focusedIndex.value = 0; selectionGeneration += 1;
  void load(true); window.scrollTo({ top: 0, behavior: "auto" });
}

onMounted(() => {
  disposed = false;
  mountGridAndModal();
  void load(true); void refreshAlbums(); void refreshPrivateAlbums(); void refreshFolderAlbums();
  void refreshTimelineIndex(); void refreshFacets(); void status();
  timer = window.setInterval(() => { if (!document.hidden) void status(); }, 4500);
});
watch([() => props.rootId, () => props.rootGeneration], () => {
  resetBackstackForRootChange();
  resetBatchForRootChange();
  rootEpoch += 1; viewGeneration += 1; selectionGeneration += 1;
  listRequests.cancel(); resetAlbumsForRootChange(); resetScrubberForRootChange(); scanStatusPoller.invalidate();
  assets.value = []; favoritesOnly.value = false; personalOnly.value = false; nextCursor.value = 0;
  loading.value = false; galleryLoaded.value = false; viewMode.value = "timeline"; onThisDayOnly.value = false;
  typeFilter.value = ""; searchInput.value = ""; searchApplied.value = ""; resetExifFilters(); sharingAlbum.value = null;
  if (searchTimer) clearTimeout(searchTimer);
  pageQueryKey = photoQueryKey();
  loadError.value = ""; loadErrorReset.value = true; scanActionError.value = "";
  scanStatusLoaded.value = false; scanStatusLoading.value = false; scanStatusError.value = "";
  scan.value = { running: false, scanned: 0, found: 0 }; lastCompletedScan = 0;
  selected.value = null; selectedIndex.value = -1; message.value = ""; focusedIndex.value = 0;
  void load(true); void refreshAlbums(); void refreshPrivateAlbums(); void refreshFolderAlbums();
  void refreshTimelineIndex(); void refreshFacets(); void status();
}, { flush: "sync" });
onUnmounted(() => {
  notifyBatchOnUnmount();
  disposed = true;
  unmountGridAndModal();
  cancelViewerLoads();
  if (timer) clearInterval(timer);
  if (searchTimer) clearTimeout(searchTimer);
  listRequests.cancel();
  cancelAlbumRequests();
  scanStatusPoller.dispose();
});
</script>

<template>
  <div ref="photosPage" class="content photos-page">
    <div class="section-heading">
      <div><h2>照片图库</h2><p>你的每个瞬间，保存在自己的 Mac 上。</p></div>
      <button v-if="admin" type="button" class="refresh" @click="startScan" :disabled="scan.running&&!scanStatusError">
        <RefreshCw :size="16" :class="{spinning:scan.running&&!scanStatusError}" /> {{scan.running&&!scanStatusError?"扫描中…":"扫描媒体"}}
      </button>
    </div>
    <div class="timeline-tools">
      <button type="button" class="album-create" :disabled="trashBusy" @click="trashSelecting=!trashSelecting;trashIDs=new Set()">{{trashSelecting?"退出多选":"多选"}}</button>
      <template v-if="trashSelecting">
        <span>已选 {{trashIDs.size}} 项（最多50项）</span>
        <button type="button" class="album-create" :disabled="trashBusy" @click="trashIDs=new Set(assets.slice(0,50).map(item=>item.id))">选择已加载的前50项</button>
        <button type="button" class="album-create album-delete" :disabled="trashBusy||!trashIDs.size" @click="trashSelectedPhotos"><Trash2 :size="15"/> 移入回收站</button>
        <button type="button" class="album-create" :disabled="trashBusy||!trashIDs.size" @click="batchShare">创建分享链接</button>
        <button type="button" class="album-create" :disabled="trashBusy||!trashIDs.size" @click="batchDownload">打包下载原文件</button>
        <AppleSelect v-model="batchFolderTarget" :options="folderAlbumOptions" size="sm" :disabled="trashBusy||!folderAlbums.length" aria-label="批量操作的文件夹相册" />
        <button type="button" class="album-create" :disabled="trashBusy||!trashIDs.size||!batchFolderTarget" @click="batchToFolder('copy')">复制到相册</button>
        <button type="button" class="album-create" :disabled="trashBusy||!trashIDs.size||!batchFolderTarget" @click="batchToFolder('move')">移动到相册</button>
        <button v-if="folderCursor" type="button" class="refresh" :disabled="folderLoading||trashBusy" @click="refreshFolderAlbums(true)">加载更多文件夹相册</button>
        <button v-if="folderError" type="button" class="refresh" :disabled="folderLoading||trashBusy" @click="refreshFolderAlbums()">相册读取失败，重试</button>
        <template v-if="privateAlbums.length">
          <AppleSelect v-model="batchPrivateAlbum" :options="privateAlbumOptions" size="sm" :disabled="trashBusy" aria-label="批量加入已有私人相册" />
          <button type="button" class="album-create" :disabled="trashBusy||!trashIDs.size||!batchPrivateAlbum" @click="batchToPrivateAlbum">加入已有私人相册</button>
        </template>
      </template>
    </div>
    <p v-if="previousRootShareWarning" class="form-error" role="alert">{{previousRootShareWarning}} <button type="button" class="refresh" @click="previousRootShareWarning=''">知道了</button></p>
    <div v-if="batchShareLinks.length" class="photo-batch-links" role="region" aria-label="已创建的分享链接">
      <p>已创建 {{batchShareLinks.length}} 条公开链接，有效期 24 小时。链接只在本次显示；可在文件管理的分享列表中撤销。</p>
      <textarea readonly :value="batchShareLinks.map(item=>`${item.name}：${item.url}`).join('\n')" rows="4" aria-label="分享链接列表" @focus="($event.target as HTMLTextAreaElement).select()"></textarea>
      <div><button type="button" class="album-create" @click="copyBatchShareLinks">复制全部链接</button><button type="button" class="refresh" @click="batchShareLinks=[];batchShareNotice=''">关闭</button><span v-if="batchShareNotice" role="status">{{batchShareNotice}}</span></div>
    </div>
    <div v-if="scan.running&&!scanStatusError" class="scan-banner">正在后台整理媒体 · 已检查 {{scan.scanned}} 项 · 发现 {{scan.found}} 项</div>
    <div v-if="scanStatusError&&assets.length" class="form-error" role="alert">扫描状态读取失败：{{scanStatusError}} <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span><button type="button" class="refresh" :disabled="scanStatusLoading" @click="status">{{scanStatusLoading?"正在重试…":"重试状态"}}</button></div>
    <p v-if="scanStatusLoaded&&scan.lastError&&assets.length" class="form-error">上次扫描：{{describeUserFacingError(scan.lastError)}}</p>
    <p v-if="message" class="gallery-message">{{message}}</p>
    <p v-if="scanActionError&&assets.length" class="gallery-message" role="alert">{{scanActionError}}</p>
    <div class="photo-mode-tabs" role="tablist" aria-label="照片浏览方式">
      <button type="button" role="tab" :aria-selected="viewMode==='timeline'" :class="{chosen:viewMode==='timeline'}" @click="viewMode='timeline'"><LayoutList :size="15"/> 时间线</button>
      <button type="button" role="tab" :aria-selected="viewMode==='albums'" :class="{chosen:viewMode==='albums'}" @click="viewMode='albums';refreshFolderAlbums()"><Images :size="15"/> 相册</button>
      <button type="button" role="tab" :aria-selected="viewMode==='map'" :class="{chosen:viewMode==='map'}" @click="viewMode='map'"><MapIcon :size="15"/> 地图回溯</button>
    </div>
    <PhotoMapView v-if="mapVisited || viewMode==='map'" v-show="viewMode==='map'" :key="(props.rootId??'legacy')+':'+(props.rootGeneration??0)" ref="photoMap" :transport="mapTransport" @open-asset="openMapAsset"/>
    <section v-show="viewMode==='albums'" class="photo-album-overview" aria-label="相册总览">
      <header class="photo-album-overview-header">
        <div><h3>整理与分享</h3><p>文件夹相册直接保存在你的照片目录中，加入照片时可选择复制或移动。</p></div>
      </header>
      <div class="photo-album-section-heading"><h4>照片目录中的相册</h4><button type="button" class="refresh" :disabled="folderLoading" @click="refreshFolderAlbums()">刷新</button></div>
      <form class="album-new" @submit.prevent="createFolderAlbum"><FolderPlus :size="18"/><input v-model="folderName" maxlength="120" aria-label="文件夹相册名称" placeholder="新相册名称" required/><button type="submit" :disabled="albumBusy">新建相册</button></form>
      <div v-if="folderError" class="gallery-message" role="alert">文件夹相册读取失败：{{folderError}} <button type="button" class="refresh" @click="refreshFolderAlbums()">重试</button></div>
      <div v-if="folderAlbums.length" class="photo-album-card-grid">
        <div v-for="album in folderAlbums" :key="album.path">
          <button type="button" class="photo-album-card" @click="openFolderAlbum(album)"><span class="photo-album-cover"><FolderPlus :size="30"/></span><strong :title="album.name">{{album.name}}</strong><small>{{album.shared?`来自 @${album.ownerUsername} · ${album.canWrite?'可读写':'只读'}`:album.shares?.length?`已共享给 ${album.shares.length} 人`:'照片目录中的文件夹'}}</small></button>
          <div class="timeline-tools" style="margin-top:6px">
            <button v-if="!album.shared&&shareTargets.length" type="button" class="refresh" :disabled="albumBusy" @click="openSharePanel(album)">{{sharingAlbum?.path===album.path?"收起共享":"共享给家人"}}</button>
            <button v-if="!album.shared" type="button" class="refresh" :disabled="albumBusy" @click="deleteFolderAlbum(album)">删除空相册</button>
            <button v-if="album.shared&&album.ownerUserId" type="button" class="refresh" :disabled="albumBusy" @click="removeFolderAlbumShare(album,album.memberUserId||0,album.ownerUserId)">退出共享</button>
          </div>
          <div v-if="sharingAlbum?.path===album.path&&!album.shared" class="album-new" style="margin-top:6px;flex-wrap:wrap">
            <AppleSelect v-model="shareMemberId" :options="shareTargetOptions" size="sm" aria-label="选择共享成员" />
            <label style="display:inline-flex;align-items:center;gap:4px;font-size:12px"><input type="checkbox" v-model="shareCanWrite"/> 允许上传（计入我的配额）</label>
            <button type="button" :disabled="albumBusy||!shareMemberId" @click="submitFolderAlbumShare(album)">确认共享</button>
            <span v-for="s in album.shares" :key="s.id" style="display:inline-flex;align-items:center;gap:4px;font-size:12px">@{{s.memberUsername}}（{{s.canWrite?'可写':'只读'}}）<button type="button" class="refresh" :disabled="albumBusy" @click="removeFolderAlbumShare(album,s.memberUserId)">移除</button></span>
          </div>
        </div>
      </div>
      <div v-else-if="!folderError&&!folderLoading&&!folderCursor" class="photo-album-empty"><Images :size="23"/><span>照片目录中还没有文件夹相册。</span></div>
      <button v-if="folderCursor" type="button" class="refresh" :disabled="folderLoading" @click="refreshFolderAlbums(true)">加载更多文件夹</button>
      <div v-if="privateAlbumsError" class="gallery-message" role="alert">私人相册读取失败：{{privateAlbumsError}} <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="refreshPrivateAlbums()">重试</button></div>
      <div class="photo-album-section-heading"><h4>旧版私人相册 ({{privateAlbums.length}})</h4><small>保留原有照片关联</small></div>
      <div v-if="privateAlbums.length" class="photo-album-card-grid">
        <button v-for="album in privateAlbums" :key="'personal-'+album.id" type="button" class="photo-album-card" @click="openAlbumFromOverview(album,true)">
          <span class="photo-album-cover">
            <img v-if="album.coverAssetId&&!failedAlbumCovers['personal:'+album.id]" :src="mediaPath('/api/v2/photos/'+album.coverAssetId+'/thumbnail')" :alt="album.name+'封面'" loading="lazy" @error="failedAlbumCovers['personal:'+album.id]=true"/>
            <Images v-else :size="30"/>
          </span>
          <strong :title="album.name">{{album.name}}</strong><small>{{album.count}} 项 · 仅自己可见</small>
        </button>
      </div>
      <div v-else-if="!privateAlbumsError" class="photo-album-empty"><Images :size="23"/><span>还没有私人相册。创建后可将照片加入个人收藏集。</span></div>
      <div class="photo-album-section-heading"><h4>旧版共享相册 ({{albums.length}})</h4><small>保留原有照片关联</small></div>
      <div v-if="sharedAlbumsError" class="gallery-message" role="alert">共享相册读取失败：{{sharedAlbumsError}} <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="refreshAlbums">重试</button></div>
      <div v-if="albums.length" class="photo-album-card-grid">
        <button v-for="album in albums" :key="'shared-'+album.id" type="button" class="photo-album-card" @click="openAlbumFromOverview(album,false)">
          <span class="photo-album-cover">
            <img v-if="album.coverAssetId&&!failedAlbumCovers['shared:'+album.id]" :src="mediaPath('/api/v2/photos/'+album.coverAssetId+'/thumbnail')" :alt="album.name+'封面'" loading="lazy" @error="failedAlbumCovers['shared:'+album.id]=true"/>
            <Images v-else :size="30"/>
          </span>
          <strong :title="album.name">{{album.name}}</strong><small>{{album.count}} 项 · 共享</small>
        </button>
      </div>
      <div v-else-if="!sharedAlbumsError" class="photo-album-empty"><Images :size="23"/><span>{{admin?'还没有共享相册，可以创建一个与家人共享。':'管理员创建的共享相册会显示在这里。'}}</span></div>
    </section>
    <div v-show="viewMode==='timeline'">
    <div class="timeline-tools">
      <div class="type-tabs" role="group" aria-label="媒体类型">
        <button type="button" :class="{chosen:!typeFilter}" @click="setTypeFilter('')">全部</button>
        <button type="button" :class="{chosen:typeFilter==='photo'}" @click="setTypeFilter('photo')"><Images :size="14"/> 照片</button>
        <button type="button" :class="{chosen:typeFilter==='video'}" @click="setTypeFilter('video')"><Film :size="14"/> 视频</button>
      </div>
      <label class="timeline-search">
        <Search :size="14"/>
        <input v-model="searchInput" placeholder="搜索文件名或文件夹" aria-label="搜索照片和视频" enterkeyhint="search">
        <button v-if="searchInput" type="button" title="清除搜索" @click="searchInput=''"><X :size="13"/></button>
      </label>
      <AppleSelect v-if="cameraOptions.length>1" v-model="cameraFilter" :options="cameraOptions" size="sm" aria-label="按相机型号筛选" @change="onExifFilterChange" />
      <AppleSelect v-model="locationFilter" :options="locationOptions" size="sm" aria-label="按定位信息筛选" @change="onExifFilterChange" />
      <AppleSelect v-if="filterYearOptions.length>1" v-model="yearFilter" :options="filterYearOptions" size="sm" aria-label="按拍摄年份筛选" @change="onExifFilterChange" />
      <button v-if="hasActiveExifFilter()" type="button" class="refresh" @click="resetExifFilters();onExifFilterChange()">清除筛选</button>
    </div>
    <div class="album-toolbar">
      <div class="album-tabs album-primary-tabs">
        <button type="button" :class="{chosen:activeAlbum===0&&!activePrivateAlbum&&!activeFolderAlbum&&!favoritesOnly&&!personalOnly&&!onThisDayOnly}" @click="changeView(0,false)"><Images :size="15"/> 全部照片</button>
        <button type="button" :class="{chosen:personalOnly}" @click="changeView(0,false,true)"><Star :size="15"/> 我的收藏</button>
        <button type="button" :class="{chosen:favoritesOnly}" @click="changeView(0,true)"><Heart :size="15"/> 共享收藏</button>
      </div>
      <details class="photo-albums-menu">
        <summary :aria-label="'浏览相册，共 '+(albums.length+privateAlbums.length+folderAlbums.length)+' 个'"><FolderPlus :size="16"/> {{activeFolderAlbum?.name||currentPrivateAlbum?.name||currentAlbum?.name||'相册'}} <small>({{albums.length+privateAlbums.length+folderAlbums.length}})</small></summary>
        <div class="photo-albums-menu-panel">
          <div class="album-tabs">
            <button type="button" :class="{chosen:onThisDayOnly}" @click="closeAlbumMenu($event);showOnThisDay()"><Sparkles :size="15"/> 那年今天</button>
            <button v-for="album in folderAlbums" :key="album.path" type="button" :class="{chosen:activeFolderAlbum?.path===album.path}" @click="closeAlbumMenu($event);openFolderAlbum(album)"><FolderPlus :size="14"/> {{album.name}}</button>
            <button v-for="album in albums" :key="album.id" type="button" :class="{chosen:activeAlbum===album.id}" @click="closeAlbumMenu($event);changeView(album.id,false)">{{album.name}} <small>{{album.count}}</small></button>
            <button v-for="album in privateAlbums" :key="'private-'+album.id" :data-private-album-filter="album.id" type="button" :class="{chosen:activePrivateAlbum===album.id}" @click="closeAlbumMenu($event);changeView(0,false,false,album.id)"><FolderPlus :size="14"/> {{album.name}} <small>{{album.count}}</small></button>
          </div>
          <div class="photo-albums-menu-create">
            <button type="button" class="album-create" @click="closeAlbumMenu($event);viewMode='albums';refreshFolderAlbums()"><Plus :size="17"/> 新建文件夹相册</button>
          </div>
        </div>
      </details>
    </div>
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
    <div v-if="!assets.length && (loadError || scanActionError || scanStatusError || scanStatusLoaded&&scan.lastError)" class="gallery-empty" role="alert">
      <Images :size="40" :stroke-width="1.2" />
      <h3>{{loadError?"暂时无法读取图库":scanActionError?"扫描无法启动":scanStatusError?"无法确认扫描状态":"上次扫描未完成"}}</h3>
      <p>{{loadError || scanActionError || (scanStatusError?"扫描状态暂不可用："+scanStatusError:"上次扫描未完成："+describeUserFacingError(scan.lastError))}}</p>
      <button v-if="loadError" type="button" class="refresh" :disabled="loading" @click="retryLoad">重试读取图库</button>
      <button v-if="scanStatusError" type="button" class="refresh" :disabled="scanStatusLoading" @click="status">重试读取扫描状态</button>
      <button v-if="admin&&(!loadError||scanActionError||scan.lastError)" type="button" class="refresh" :disabled="scan.running&&!scanStatusError" @click="startScan">重新扫描</button>
      <p v-if="!admin">可在设置的「缺失媒体」中重新检查自己的目录；其他目录请联系管理员。</p>
    </div>
    <div v-else-if="!assets.length&&(loading||!galleryLoaded||(!scanStatusLoaded&&!scanStatusError)||scan.running&&!scanStatusError)" class="gallery-empty">{{scan.running&&!scanStatusError?"正在扫描媒体…":!scanStatusLoaded&&!scanStatusError?"正在确认媒体扫描状态…":"正在读取媒体索引…"}}</div>
    <div v-else-if="!assets.length" class="gallery-empty">
      <Images :size="40" :stroke-width="1.2" />
      <h3>{{searchApplied?'没有匹配「'+searchApplied+'」的媒体':activeFolderAlbum?'文件夹相册还没有照片':currentPrivateAlbum?'私人相册还没有照片':currentAlbum?'此相册还没有照片':onThisDayOnly?'今天还没有那年今天的回忆':personalOnly?'还没有个人收藏':favoritesOnly?'还没有共享收藏':typeFilter==='video'?'这里还没有视频':typeFilter==='photo'?'这里还没有照片':'这里还没有照片或视频'}}</h3>
      <p v-if="activeFolderAlbum">可以在文件管理中放入照片，或在照片预览中选择复制或移动到此相册。新文件会在扫描后显示。</p>
      <p v-else-if="currentPrivateAlbum">打开全部照片，预览照片后选择自己的私人相册并点击「加入我的相册」。其他账号不会看到这里的相册名称和照片清单。</p>
      <p v-else-if="currentAlbum">打开全部照片，预览照片后选择此相册并点击「加入相册」。</p>
      <p v-else-if="onThisDayOnly">还没有照片拍摄于历史上的今天。带拍摄时间的照片（相机 JPEG、iPhone 照片与视频）会在多年后的同一天出现在这里。</p>
      <p v-else-if="favoritesOnly">在照片预览中点击收藏，已授权查看该照片的成员都可以看到。</p>
      <p v-else-if="personalOnly">预览自己有权限查看的照片，点击星形按钮保存到仅自己可见的收藏夹。</p>
      <p v-else>在文件管理中上传照片或视频，然后点击「扫描媒体」。<span v-if="!admin">请让管理员执行扫描。</span></p>
      <button v-if="activeFolderAlbum||currentAlbum||currentPrivateAlbum||favoritesOnly||personalOnly||onThisDayOnly" type="button" class="refresh" @click="changeView(0,false)">浏览全部照片</button>
    </div>
    <p v-if="loadError&&assets.length" class="form-error" role="alert">{{loadError}} 当前仍显示上次成功读取的内容。 <button type="button" class="refresh" :disabled="loading" @click="retryLoad">重试加载</button></p>
    <div v-if="assets.length&&timelineYears.length&&!onThisDayOnly" class="timeline-jump">
      <div class="timeline-jump-field"><span>年份</span>
        <AppleSelect v-model="jumpYear" :options="yearOptions" size="sm" aria-label="选择年份" @change="onJumpYearChange" />
      </div>
      <div class="timeline-jump-field"><span>月份</span>
        <AppleSelect v-model="jumpMonth" :options="monthOptions" :disabled="!jumpMonths.length" size="sm" aria-label="选择月份" @change="jumpToTimeline" />
      </div>
      <span v-if="browseTitle" class="timeline-jump-current">正在浏览 {{browseTitle}}</span>
      <button type="button" class="timeline-jump-top" title="回到最新照片" @click="scrollToTop"><ArrowUp :size="14"/> 最新</button>
    </div>
    <div v-if="assets.length" ref="gridElement" class="photo-grid" role="group" aria-label="按年月排列的照片和视频" :style="{height:timelineLayout.totalHeight+'px'}">
      <div v-for="header in visibleHeaders" :key="header.startIndex" class="photo-month-heading" :style="{top:header.top+'px'}" role="heading" aria-level="3">
        {{header.title}} <small>{{header.count}} 项<span v-if="nextCursor"> · 已加载</span></small>
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
  </div>
  <Teleport to="body">
  <div v-if="selected" class="dialog-backdrop" @click.self="closeModal()">
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
      <div v-if="viewerInfo" id="photo-viewer-info" class="viewer-info" role="region" aria-label="当前媒体信息">
        <div class="viewer-info-heading"><strong>媒体信息</strong><button type="button" aria-label="关闭媒体信息" @click="viewerInfo=false"><X :size="18"/></button></div>
        <dl>
          <div v-if="capturedLabel(selected)"><dt>拍摄时间</dt><dd>{{capturedLabel(selected)}}</dd></div>
          <div v-if="selected.cameraMake||selected.cameraModel"><dt>相机</dt><dd>{{[selected.cameraMake,selected.cameraModel].filter(Boolean).join(" ")}}</dd></div>
          <div v-if="selected.lensModel"><dt>镜头</dt><dd>{{selected.lensModel}}</dd></div>
          <div v-if="selected.iso||selected.fNumber||selected.exposureSeconds||selected.focalLength"><dt>参数</dt><dd>{{[selected.iso?"ISO "+selected.iso:"",selected.fNumber?formatAperture(selected.fNumber):"",selected.exposureSeconds?formatExposure(selected.exposureSeconds):"",selected.focalLength?selected.focalLength+"mm":""].filter(Boolean).join(" · ")}}</dd></div>
          <div v-if="selected.width&&selected.height"><dt>分辨率</dt><dd>{{selected.width}} × {{selected.height}}</dd></div>
          <div v-if="selected.durationSeconds"><dt>时长</dt><dd>{{formatDuration(selected.durationSeconds)}}</dd></div>
          <div><dt>文件</dt><dd>{{formatBytes(selected.size)}}</dd></div>
          <div v-if="selected.latitude!=null&&selected.longitude!=null"><dt>位置</dt><dd class="viewer-location"><MapPin :size="13"/> {{coordinateLabel(selected.latitude,selected.longitude)}} <button type="button" class="viewer-map-link" @click="showOnMap(selected.latitude!,selected.longitude!)">在地图上查看</button></dd></div>
        </dl>
      </div>
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
        <video v-else controls playsinline :src="original(selected)" class="gallery-modal-video"/>
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
</template>

<style scoped src="./PhotosView.css"></style>
