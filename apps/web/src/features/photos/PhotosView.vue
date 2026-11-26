<script setup lang="ts">
import { createVisibleMediaPolling } from "../../api/visibleMediaPolling.ts";
import { usePhotoPersonalFavorite } from "./usePhotoPersonalFavorite.ts";
import { computed, nextTick, onMounted, onUnmounted, provide, ref, watch } from "vue";
import { createScopedRootApi } from "../../api/apiClient.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import {
  PHOTO_ALBUMS_OVERVIEW_CTX,
  PHOTO_BATCH_CTX,
  PHOTO_TIMELINE_CTX,
  PHOTO_VIEWER_CTX,
} from "../../contexts/photosContext.ts";
import {
  RefreshCw, Images, Sparkles, LayoutList,
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
import PhotoStickyMonthBar from "./PhotoStickyMonthBar.vue";
import PhotoViewerModal from "./PhotoViewerModal.vue";
import PhotoFrameOverlay from "./PhotoFrameOverlay.vue";
import PhotoMetadataEditModal from "./PhotoMetadataEditModal.vue";
import PhotoTimelineScrubber from "./PhotoTimelineScrubber.vue";
import PhotoTimelineEmptyState from "./PhotoTimelineEmptyState.vue";
import PhotoAlbumInlineManagement from "./PhotoAlbumInlineManagement.vue";
import PhotoScanStatusBanners from "./PhotoScanStatusBanners.vue";
import PhotoTimelineGrid from "./PhotoTimelineGrid.vue";
import { usePhotoMetadataEditor } from "./usePhotoMetadataEditor.ts";
import { useSlidingIndicator } from "../../composables/useSlidingIndicator.ts";
import IsleSlidingIndicator from "../../components/ui/IsleSlidingIndicator.vue";
import { PHOTO_STAGE_EXT_CTX } from "./photoStageContext.ts";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import { usePhotoViewer } from "./usePhotoViewer.ts";
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
const thumbnailLoaded = ref<Record<number, boolean>>({});
const pendingFavorites = ref<Record<number, boolean>>({});
const photosPage = ref<HTMLElement | null>(null);
const albumOrganizerOpen = ref(false);
const focusedIndex = ref(0);
const nextCursor = ref(0);
const viewMode = ref<PhotoViewMode>("timeline");
const modeTabsRef = ref<HTMLElement | null>(null);
const albumSubtabsRef = ref<HTMLElement | null>(null);

const { indicatorStyle: modeIndicatorStyle, indicatorReady: modeIndicatorReady } = useSlidingIndicator({
  containerRef: modeTabsRef,
  activeSelector: "button.chosen",
  watchSources: [viewMode, () => props.active],
});
const { indicatorStyle: subtabsIndicatorStyle, indicatorReady: subtabsIndicatorReady } = useSlidingIndicator({
  containerRef: albumSubtabsRef,
  activeSelector: "button.chosen",
  watchSources: [viewMode, () => props.active],
});
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
function markThumbnailFailed(id: number) {
  if (!thumbnailFailed.value[id]) {
    thumbnailFailed.value = { ...thumbnailFailed.value, [id]: true };
  }
}
function onThumbnailLoad(event: Event, id: number) {
  const img = event.target as HTMLImageElement | null;
  if (img && img.naturalWidth === 0) {
    markThumbnailFailed(id);
    return;
  }
  if (!thumbnailLoaded.value[id]) {
    thumbnailLoaded.value = { ...thumbnailLoaded.value, [id]: true };
  }
}

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
  folderError, folderLoading, folderName, folderTarget, activeFolderAlbum, folderCovers,
  folderCoverStatus, sharedAlbumsError,
  privateAlbumsError, sharedAlbumsLoading, privateAlbumsLoading, creating, albumName,
  addAlbum, addPrivateAlbum, creatingPrivate, editingPrivate, privateAlbumName,
  failedAlbumCovers, editingAlbum, folderAlbumOptions, albumOptions, privateAlbumOptions,
  currentPrivateAlbum, currentAlbum, refreshAlbums, refreshPrivateAlbums, refreshFolderAlbums,
  requestFolderCover, createFolderAlbum, deleteFolderAlbum, openFolderAlbum, addSelectedToFolder, editPrivateAlbum,
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
  move(delta): boolean {
    const index = selectedIndex.value + delta;
    if (index < 0 || index >= modalAssets.value.length) return false;
    showAssetAt(index);
    return true;
  },
  canMove(delta): boolean {
    const index = selectedIndex.value + delta;
    return index >= 0 && index < modalAssets.value.length;
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
  scrubPreview, scrubCurrentIndex, scrubScrolling, scrolledPastHeader, activeStickyGroup,
  refreshTimelineIndex, jumpToTimeline, onJumpYearChange, startScrub, moveScrub,
  stopScrub, scrubKeydown, scrollToTop, resetScrubberForRootChange,
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
    thumbnailFailed.value = {};
    thumbnailLoaded.value = {};
    void refreshAlbums(); void refreshPrivateAlbums(); void refreshTimelineIndex(); void refreshFacets(); void refreshSmartMemories();
  },
});

