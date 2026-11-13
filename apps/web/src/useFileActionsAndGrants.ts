import { computed, ref, watch, type Ref } from "vue";
import { createFileOperationsClient } from "./fileOperationsClient.ts";
import { readApiFailure } from "./apiFailure.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { requestConfirm } from "./useConfirmDialog.ts";
import type { ManagedAccount } from "./useAccountManagement.ts";
import type { SharedFileEntry } from "./useFileShares.ts";

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
  loadFiles: (path?: string) => Promise<void>;
  loadTrash: () => Promise<void>;
  isAbortError: (error: unknown) => boolean;
}) {
  const grantUser = ref<ManagedAccount | null>(null);
  const grants = ref<FileGrant[]>([]);
  const grantError = ref("");
  const grantNotice = ref("");
  const grantPathInput = ref("");
  const grantCanWrite = ref(false);
  const grantBusy = ref(false);

  const fileOperationDialog = ref<{ item: SharedFileEntry; action: "move" | "copy" } | null>(null);
  const fileOperationNotice = ref("");
  const newFolderName = ref("");
  const trashTarget = ref<SharedFileEntry | null>(null);
  const previewItem = ref<SharedFileEntry | null>(null);
  const previewText = ref("");
  const previewError = ref("");
  const showPreviewPlaylist = ref(false);
  const previewAutoplayNext = ref(false);

  function entryDirectory(path: string) {
    const normalized = path.replace(/\\/g, "/").trim().replace(/^\/+|\/+$/g, "");
    const slash = normalized.lastIndexOf("/");
    return slash < 0 ? "" : normalized.slice(0, slash);
  }

  function isPreviewVideo(item: SharedFileEntry | null) {
    return Boolean(item && item.type === "file" && /\.(mp4|webm|m4v|mov)$/i.test(item.name));
  }

  function isPreviewImage(item: SharedFileEntry | null) {
    return Boolean(item && item.type === "file" && /\.(jpe?g|png|gif|webp|heic|heif)$/i.test(item.name));
  }

  const previewImagePlaylist = computed<SharedFileEntry[]>(() => {
    const current = previewItem.value;
    if (!isPreviewImage(current) || !current) return [];
    const dir = entryDirectory(current.path);
    const items = options.fileEntries.value.filter(
      (entry) => isPreviewImage(entry) && entryDirectory(entry.path) === dir,
    );
    if (!items.some((entry) => entry.path === current.path)) {
      items.push(current);
    }
    return items.slice().sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
  });

  const currentPreviewImageIndex = computed(() => {
    const current = previewItem.value;
    if (!current) return 0;
    const idx = previewImagePlaylist.value.findIndex((entry) => entry.path === current.path);
    return idx < 0 ? 0 : idx;
  });

  const prevPreviewImage = computed(() =>
    currentPreviewImageIndex.value > 0
      ? previewImagePlaylist.value[currentPreviewImageIndex.value - 1] ?? null
      : null,
  );

  const nextPreviewImage = computed(() =>
    currentPreviewImageIndex.value + 1 < previewImagePlaylist.value.length
      ? previewImagePlaylist.value[currentPreviewImageIndex.value + 1] ?? null
      : null,
  );

  const previewVideoPlaylist = computed<SharedFileEntry[]>(() => {
    const current = previewItem.value;
    if (!isPreviewVideo(current) || !current) return [];
    const dir = entryDirectory(current.path);
    const items = options.fileEntries.value.filter(
      (entry) => isPreviewVideo(entry) && entryDirectory(entry.path) === dir,
    );
    if (!items.some((entry) => entry.path === current.path)) {
      items.push(current);
    }
    return items.slice().sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
  });

  const currentPreviewVideoIndex = computed(() => {
    const current = previewItem.value;
    if (!current) return 0;
    const idx = previewVideoPlaylist.value.findIndex((entry) => entry.path === current.path);
    return idx < 0 ? 0 : idx;
  });

  const prevPreviewVideo = computed(() =>
    currentPreviewVideoIndex.value > 0
      ? previewVideoPlaylist.value[currentPreviewVideoIndex.value - 1] ?? null
      : null,
  );

  const nextPreviewVideo = computed(() =>
    currentPreviewVideoIndex.value + 1 < previewVideoPlaylist.value.length
      ? previewVideoPlaylist.value[currentPreviewVideoIndex.value + 1] ?? null
      : null,
  );

  function onPreviewVideoEnded() {
    if (previewAutoplayNext.value && nextPreviewVideo.value) {
      void previewFile(nextPreviewVideo.value);
    }
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

  function operateFile(item: SharedFileEntry, action: "move" | "copy") {
    if (action === "move" && !canWriteEntry(item)) return;
    if (options.showingTrash.value || options.searchingFiles.value) return;
    fileOperationNotice.value = "";
    fileOperationDialog.value = { item, action };
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
    return fileOperations.commit<{ done: boolean; finalTo: string; skipped: boolean }>({
      action: dialog.action,
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

  async function previewFile(item: SharedFileEntry) {
    previewItem.value = item;
    previewText.value = "";
    previewError.value = "";
    const scopeEpoch = options.rootContextEpoch();
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
    if (!isPreviewVideo(item)) {
      showPreviewPlaylist.value = false;
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

  async function makeFolder() {
    if (!options.currentFolderCanWrite.value) return;
    const name = newFolderName.value.trim();
    if (!name) return;
    const full = options.filesPath.value === "." ? name : options.filesPath.value + "/" + name;
    options.filesError.value = "";
    try {
      await options.jsonWrite(options.scopedApiPath("/api/v2/files/folders"), "POST", { path: full });
      newFolderName.value = "";
      await options.loadFiles();
    } catch (e) {
      if (!options.isAbortError(e)) options.filesError.value = "新建文件夹失败：" + describeUserFacingError(e);
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
    try {
      if (!navigator.clipboard?.writeText) throw new Error("clipboard_unavailable");
      await navigator.clipboard.writeText(selected.join("\n"));
      selectedPathsFallback.value = "";
      fileOperationNotice.value = "已复制 " + selected.length + " 项的相对路径，原文件未改变。";
    } catch {
      // Clipboard API is unavailable on many default LAN HTTP origins.
      // Offer a selectable read-only field rather than a dead-end error.
      selectedPathsFallback.value = selected.join("\n");
      fileOperationNotice.value = "浏览器不支持自动复制，已在下方显示路径，可长按或选中后复制。";
    }
  }

  async function removeFile() {
    if (!trashTarget.value) return;
    const name = trashTarget.value.name;
    const filepath = trashTarget.value.path;
    trashTarget.value = null;
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
    } catch (e) {
      if (!options.isAbortError(e)) {
        options.filesError.value = "移动 " + name + " 到回收站失败：" + describeUserFacingError(e);
      }
    }
  }

  function resetFileActionsAndGrantsForRoot() {
    fileOperationDialog.value = null;
    fileOperationNotice.value = "";
    newFolderName.value = "";
    previewItem.value = null;
    previewText.value = "";
    previewError.value = "";
    showPreviewPlaylist.value = false;
    trashTarget.value = null;
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
    previewItem,
    previewText,
    previewError,
    previewURL,
    showPreviewPlaylist,
    previewAutoplayNext,
    previewVideoPlaylist,
    currentPreviewVideoIndex,
    prevPreviewVideo,
    nextPreviewVideo,
    isPreviewImage,
    previewImagePlaylist,
    currentPreviewImageIndex,
    prevPreviewImage,
    nextPreviewImage,
    onPreviewVideoEnded,
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
    selectFallbackPaths,
    copySelectedPaths,
    removeFile,
    resetFileActionsAndGrantsForRoot,
  };
}
