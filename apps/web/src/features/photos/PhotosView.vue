<script setup lang="ts">
import { createVisibleMediaPolling } from "../../api/visibleMediaPolling.ts";
import { usePhotoPersonalFavorite } from "./usePhotoPersonalFavorite.ts";
import { computed, nextTick, onMounted, onUnmounted, provide, ref, watch } from "vue";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { createScopedRootApi } from "../../api/apiClient.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import {
  PHOTO_ALBUMS_OVERVIEW_CTX,
  PHOTO_BATCH_CTX,
  PHOTO_TIMELINE_CTX,
  PHOTO_VIEWER_CTX,
} from "../../contexts/photosContext.ts";
import {
  Heart, Star, RefreshCw, Images, Film,
  Pencil, Trash2, Sparkles, LayoutList,
  Map as MapIcon, Users, FolderPlus,
} from "lucide-vue-next";
import { createLatestRequestGate } from "../../api/latestRequestGate.ts";
import { mediaQueryKey } from "../../api/mediaQueryContext.ts";
import { rootApiPath, rootMediaPath } from "../../api/rootApi.ts";
import PhotoMapView from "./PhotoMapView.vue";
import PhotoPeopleView from "./PhotoPeopleView.vue";
import PhotoSimilarCleanupView from "./PhotoSimilarCleanupView.vue";
import PhotoAlbumOverviewSection from "./PhotoAlbumOverviewSection.vue";
import PhotosBatchBar from "./PhotosBatchBar.vue";
import PhotosTimelineToolbar from "./PhotosTimelineToolbar.vue";
import PhotoViewerModal from "./PhotoViewerModal.vue";
import PhotoFrameOverlay from "./PhotoFrameOverlay.vue";
import PhotoMetadataEditModal from "./PhotoMetadataEditModal.vue";
import { usePhotoMetadataEditor } from "./usePhotoMetadataEditor.ts";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleCharts from "../../components/ui/IsleCharts.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import { ISLE_CHART_COLORS } from "../../components/ui/isleChartsMath.ts";
import { usePhotoViewer } from "./usePhotoViewer.ts";
import { dateLabel, formatDuration } from "./photoPresentation.ts";
import { usePhotoFilterAndSharing } from "./usePhotoFilterAndSharing.ts";
import { usePhotoBatchActions, type BatchAsset } from "./usePhotoBatchActions.ts";
import { usePhotoAlbums } from "./usePhotoAlbums.ts";
import { usePhotoTimelineScrubber } from "./usePhotoTimelineScrubber.ts";
import { usePhotoGridAndModal } from "./usePhotoGridAndModal.ts";
import { usePhotoAISearchAndPeople, type PhotoViewMode } from "./usePhotoAISearchAndPeople.ts";
import { usePhotosCatalogLoader } from "./usePhotosCatalogLoader.ts";
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
let searchTimer: number | undefined;

const loading = ref(false);
const galleryLoaded = ref(false);
const loadError = ref("");
const message = ref("");
const albumBusy = ref(false);
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

let refreshFolderAlbumsBridge: (more?: boolean) => Promise<void> = async () => {};
const {
  cameraFilter, locationFilter, yearFilter, shareTargets, sharingAlbum, shareMemberId, shareCanWrite,
  cameraOptions, locationOptions, filterYearOptions, shareTargetOptions, hasActiveExifFilter,
  resetExifFilters, appendExifFilterParams, refreshFacets, openSharePanel, submitFolderAlbumShare,
  removeFolderAlbumShare, onExifFilterChange,
} = usePhotoFilterAndSharing({
  api: (url, method, body, signal) => api(url, method, body, signal),
  apiPath: (path) => apiPath(path),
  albumBusy,
  message,
  refreshFolderAlbums: (more) => refreshFolderAlbumsBridge(more),
  onFilterChanged: () => { void load(true); },
});