const { smartMemories, refreshSmartMemories } = usePhotoMemories({
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
  viewMode.value = "timeline";
  if (mem.kind === "live") { setTypeFilter("live"); return; }
  if (mem.takenFrom) {
    const yr = new Date(mem.takenFrom * 1000).getFullYear();
    if (yr > 1970) { yearFilter.value = yr; onExifFilterChange(); }
  }
}
function jumpToYearMonth(year: number, month: number) {
  jumpYear.value = year;
  jumpMonth.value = month;
  void jumpToTimeline();
}
function downloadSingleAsset(asset: Asset) {
  const link = document.createElement("a");
  link.href = mediaPath("/api/v2/files/content?path=" + encodeURIComponent(asset.path));
  link.download = asset.name;
  link.rel = "noopener";
  document.body.appendChild(link);
  link.click();
  link.remove();
}

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

provide(PHOTO_STAGE_EXT_CTX, {
  mediaPath,
  folderCovers,
  folderCoverStatus,
  requestFolderCover,
  openSmartMemory,
  downloadAsset: downloadSingleAsset,
  toggleZoomAtPointer: toggleViewerZoom,
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
        <div ref="modeTabsRef" class="photo-mode-tabs" role="tablist" aria-label="照片浏览方式">
          <IsleSlidingIndicator variant="segment" :ready="modeIndicatorReady" :pill-rect="modeIndicatorStyle" />
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

    <div v-if="viewMode==='albums'||viewMode==='people'||viewMode==='map'" ref="albumSubtabsRef" class="photos-album-subtabs" role="tablist" aria-label="相册分区">
      <IsleSlidingIndicator variant="segment" :ready="subtabsIndicatorReady" :pill-rect="subtabsIndicatorStyle" />
      <button type="button" role="tab" :aria-selected="viewMode==='albums'" :class="{chosen:viewMode==='albums'}" @click="viewMode='albums';refreshFolderAlbums()"><FolderPlus :size="14"/> 文件夹与共享相册</button>
      <button type="button" role="tab" :aria-selected="viewMode==='people'" :class="{chosen:viewMode==='people'}" @click="viewMode='people'"><Users :size="14"/> 人物</button>
      <button type="button" role="tab" :aria-selected="viewMode==='map'" :class="{chosen:viewMode==='map'}" @click="viewMode='map'"><MapIcon :size="14"/> 足迹地图</button>
    </div>

    <PhotoScanStatusBanners
      :admin="admin"
      :has-assets="assets.length > 0"
      :scan="scan"
      :scan-status-loaded="scanStatusLoaded"
      :scan-status-loading="scanStatusLoading"
      :scan-status-error="scanStatusError"
      :scan-action-error="scanActionError"
      :ai-pause-busy="aiPauseBusy"
      :message="message"
      :previous-root-share-warning="previousRootShareWarning"
      @dismiss-share-warning="previousRootShareWarning = ''"
      @toggle-ai-pause="toggleAIPause($event)"
      @retry-status="status"
    />
    <PhotoMapView v-if="props.active !== false && viewMode === 'map'" class="isle-subview-pane" :key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :root-id="props.rootId" :root-generation="props.rootGeneration" ref="photoMap" :transport="mapTransport" @open-asset="openMapAsset"/>
    <PhotoPeopleView v-if="props.active !== false && viewMode === 'people'" class="isle-subview-pane" :active="viewMode === 'people'" :root-key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :api="api" :api-path="apiPath" :media-path="mediaPath" @select-person="filterByPerson" />
    <PhotoSimilarCleanupView v-if="props.active !== false && viewMode === 'cleanup'" class="isle-subview-pane" :active="viewMode === 'cleanup'" :root-key="(props.rootId ?? 'legacy') + ':' + (props.rootGeneration ?? 0)" :api="api" :api-path="apiPath" :media-path="mediaPath" @trashed="load(true); status()" />
    <PhotoAlbumOverviewSection v-show="viewMode === 'albums'" class="isle-subview-pane" />
    <div v-show="viewMode === 'timeline'" class="isle-subview-pane">
      <PhotosTimelineToolbar />

      <PhotoAlbumInlineManagement
        v-model:private-album-name="privateAlbumName"
        v-model:album-name="albumName"
        :admin="admin"
        :album-busy="albumBusy"
        :selected-open="Boolean(selected)"
        :shared-albums-error="sharedAlbumsError"
        :shared-albums-loading="sharedAlbumsLoading"
        :private-albums-error="privateAlbumsError"
        :private-albums-loading="privateAlbumsLoading"
        :active-folder-album="activeFolderAlbum"
        :current-private-album="currentPrivateAlbum"
        :current-album="currentAlbum"
        :creating-private="creatingPrivate"
        :editing-private="editingPrivate"
        :creating="creating"
        :editing-album="editingAlbum"
        @retry-shared="refreshAlbums"
        @retry-private="refreshPrivateAlbums()"
        @back-to-albums="viewMode = 'albums'; refreshFolderAlbums()"
        @edit-private="editPrivateAlbum($event)"
        @delete-private="deletePrivateAlbum"
        @save-private="savePrivateAlbum"
        @cancel-private="cancelPrivateAlbum"
        @begin-rename="beginAlbumRename($event)"
        @delete-album="deleteCurrentAlbum"
        @save-album="createAlbum"
        @cancel-album="cancelAlbumForm"
      />
    <PhotoTimelineEmptyState
      v-if="!assets.length"
      :admin="admin"
      :loading="loading"
      :gallery-loaded="galleryLoaded"
      :load-error="loadError"
      :scan-action-error="scanActionError"
      :scan-status-error="scanStatusError"
      :scan-status-loaded="scanStatusLoaded"
      :scan-status-loading="scanStatusLoading"
      :scan-running="scan.running"
      :scan-last-error="scan.lastError"
      :root-name="rootName"
      :has-other-roots="hasOtherRoots"
      @retry-load="retryLoad"
      @retry-status="status"
      @start-scan="startScan"
    />
    <p v-if="loadError&&assets.length" class="form-error" role="alert">{{loadError}} 当前仍显示上次成功读取的内容。 <button type="button" class="refresh" :disabled="loading" @click="retryLoad">重试加载</button></p>
    <PhotoStickyMonthBar
      v-if="assets.length"
      :visible="scrolledPastHeader && !onThisDayOnly"
      :group="activeStickyGroup"
      :selected="activeStickyGroup ? isMonthSelected(activeStickyGroup) : false"
      :busy="trashBusy"
      :has-more="nextCursor > 0"
      :timeline-years="timelineYears"
      :jump-year="jumpYear"
      :jump-month="jumpMonth"
      @toggle-month="toggleMonthSelection($event)"
      @jump-month="(y, m) => jumpToYearMonth(y, m)"
      @scroll-top="scrollToTop()"
    />
    <PhotoTimelineGrid
      v-if="assets.length"
      :total-height="timelineLayout.totalHeight"
      :compact-grid="compactGrid"
      :trash-selecting="trashSelecting"
      :trash-busy="trashBusy"
      :trash-ids="trashIDs"
      :has-more="nextCursor > 0"
      :visible-headers="visibleHeaders"
      :visible-assets="visibleAssets"
      :start-index="virtualWindow.startIndex"
      :focused-index="focusedIndex"
      :thumbnail-loaded="thumbnailLoaded"
      :thumbnail-failed="thumbnailFailed"
      :thumb-for="thumb"
      :tile-style-for="tileStyle"
      :is-month-selected="isMonthSelected"
      :set-grid-ref="(el) => { gridElement = el; }"
      @toggle-month="toggleMonthSelection($event)"
      @focus-index="focusedIndex = $event"
      @tile-keydown="(e, i) => onTileKeydown(e, i)"
      @tile-click="(a, i, s) => (trashSelecting ? toggleTrashID(a.id, s) : openAsset(a, i))"
      @thumb-load="(e, id) => onThumbnailLoad(e, id)"
      @thumb-error="markThumbnailFailed($event)"
    />
    <PhotoTimelineScrubber
      :visible="props.active !== false && scrubberInView && isFullTimelineView() && viewMode === 'timeline' && !selected && fullTimelineMonths.length > 1"
      :scrub-months="scrubMonths"
      :scrubbing="scrubbing"
      :scrub-preview="scrubPreview"
      :scrub-current-index="scrubCurrentIndex"
      :scrolling="scrubScrolling"
      @start="startScrub"
      @move="moveScrub"
      @stop="stopScrub"
      @keydown="scrubKeydown"
    />
    <div ref="loadMarker" class="gallery-load">
      <button v-if="nextCursor" type="button" @click="load()" :disabled="loading">{{loading?"自动加载中…":"加载更多"}}</button>
      <span v-else-if="assets.length">已显示 {{assets.length}} 项</span>
    </div>
    </div>

    <PhotosBatchBar />

    <PhotoFrameOverlay :open="photoFrameOpen" :assets="assets" :title="activePerson?.name || activeFolderAlbum?.name || currentAlbum?.name || '时光相册'" :media-path="mediaPath" @close="photoFrameOpen = false" />
    <PhotoMetadataEditModal :open="metadataEditor.open.value" :asset-ids="metadataEditor.targetIds.value" :initial-taken-at="metadataEditor.initialTakenAt.value" :initial-latitude="metadataEditor.initialLatitude.value" :initial-longitude="metadataEditor.initialLongitude.value" :busy="metadataEditor.busy.value" :error="metadataEditor.error.value" @close="metadataEditor.close()" @submit="metadataEditor.submit($event)" />
    <PhotoViewerModal />
  </div>
</template>
