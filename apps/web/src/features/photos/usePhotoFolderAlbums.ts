import { computed, ref, type Ref } from "vue";
import { validateAlbumName } from "./albumNameValidation.ts";
import { createLatestRequestGate } from "../../api/latestRequestGate.ts";
import { describeRootOperationFailure } from "../../api/rootDiscovery.ts";
import { albumError } from "./photoPresentation.ts";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import type { FolderAlbum, ShareTarget } from "./usePhotoFilterAndSharing.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";

export function usePhotoFolderAlbums<TAsset extends BatchAsset>(options: {
  selected: Ref<TAsset | null>;
  selectedIndex: Ref<number>;
  focusedIndex: Ref<number>;
  activeAlbum: Ref<number>;
  activePrivateAlbum: Ref<number>;
  favoritesOnly: Ref<boolean>;
  personalOnly: Ref<boolean>;
  onThisDayOnly: Ref<boolean>;
  searchInput: Ref<string>;
  searchApplied: Ref<string>;
  viewMode: Ref<"timeline" | "albums" | "people" | "cleanup" | "map">;
  shareTargets: Ref<ShareTarget[]>;
  albumBusy: Ref<boolean>;
  message: Ref<string>;
  getRootEpoch: () => number;
  getViewGeneration: () => number;
  bumpViewGeneration: () => number;
  getSelectionGeneration: () => number;
  bumpSelectionGeneration: () => number;
  isDisposed: () => boolean;
  canWriteAsset: (asset: TAsset) => boolean;
  api: <T>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  load: (reset?: boolean) => Promise<void>;
  closeModal: (restoreFocus?: boolean) => void;
  changeView: (album: number, favorites: boolean, mine?: boolean, privateID?: number) => void;
}) {
  const folderAlbums = ref<FolderAlbum[]>([]);
  const folderCursor = ref("");
  const folderError = ref("");
  const folderLoading = ref(false);
  const folderName = ref("");
  const folderTarget = ref("");
  const activeFolderAlbum = ref<FolderAlbum | null>(null);
  const folderCovers = ref<Record<string, number>>({});
  const folderCoverStatus = ref<Record<string, "idle" | "loading" | "done" | "empty" | "error">>({});
  const folderAlbumRequests = createLatestRequestGate();
  const maxConcurrentCovers = 4;
  let coverAbort = new AbortController();
  let coverQueue: string[] = [];
  const coverInFlight = new Set<string>();

  function cancelCoverQueue() {
    coverAbort.abort();
    coverAbort = new AbortController();
    coverQueue = [];
    coverInFlight.clear();
  }

  function pumpCoverQueue() {
    while (coverInFlight.size < maxConcurrentCovers && coverQueue.length > 0 && !options.isDisposed()) {
      const albumPath = coverQueue.shift()!;
      const existing = folderCoverStatus.value[albumPath];
      if (existing === "loading" || existing === "done" || existing === "empty") continue;
      const epoch = options.getRootEpoch();
      const controller = coverAbort;
      coverInFlight.add(albumPath);
      folderCoverStatus.value = { ...folderCoverStatus.value, [albumPath]: "loading" };
      void (async () => {
        try {
          const query = new URLSearchParams({ limit: "1", cursor: "0", directory: albumPath });
          const res = await options.api<{ assets?: Array<{ id: number }> }>(
            options.apiPath("/api/v2/photos") + "?" + query.toString(),
            "GET",
            undefined,
            controller.signal,
          );
          if (options.isDisposed() || epoch !== options.getRootEpoch() || controller.signal.aborted) return;
          const coverId = res.assets?.[0]?.id ?? 0;
          if (coverId > 0) {
            folderCovers.value = { ...folderCovers.value, [albumPath]: coverId };
            folderCoverStatus.value = { ...folderCoverStatus.value, [albumPath]: "done" };
          } else {
            const nextCovers = { ...folderCovers.value };
            delete nextCovers[albumPath];
            folderCovers.value = nextCovers;
            folderCoverStatus.value = { ...folderCoverStatus.value, [albumPath]: "empty" };
          }
        } catch (err) {
          if (options.isDisposed() || epoch !== options.getRootEpoch() || controller.signal.aborted) return;
          if (!(err instanceof Error && err.name === "AbortError")) {
            folderCoverStatus.value = { ...folderCoverStatus.value, [albumPath]: "error" };
          }
        } finally {
          coverInFlight.delete(albumPath);
          pumpCoverQueue();
        }
      })();
    }
  }

  function requestFolderCover(albumPath: string) {
    if (!albumPath || options.isDisposed()) return;
    const status = folderCoverStatus.value[albumPath];
    if (status === "loading" || status === "done" || status === "empty") return;
    if (coverInFlight.has(albumPath) || coverQueue.includes(albumPath)) return;
    coverQueue.push(albumPath);
    pumpCoverQueue();
  }

  const folderAlbumOptions = computed(() => [
    { value: "", label: "选择文件夹相册…" },
    ...folderAlbums.value
      .filter((album) => album.canWrite !== false)
      .map((album) => ({
        value: album.path,
        label: album.shared ? `${album.name} (@${album.ownerUsername})` : album.name,
      })),
  ]);

  async function refreshFolderAlbums(more = false) {
    if (folderLoading.value) return;
    const request = folderAlbumRequests.begin();
    folderLoading.value = true;
    folderError.value = "";
    try {
      const query = new URLSearchParams();
      if (more && folderCursor.value) query.set("cursor", folderCursor.value);
      const result = await options.api<{ albums: FolderAlbum[]; shareTargets?: ShareTarget[]; nextCursor: string }>(
        options.apiPath("/api/v2/photos/folder-albums") + (query.size ? "?" + query : ""),
        "GET",
        undefined,
        request.signal,
      );
      if (!options.isDisposed() && request.isCurrent()) {
        folderAlbums.value = more ? [...folderAlbums.value, ...result.albums] : result.albums;
        if (!more && Array.isArray(result.shareTargets)) options.shareTargets.value = result.shareTargets;
        folderCursor.value = result.nextCursor;
        if (!more) {
          cancelCoverQueue();
          const validPaths = new Set(result.albums.map((item) => item.path));
          const prunedCovers: Record<string, number> = {};
          for (const [path, id] of Object.entries(folderCovers.value)) {
            if (validPaths.has(path)) prunedCovers[path] = id;
          }
          folderCovers.value = prunedCovers;
          folderCoverStatus.value = {};
        }
      }
    } catch (error) {
      if (!options.isDisposed() && request.isCurrent() && !(error instanceof Error && error.name === "AbortError")) {
        folderError.value = describeRootOperationFailure(error);
      }
    } finally {
      if (request.isCurrent()) folderLoading.value = false;
    }
  }

  async function createFolderAlbum() {
    if (options.albumBusy.value) return;
    const validation = validateAlbumName(folderName.value);
    if (!validation.valid || /[\/\\]/.test(validation.name)) {
      options.message.value = "相册名称需为 1–60 个字符，不能包含斜杠或控制字符。";
      return;
    }
    const root = options.getRootEpoch();
    const name = validation.name;
    options.albumBusy.value = true;
    options.message.value = "";
    try {
      await options.api(options.apiPath("/api/v2/photos/folder-albums"), "POST", { name });
      if (root !== options.getRootEpoch()) return;
      folderName.value = "";
      await refreshFolderAlbums();
      options.message.value = "已在照片目录中新建文件夹相册。";
    } catch (error) {
      if (root === options.getRootEpoch()) options.message.value = "创建文件夹相册失败：" + albumError(error);
    } finally {
      options.albumBusy.value = false;
    }
  }

  async function deleteFolderAlbum(album: FolderAlbum) {
    if (
      options.albumBusy.value ||
      !(await requestConfirm({
        title: "删除空相册文件夹",
        message: `删除空相册“${album.name}”？含有照片或其他文件的相册不能删除。`,
        confirmText: "删除文件夹",
        variant: "danger",
      }))
    )
      return;
    const root = options.getRootEpoch();
    options.albumBusy.value = true;
    options.message.value = "";
    try {
      await options.api(options.apiPath("/api/v2/photos/folder-albums/") + encodeURIComponent(album.name), "DELETE");
      if (root !== options.getRootEpoch()) return;
      if (activeFolderAlbum.value?.path === album.path) options.changeView(0, false);
      await refreshFolderAlbums();
      options.message.value = "空相册文件夹已删除。";
    } catch (error) {
      if (root === options.getRootEpoch()) options.message.value = "删除相册失败：" + describeRootOperationFailure(error);
    } finally {
      options.albumBusy.value = false;
    }
  }

  function openFolderAlbum(album: FolderAlbum) {
    options.bumpViewGeneration();
    options.bumpSelectionGeneration();
    activeFolderAlbum.value = album;
    options.activeAlbum.value = 0;
    options.activePrivateAlbum.value = 0;
    options.favoritesOnly.value = false;
    options.personalOnly.value = false;
    options.onThisDayOnly.value = false;
    options.searchInput.value = "";
    options.searchApplied.value = "";
    options.selected.value = null;
    options.selectedIndex.value = -1;
    options.focusedIndex.value = 0;
    options.viewMode.value = "timeline";
    void options.load(true);
  }

  async function addSelectedToFolder(action: "copy" | "move") {
    const asset = options.selected.value;
    const destination = folderAlbums.value.find((item) => item.path === folderTarget.value);
    if (!asset || !destination || options.albumBusy.value) return;
    if (action === "move" && !options.canWriteAsset(asset)) {
      options.message.value = "没有移动原文件的权限，可以选择复制。";
      return;
    }
    const root = options.getRootEpoch();
    const view = options.getViewGeneration();
    const selection = options.getSelectionGeneration();
    const from = asset.path;
    const to = destination.path + "/" + asset.name;
    if (from === to) {
      options.message.value = "照片已经在这个相册中。";
      return;
    }
    if (
      action === "move" &&
      !(await requestConfirm({
        title: "移动照片到文件夹相册",
        message: `将“${asset.name}”移动到“${destination.name}”？原位置将不再保留该文件。`,
        confirmText: "确认移动",
      }))
    )
      return;
    if (
      root !== options.getRootEpoch() ||
      view !== options.getViewGeneration() ||
      selection !== options.getSelectionGeneration() ||
      options.selected.value?.id !== asset.id
    ) {
      return;
    }
    options.albumBusy.value = true;
    options.message.value = "";
    try {
      await options.api(options.apiPath("/api/v2/files/operations"), "POST", { action, from, to, conflict: "" });
      if (root !== options.getRootEpoch()) return;
      if (action === "move") options.closeModal(false);
      await options.load(true);
      if (root === options.getRootEpoch()) {
        options.message.value = action === "copy" ? "照片已复制到相册，图库正在更新。" : "照片已移动到相册，图库正在更新。";
      }
    } catch (error) {
      if (root === options.getRootEpoch()) {
        options.message.value = (action === "copy" ? "复制" : "移动") + "到相册失败：" + describeRootOperationFailure(error);
      }
    } finally {
      options.albumBusy.value = false;
    }
  }

  function cancelFolderAlbumRequests() {
    folderAlbumRequests.cancel();
    cancelCoverQueue();
  }

  function resetFolderAlbumsForRootChange() {
    folderAlbumRequests.cancel();
    cancelCoverQueue();
    folderAlbums.value = [];
    folderCursor.value = "";
    folderError.value = "";
    folderLoading.value = false;
    folderTarget.value = "";
    activeFolderAlbum.value = null;
    folderCovers.value = {};
    folderCoverStatus.value = {};
  }

  return {
    folderAlbums,
    folderCursor,
    folderError,
    folderLoading,
    folderName,
    folderTarget,
    activeFolderAlbum,
    folderCovers,
    folderCoverStatus,
    folderAlbumOptions,
    refreshFolderAlbums,
    requestFolderCover,
    createFolderAlbum,
    deleteFolderAlbum,
    openFolderAlbum,
    addSelectedToFolder,
    cancelFolderAlbumRequests,
    resetFolderAlbumsForRootChange,
  };
}
