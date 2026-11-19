import { computed, nextTick, onUnmounted, ref, watch, type Ref } from "vue";
import { pushModalLayer, type ModalLayerHandle } from "../modalStack.ts";
import { usePhotoViewer } from "../usePhotoViewer.ts";
import type { BatchAsset } from "../usePhotoBatchActions.ts";
import type { SharedFileEntry } from "../useFileShares.ts";

export function useFileMediaLightbox(options: {
  active: () => boolean;
  isAdmin: () => boolean;
  selected: Ref<BatchAsset | null>;
  assets: Ref<BatchAsset[]>;
  selectedIndex: Ref<number>;
  showAt: (index: number) => boolean;
  close: () => void;
  scopedMediaPath: (path: string) => string;
  fileEntryForMediaAsset: (asset: BatchAsset | null) => SharedFileEntry | null;
  downloadFile: (entry: SharedFileEntry) => Promise<void> | void;
}) {
  function originalUrl(asset: BatchAsset): string {
    return options.scopedMediaPath(
      "/api/v2/files/preview?path=" + encodeURIComponent(asset.path),
    );
  }

  function thumbUrl(asset: BatchAsset): string {
    return options.scopedMediaPath(
      "/api/v2/files/thumbnail?path=" + encodeURIComponent(asset.path) + "&size=512",
    );
  }

  const viewer = usePhotoViewer({
    selected: options.selected,
    mediaPath: options.scopedMediaPath,
    original: originalUrl,
    thumb: thumbUrl,
    move: (direction) => options.showAt(options.selectedIndex.value + direction),
  });

  const dialogRef = ref<HTMLElement | null>(null);
  const closeButtonRef = ref<HTMLButtonElement | null>(null);
  let layer: ModalLayerHandle | null = null;

  function onKeydown(event: KeyboardEvent) {
    if (!options.selected.value) return;
    if (event.key === "ArrowLeft" && options.selectedIndex.value > 0) {
      event.preventDefault();
      options.showAt(options.selectedIndex.value - 1);
    } else if (
      event.key === "ArrowRight" &&
      options.selectedIndex.value + 1 < options.assets.value.length
    ) {
      event.preventDefault();
      options.showAt(options.selectedIndex.value + 1);
    }
  }

  watch(options.selected, (asset) => {
    if (asset) {
      viewer.startViewerStages(asset);
      layer?.dispose();
      layer = pushModalLayer({ onEsc: () => options.close(), lockScroll: true });
      window.addEventListener("keydown", onKeydown);
      void nextTick(() => dialogRef.value?.focus());
    } else {
      viewer.cancelViewerLoads();
      layer?.dispose();
      layer = null;
      window.removeEventListener("keydown", onKeydown);
    }
  });

  onUnmounted(() => {
    layer?.dispose();
    layer = null;
    window.removeEventListener("keydown", onKeydown);
  });

  function downloadSelected() {
    const entry = options.fileEntryForMediaAsset(options.selected.value);
    if (entry) void options.downloadFile(entry);
  }

  const modalProps = computed(() => {
    const current = options.selected.value;
    return {
      selected: current,
      active: options.active(),
      selectedIndex: options.selectedIndex.value,
      modalAssets: options.assets.value,
      viewerInfo: false,
      albumOrganizerOpen: false,
      admin: options.isAdmin(),
      canWrite: false,
      pendingFavorite: false,
      trashBusy: false,
      slideshow: false,
      viewerAIDetail: null,
      viewerAILoading: false,
      viewerSrc: current ? viewer.viewerSrc(current) : "",
      viewerStage: viewer.viewerStage.value,
      viewerPreviewLoading: viewer.viewerPreviewLoading.value,
      viewerPreviewError: viewer.viewerPreviewError.value,
      viewerOriginalLoading: viewer.viewerOriginalLoading.value,
      viewerOriginalError: viewer.viewerOriginalError.value,
      viewerScale: viewer.viewerScale.value,
      viewerTransform: viewer.viewerTransform.value,
      viewerAnimate: viewer.viewerAnimate.value,
      viewerPointersSize: viewer.viewerPointers.size,
      browserDecodable: current ? viewer.browserDecodable(current) : false,
      mediaPath: options.scopedMediaPath,
      originalUrl: current ? originalUrl(current) : "",
      thumbFor: thumbUrl,
      folderAlbums: [],
      folderAlbumOptions: [],
      folderTarget: "",
      albums: [],
      albumOptions: [],
      addAlbum: 0,
      activeAlbum: 0,
      sharedAlbumsError: "",
      sharedAlbumsLoading: false,
      privateAlbums: [],
      privateAlbumOptions: [],
      addPrivateAlbum: 0,
      activePrivateAlbum: 0,
      privateAlbumsError: "",
      privateAlbumsLoading: false,
      albumBusy: false,
      message: "",
      fileBrowserMode: true,
      setDialogRef: (el: HTMLElement | null) => { dialogRef.value = el; },
      setCloseButtonRef: (el: HTMLButtonElement | null) => { closeButtonRef.value = el; },
    };
  });

  const modalEvents = {
    close: () => options.close(),
    download: downloadSelected,
    "show-at": (index: number) => options.showAt(index),
    "toggle-zoom": () => viewer.toggleViewerZoom(),
    "request-original": () => viewer.requestViewerOriginal(),
    "pointer-down": (event: PointerEvent) => viewer.viewerPointerDown(event),
    "pointer-move": (event: PointerEvent) => viewer.viewerPointerMove(event),
    "pointer-up": (event: PointerEvent) => viewer.viewerPointerUp(event),
    wheel: (event: WheelEvent) => viewer.viewerWheel(event),
  };

  return { modalProps, modalEvents };
}