const {
  albums, privateAlbums, activeAlbum, activePrivateAlbum, folderAlbums, folderCursor,
  folderError, folderLoading, folderName, folderTarget, activeFolderAlbum, sharedAlbumsError,
  privateAlbumsError, sharedAlbumsLoading, privateAlbumsLoading, creating, albumName,
  addAlbum, addPrivateAlbum, creatingPrivate, editingPrivate, privateAlbumName,
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
  photosPage, shareTargets, message, albumBusy,
  getRootEpoch: () => rootEpoch, getViewGeneration: () => viewGeneration, bumpViewGeneration: () => ++viewGeneration,
  getSelectionGeneration: () => selectionGeneration, bumpSelectionGeneration: () => ++selectionGeneration,
  isDisposed: () => disposed, canWriteAsset, api, apiPath,
  load: (reset?: boolean): Promise<void> => load(reset),
  showAssetAt: (index: number): void => showAssetAt(index),
  closeModal: (restore?: boolean): void => { closeModal(Boolean(restore)); },
  focusTile: (index: number): Promise<void> => focusTile(index),
  changeView: (album: number, favorites: boolean, mine?: boolean, privateID?: number): void => { changeView(album, favorites, mine, privateID); },
});
refreshFolderAlbumsBridge = refreshFolderAlbums;

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
  if (searchTimer) clearTimeout(searchTimer);
  searchTimer = window.setTimeout(() => {
    const term = value.trim();
    if (term === searchApplied.value) return;
    searchApplied.value = term;
    void load(true);
  }, TIMINGS_MS.SEARCH_DEBOUNCE);
});

function onSearchSubmit() {
  if (searchTimer) clearTimeout(searchTimer);
  const term = searchInput.value.trim();
  if (term !== searchApplied.value) {
    searchApplied.value = term;
    void load(true);
  }
}

