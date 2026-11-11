import { computed, nextTick, ref, type Ref } from "vue";
import { validateAlbumName } from "./albumNameValidation.ts";
import { createLatestRequestGate } from "./latestRequestGate.ts";
import { albumError } from "./photoPresentation.ts";
import { requestConfirm } from "./useConfirmDialog.ts";
import type { ShareTarget } from "./usePhotoFilterAndSharing.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";
import { usePhotoFolderAlbums } from "./usePhotoFolderAlbums.ts";

export type PhotoAlbum = {
  id: number;
  name: string;
  count: number;
  coverAssetId?: number;
};

export function usePhotoAlbums<TAsset extends BatchAsset>(options: {
  isAdmin: () => boolean;
  assets: Ref<TAsset[]>;
  selected: Ref<TAsset | null>;
  selectedIndex: Ref<number>;
  focusedIndex: Ref<number>;
  favoritesOnly: Ref<boolean>;
  personalOnly: Ref<boolean>;
  onThisDayOnly: Ref<boolean>;
  searchInput: Ref<string>;
  searchApplied: Ref<string>;
  viewMode: Ref<"timeline" | "albums" | "people" | "cleanup" | "map">;
  photosPage: Ref<HTMLElement | null>;
  shareTargets: Ref<ShareTarget[]>;
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
  focusTile: (index: number) => Promise<void>;
  changeView: (album: number, favorites: boolean, mine?: boolean, privateID?: number) => void;
}) {
  const albums = ref<PhotoAlbum[]>([]);
  const privateAlbums = ref<PhotoAlbum[]>([]);
  const activeAlbum = ref(0);
  const activePrivateAlbum = ref(0);
  const sharedAlbumsError = ref("");
  const privateAlbumsError = ref("");
  const sharedAlbumsLoading = ref(false);
  const privateAlbumsLoading = ref(false);
  const creating = ref(false);
  const albumName = ref("");
  const addAlbum = ref(0);
  const addPrivateAlbum = ref(0);
  const creatingPrivate = ref(false);
  const editingPrivate = ref<PhotoAlbum | null>(null);
  const privateAlbumName = ref("");
  const albumBusy = ref(false);
  const creationReturnsToAlbums = ref(false);
  const failedAlbumCovers = ref<Record<string, boolean>>({});
  const editingAlbum = ref<PhotoAlbum | null>(null);

  const albumRequests = createLatestRequestGate();
  const privateAlbumRequests = createLatestRequestGate();

  const {
    folderAlbums, folderCursor, folderError, folderLoading, folderName,
    folderTarget, activeFolderAlbum, folderAlbumOptions, refreshFolderAlbums,
    createFolderAlbum, deleteFolderAlbum, openFolderAlbum, addSelectedToFolder,
    cancelFolderAlbumRequests, resetFolderAlbumsForRootChange,
  } = usePhotoFolderAlbums({
    ...options,
    activeAlbum,
    activePrivateAlbum,
    albumBusy,
  });

  const albumOptions = computed(() => [
    { value: 0, label: "选择一个相册…" },
    ...albums.value.map((album) => ({ value: album.id, label: album.name, hint: `${album.count} 张` })),
  ]);
  const privateAlbumOptions = computed(() => [
    { value: 0, label: "选择要加入的相册…" },
    ...privateAlbums.value.map((album) => ({ value: album.id, label: album.name, hint: `${album.count} 张` })),
  ]);
  const currentPrivateAlbum = computed(() =>
    privateAlbums.value.find((item) => item.id === activePrivateAlbum.value),
  );
  const currentAlbum = computed(() =>
    albums.value.find((album) => album.id === activeAlbum.value),
  );

  async function refreshAlbums() {
    const request = albumRequests.begin();
    sharedAlbumsLoading.value = true;
    try {
      const result = await options.api<{ albums: PhotoAlbum[] }>(
        options.apiPath("/api/v2/photos/albums"),
        "GET",
        undefined,
        request.signal,
      );
      if (!options.isDisposed() && request.isCurrent()) {
        albums.value = result.albums;
        sharedAlbumsError.value = "";
      }
    } catch (error) {
      if (!options.isDisposed() && request.isCurrent() && !(error instanceof Error && error.name === "AbortError")) {
        sharedAlbumsError.value = albumError(error);
      }
    } finally {
      if (!options.isDisposed() && request.isCurrent()) sharedAlbumsLoading.value = false;
    }
  }

  async function refreshPrivateAlbums(isCurrent: () => boolean = () => true) {
    const request = privateAlbumRequests.begin();
    privateAlbumsLoading.value = true;
    try {
      const result = await options.api<{ albums: PhotoAlbum[] }>(
        options.apiPath("/api/v2/photos/private-albums"),
        "GET",
        undefined,
        request.signal,
      );
      if (!options.isDisposed() && request.isCurrent()) {
        privateAlbums.value = result.albums;
        privateAlbumsError.value = "";
      }
    } catch (e) {
      if (request.isCurrent() && !options.isDisposed() && isCurrent() && !(e instanceof Error && e.name === "AbortError")) {
        privateAlbumsError.value = albumError(e);
      }
    } finally {
      if (!options.isDisposed() && request.isCurrent()) privateAlbumsLoading.value = false;
    }
  }

  function editPrivateAlbum(album: PhotoAlbum) {
    editingPrivate.value = album;
    privateAlbumName.value = album.name;
    creatingPrivate.value = true;
  }

  function cancelPrivateAlbum() {
    creatingPrivate.value = false;
    editingPrivate.value = null;
    privateAlbumName.value = "";
    if (creationReturnsToAlbums.value) {
      options.viewMode.value = "albums";
      creationReturnsToAlbums.value = false;
    }
  }

  async function savePrivateAlbum() {
    if (albumBusy.value) return;
    const validation = validateAlbumName(privateAlbumName.value);
    if (!validation.valid) {
      options.message.value = "私人相册名称需为 1–60 个字符，不能包含控制字符。";
      return;
    }
    const view = options.getViewGeneration();
    const editingID = editingPrivate.value?.id ?? 0;
    const formIsCurrent = () =>
      view === options.getViewGeneration() &&
      creatingPrivate.value &&
      (editingPrivate.value?.id ?? 0) === editingID &&
      privateAlbumName.value.trim() === validation.name;
    albumBusy.value = true;
    options.message.value = "";
    try {
      if (editingPrivate.value) {
        await options.api(options.apiPath("/api/v2/photos/private-albums/" + editingPrivate.value.id), "PATCH", {
          name: validation.name,
        });
      } else {
        await options.api(options.apiPath("/api/v2/photos/private-albums"), "POST", { name: validation.name });
      }
      await refreshPrivateAlbums(formIsCurrent);
      if (formIsCurrent()) {
        cancelPrivateAlbum();
        options.message.value = "私人相册已保存，其他账号不可查看。";
      }
    } catch (e) {
      if (formIsCurrent()) options.message.value = "私人相册保存失败：" + albumError(e);
    } finally {
      albumBusy.value = false;
    }
  }

  async function deletePrivateAlbum() {
    const album = currentPrivateAlbum.value;
    if (
      !album ||
      albumBusy.value ||
      !(await requestConfirm({
        title: "删除私人相册",
        message: "仅删除你的私人相册「" + album.name + "」及其中的关联记录，原始照片不会被删除。确认吗？",
        confirmText: "删除相册",
        variant: "danger",
      }))
    ) {
      return;
    }
    const albumID = album.id;
    const wasCurrent = activePrivateAlbum.value === album.id;
    const view = options.getViewGeneration();
    albumBusy.value = true;
    try {
      await options.api(options.apiPath("/api/v2/photos/private-albums/" + albumID), "DELETE");
      const sameView = view === options.getViewGeneration();
      if (wasCurrent && activePrivateAlbum.value === albumID) options.changeView(0, false);
      await refreshPrivateAlbums(() => view === options.getViewGeneration());
      if (sameView) options.message.value = "私人相册已删除，原始文件及共享相册不受影响。";
    } catch (e) {
      if (view === options.getViewGeneration()) options.message.value = "删除私人相册失败：" + albumError(e);
    } finally {
      albumBusy.value = false;
    }
  }

  async function addSelectedPrivate() {
    if (!options.selected.value || !addPrivateAlbum.value || albumBusy.value) return;
    const assetID = options.selected.value.id;
    const albumID = addPrivateAlbum.value;
    const selection = options.getSelectionGeneration();
    const view = options.getViewGeneration();
    albumBusy.value = true;
    options.message.value = "";
    try {
      await options.api(options.apiPath("/api/v2/photos/private-albums/" + albumID + "/items"), "POST", { assetId: assetID });
      await refreshPrivateAlbums(
        () =>
          selection === options.getSelectionGeneration() &&
          view === options.getViewGeneration() &&
          options.selected.value?.id === assetID,
      );
      if (
        selection === options.getSelectionGeneration() &&
        view === options.getViewGeneration() &&
        options.selected.value?.id === assetID &&
        addPrivateAlbum.value === albumID
      ) {
        options.message.value = "已加入我的私人相册";
      }
    } catch (e) {
      if (
        selection === options.getSelectionGeneration() &&
        view === options.getViewGeneration() &&
        options.selected.value?.id === assetID
      ) {
        options.message.value = "加入私人相册失败：" + albumError(e);
      }
    } finally {
      albumBusy.value = false;
    }
  }

  async function removeSelectedPrivate() {
    if (!options.selected.value || !activePrivateAlbum.value || albumBusy.value) return;
    const assetID = options.selected.value.id;
    const albumID = activePrivateAlbum.value;
    const removedIndex = options.selectedIndex.value;
    const selection = options.getSelectionGeneration();
    const view = options.getViewGeneration();
    albumBusy.value = true;
    try {
      await options.api(options.apiPath("/api/v2/photos/private-albums/" + albumID + "/items/" + assetID), "DELETE");
      const shouldClose = activePrivateAlbum.value === albumID && options.selected.value?.id === assetID;
      const retainedSelection = shouldClose ? 0 : (options.selected.value?.id ?? 0);
      if (shouldClose) options.closeModal(false);
      if (activePrivateAlbum.value === albumID) {
        await options.load(true);
        if (retainedSelection && activePrivateAlbum.value === albumID) {
          const index = options.assets.value.findIndex((item) => item.id === retainedSelection);
          if (index >= 0) options.selectedIndex.value = index;
        }
      }
      await refreshPrivateAlbums(() => view === options.getViewGeneration() && activePrivateAlbum.value === albumID);
      if (view === options.getViewGeneration() && activePrivateAlbum.value === albumID) {
        if (shouldClose) {
          if (options.assets.value.length) await options.focusTile(Math.min(removedIndex, options.assets.value.length - 1));
          else {
            await nextTick();
            options.photosPage.value?.querySelector<HTMLButtonElement>(`[data-private-album-filter="${albumID}"]`)?.focus();
          }
        }
        options.message.value = "照片已从私人相册移出，原文件不受影响。";
      }
    } catch (e) {
      if (
        selection === options.getSelectionGeneration() &&
        view === options.getViewGeneration() &&
        options.selected.value?.id === assetID
      ) {
        options.message.value = "移出私人相册失败：" + albumError(e);
      }
    } finally {
      albumBusy.value = false;
    }
  }

  function beginAlbumRename(album: PhotoAlbum) {
    if (!options.isAdmin()) return;
    editingAlbum.value = album;
    albumName.value = album.name;
    creating.value = true;
    options.message.value = "";
  }

  function cancelAlbumForm() {
    creating.value = false;
    editingAlbum.value = null;
    albumName.value = "";
    if (creationReturnsToAlbums.value) {
      options.viewMode.value = "albums";
      creationReturnsToAlbums.value = false;
    }
  }

  async function createAlbum() {
    if (!options.isAdmin()) return;
    const validation = validateAlbumName(albumName.value);
    const name = validation.name;
    if (!validation.valid) {
      options.message.value =
        validation.reason === "empty" ? "请输入相册名称。" : "相册名称需为 1–60 个字符，且不能包含控制字符。";
      return;
    }
    albumBusy.value = true;
    options.message.value = "";
    try {
      if (editingAlbum.value) {
        const album = await options.api<PhotoAlbum>(options.apiPath("/api/v2/photos/albums/" + editingAlbum.value.id), "PATCH", {
          name,
        });
        albums.value = albums.value.map((item) => (item.id === album.id ? album : item));
        options.message.value = "相册名称已更新。";
      } else {
        await options.api(options.apiPath("/api/v2/photos/albums"), "POST", { name });
        options.message.value = "相册已创建。";
      }
      albumName.value = "";
      creating.value = false;
      editingAlbum.value = null;
      await refreshAlbums();
      if (creationReturnsToAlbums.value) {
        options.viewMode.value = "albums";
        creationReturnsToAlbums.value = false;
      }
    } catch (e) {
      const failure = (editingAlbum.value ? "修改相册失败：" : "创建相册失败：") + albumError(e);
      if (e instanceof Error && e.message === "not_found" && editingAlbum.value) {
        const id = editingAlbum.value.id;
        await refreshAlbums();
        if (!albums.value.some((album) => album.id === id)) {
          activeAlbum.value = 0;
          options.favoritesOnly.value = false;
          cancelAlbumForm();
          await options.load(true);
        }
      }
      options.message.value = failure;
    } finally {
      albumBusy.value = false;
    }
  }

  async function deleteCurrentAlbum() {
    const album = currentAlbum.value;
    if (!options.isAdmin() || !album || albumBusy.value) return;
    const confirmed = await requestConfirm({
      title: "删除共享相册",
      message: `仅删除「${album.name}」相册及其照片关系；原始照片和视频仍保留，也不会删除收藏。确定删除吗？`,
      confirmText: "删除相册",
      variant: "danger",
    });
    if (!confirmed) return;
    const albumID = album.id;
    const view = options.getViewGeneration();
    albumBusy.value = true;
    options.message.value = "";
    try {
      await options.api(options.apiPath("/api/v2/photos/albums/" + albumID), "DELETE");
      albums.value = albums.value.filter((item) => item.id !== albumID);
      if (activeAlbum.value === albumID) {
        activeAlbum.value = 0;
        options.favoritesOnly.value = false;
        options.selected.value = null;
        options.selectedIndex.value = -1;
        options.bumpSelectionGeneration();
        cancelAlbumForm();
        await options.load(true);
      }
      await refreshAlbums();
      if (view === options.getViewGeneration()) options.message.value = "相册已删除，照片和视频原件仍保留。";
    } catch (e) {
      if (view === options.getViewGeneration()) options.message.value = albumError(e);
      if (e instanceof Error && e.message === "not_found") {
        await refreshAlbums();
        if (activeAlbum.value === albumID && !albums.value.some((item) => item.id === albumID)) {
          activeAlbum.value = 0;
          options.favoritesOnly.value = false;
          await options.load(true);
          if (view === options.getViewGeneration()) options.message.value = "相册已不存在，图库已刷新。";
        }
      }
    } finally {
      albumBusy.value = false;
    }
  }

  async function addSelected() {
    if (!options.isAdmin() || !options.selected.value || !addAlbum.value || albumBusy.value) return;
    const assetID = options.selected.value.id;
    const albumID = addAlbum.value;
    const selection = options.getSelectionGeneration();
    const view = options.getViewGeneration();
    albumBusy.value = true;
    try {
      await options.api(options.apiPath("/api/v2/photos/albums/" + albumID + "/items"), "POST", { assetId: assetID });
      await refreshAlbums();
      if (
        selection === options.getSelectionGeneration() &&
        view === options.getViewGeneration() &&
        options.selected.value?.id === assetID &&
        addAlbum.value === albumID
      ) {
        options.message.value = "已加入相册";
      }
    } catch (e) {
      if (
        selection === options.getSelectionGeneration() &&
        view === options.getViewGeneration() &&
        options.selected.value?.id === assetID
      ) {
        options.message.value = "加入相册失败：" + (e instanceof Error ? e.message : "未知错误");
      }
    } finally {
      albumBusy.value = false;
    }
  }

  async function removeSelectedFromAlbum() {
    if (!options.isAdmin() || !options.selected.value || !activeAlbum.value || albumBusy.value) return;
    const albumId = activeAlbum.value;
    const assetId = options.selected.value.id;
    const removedIndex = options.selectedIndex.value;
    const selection = options.getSelectionGeneration();
    const view = options.getViewGeneration();
    albumBusy.value = true;
    options.message.value = "";
    try {
      await options.api(options.apiPath(`/api/v2/photos/albums/${albumId}/items/${assetId}`), "DELETE");
      const shouldClose = activeAlbum.value === albumId && options.selected.value?.id === assetId;
      const retainedSelection = shouldClose ? 0 : (options.selected.value?.id ?? 0);
      if (shouldClose) options.closeModal(false);
      await refreshAlbums();
      if (activeAlbum.value === albumId) {
        await options.load(true);
        if (retainedSelection) {
          const index = options.assets.value.findIndex((item) => item.id === retainedSelection);
          if (index >= 0) options.selectedIndex.value = index;
        }
        if (view === options.getViewGeneration()) {
          if (shouldClose && options.assets.value.length) {
            await options.focusTile(Math.min(removedIndex, options.assets.value.length - 1));
          }
          options.message.value = "已从相册移出，原始文件仍保留。";
        }
      }
    } catch (e) {
      if (
        view === options.getViewGeneration() &&
        selection === options.getSelectionGeneration() &&
        options.selected.value?.id === assetId &&
        e instanceof Error &&
        e.message === "not_found"
      ) {
        await refreshAlbums();
        await options.load(true);
        options.message.value = "这张照片已不在当前相册，列表已刷新。原始文件仍保留。";
      } else if (
        view === options.getViewGeneration() &&
        selection === options.getSelectionGeneration() &&
        options.selected.value?.id === assetId
      ) {
        options.message.value = "移出相册失败：" + albumError(e);
      }
    } finally {
      albumBusy.value = false;
    }
  }

  function openAlbumFromOverview(album: PhotoAlbum, personal: boolean) {
    options.viewMode.value = "timeline";
    options.changeView(personal ? 0 : album.id, false, false, personal ? album.id : 0);
  }

  function cancelAlbumRequests() {
    albumRequests.cancel();
    privateAlbumRequests.cancel();
    cancelFolderAlbumRequests();
  }

  function resetAlbumsForRootChange() {
    albumRequests.cancel();
    privateAlbumRequests.cancel();
    resetFolderAlbumsForRootChange();
    albums.value = [];
    privateAlbums.value = [];
    activeAlbum.value = 0;
    activePrivateAlbum.value = 0;
    creationReturnsToAlbums.value = false;
    failedAlbumCovers.value = {};
    sharedAlbumsError.value = "";
    privateAlbumsError.value = "";
    sharedAlbumsLoading.value = false;
    privateAlbumsLoading.value = false;
    creating.value = false;
    creatingPrivate.value = false;
    editingAlbum.value = null;
    editingPrivate.value = null;
  }

  return {
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
  };
}
