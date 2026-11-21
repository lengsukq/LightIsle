import { computed, ref, watch, type Ref } from "vue";
import { createFileOperationsClient } from "./fileOperationsClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import type { ManagedAccount } from "../settings/useAccountManagement.ts";
import type { SharedFileEntry } from "./useFileShares.ts";
import type { BatchAsset } from "../photos/usePhotoBatchActions.ts";
import type { Movie } from "../cinema/cinemaTypes.ts";

export type FileGrant = { userId: number; path: string; canWrite: boolean };

export function useFileActionsAndGrants(options: {
  userRole: () => "admin" | "member" | undefined;
  selectedRootID: () => string;
  rootFeatureContextReady: () => boolean;
  rootContextEpoch: () => number;
  currentRootContextKey: () => string;
  filesPath: Ref<string>;
  sharedRootName: Ref<string>;
  currentFolderCanWrite: Ref<boolean>;
  fileDirectoryLoaded: Ref<boolean>;
  fileEntries: Ref<SharedFileEntry[]>;
  checkedFiles: Ref<string[]>;
  filesError: Ref<string>;
  showingTrash: Ref<boolean>;
  searchingFiles: Ref<boolean>;
  failedThumbnails: Ref<Set<string>>;
  scopedApiPath: (path: string) => string;
  scopedMediaPath: (path: string) => string;
  rootFetch: (endpoint: string, init?: RequestInit) => Promise<Response>;
  jsonGet: <T>(endpoint: string, signal?: AbortSignal) => Promise<T>;
  jsonWrite: <T>(endpoint: string, method: "POST" | "PATCH" | "PUT" | "DELETE", body?: object, signal?: AbortSignal) => Promise<T>;
  loadFiles: (path?: string) => Promise<unknown>;
  loadTrash: () => Promise<void>;
  isAbortError: (error: unknown) => boolean;
  onCinemaFilmMatched?: (film: Movie) => void;
}) {
  const grantUser = ref<ManagedAccount | null>(null);
  const grants = ref<FileGrant[]>([]);
  const grantError = ref("");
  const grantNotice = ref("");
  const grantPathInput = ref("");
  const grantCanWrite = ref(false);
  const grantBusy = ref(false);

  const fileOperationDialog = ref<{
    item: SharedFileEntry;
    action: "rename" | "move" | "copy";
    batchItems?: SharedFileEntry[];
  } | null>(null);
  const fileOperationNotice = ref("");
  const newFolderName = ref("");
  const trashTarget = ref<SharedFileEntry | null>(null);
  const fileActionBusy = ref(false);
  const previewItem = ref<SharedFileEntry | null>(null);
  const previewText = ref("");
  const previewError = ref("");
  const fileMediaAssets = ref<BatchAsset[]>([]);
  const fileMediaSelected = ref<BatchAsset | null>(null);
  const fileMediaEntriesByPath = new Map<string, SharedFileEntry>();

  function entryDirectory(path: string) {
    const normalized = path.replace(/\\/g, "/").trim().replace(/^\/+|\/+$/g, "");
    const slash = normalized.lastIndexOf("/");
    return slash < 0 ? "" : normalized.slice(0, slash);
  }

  function isPreviewVideo(item: SharedFileEntry | null) {
    return Boolean(item && item.type === "file" && /\.(mp4|webm|m4v|mov|mkv|avi|ts|mts|3gp|flv)$/i.test(item.name));
  }

  function isPreviewImage(item: SharedFileEntry | null) {
    return Boolean(item && item.type === "file" && /\.(jpe?g|png|gif|webp|heic|heif|bmp)$/i.test(item.name));
  }

  function toFileMediaAsset(entry: SharedFileEntry, syntheticId: number): BatchAsset {
    const numericModified = Number(entry.modified);
    const parsedTime = Number.isFinite(numericModified) && numericModified > 0
      ? numericModified
      : Math.floor((Date.parse(entry.modified) || 0) / 1000);
    return {
      id: syntheticId,
      path: entry.path,
      name: entry.name,
      type: isPreviewVideo(entry) ? "video" : "photo",
      size: entry.size,
      takenAt: parsedTime > 0 ? parsedTime : 0,
      favorite: false,
      canWrite: false,
    };
  }

  const fileMediaIndex = computed(() => {
    const current = fileMediaSelected.value;
    if (!current) return -1;
    return fileMediaAssets.value.findIndex((asset) => asset.path === current.path);
  });

  function showFileMediaAt(index: number): boolean {
    const target = fileMediaAssets.value[index];
    if (!target) return false;
    fileMediaSelected.value = target;
    return true;
  }

  function closeFileMedia() {
    fileMediaSelected.value = null;
    fileMediaAssets.value = [];
  }

  function fileEntryForMediaAsset(asset: BatchAsset | null): SharedFileEntry | null {
    if (!asset) return null;
    return fileMediaEntriesByPath.get(asset.path) ?? null;
  }

  function thumbnailKey(item: SharedFileEntry) {
    return item.path + "@" + item.modified;
  }

  function thumbnailEligible(item: SharedFileEntry) {
    return item.type === "file" && /\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v)$/i.test(item.name);
  }

  function fileThumbnailURL(item: SharedFileEntry, size = 512) {
    return options.scopedMediaPath("/api/v2/files/thumbnail?path=" + encodeURIComponent(item.path) + "&size=" + size);
  }

  function closeFileMenu(event: Event) {
    const menu = (event.target as HTMLElement)?.closest("details.file-entry-more");
    if (menu instanceof HTMLDetailsElement) menu.open = false;
  }

  function markThumbnailFailure(item: SharedFileEntry) {
    options.failedThumbnails.value = new Set([...options.failedThumbnails.value, thumbnailKey(item)]);
  }

  const pathSegments = computed(() => {
    const p = options.filesPath.value;
    if (p === ".") return [{ name: options.sharedRootName.value, path: "." }];
    const parts = p.split("/");
    return [
      { name: options.sharedRootName.value, path: "." },
      ...parts.map((name, index) => ({ name, path: parts.slice(0, index + 1).join("/") })),
    ];
  });

  function canWriteEntry(item: SharedFileEntry) {
    // A cached row can stay visible after a failed refresh, but its write
    // capability is not valid until this physical-root directory is confirmed.
    return options.fileDirectoryLoaded.value && (item.canWrite === true || options.userRole() === "admin");
  }

  function operateFile(item: SharedFileEntry, action: "rename" | "move" | "copy") {
    if ((action === "move" || action === "rename") && !canWriteEntry(item)) return;
    if (options.showingTrash.value) return;
    fileOperationNotice.value = "";
    fileOperationDialog.value = { item, action };
  }

  function operateBatchMove() {
    if (options.showingTrash.value || !selectedFilesAllWritable.value) return;
    const selectedEntries = options.checkedFiles.value
      .slice(0, 50)
      .map((path) => options.fileEntries.value.find((entry) => entry.path === path))
      .filter((entry): entry is SharedFileEntry => Boolean(entry));
    if (!selectedEntries.length) return;
    fileOperationNotice.value = "";
    fileOperationDialog.value = {
      item: selectedEntries[0],
      action: "move",
      batchItems: selectedEntries,
    };
  }

  const fileOperations = createFileOperationsClient({
    apiPath: options.scopedApiPath,
    get: options.jsonGet,
    write: options.jsonWrite,
    getEpoch: options.rootContextEpoch,
  });

  function listOperationFolders(path: string, cursor: string) {
    return fileOperations.listFolders<{ entries: SharedFileEntry[]; nextCursor: string; canWrite: boolean }>(
      path,
      cursor,
    );
  }

  async function commitFileOperation(target: string, conflict: "" | "skip" | "rename") {
    const dialog = fileOperationDialog.value;
    if (!dialog) throw new Error("操作已经取消");
    if (dialog.batchItems && dialog.batchItems.length > 1) {
      let moved = 0;
      let skipped = 0;
      let failed = 0;
      let lastError = "";
      for (const entry of dialog.batchItems) {
        const dest = target === "." ? entry.name : `${target}/${entry.name}`;
        if (dest === entry.path) {
          skipped += 1;
          continue;
        }
        try {
          const res = await fileOperations.commit<{ done: boolean; finalTo: string; skipped: boolean }>({
            action: "move",
            from: entry.path,
            to: dest,
            conflict,
          });
          if (res.skipped) skipped += 1;
          else moved += 1;
        } catch (err) {
          if (options.isAbortError(err)) throw err;
          failed += 1;
          lastError = describeUserFacingError(err);
        }
      }
      options.checkedFiles.value = [];
      if (failed > 0 && moved === 0 && skipped === 0) {
        throw new Error(lastError || "批量移动未能完成");
      }
      const parts = [`已移动 ${moved} 项`];
      if (skipped > 0) parts.push(`跳过 ${skipped} 项`);
      if (failed > 0) parts.push(`失败 ${failed} 项（${lastError}）`);
      return { summary: `批量移动结束：${parts.join("，")}。` };
    }
    return fileOperations.commit<{ done: boolean; finalTo: string; skipped: boolean }>({
      action: dialog.action === "rename" ? "move" : dialog.action,
      from: dialog.item.path,
      to: target,
      conflict,
    });
  }

  function finishFileOperation(message: string) {
    fileOperationDialog.value = null;
    fileOperationNotice.value = message;
    void options.loadFiles();
  }

  function grantEndpointForUser(userID: number) {
    const rootID = options.selectedRootID();
    return rootID
      ? `/api/v2/roots/${encodeURIComponent(rootID)}/users/${userID}/file-grants`
      : `/api/v2/users/${userID}/file-grants`;
  }

  async function editGrants(account: ManagedAccount) {
    if (!options.rootFeatureContextReady()) {
      grantError.value = "请先选择共享目录，再管理该目录的授权。";
      return;
    }
    grantUser.value = account;
    grantError.value = "";
    grantNotice.value = "";
    try {
      const endpoint = grantEndpointForUser(account.id);
      const data = await options.jsonGet<{ grants: FileGrant[] }>(endpoint);
      grants.value = data.grants;
    } catch (e) {
      if (!options.isAbortError(e)) grantError.value = "读取文件权限失败：" + describeUserFacingError(e);
    }
  }

  async function saveGrant() {
    const target = grantUser.value;
    if (!target || grantBusy.value) return;
    if (!options.rootFeatureContextReady()) {
      grantError.value = "请先选择共享目录，再管理该目录的授权。";
      return;
    }
    const normalizedPath = grantPathInput.value.trim().replace(/^\/+|\/+$/g, "") || ".";
    grantError.value = "";
    grantNotice.value = "";
    grantBusy.value = true;
    try {
      const endpoint = grantEndpointForUser(target.id);
      await options.jsonWrite(endpoint, "PUT", {
        path: normalizedPath,
        canWrite: grantCanWrite.value,
      });
      grantPathInput.value = "";
      grantCanWrite.value = false;
      grantNotice.value = `已保存「${normalizedPath}」的目录授权。`;
      const data = await options.jsonGet<{ grants: FileGrant[] }>(endpoint);
      grants.value = data.grants;
    } catch (e) {
      if (!options.isAbortError(e)) {
        grantError.value = "保存目录授权失败：" + describeUserFacingError(e);
      }
    } finally {
      grantBusy.value = false;
    }
  }

  async function toggleGrantWrite(grant: FileGrant) {
    const target = grantUser.value;
    if (!target || grantBusy.value) return;
    grantError.value = "";
    grantNotice.value = "";
    grantBusy.value = true;
    try {
      const endpoint = grantEndpointForUser(target.id);
      await options.jsonWrite(endpoint, "PUT", {
        path: grant.path,
        canWrite: !grant.canWrite,
      });
      grantNotice.value = `已更新「${grant.path}」为${!grant.canWrite ? "可读写" : "只读"}。`;
      const data = await options.jsonGet<{ grants: FileGrant[] }>(endpoint);
      grants.value = data.grants;
    } catch (e) {
      if (!options.isAbortError(e)) {
        grantError.value = "更新目录授权失败：" + describeUserFacingError(e);
      }
    } finally {
      grantBusy.value = false;
    }
  }

  async function removeGrant(path: string) {
    const target = grantUser.value;
    if (!target || grantBusy.value) return;
    grantError.value = "";
    grantNotice.value = "";
    grantBusy.value = true;
    try {
      const endpoint = grantEndpointForUser(target.id);
      const response = await options.rootFetch(
        `${endpoint}?path=${encodeURIComponent(path)}`,
        {
          method: "DELETE",
          credentials: "same-origin",
          headers: { "X-LightIsle-Request": "1" },
        },
      );
      if (!response.ok) throw await readApiFailure(response);
      grantNotice.value = `已移除「${path}」的目录授权。`;
      const data = await options.jsonGet<{ grants: FileGrant[] }>(endpoint);
      grants.value = data.grants;
    } catch (e) {
      if (!options.isAbortError(e)) {
        grantError.value = "移除目录授权失败：" + describeUserFacingError(e);
      }
    } finally {
      grantBusy.value = false;
    }
  }

  async function lookupCinemaFilm(path: string): Promise<Movie | null> {
    try {
      const response = await options.rootFetch(
        options.scopedApiPath("/api/v2/cinema/lookup") + "?path=" + encodeURIComponent(path),
        { credentials: "same-origin" },
      );
      if (!response.ok) return null;
      const film = (await response.json()) as Movie;
      return film && film.id > 0 ? film : null;
    } catch {
      return null;
    }
  }

  function openFileMediaViewer(item: SharedFileEntry) {
    const dir = entryDirectory(item.path);
    const siblings = options.fileEntries.value.filter(
      (entry) => (isPreviewImage(entry) || isPreviewVideo(entry)) && entryDirectory(entry.path) === dir,
    );
    if (!siblings.some((entry) => entry.path === item.path)) {
      siblings.push(item);
    }
    siblings.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
    fileMediaEntriesByPath.clear();
    const assets: BatchAsset[] = siblings.map((entry, idx) => {
      fileMediaEntriesByPath.set(entry.path, entry);
      return toFileMediaAsset(entry, -(idx + 1));
    });
    fileMediaAssets.value = assets;
    fileMediaSelected.value = assets.find((asset) => asset.path === item.path) ?? assets[0] ?? null;
    previewItem.value = null;
  }

  async function previewFile(item: SharedFileEntry) {
    const scopeEpoch = options.rootContextEpoch();
    if (isPreviewVideo(item) && options.onCinemaFilmMatched) {
      const cinemaFilm = await lookupCinemaFilm(item.path);
      if (scopeEpoch !== options.rootContextEpoch()) return;
      if (cinemaFilm) {
        previewItem.value = null;
        closeFileMedia();
        options.onCinemaFilmMatched(cinemaFilm);
        return;
      }
    }
    if (isPreviewImage(item) || isPreviewVideo(item)) {
      openFileMediaViewer(item);
      return;
    }
    closeFileMedia();
    previewItem.value = item;
    previewText.value = "";
    previewError.value = "";
    if (/\.(txt|md|json|log|ya?ml|toml|csv|xml|ini|conf|sh|py|ts|js|vue|go|swift|css|html)$/i.test(item.name)) {
      try {
        const response = await options.rootFetch(
          options.scopedApiPath("/api/v2/files/preview") + "?path=" + encodeURIComponent(item.path),
          { credentials: "same-origin" },
        );
        if (!response.ok) throw await readApiFailure(response);
        const text = await response.text();
        if (scopeEpoch === options.rootContextEpoch()) previewText.value = text;
      } catch (e) {
        if (scopeEpoch === options.rootContextEpoch() && !options.isAbortError(e)) {
          previewError.value = describeUserFacingError(e);
        }
      }
    }
  }

  const previewURL = computed(() => {
    const item = previewItem.value;
    if (!item) return "";
    if (/\.(heic|heif)$/i.test(item.name)) return fileThumbnailURL(item, 2048);
    return options.scopedMediaPath("/api/v2/files/preview?path=" + encodeURIComponent(item.path));
  });

  function goUp() {
    if (options.filesPath.value === ".") return;
    const p = options.filesPath.value.split("/");
    p.pop();
    void options.loadFiles(p.length ? p.join("/") : ".");
  }

  async function makeFolder(): Promise<boolean> {
    if (!options.currentFolderCanWrite.value || fileActionBusy.value) return false;
    const name = newFolderName.value.trim();
    if (!name) return false;
    const full = options.filesPath.value === "." ? name : options.filesPath.value + "/" + name;
    fileActionBusy.value = true;
    options.filesError.value = "";
    try {
      await options.jsonWrite(options.scopedApiPath("/api/v2/files/folders"), "POST", { path: full });
      newFolderName.value = "";
      await options.loadFiles();
      fileOperationNotice.value = "已新建文件夹「" + name + "」。";
      return true;
    } catch (e) {
      if (!options.isAbortError(e)) options.filesError.value = "新建文件夹失败：" + describeUserFacingError(e);
      return false;
    } finally {
      fileActionBusy.value = false;
    }
  }

  async function batchTrash() {
    if (!options.checkedFiles.value.length) return;
    if (options.checkedFiles.value.length > 50) {
      options.filesError.value = "每次最多选择 50 项文件，请缩小选择范围。";
      return;
    }
    if (
      options.checkedFiles.value.some(
        (path) => !options.fileEntries.value.some((entry) => entry.path === path && canWriteEntry(entry)),
      )
    ) {
      options.filesError.value = "所选项目包含只读或已变更的项目，请刷新后重试。";
      return;
    }
    const scope = options.currentRootContextKey();
    const selected = options.checkedFiles.value.slice();
    if (
      !(await requestConfirm({
        title: "批量移入回收站",
        message: "将选中的 " + options.checkedFiles.value.length + " 项移到回收站？",
        confirmText: "移入回收站",
        variant: "danger",
      }))
    )
      return;
    if (
      scope !== options.currentRootContextKey() ||
      selected.length !== options.checkedFiles.value.length ||
      !selected.every(
        (path) =>
          options.checkedFiles.value.includes(path) &&
          options.fileEntries.value.some((entry) => entry.path === path && canWriteEntry(entry)),
      )
    ) {
      options.filesError.value = "共享目录或选择已变化，未执行批量删除。";
      return;
    }
    try {
      const result = await options.jsonWrite<{ results: { success: boolean; path: string; error?: string }[] }>(
        options.scopedApiPath("/api/v2/files/batch"),
        "POST",
        { action: "trash", paths: selected },
      );
      if (scope !== options.currentRootContextKey()) return;
      const failed = result.results.filter((x) => !x.success).length;
      const changed = result.results.some((x) => x.error === "trash_item_changed");
      await options.loadFiles();
      if (scope !== options.currentRootContextKey()) return;
      if (changed) options.filesError.value = "检测到文件已变化，后续操作已停止；请检查原目录和回收站。";
      else if (failed) options.filesError.value = failed + " 项处理失败，请刷新列表核对已完成的文件后重试。";
    } catch (e) {
      if (scope === options.currentRootContextKey() && !options.isAbortError(e)) {
        options.filesError.value = "批量操作失败：" + describeUserFacingError(e);
      }
    }
  }

  async function downloadFile(item: SharedFileEntry) {
    if (item.type === "folder") {
      try {
        const response = await options.rootFetch(
          options.scopedApiPath("/api/v2/files/archive") + "?path=" + encodeURIComponent(item.path),
          {
            method: "HEAD",
            credentials: "same-origin",
            cache: "no-store",
          },
        );
        if (!response.ok) {
          options.filesError.value =
            response.status === 413
              ? "这个文件夹超过 ZIP 下载的限制（2 GiB、2,000 项或 16 层），请打开文件夹分批下载。"
              : response.status === 429
                ? "当前打包下载较多，请稍后重试。"
                : response.status === 403
                  ? "没有读取该文件夹的权限。"
                  : response.status === 404
                    ? "该文件夹已不存在，请刷新列表。"
                    : "无法准备文件夹下载：" + describeUserFacingError(await readApiFailure(response));
          return;
        }
      } catch (e) {
        if (options.isAbortError(e)) return;
        options.filesError.value = "准备文件夹下载失败：" + describeUserFacingError(e);
        return;
      }
    }
    options.filesError.value = "";
    const a = document.createElement("a");
    a.href = options.scopedMediaPath(
      (item.type === "folder" ? "/api/v2/files/archive?path=" : "/api/v2/files/content?path=") +
        encodeURIComponent(item.path),
    );
    a.download = item.type === "folder" ? item.name + ".zip" : item.name;
    a.rel = "noopener";
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  async function batchDownloadSelected() {
    const selectedEntries = options.checkedFiles.value
      .slice(0, 50)
      .map((path) => options.fileEntries.value.find((entry) => entry.path === path))
      .filter((entry): entry is SharedFileEntry => Boolean(entry));
    if (!selectedEntries.length) return;
    if (selectedEntries.length > 10) {
      const ok = await requestConfirm({
        title: "批量下载确认",
        message: `将依次触发 ${selectedEntries.length} 个文件或文件夹下载，浏览器可能会询问是否允许连续下载多个文件。确认继续？`,
        confirmText: "开始下载",
      });
      if (!ok) return;
    }
    const scope = options.currentRootContextKey();
    fileOperationNotice.value = `正在依次触发 ${selectedEntries.length} 项下载…`;
    for (let i = 0; i < selectedEntries.length; i += 1) {
      if (scope !== options.currentRootContextKey()) return;
      await downloadFile(selectedEntries[i]);
      if (i + 1 < selectedEntries.length) {
        await new Promise((resolve) => setTimeout(resolve, TIMINGS_MS.BATCH_DOWNLOAD_STAGGER));
      }
    }
    if (scope === options.currentRootContextKey()) {
      fileOperationNotice.value = `已触发 ${selectedEntries.length} 项下载，请在浏览器下载列表中确认保存完成。`;
    }
  }

  const selectedFilesAllWritable = computed(
    () =>
      options.fileDirectoryLoaded.value &&
      !options.filesError.value &&
      options.checkedFiles.value.length > 0 &&
      options.checkedFiles.value.every((path) =>
        options.fileEntries.value.some((entry) => entry.path === path && canWriteEntry(entry)),
      ),
  );

  const selectedPathsFallback = ref("");
  watch(options.checkedFiles, () => {
    selectedPathsFallback.value = "";
  });

  function selectFallbackPaths(event: FocusEvent) {
    (event.target as HTMLTextAreaElement)?.select();
  }

  async function copySelectedPaths() {
    const selected = options.checkedFiles.value.slice(0, 50);
    if (!selected.length) return;
    if (selected.some((path) => !options.fileEntries.value.some((entry) => entry.path === path))) {
      options.filesError.value = "所选文件列表已经变化，请刷新并重新选择。";
      return;
    }
    if (await copyTextToClipboard(selected.join("\n"))) {
      selectedPathsFallback.value = "";
      fileOperationNotice.value = "已复制 " + selected.length + " 项的相对路径，原文件未改变。";
    } else {
      // Clipboard API may be unavailable on default LAN HTTP origins.
      // Offer a selectable read-only field rather than a dead-end error.
      selectedPathsFallback.value = selected.join("\n");
      fileOperationNotice.value = "浏览器不支持自动复制，已在下方显示路径，可长按或选中后复制。";
    }
  }

  async function removeFile() {
    if (!trashTarget.value || fileActionBusy.value) return;
    const name = trashTarget.value.name;
    const filepath = trashTarget.value.path;
    fileActionBusy.value = true;
    options.filesError.value = "";
    try {
      const response = await options.rootFetch(
        options.scopedApiPath("/api/v2/files") + "?path=" + encodeURIComponent(filepath),
        {
          method: "DELETE",
          credentials: "same-origin",
          headers: { "X-LightIsle-Request": "1" },
        },
      );
      if (!response.ok) throw await readApiFailure(response);
      await options.loadFiles();
      if (options.showingTrash.value) await options.loadTrash();
      fileOperationNotice.value = "已将「" + name + "」移入回收站。";
    } catch (e) {
      if (!options.isAbortError(e)) {
        options.filesError.value = "移动 " + name + " 到回收站失败：" + describeUserFacingError(e);
      }
    } finally {
      trashTarget.value = null;
      fileActionBusy.value = false;
    }
  }

  function resetFileActionsAndGrantsForRoot() {
    fileOperationDialog.value = null;
    fileOperationNotice.value = "";
    newFolderName.value = "";
    trashTarget.value = null;
    fileActionBusy.value = false;
    previewItem.value = null;
    previewText.value = "";
    previewError.value = "";
    closeFileMedia();
    fileMediaEntriesByPath.clear();
    grantUser.value = null;
    grants.value = [];
    grantError.value = "";
    grantNotice.value = "";
    grantPathInput.value = "";
    grantCanWrite.value = false;
    grantBusy.value = false;
  }

  return {
    grantUser,
    grants,
    grantError,
    grantNotice,
    grantPathInput,
    grantCanWrite,
    grantBusy,
    fileOperationDialog,
    fileOperationNotice,
    newFolderName,
    trashTarget,
    fileActionBusy,
    previewItem,
    previewText,
    previewError,
    previewURL,
    fileMediaAssets,
    fileMediaSelected,
    fileMediaIndex,
    showFileMediaAt,
    closeFileMedia,
    fileEntryForMediaAsset,
    isPreviewImage,
    pathSegments,
    selectedFilesAllWritable,
    selectedPathsFallback,
    thumbnailKey,
    thumbnailEligible,
    fileThumbnailURL,
    closeFileMenu,
    markThumbnailFailure,
    canWriteEntry,
    operateFile,
    operateBatchMove,
    listOperationFolders,
    commitFileOperation,
    finishFileOperation,
    editGrants,
    saveGrant,
    toggleGrantWrite,
    removeGrant,
    previewFile,
    goUp,
    makeFolder,
    batchTrash,
    downloadFile,
    batchDownloadSelected,
    selectFallbackPaths,
    copySelectedPaths,
    removeFile,
    resetFileActionsAndGrantsForRoot,
  };
}
