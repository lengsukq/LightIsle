import { nextTick, ref, type Ref } from "vue";
import { describeRootOperationFailure } from "../rootDiscovery.ts";
import { describeUserFacingError } from "../userFacingError.ts";
import { createMediaStatusPoller } from "../mediaStatusPoller.ts";
import { transitionMediaQuery } from "../mediaQueryContext.ts";
import { getMetadata, putMetadata } from "../useIsleCache.ts";
import { appendAISearchParams, type AIIndexingStatus, type PhotoSearchMode } from "../usePhotoAISearchAndPeople.ts";
import type { BatchAsset } from "../usePhotoBatchActions.ts";

export type PhotosScanStatus = {
  running: boolean;
  scanned: number;
  found: number;
  lastError?: string;
  lastDone?: number;
  aiIndexing?: AIIndexingStatus;
};

export function usePhotosCatalogLoader({
  props,
  assets,
  nextCursor,
  loading,
  galleryLoaded,
  loadError,
  focusedIndex,
  timelineCursorStart,
  activeAlbum,
  activePrivateAlbum,
  activeFolderAlbum,
  favoritesOnly,
  personalOnly,
  onThisDayOnly,
  typeFilter,
  searchInput,
  searchApplied,
  searchMode,
  activePerson,
  selected,
  selectedIndex,
  pendingFavorites,
  message,
  photosPage,
  loadMarker,
  photoQueryKey,
  beginListRequest,
  getRootEpoch,
  getSelectionGeneration,
  bumpViewGeneration,
  bumpSelectionGeneration,
  isDisposed,
  api,
  apiPath,
  appendExifFilterParams,
  updateViewport,
  onScanCompleted,
}: {
  props: { admin: boolean };
  assets: Ref<BatchAsset[]>;
  nextCursor: Ref<number>;
  loading: Ref<boolean>;
  galleryLoaded: Ref<boolean>;
  loadError: Ref<string>;
  focusedIndex: Ref<number>;
  timelineCursorStart: Ref<number>;
  activeAlbum: Ref<number>;
  activePrivateAlbum: Ref<number>;
  activeFolderAlbum: Ref<{ path: string; name: string } | null>;
  favoritesOnly: Ref<boolean>;
  personalOnly: Ref<boolean>;
  onThisDayOnly: Ref<boolean>;
  typeFilter: Ref<"" | "photo" | "video">;
  searchInput: Ref<string>;
  searchApplied: Ref<string>;
  searchMode: Ref<PhotoSearchMode>;
  activePerson: Ref<{ id: number; name: string } | null>;
  selected: Ref<BatchAsset | null>;
  selectedIndex: Ref<number>;
  pendingFavorites: Ref<Record<number, boolean>>;
  message: Ref<string>;
  photosPage: Ref<HTMLElement | null>;
  loadMarker: Ref<HTMLElement | null>;
  photoQueryKey: () => string;
  beginListRequest: () => { signal: AbortSignal; isCurrent: () => boolean };
  getRootEpoch: () => number;
  getSelectionGeneration: () => number;
  bumpViewGeneration: () => void;
  bumpSelectionGeneration: () => void;
  isDisposed: () => boolean;
  api: <T = unknown>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  appendExifFilterParams: (query: URLSearchParams) => void;
  updateViewport: () => void;
  onScanCompleted: () => void;
}) {
  const loadErrorReset = ref(true);
  const scanActionError = ref("");
  const scanStatusLoading = ref(false);
  const scanStatusLoaded = ref(false);
  const scanStatusError = ref("");
  const scan = ref<PhotosScanStatus>({ running: false, scanned: 0, found: 0 });

  let pageQueryKey = photoQueryKey();
  let lastCompletedScan = 0;

  const scanStatusPoller = createMediaStatusPoller(
    (signal) => api<{ status: PhotosScanStatus; count: number }>(apiPath("/api/v2/photos/status"), "GET", undefined, signal),
    {
      onValue: (result) => {
        const previous = scan.value.lastDone;
        scan.value = result.status;
        scanStatusLoaded.value = true;
        scanStatusError.value = "";
        scanStatusLoading.value = false;
        if (!scan.value.running && scan.value.lastDone && scan.value.lastDone !== previous && scan.value.lastDone > lastCompletedScan) {
          lastCompletedScan = scan.value.lastDone;
          void load(true);
          onScanCompleted();
        }
      },
      onError: (error) => {
        scanStatusError.value = describeRootOperationFailure(error);
        scanStatusLoading.value = false;
      },
    },
  );

  function status() {
    scanStatusLoading.value = true;
    return scanStatusPoller.refresh();
  }

  async function load(reset = false) {
    if (loading.value && !reset) return;
    const transition = transitionMediaQuery(pageQueryKey, photoQueryKey());
    if (transition.clearContent) {
      pageQueryKey = transition.queryKey;
      assets.value = [];
      nextCursor.value = 0;
      galleryLoaded.value = false;
      focusedIndex.value = 0;
      timelineCursorStart.value = 0;
    }
    const request = beginListRequest();
    loading.value = true;
    loadError.value = "";
    if (reset) {
      focusedIndex.value = 0;
      timelineCursorStart.value = 0;
    }
    if (reset && !assets.value.length) {
      const cached = getMetadata<{ assets: BatchAsset[]; nextCursor: number }>("photos:list:" + photoQueryKey());
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
      appendAISearchParams(query, searchApplied.value, searchMode.value, activePerson.value?.id ?? 0);
      appendExifFilterParams(query);
      const result = await api<{ assets: BatchAsset[]; nextCursor: number }>(
        apiPath("/api/v2/photos") + "?" + query.toString(),
        "GET",
        undefined,
        request.signal,
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
            if (!isDisposed() && !loading.value && marker && marker.getBoundingClientRect().top < window.innerHeight + 650) {
              void load(false);
            }
          });
        }
      }
    }
  }

  function retryLoad() {
    void load(loadErrorReset.value);
  }

  async function startScan() {
    const context = getRootEpoch();
    scanActionError.value = "";
    try {
      await api(apiPath("/api/v2/photos/scan"), "POST");
      if (context !== getRootEpoch()) return;
      message.value = "正在后台扫描授权的共享目录";
      scanStatusPoller.invalidate();
      await status();
    } catch (e) {
      if (context === getRootEpoch()) scanActionError.value = "无法启动扫描：" + describeUserFacingError(e);
    }
  }

  async function toggleFavorite(asset: BatchAsset) {
    if (!props.admin && asset.canWrite !== true) return;
    if (pendingFavorites.value[asset.id]) return;
    pendingFavorites.value[asset.id] = true;
    const next = !asset.favorite;
    const selection = getSelectionGeneration();
    try {
      await api(apiPath("/api/v2/photos/" + asset.id + "/favorite"), "POST", { favorite: next });
      const current = assets.value.find((item) => item.id === asset.id);
      if (current) current.favorite = next;
      if (selected.value?.id === asset.id) selected.value.favorite = next;
    } catch (e) {
      if (selection === getSelectionGeneration() && selected.value?.id === asset.id) {
        message.value = "收藏失败：" + describeUserFacingError(e);
      }
    } finally {
      delete pendingFavorites.value[asset.id];
    }
  }

  function changeView(album: number, favorites: boolean, mine = false, privateID = 0) {
    if (
      activeAlbum.value === album &&
      favoritesOnly.value === favorites &&
      personalOnly.value === mine &&
      activePrivateAlbum.value === privateID &&
      !onThisDayOnly.value &&
      !activeFolderAlbum.value
    ) {
      return;
    }
    bumpViewGeneration();
    activeAlbum.value = album;
    favoritesOnly.value = favorites;
    personalOnly.value = mine;
    activePrivateAlbum.value = privateID;
    activeFolderAlbum.value = null;
    onThisDayOnly.value = false;
    activePerson.value = null;
    searchInput.value = "";
    searchApplied.value = "";
    selected.value = null;
    selectedIndex.value = -1;
    focusedIndex.value = 0;
    bumpSelectionGeneration();
    void load(true);
    requestAnimationFrame(() => {
      const root = photosPage.value;
      if (root) window.scrollTo({ top: Math.max(0, root.getBoundingClientRect().top + window.scrollY - 100), behavior: "auto" });
    });
  }

  function showOnThisDay() {
    if (onThisDayOnly.value) return;
    bumpViewGeneration();
    activeAlbum.value = 0;
    favoritesOnly.value = false;
    personalOnly.value = false;
    activePrivateAlbum.value = 0;
    activeFolderAlbum.value = null;
    onThisDayOnly.value = true;
    searchInput.value = "";
    searchApplied.value = "";
    selected.value = null;
    selectedIndex.value = -1;
    focusedIndex.value = 0;
    bumpSelectionGeneration();
    void load(true);
    window.scrollTo({ top: 0, behavior: "auto" });
  }

  function resetCatalogForRootChange() {
    scanStatusPoller.invalidate();
    pageQueryKey = photoQueryKey();
    loadError.value = "";
    loadErrorReset.value = true;
    scanActionError.value = "";
    scanStatusLoaded.value = false;
    scanStatusLoading.value = false;
    scanStatusError.value = "";
    scan.value = { running: false, scanned: 0, found: 0 };
    lastCompletedScan = 0;
  }

  function disposeCatalogLoader() {
    scanStatusPoller.dispose();
  }

  return {
    scanActionError,
    scanStatusLoading,
    scanStatusLoaded,
    scanStatusError,
    scan,
    status,
    load,
    retryLoad,
    startScan,
    toggleFavorite,
    changeView,
    showOnThisDay,
    resetCatalogForRootChange,
    disposeCatalogLoader,
  };
}
