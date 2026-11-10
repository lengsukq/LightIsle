import { ref, watch, type Ref } from "vue";
import { describeRootOperationFailure } from "./rootDiscovery.js";
import { describeUserFacingError } from "./userFacingError.js";
import { trashMediaOriginals } from "./mediaTrash.js";
import { requestConfirm } from "./useConfirmDialog";
import {
  photoArchivePath,
  photoShareUrl,
  preparePhotoArchive,
  runPhotoBatch,
  type PhotoBatchItem,
  type PhotoBatchResult,
} from "./photoBatchOperations.js";
import type { FolderAlbum } from "./usePhotoFilterAndSharing";

export type BatchAsset = {
  id: number;
  path: string;
  name: string;
  type: "photo" | "video";
  size: number;
  takenAt: number;
  favorite: boolean;
  personalFavorite?: boolean;
  canWrite?: boolean;
  capturedAt?: string;
  latitude?: number;
  longitude?: number;
  cameraMake?: string;
  cameraModel?: string;
  lensModel?: string;
  iso?: number;
  fNumber?: number;
  exposureSeconds?: number;
  focalLength?: number;
  width?: number;
  height?: number;
  durationSeconds?: number;
};

export function usePhotoBatchActions<TAsset extends BatchAsset>(options: {
  assets: Ref<TAsset[]>;
  selected: Ref<TAsset | null>;
  folderAlbums: Ref<FolderAlbum[]>;
  privateAlbums: Ref<Array<{ id: number; name: string; count: number }>>;
  message: Ref<string>;
  photoQueryKey: () => string;
  getRootEpoch: () => number;
  getViewGeneration: () => number;
  isDisposed: () => boolean;
  getRootId: () => string | undefined;
  getRootGeneration: () => number;
  canWriteAsset: (asset: TAsset) => boolean;
  api: <T>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  mediaPath: (path: string) => string;
  closeModal: (restoreFocus?: boolean) => void;
  load: (reset?: boolean) => Promise<void>;
  refreshPrivateAlbums: (isCurrent?: () => boolean) => Promise<void>;
}) {
  const trashSelecting = ref(false);
  const trashBusy = ref(false);
  const trashIDs = ref<Set<number>>(new Set());
  const batchFolderTarget = ref("");
  const batchPrivateAlbum = ref(0);
  const batchShareLinks = ref<Array<{ name: string; url: string }>>([]);
  const batchShareNotice = ref("");
  const previousRootShareWarning = ref("");
  let shareBatchInFlight = false;
  let folderBatchInFlight = false;

  watch(
    options.photoQueryKey,
    () => {
      trashIDs.value = new Set();
      trashSelecting.value = false;
      batchFolderTarget.value = "";
      batchPrivateAlbum.value = 0;
    },
    { flush: "sync" },
  );

  function toggleTrashID(id: number) {
    if (trashBusy.value) return;
    const next = new Set(trashIDs.value);
    if (next.has(id)) next.delete(id);
    else if (next.size < 50) next.add(id);
    trashIDs.value = next;
  }

  async function trashPhotos(items: TAsset[]) {
    if (trashBusy.value || !items.length) return;
    if (items.length > 50 || items.some((item) => !options.canWriteAsset(item))) {
      options.message.value = "每次最多删除50项，且必须拥有对应原文件的写入权限。";
      return;
    }
    const root = options.getRootEpoch();
    const view = options.getViewGeneration();
    const selectedIDs = items.map((item) => item.id);
    const paths = items.map((item) => item.path);
    if (
      !(await requestConfirm({
        title: "移入回收站",
        message: `将这 ${items.length} 项照片/视频原文件移入回收站？之后可在文件管理中恢复。`,
        confirmText: "移入回收站",
        variant: "danger",
      }))
    )
      return;
    const current = () =>
      !options.isDisposed() &&
      root === options.getRootEpoch() &&
      view === options.getViewGeneration() &&
      selectedIDs.every((id, i) => options.assets.value.some((item) => item.id === id && item.path === paths[i]));
    if (!current()) {
      options.message.value = "媒体列表或存储目录已变化，请重新选择。";
      return;
    }
    trashBusy.value = true;
    try {
      const result = await trashMediaOriginals(
        paths,
        (batch) =>
          options.api<{ results: Array<{ path?: string; success: boolean; error?: string }> }>(
            options.apiPath("/api/v2/files/batch"),
            "POST",
            { action: "trash", paths: batch },
          ),
        current,
      );
      if (result.cancelled) {
        options.message.value = "原硬盘或列表已变化，请返回原目录检查回收站。";
        return;
      }
      if (options.selected.value && selectedIDs.includes(options.selected.value.id)) options.closeModal(false);
      trashIDs.value = new Set();
      trashSelecting.value = false;
      options.message.value =
        `已确认移入回收站 ${result.completed}/${items.length} 项。` +
        (result.needsRootCheck
          ? "硬盘连接发生变化，部分操作的结果不确定。请重新连接原硬盘，检查原目录和回收站后再重试。"
          : result.failed.length
            ? "其余项目请检查权限或文件状态。"
            : "");
      await options.load(true);
    } catch (error) {
      if (root === options.getRootEpoch()) {
        options.message.value = "未能确认移入回收站的结果：" + describeRootOperationFailure(error);
      }
    } finally {
      trashBusy.value = false;
    }
  }

  function trashSelectedPhotos() {
    const items = options.assets.value.filter((item) => trashIDs.value.has(item.id));
    if (items.length !== trashIDs.value.size) {
      options.message.value = "选择的媒体已变化，请重新选择。";
      return;
    }
    void trashPhotos(items);
  }

  function selectedBatchItems(): TAsset[] | null {
    const items = options.assets.value.filter((item) => trashIDs.value.has(item.id));
    if (!items.length || items.length !== trashIDs.value.size) {
      options.message.value = "选择的媒体已变化，请重新选择。";
      return null;
    }
    return items;
  }

  function sameSelection(ids: number[]) {
    return trashIDs.value.size === ids.length && ids.every((id) => trashIDs.value.has(id));
  }

  function photoBatchMessage(result: PhotoBatchResult, total: number, verb: string, already = 0) {
    let text = `${verb}：已确认处理 ${result.completed.length}/${total} 项。`;
    if (already) text += `其中 ${already} 项已在目标相册中。`;
    if (result.stopped) return text + "存储目录或当前视图发生变化，后续操作已停止；请在原硬盘核对后再试。";
    if (result.failure) {
      const failure = result.failure.error as { status?: number; code?: string } | null;
      const uncertain =
        !failure || typeof failure.status !== "number" || failure.status >= 500 || failure.code === "storage_accounting_uncertain";
      text += `“${result.failure.item.name}”${uncertain ? "的结果无法确认，请先检查目标相册和原目录" : "未处理：" + describeRootOperationFailure(result.failure.error)}。`;
      if (result.remaining.length) text += `另有 ${result.remaining.length} 项尚未处理。`;
    }
    return text;
  }

  async function batchToFolder(action: "copy" | "move") {
    if (trashBusy.value) return;
    const items = selectedBatchItems();
    const destination = options.folderAlbums.value.find((album) => album.path === batchFolderTarget.value);
    if (!items || !destination) {
      if (items) options.message.value = "请先选择目标文件夹相册。";
      return;
    }
    if (action === "move" && items.some((item) => !options.canWriteAsset(item))) {
      options.message.value = "部分原文件没有移动权限，可选择复制或调整选择。";
      return;
    }
    const root = options.getRootEpoch();
    const query = options.photoQueryKey();
    const ids = items.map((item) => item.id);
    const target = destination.path;
    if (
      action === "move" &&
      !(await requestConfirm({
        title: "批量移动到相册文件夹",
        message: `将选中的 ${items.length} 项移动到“${destination.name}”？原位置将不再保留已移动的文件。`,
        confirmText: "确认移动",
      }))
    )
      return;
    const current = () =>
      !options.isDisposed() &&
      root === options.getRootEpoch() &&
      options.photoQueryKey() === query &&
      sameSelection(ids) &&
      batchFolderTarget.value === target;
    if (!current()) {
      options.message.value = "选择或存储目录已变化，请重新选择。";
      return;
    }
    trashBusy.value = true;
    folderBatchInFlight = true;
    options.message.value = "";
    let already = 0;
    try {
      const result = await runPhotoBatch(
        items,
        async (item: PhotoBatchItem) => {
          const to = target + "/" + item.name;
          if (item.path === to) {
            already++;
            return;
          }
          const reply = await options.api<{ done: boolean; finalTo: string; skipped: boolean }>(
            options.apiPath("/api/v2/files/operations"),
            "POST",
            { action, from: item.path, to, conflict: "rename" },
          );
          if (reply.done !== true || typeof reply.finalTo !== "string" || !reply.finalTo || reply.skipped) {
            throw new Error("operation_result_uncertain");
          }
        },
        current,
      );
      if (root !== options.getRootEpoch()) {
        if (!options.isDisposed()) window.dispatchEvent(new Event("lightisle-photo-batch-outcome-uncertain"));
        return;
      }
      if (!current()) {
        options.message.value = photoBatchMessage(result, items.length, action === "copy" ? "复制到相册" : "移动到相册", already);
        return;
      }
      trashIDs.value = new Set([
        ...result.remaining.map((item) => item.id),
        ...(result.failure ? [result.failure.item.id] : []),
      ]);
      if (!trashIDs.value.size) trashSelecting.value = false;
      options.message.value = photoBatchMessage(result, items.length, action === "copy" ? "复制到相册" : "移动到相册", already);
      if (action === "move" && !result.failure && !result.stopped) await options.load(true);
    } catch (error) {
      if (root === options.getRootEpoch()) options.message.value = "无法完成批量操作：" + describeRootOperationFailure(error);
    } finally {
      folderBatchInFlight = false;
      if (root === options.getRootEpoch()) trashBusy.value = false;
    }
  }

  async function batchToPrivateAlbum() {
    if (trashBusy.value) return;
    const items = selectedBatchItems();
    const album = options.privateAlbums.value.find((item) => item.id === batchPrivateAlbum.value);
    if (!items || !album) {
      if (items) options.message.value = "请先选择要加入的私人相册。";
      return;
    }
    const root = options.getRootEpoch();
    const query = options.photoQueryKey();
    const ids = items.map((item) => item.id);
    const albumID = album.id;
    const current = () =>
      !options.isDisposed() &&
      root === options.getRootEpoch() &&
      options.photoQueryKey() === query &&
      sameSelection(ids) &&
      batchPrivateAlbum.value === albumID;
    if (!current()) return;
    trashBusy.value = true;
    options.message.value = "";
    try {
      const result = await runPhotoBatch(
        items,
        async (item: PhotoBatchItem) => {
          const reply = await options.api<{ added: boolean }>(
            options.apiPath(`/api/v2/photos/private-albums/${albumID}/items`),
            "POST",
            { assetId: item.id },
          );
          if (reply.added !== true) throw new Error("operation_result_uncertain");
        },
        current,
      );
      if (root !== options.getRootEpoch()) return;
      if (!current()) {
        options.message.value = photoBatchMessage(result, items.length, "加入私人相册");
        return;
      }
      trashIDs.value = new Set([
        ...result.remaining.map((item) => item.id),
        ...(result.failure ? [result.failure.item.id] : []),
      ]);
      if (!trashIDs.value.size) trashSelecting.value = false;
      options.message.value = photoBatchMessage(result, items.length, "加入私人相册");
      await options.refreshPrivateAlbums(() => root === options.getRootEpoch());
    } catch (error) {
      if (root === options.getRootEpoch()) options.message.value = "无法加入私人相册：" + describeRootOperationFailure(error);
    } finally {
      if (root === options.getRootEpoch()) trashBusy.value = false;
    }
  }

  async function batchShare() {
    if (trashBusy.value) return;
    const items = selectedBatchItems();
    if (!items) return;
    if (items.length > 10) {
      options.message.value = "每次最多创建 10 条分享链接，请减少选择。";
      return;
    }
    const oversized = items.find((item) => item.size > 2 * 1024 * 1024 * 1024);
    if (oversized) {
      options.message.value = `“${oversized.name}”超过 2 GiB，当前不能创建分享链接。`;
      return;
    }
    const root = options.getRootEpoch();
    const rootID = options.getRootId();
    const rootGeneration = options.getRootGeneration();
    const query = options.photoQueryKey();
    const ids = items.map((item) => item.id);
    if (
      !(await requestConfirm({
        title: "创建批量分享链接",
        message: `为选中的 ${items.length} 个文件分别创建 24 小时有效的公开下载链接？获得链接的人无需登录即可下载。`,
        confirmText: "创建链接",
      }))
    )
      return;
    const current = () =>
      !options.isDisposed() &&
      root === options.getRootEpoch() &&
      options.photoQueryKey() === query &&
      sameSelection(ids);
    if (!current()) {
      options.message.value = "选择或存储目录已变化，请重新选择。";
      return;
    }
    trashBusy.value = true;
    shareBatchInFlight = true;
    options.message.value = "";
    batchShareNotice.value = "";
    const links: Array<{ name: string; url: string }> = [...batchShareLinks.value];
    try {
      const result = await runPhotoBatch(
        items,
        async (item: PhotoBatchItem) => {
          const reply = await options.api<{ token: string }>(options.apiPath("/api/v2/file-shares"), "POST", {
            path: item.path,
            hours: 24,
            password: "",
            maxDownloads: 0,
          });
          links.push({ name: item.name, url: photoShareUrl(window.location.origin, rootID, rootGeneration, reply.token) });
        },
        current,
      );
      if (root !== options.getRootEpoch()) {
        if (!options.isDisposed() && (result.completed.length || result.failure)) {
          previousRootShareWarning.value =
            "切换硬盘前的分享请求可能已创建链接。请回到原硬盘的文件管理分享列表，检查并撤销不需要的链接。";
        }
        return;
      }
      batchShareLinks.value = links;
      if (!current()) {
        options.message.value = "已停止后续分享；已创建的链接请妥善保存，也可在文件管理的分享列表中撤销。";
        return;
      }
      trashIDs.value = new Set([
        ...result.remaining.map((item) => item.id),
        ...(result.failure ? [result.failure.item.id] : []),
      ]);
      if (!trashIDs.value.size) trashSelecting.value = false;
      options.message.value =
        photoBatchMessage(result, items.length, "创建分享链接") +
        (result.failure ? " 未确认的链接可在文件管理的分享列表中检查或撤销。" : "");
    } catch (error) {
      if (root === options.getRootEpoch()) {
        batchShareLinks.value = links;
        options.message.value = "创建分享链接时中断，请检查文件管理的分享列表：" + describeRootOperationFailure(error);
      }
    } finally {
      shareBatchInFlight = false;
      if (root === options.getRootEpoch()) trashBusy.value = false;
    }
  }

  async function batchDownload() {
    if (trashBusy.value) return;
    const items = selectedBatchItems();
    if (!items) return;
    const root = options.getRootEpoch();
    const query = options.photoQueryKey();
    const ids = items.map((item) => item.id);
    const current = () =>
      !options.isDisposed() &&
      root === options.getRootEpoch() &&
      options.photoQueryKey() === query &&
      sameSelection(ids);
    trashBusy.value = true;
    options.message.value = "正在检查原文件和下载权限…";
    try {
      const url = options.mediaPath(photoArchivePath(ids));
      const result = await preparePhotoArchive(
        url,
        current,
        (path) => fetch(path, { method: "HEAD", credentials: "same-origin", cache: "no-store" }),
        (path) => {
          const link = document.createElement("a");
          link.href = path;
          link.download = "LightIsle-photos.zip";
          link.rel = "noopener";
          document.body.appendChild(link);
          link.click();
          link.remove();
        },
      );
      if (result.stopped) return;
      if (!result.started) {
        const reason: Record<number, string> = {
          401: "登录状态已失效，请重新登录。",
          403: "当前账号没有读取这些文件的权限。",
          404: "部分照片已不存在或无权访问，请刷新图库后重新选择。",
          409: "存储目录或原文件已发生变化，请刷新图库和硬盘列表后重试。",
          413: "所选原文件合计超过 2 GiB，请减少选择后分批下载。",
          429: "当前打包下载较多，请稍后重试。",
          503: "图库或原硬盘暂不可用，请检查连接。",
        };
        options.message.value = "无法准备批量下载：" + (reason[result.status ?? 0] ?? "请刷新图库并检查网络后重试。");
        return;
      }
      options.message.value = "已开始打包下载；ZIP 内文件名前会加序号以区分同名文件，请在浏览器下载列表中确认保存完成。";
    } catch (error) {
      if (root === options.getRootEpoch() && current()) {
        options.message.value = "无法准备批量下载：" + describeUserFacingError(error);
      }
    } finally {
      if (root === options.getRootEpoch()) trashBusy.value = false;
    }
  }

  async function copyBatchShareLinks() {
    const root = options.getRootEpoch();
    const links = batchShareLinks.value.map((item) => `${item.name}：${item.url}`).join("\n");
    try {
      await navigator.clipboard.writeText(links);
      if (root === options.getRootEpoch()) batchShareNotice.value = "链接已复制。";
    } catch {
      if (root === options.getRootEpoch()) batchShareNotice.value = "无法自动复制，请手动选择并复制下方链接。";
    }
  }

  function resetBatchForRootChange() {
    if (batchShareLinks.value.length && batchShareNotice.value !== "链接已复制。") {
      previousRootShareWarning.value = "原硬盘已有未确认保存的分享链接。请在文件管理分享列表中检查并撤销不需要的链接。";
    }
    trashIDs.value = new Set();
    trashSelecting.value = false;
    trashBusy.value = false;
    batchFolderTarget.value = "";
    batchPrivateAlbum.value = 0;
    batchShareLinks.value = [];
    batchShareNotice.value = "";
  }

  function notifyBatchOnUnmount() {
    if (shareBatchInFlight || (batchShareLinks.value.length && batchShareNotice.value !== "链接已复制。")) {
      window.dispatchEvent(new Event("lightisle-share-outcome-uncertain"));
    }
    if (folderBatchInFlight) {
      window.dispatchEvent(new Event("lightisle-photo-batch-outcome-uncertain"));
    }
  }

  return {
    trashSelecting,
    trashBusy,
    trashIDs,
    batchFolderTarget,
    batchPrivateAlbum,
    batchShareLinks,
    batchShareNotice,
    previousRootShareWarning,
    toggleTrashID,
    trashPhotos,
    trashSelectedPhotos,
    batchToFolder,
    batchToPrivateAlbum,
    batchShare,
    batchDownload,
    copyBatchShareLinks,
    resetBatchForRootChange,
    notifyBatchOnUnmount,
  };
}