function onSearchClear() {
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

const photoFrameOpen = ref(false);
const metadataEditor = usePhotoMetadataEditor({
  api,
  rootPath: apiPath,
  onUpdated: async () => {
    message.value = "已更新拍摄时间或地点（原片文件未改动）。";
    await load(true);
    void refreshTimelineIndex();
    void refreshFacets();
  },
});
function openPhotoFrame() {
  if (selected.value) closeModal(false);
  photoFrameOpen.value = true;
}

provide(PHOTO_TIMELINE_CTX, {
  activeAlbum, activePrivateAlbum, activeFolderAlbum, currentPrivateAlbum, currentAlbum,
  favoritesOnly, personalOnly, isOnThisDay: onThisDayOnly, albums, privateAlbums, folderAlbums,
  typeFilter, exifFilterOpen,
  hasActiveExif: computed(() => hasActiveExifFilter()),
  hasAssets: computed(() => assets.value.length > 0),
  hasTimelineYears: computed(() => timelineYears.value.length > 0),
  jumpYear, jumpMonth, hasJumpMonths: computed(() => jumpMonths.value.length > 0),
  yearOptions, monthOptions, searchInput,
  searchPlaceholder: computed(() => currentSearchPlaceholder()),
  searchApplied, searchMode,
  activePersonName: computed(() => activePerson.value?.name ?? ""),
  cameraFilter, cameraOptions, locationFilter, locationOptions, yearFilter, filterYearOptions,
  showMemoriesStrip: computed(() => isFullTimelineView() && assets.value.length > 0),
  smartMemories, compactGrid, trashSelecting, trashBusy,
  selectAll: () => changeView(0, false),
  selectOnThisDay: () => showOnThisDay(),
  selectPersonal: () => changeView(0, false, true),
  selectFavorites: () => changeView(0, true),
  openFolderAlbum,
  openSharedAlbum: (id) => changeView(id, false),
  openPrivateAlbum: (id) => changeView(0, false, false, id),
  goCreateFolderAlbum: () => { viewMode.value = "albums"; void refreshFolderAlbums(); },
  setTypeFilter,
  selectSmartMemory: openSmartMemory,
  toggleExifFilter: () => { exifFilterOpen.value = !exifFilterOpen.value; },
  onJumpYearChange, jumpToTimeline, scrollToTop, onSearchSubmit, onSearchClear,
  toggleCompactGrid,
  toggleTrashSelecting: () => { trashSelecting.value = !trashSelecting.value; trashIDs.value = new Set(); },
  selectSearchMode: (m) => setSearchMode(m, Boolean(searchApplied.value)),
  clearPerson: clearPersonFilter,
  onExifFilterChange,
  resetExifFiltersAndReload: () => { resetExifFilters(); onExifFilterChange(); },
  clearAllFilters,
  openPhotoFrame,
});

provide(PHOTO_ALBUMS_OVERVIEW_CTX, {
  folderAlbums, folderCursor, folderError, folderLoading, folderName, albumBusy,
  shareTargetsCount: computed(() => shareTargets.value.length),
  sharingAlbumPath: computed(() => sharingAlbum.value?.path ?? ""),
  shareMemberId, shareCanWrite, shareTargetOptions,
  privateAlbums, privateAlbumsError, privateAlbumsLoading, albums,
  sharedAlbumsError, sharedAlbumsLoading, failedAlbumCovers, mediaPath,
  refreshFolders: (more) => void refreshFolderAlbums(more),
  createFolder: () => void createFolderAlbum(),
  openFolder: openFolderAlbum,
  openShare: openSharePanel,
  deleteFolder: (album) => void deleteFolderAlbum(album),
  submitShare: (album) => void submitFolderAlbumShare(album),
  removeShare: (album, memberId, ownerId) => void removeFolderAlbumShare(album, memberId, ownerId),
  refreshPrivate: () => void refreshPrivateAlbums(),
  refreshShared: () => void refreshAlbums(),
  openLegacy: openAlbumFromOverview,
  markCoverError: (key) => { failedAlbumCovers.value[key] = true; },
});

provide(PHOTO_BATCH_CTX, {
  selecting: trashSelecting,
  busy: trashBusy,
  selectedCount: computed(() => trashIDs.value.size),
  totalLoaded: computed(() => assets.value.length),
  folderTarget: batchFolderTarget,
  folderOptions: folderAlbumOptions,
  hasFolderAlbums: computed(() => folderAlbums.value.length > 0),
  folderCursor, folderLoading, folderError,
  privateAlbum: batchPrivateAlbum,
  privateAlbumOptions,
  hasPrivateAlbums: computed(() => privateAlbums.value.length > 0),
  shareLinks: batchShareLinks,
  shareNotice: batchShareNotice,
  selectTop50: () => { trashIDs.value = new Set(assets.value.slice(0, 50).map((item) => item.id)); },
  clearSelection: () => { trashIDs.value = new Set(); },
  exitSelecting: () => { trashSelecting.value = false; trashIDs.value = new Set(); },
  trashSelected: () => void trashSelectedPhotos(),
  batchShare: () => void batchShare(),
  batchDownload: () => void batchDownload(),
  batchFolder: (mode) => void batchToFolder(mode),
  loadMoreFolders: () => void refreshFolderAlbums(true),
  retryFolders: () => void refreshFolderAlbums(),
  batchPrivateAlbum: () => void batchToPrivateAlbum(),
  copyShareLinks: () => void copyBatchShareLinks(),
  closeShareLinks: () => { batchShareLinks.value = []; batchShareNotice.value = ""; },
  editSelectedMetadata: () => metadataEditor.openForAssets(assets.value.filter((a) => trashIDs.value.has(a.id))),
});

provide(PHOTO_VIEWER_CTX, {
  selected,
  active: computed(() => props.active !== false),
  selectedIndex, modalAssets, viewerInfo, albumOrganizerOpen,
  admin: computed(() => props.admin),
  canWrite: computed(() => (selected.value ? canWriteAsset(selected.value) : false)),
  pendingFavorite: computed(() => (selected.value ? Boolean(pendingFavorites.value[selected.value.id]) : false)),
  trashBusy, slideshow, viewerAIDetail, viewerAILoading,
  viewerSrc: computed(() => (selected.value ? viewerSrc(selected.value) : "")),
  viewerStage, viewerPreviewLoading, viewerPreviewError, viewerOriginalLoading, viewerOriginalError,
  viewerScale, viewerTransform, viewerAnimate,
  viewerPointersSize: computed(() => viewerPointers.size),
  browserDecodable: computed(() => (selected.value ? browserDecodable(selected.value) : false)),
  mediaPath,
  originalUrl: computed(() => (selected.value ? original(selected.value) : "")),
  thumbFor: thumb,
  folderAlbums, folderAlbumOptions, folderTarget, albums, albumOptions, addAlbum, activeAlbum,
  sharedAlbumsError, sharedAlbumsLoading, privateAlbums, privateAlbumOptions, addPrivateAlbum,
  activePrivateAlbum, privateAlbumsError, privateAlbumsLoading, albumBusy, message,
  setDialogRef: (el) => { galleryDialog.value = el; },
  setCloseButtonRef: (el) => { modalCloseButton.value = el; },
  close: () => closeModal(),
  showAt: showAssetAt,
  toggleFavorite: () => { if (selected.value) void toggleFavorite(selected.value); },
  togglePersonalFavorite: () => { if (selected.value) void togglePersonalFavorite(selected.value); },
  toggleAlbumOrganizer: () => { albumOrganizerOpen.value = !albumOrganizerOpen.value; },
  toggleSlideshow,
  toggleInfo: () => { viewerInfo.value = !viewerInfo.value; },
  trashSelected: () => { if (selected.value) void trashPhotos([selected.value]); },
  toggleZoom: toggleViewerZoom,
  requestOriginal: requestViewerOriginal,
  pointerDown: viewerPointerDown,
  pointerMove: viewerPointerMove,
  pointerUp: viewerPointerUp,
  wheel: viewerWheel,
  showOnMap,
  selectPerson: (person) => { closeModal(false); filterByPerson(person); },
  searchTag: (tag) => { closeModal(false); searchMode.value = "scene"; searchInput.value = tag; searchApplied.value = tag; void load(true); },
  folderAction: (mode) => void addSelectedToFolder(mode),
  addShared: () => void addSelected(),
  removeShared: () => void removeSelectedFromAlbum(),
  retryShared: () => void refreshAlbums(),
  addPrivate: () => void addSelectedPrivate(),
  removePrivate: () => void removeSelectedPrivate(),
  retryPrivate: () => void refreshPrivateAlbums(),
  openPhotoFrame,
  editMetadata: () => { if (selected.value) metadataEditor.openForAssets([selected.value]); },
});

const setScanPolling = createVisibleMediaPolling(status, 4500);
let initialLoadPending = false;
function triggerInitialLoad() {
  void load(true);
  void refreshAlbums();
  void refreshPrivateAlbums();
  void refreshFolderAlbums();
  void refreshTimelineIndex();
  void refreshFacets();
  void refreshSmartMemories();
  void status();
}
onMounted(() => {
  disposed = false;
  mountGridAndModal();
  if (props.active !== false) {
    initialLoadPending = false;
    triggerInitialLoad();
    setScanPolling(true);
  } else {
    initialLoadPending = true;
    setScanPolling(false);
  }
});
watch(() => props.active, (val) => {
  const isActive = val !== false;
  setGridActive(isActive);
  if (!isActive) {
    setScanPolling(false);
    if (selected.value) closeModal(false);
  } else {
    setScanPolling(true);
    if (initialLoadPending) {
      initialLoadPending = false;
      triggerInitialLoad();
    } else if (!document.hidden) {
      void status();
    }
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
    <IslePageHeader
      title="时光相册"
      :subtitle="activePerson ? '人物筛选 · ' + activePerson.name : activeFolderAlbum ? '文件夹相册 · ' + activeFolderAlbum.name : currentPrivateAlbum ? '私人相册 · ' + currentPrivateAlbum.name : currentAlbum ? '共享相册 · ' + currentAlbum.name : onThisDayOnly ? '那年今天' : personalOnly ? '我的收藏' : favoritesOnly ? '共享收藏' : browseTitle ? '正在浏览 ' + browseTitle : '按时间线、人物、相册与足迹整理原片，绝不改动原始文件'"
      class="photos-header-bar"
    >
      <template #title-extra>
        <IsleHelpButton
          title="相册浏览与原片保护"
          :items="[
            { title: '原片零改动', body: '照片和视频缩略图按需生成缓存加速浏览，图库绝不修改或复制你的原始媒体文件。' },
            { title: '收藏作用域区分', body: '「我的收藏 ★」仅当前账号可见；「共享收藏 ♥」对拥有当前共享目录权限的家庭成员均可见。' },
            { title: '相册与智能整理', body: '在「相册」中可按文件夹相册、共享相册、人物和足迹地图浏览；在「清理」中可一键发现相似照片。' },
          ]"
        />
      </template>
      <template #actions>
        <div class="photo-mode-tabs" role="tablist" aria-label="照片浏览方式">
          <button type="button" role="tab" :aria-selected="viewMode==='timeline'" :class="{chosen:viewMode==='timeline'}" @click="viewMode='timeline'"><LayoutList :size="15"/> 照片</button>
          <button type="button" role="tab" :aria-selected="viewMode==='albums'||viewMode==='people'||viewMode==='map'" :class="{chosen:viewMode==='albums'||viewMode==='people'||viewMode==='map'}" @click="viewMode='albums';refreshFolderAlbums()"><Images :size="15"/> 相册</button>
          <button type="button" role="tab" :aria-selected="viewMode==='cleanup'" :class="{chosen:viewMode==='cleanup'}" @click="viewMode='cleanup'"><Sparkles :size="15"/> 清理</button>
        </div>
        <IsleButton v-if="admin" variant="glass" size="sm" :disabled="scan.running&&!scanStatusError" @click="startScan">
          <template #icon><RefreshCw :size="15" :class="{spinning:scan.running&&!scanStatusError}" /></template>
          {{scan.running&&!scanStatusError?"扫描中…":"扫描媒体"}}
        </IsleButton>
      </template>
    </IslePageHeader>

    <div v-if="viewMode==='albums'||viewMode==='people'||viewMode==='map'" class="photos-album-subtabs" role="tablist" aria-label="相册分区">
      <button type="button" role="tab" :aria-selected="viewMode==='albums'" :class="{chosen:viewMode==='albums'}" @click="viewMode='albums';refreshFolderAlbums()"><FolderPlus :size="14"/> 文件夹与共享相册</button>
      <button type="button" role="tab" :aria-selected="viewMode==='people'" :class="{chosen:viewMode==='people'}" @click="viewMode='people'"><Users :size="14"/> 人物</button>
      <button type="button" role="tab" :aria-selected="viewMode==='map'" :class="{chosen:viewMode==='map'}" @click="viewMode='map'"><MapIcon :size="14"/> 足迹地图</button>
    </div>

    <p v-if="previousRootShareWarning" class="form-error" role="alert">{{previousRootShareWarning}} <button type="button" class="refresh" @click="previousRootShareWarning=''">知道了</button></p>
    <div v-if="scan.running&&!scanStatusError" class="scan-banner">正在后台整理媒体 · 已检查 {{scan.scanned}} 项 · 发现 {{scan.found}} 项</div>
    <div v-else-if="scan.aiIndexing&&(scan.aiIndexing.running||scan.aiIndexing.paused||(scan.aiIndexing.remaining??0)>0)" class="scan-banner scan-banner--ai">
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
      <button v-if="admin" type="button" class="refresh scan-banner-action" :disabled="aiPauseBusy" @click="toggleAIPause(scan.aiIndexing.paused)">{{ scan.aiIndexing.paused ? "恢复索引" : "暂停索引" }}</button>
    </div>
    <div v-if="scanStatusError&&assets.length" class="form-error" role="alert">扫描状态读取失败：{{scanStatusError}} <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span><button type="button" class="refresh" :disabled="scanStatusLoading" @click="status">{{scanStatusLoading?"正在重试…":"重试状态"}}</button></div>
    <p v-if="scanStatusLoaded&&scan.lastError&&assets.length" class="form-error">上次扫描：{{describeUserFacingError(scan.lastError)}}</p>
    <p v-if="message" class="gallery-message">{{message}}</p>
    <p v-if="scanActionError&&assets.length" class="gallery-message" role="alert">{{scanActionError}}</p>
    <PhotoMapView v-if="props.active !== false && viewMode === 'map'" class="isle-subview-pane" :key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :root-id="props.rootId" :root-generation="props.rootGeneration" ref="photoMap" :transport="mapTransport" @open-asset="openMapAsset"/>
    <PhotoPeopleView v-if="props.active !== false && viewMode === 'people'" class="isle-subview-pane" :active="viewMode === 'people'" :root-key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :api="api" :api-path="apiPath" :media-path="mediaPath" @select-person="filterByPerson" />
    <PhotoSimilarCleanupView v-if="props.active !== false && viewMode === 'cleanup'" class="isle-subview-pane" :active="viewMode === 'cleanup'" :root-key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :api="api" :api-path="apiPath" :media-path="mediaPath" @trashed="load(true); status()" />
    <PhotoAlbumOverviewSection v-show="viewMode === 'albums'" class="isle-subview-pane" />
    <div v-show="viewMode === 'timeline'" class="isle-subview-pane">
      <PhotosTimelineToolbar />

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
    </div>

    <PhotosBatchBar />

    <PhotoViewerModal />
    <PhotoFrameOverlay :open="photoFrameOpen" :assets="assets" :title="activePerson?.name || activeFolderAlbum?.name || currentAlbum?.name || '时光相册'" :media-path="mediaPath" @close="photoFrameOpen = false" />
    <PhotoMetadataEditModal :open="metadataEditor.open.value" :asset-ids="metadataEditor.targetIds.value" :initial-taken-at="metadataEditor.initialTakenAt.value" :initial-latitude="metadataEditor.initialLatitude.value" :initial-longitude="metadataEditor.initialLongitude.value" :busy="metadataEditor.busy.value" :error="metadataEditor.error.value" @close="metadataEditor.close()" @submit="metadataEditor.submit($event)" />
  </div>
</template>
