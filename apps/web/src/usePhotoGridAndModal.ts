import { computed, nextTick, ref, watch, type ComputedRef, type Ref } from "vue";
import { createBrowserMediaBackstack } from "./browserMediaBackstack.js";
import { createPhotoTimelineLayout, getPhotoTimelineWindow } from "./photoTimelineLayout.js";
import type { MapStripAsset, MapTransport } from "./photoMapTransport.js";
import { usePhotoSlideshow } from "./usePhotoSlideshow";
import type { BatchAsset } from "./usePhotoBatchActions";

export function usePhotoGridAndModal<TAsset extends BatchAsset>(options: {
  assets: Ref<TAsset[]>;
  selected: Ref<TAsset | null>;
  selectedIndex: Ref<number>;
  focusedIndex: Ref<number>;
  nextCursor: Ref<number>;
  loading: Ref<boolean>;
  loadError: Ref<string>;
  viewMode: Ref<"timeline" | "albums" | "map">;
  addAlbum: Ref<number>;
  addPrivateAlbum: Ref<number>;
  message: Ref<string>;
  viewerAnimate: Ref<boolean>;
  viewerScale: Ref<number>;
  viewerOffset: Ref<{ x: number; y: number }>;
  bumpSelectionGeneration: () => number;
  startViewerStages: (asset: TAsset) => void;
  cancelViewerLoads: () => void;
  api: <T>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  mediaPath: (path: string) => string;
  load: (reset?: boolean) => Promise<void>;
}) {
  const gridElement = ref<HTMLElement | null>(null);
  const loadMarker = ref<HTMLElement | null>(null);
  const galleryDialog = ref<HTMLElement | null>(null);
  const modalCloseButton = ref<HTMLButtonElement | null>(null);
  const containerWidth = ref(0);
  const viewportTop = ref(0);
  const viewportHeight = ref(0);
  const scrubberInView = ref(false);
  const viewerInfo = ref(false);
  const compactGrid = ref(false);
  const exifFilterOpen = ref(false);
  const photoMap = ref<{ focusAsset: (latitude: number, longitude: number) => void } | null>(null);
  const mapSelection = ref<TAsset[]>([]) as Ref<TAsset[]>;
  const modalAssets: ComputedRef<TAsset[]> = computed(() =>
    options.viewMode.value === "map" ? mapSelection.value : options.assets.value,
  );

  function toggleCompactGrid() {
    compactGrid.value = !compactGrid.value;
    updateViewport();
  }

  let viewportFrame = 0;
  let resizeObserver: ResizeObserver | undefined;
  let loadObserver: IntersectionObserver | undefined;
  let viewerBackstack: ReturnType<typeof createBrowserMediaBackstack> | null = null;
  let restoreTileFocus = true;

  const timelineLayout = computed(() =>
    createPhotoTimelineLayout(
      options.assets.value.map((asset) => asset.takenAt),
      containerWidth.value,
      { compact: compactGrid.value },
    ),
  );
  const virtualWindow = computed(() =>
    getPhotoTimelineWindow(timelineLayout.value, viewportTop.value, viewportHeight.value),
  );
  const visibleAssets = computed(() =>
    options.assets.value.slice(virtualWindow.value.startIndex, virtualWindow.value.endIndex),
  );
  const visibleHeaders = computed(() => virtualWindow.value.headers);

  const mapTransport: MapTransport = {
    loadGeo: () =>
      options.api<{
        points: { id: number; lat: number; lon: number; takenAt: number; type: string }[];
        total: number;
        truncated: boolean;
      }>(options.apiPath("/api/v2/photos/geo")),
    loadMapStatus: () => options.api<{ tiandituConfigured: boolean }>("/api/v2/map/status"),
    loadAssetsByIds: async (ids) => {
      if (!ids.length) return [];
      const query = new URLSearchParams({
        limit: String(Math.min(120, Math.max(1, ids.length))),
        cursor: "0",
        ids: ids.join(","),
      });
      const result = await options.api<{ assets: TAsset[] }>(
        options.apiPath("/api/v2/photos") + "?" + query.toString(),
      );
      return result.assets;
    },
    thumbnail: (id) => options.mediaPath("/api/v2/photos/" + id + "/thumbnail"),
  };

  function selectModalAsset(asset: TAsset, index: number) {
    options.bumpSelectionGeneration();
    options.selected.value = asset;
    options.selectedIndex.value = index;
    options.addAlbum.value = 0;
    options.addPrivateAlbum.value = 0;
    options.message.value = "";
  }

  function showAssetAt(index: number) {
    const asset = modalAssets.value[index];
    if (!asset) return;
    selectModalAsset(asset, index);
    options.viewerAnimate.value = true;
    options.viewerScale.value = 1;
    options.viewerOffset.value = { x: 0, y: 0 };
    options.startViewerStages(asset);
  }

  const { slideshow, stopSlideshow, toggleSlideshow } = usePhotoSlideshow({
    selected: options.selected,
    selectedIndex: options.selectedIndex,
    modalAssets,
    showAssetAt,
  });

  function openMapAsset(item: MapStripAsset, group: MapStripAsset[]) {
    stopSlideshow();
    mapSelection.value = group.map((asset) => ({ ...(asset as unknown as TAsset) }));
    const index = mapSelection.value.findIndex((asset) => asset.id === item.id);
    showAssetAt(index >= 0 ? index : 0);
    void nextTick(() => modalCloseButton.value?.focus());
  }

  async function showOnMap(latitude: number, longitude: number) {
    closeModal(false);
    options.viewMode.value = "map";
    await nextTick();
    photoMap.value?.focusAsset(latitude, longitude);
  }

  function tileStyle(index: number) {
    const position = timelineLayout.value.positions[index];
    return {
      left: `${position.left}px`,
      top: `${position.top}px`,
      width: `${timelineLayout.value.tileSize}px`,
      height: `${timelineLayout.value.tileSize}px`,
    };
  }

  function measureViewport() {
    const element = gridElement.value;
    if (!element) {
      scrubberInView.value = false;
      return;
    }
    containerWidth.value = element.clientWidth;
    viewportTop.value = Math.max(0, -element.getBoundingClientRect().top);
    viewportHeight.value = window.innerHeight;
    const rect = element.getBoundingClientRect();
    scrubberInView.value = rect.top < window.innerHeight - 90 && rect.bottom > 150;
  }

  function updateViewport() {
    if (viewportFrame) cancelAnimationFrame(viewportFrame);
    viewportFrame = requestAnimationFrame(() => {
      measureViewport();
    });
  }

  async function focusTile(index: number) {
    if (index < 0) return;
    if (index >= options.assets.value.length && options.nextCursor.value && !options.loading.value) {
      await options.load(false);
    }
    const safeIndex = Math.min(index, options.assets.value.length - 1);
    if (safeIndex < 0) return;
    options.focusedIndex.value = safeIndex;
    const grid = gridElement.value;
    if (grid) {
      const targetTop =
        grid.getBoundingClientRect().top + window.scrollY + timelineLayout.value.positions[safeIndex].top;
      if (
        targetTop < window.scrollY ||
        targetTop + timelineLayout.value.tileSize > window.scrollY + window.innerHeight
      ) {
        window.scrollTo({ top: Math.max(0, targetTop - window.innerHeight / 3), behavior: "auto" });
      }
    }
    measureViewport();
    await nextTick();
    gridElement.value?.querySelector<HTMLButtonElement>(`[data-photo-index="${safeIndex}"]`)?.focus();
  }

  function onTileKeydown(event: KeyboardEvent, index: number) {
    const columns = timelineLayout.value.columns;
    let next = index;
    if (event.key === "ArrowRight") next = index + 1;
    else if (event.key === "ArrowLeft") next = index - 1;
    else if (event.key === "ArrowDown") next = index + columns;
    else if (event.key === "ArrowUp") next = index - columns;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = options.assets.value.length - 1;
    else if (event.key === "PageDown") {
      next = Math.min(
        options.assets.value.length - 1,
        index + columns * Math.max(1, Math.floor(window.innerHeight / timelineLayout.value.rowPitch)),
      );
    } else if (event.key === "PageUp") {
      next = Math.max(
        0,
        index - columns * Math.max(1, Math.floor(window.innerHeight / timelineLayout.value.rowPitch)),
      );
    } else return;
    event.preventDefault();
    void focusTile(next);
  }

  function openAsset(asset: TAsset, index: number) {
    if (!options.selected.value) viewerBackstack?.push();
    showAssetAt(index);
    void nextTick(() => modalCloseButton.value?.focus());
  }

  function finishCloseModal(restoreFocus = true) {
    const previousIndex = options.selectedIndex.value;
    stopSlideshow();
    options.cancelViewerLoads();
    options.bumpSelectionGeneration();
    viewerInfo.value = false;
    options.selected.value = null;
    options.selectedIndex.value = -1;
    if (restoreFocus && options.viewMode.value !== "map" && previousIndex >= 0) void focusTile(previousIndex);
  }

  function closeModal(restoreFocus = true) {
    restoreTileFocus = restoreFocus;
    if (options.selected.value && viewerBackstack?.back()) return;
    finishCloseModal(restoreFocus);
  }

  function modalKeydown(event: KeyboardEvent) {
    if (!options.selected.value) return;
    if (event.key === "Escape") {
      event.preventDefault();
      closeModal();
      return;
    }
    if (event.key === "Tab") {
      const dialog = galleryDialog.value;
      if (!dialog) return;
      const focusable = Array.from(
        dialog.querySelectorAll<HTMLElement>(
          'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),video[controls],[tabindex]:not([tabindex="-1"])',
        ),
      ).filter((element) => element.offsetWidth > 0 || element.offsetHeight > 0 || element === document.activeElement);
      if (!focusable.length) {
        event.preventDefault();
        dialog.focus();
        return;
      }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement;
      if (!focusable.includes(active as HTMLElement)) {
        event.preventDefault();
        (event.shiftKey ? last : first).focus();
        return;
      }
      if (event.shiftKey && active === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && active === last) {
        event.preventDefault();
        first.focus();
      }
      return;
    }
    if (event.target instanceof HTMLVideoElement) return;
    if (
      event.target instanceof HTMLInputElement ||
      event.target instanceof HTMLSelectElement ||
      event.target instanceof HTMLTextAreaElement
    ) {
      return;
    }
    if (event.key === "ArrowLeft" && options.selectedIndex.value > 0) {
      event.preventDefault();
      showAssetAt(options.selectedIndex.value - 1);
    }
    if (event.key === "ArrowRight" && options.selectedIndex.value + 1 < modalAssets.value.length) {
      event.preventDefault();
      showAssetAt(options.selectedIndex.value + 1);
    }
  }

  function mountGridAndModal() {
    viewerBackstack = createBrowserMediaBackstack(window, "lightisle-photos", async () => {
      finishCloseModal(restoreTileFocus);
      restoreTileFocus = true;
      return true;
    });
    viewportHeight.value = window.innerHeight;
    updateViewport();
    window.addEventListener("scroll", updateViewport, { passive: true });
    window.addEventListener("resize", updateViewport);
    window.addEventListener("keydown", modalKeydown);
    if (typeof ResizeObserver !== "undefined") {
      resizeObserver = new ResizeObserver(updateViewport);
      if (gridElement.value) resizeObserver.observe(gridElement.value);
    }
    if (typeof IntersectionObserver !== "undefined") {
      loadObserver = new IntersectionObserver(
        (entries) => {
          if (
            entries.some((entry) => entry.isIntersecting) &&
            options.nextCursor.value &&
            !options.loading.value &&
            !options.loadError.value
          ) {
            void options.load(false);
          }
        },
        { rootMargin: "650px 0px" },
      );
      if (loadMarker.value) loadObserver.observe(loadMarker.value);
    }
  }

  function unmountGridAndModal() {
    viewerBackstack?.dispose();
    viewerBackstack = null;
    stopSlideshow();
    if (viewportFrame) cancelAnimationFrame(viewportFrame);
    resizeObserver?.disconnect();
    loadObserver?.disconnect();
    window.removeEventListener("scroll", updateViewport);
    window.removeEventListener("resize", updateViewport);
    window.removeEventListener("keydown", modalKeydown);
  }

  function resetBackstackForRootChange() {
    viewerBackstack?.reset();
  }

  watch(loadMarker, (element) => {
    loadObserver?.disconnect();
    if (element) loadObserver?.observe(element);
  });

  watch(
    gridElement,
    (element) => {
      if (resizeObserver) {
        resizeObserver.disconnect();
        if (element) resizeObserver.observe(element);
      }
      updateViewport();
    },
    { flush: "post" },
  );

  return {
    gridElement,
    loadMarker,
    galleryDialog,
    modalCloseButton,
    scrubberInView,
    viewerInfo,
    compactGrid,
    exifFilterOpen,
    toggleCompactGrid,
    photoMap,
    modalAssets,
    timelineLayout,
    virtualWindow,
    visibleAssets,
    visibleHeaders,
    mapTransport,
    slideshow,
    toggleSlideshow,
    showAssetAt,
    openAsset,
    openMapAsset,
    showOnMap,
    tileStyle,
    updateViewport,
    measureViewport,
    focusTile,
    onTileKeydown,
    closeModal,
    mountGridAndModal,
    unmountGridAndModal,
    resetBackstackForRootChange,
  };
}
