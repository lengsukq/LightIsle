import { ref } from "vue";
import { describeRootOperationFailure } from "./rootDiscovery.ts";
import {
  clearFileSearchHistory,
  parentDirOfPath,
  rankSearchEntries,
  readFileSearchHistory,
  recordFileSearchHistory,
  removeFileSearchHistory,
  type FileSearchKind,
  type FileSearchScope,
} from "./fileSearchUtils.ts";
import type { SharedFileEntry } from "./useFileShares.ts";

type BrowserDependencies = {
  authenticated: () => boolean;
  rootAvailable: () => boolean;
  rootError: () => string;
  rootEpoch: () => number;
  apiPath: (path: string) => string;
  read: <T>(path: string) => Promise<T>;
  write?: <T>(path: string, body: object) => Promise<T>;
  isAbort: (error: unknown) => boolean;
  onOpenFiles: () => void;
  onDirectoryLeave: () => void;
  onExtracted?: (name: string) => void;
  captureScrollTop?: () => number | null;
  restoreScrollTop?: (top: number) => void;
  historyStorageKey?: () => string;
};

/// File list, search and pagination belong to a physical-root-specific view.
/// Other operations (upload, trash, preview) operate on the current snapshot
/// and remain separate so no network response can silently change their root.
export function useFileBrowser(deps: BrowserDependencies) {
  const filesPath = ref(".");
  const preSearchPath = ref(".");
  const searchFolderBase = ref(".");
  const preSearchScrollTop = ref<number | null>(null);
  const currentFolderCanWrite = ref(false);
  const fileDirectoryLoaded = ref(false);
  const sharedRootName = ref("共享文件");
  const fileEntries = ref<SharedFileEntry[]>([]);
  const fileNextCursor = ref("");
  const fileSortKey = ref<"name" | "size" | "mtime">("name");
  const fileSortDirection = ref<"asc" | "desc">("asc");
  const failedThumbnails = ref(new Set<string>());
  const fileSearch = ref("");
  const lastExecutedQuery = ref("");
  const fileSearchKind = ref<FileSearchKind>("");
  const fileSearchScope = ref<FileSearchScope>("all");
  const searchViaSpotlight = ref(false);
  const searchingFiles = ref(false);
  const searchTruncated = ref(false);
  const recentSearches = ref<string[]>([]);
  const revealedFilePath = ref("");
  const revealingFilePath = ref("");
  const checkedFiles = ref<string[]>([]);
  const filesLoading = ref(false);
  const extracting = ref(false);
  const filesError = ref("");
  let requestGeneration = 0;
  let extractGeneration = 0;
  let revealHighlightTimer: number | null = null;

  function syncSearchHistory() {
    recentSearches.value = readFileSearchHistory(deps.historyStorageKey?.() ?? "");
  }

  function clearRevealHighlight() {
    if (revealHighlightTimer !== null && typeof window !== "undefined") {
      window.clearTimeout(revealHighlightTimer);
      revealHighlightTimer = null;
    }
    revealedFilePath.value = "";
  }

  function reset() {
    requestGeneration++;
    extractGeneration++;
    clearRevealHighlight();
    filesPath.value = ".";
    preSearchPath.value = ".";
    searchFolderBase.value = ".";
    preSearchScrollTop.value = null;
    currentFolderCanWrite.value = false;
    fileDirectoryLoaded.value = false;
    sharedRootName.value = "共享文件";
    fileEntries.value = [];
    fileNextCursor.value = "";
    fileSearch.value = "";
    lastExecutedQuery.value = "";
    fileSearchKind.value = "";
    fileSearchScope.value = "all";
    searchingFiles.value = false;
    searchTruncated.value = false;
    revealingFilePath.value = "";
    checkedFiles.value = [];
    filesLoading.value = false;
    extracting.value = false;
    filesError.value = "";
    failedThumbnails.value = new Set();
    syncSearchHistory();
  }

  async function loadFiles(target = filesPath.value, more = false): Promise<boolean> {
    if (!deps.authenticated()) return false;
    const request = ++requestGeneration;
    const epoch = deps.rootEpoch();
    if (!more && target !== filesPath.value) deps.onDirectoryLeave();
    if (!deps.rootAvailable()) {
      reset();
      filesError.value = deps.rootError() || "当前账号没有可访问的共享目录。";
      return false;
    }
    if (!more && !revealingFilePath.value) clearRevealHighlight();
    filesLoading.value = true;
    filesError.value = "";
    if (!more) searchTruncated.value = false;
    try {
      const root = await deps.read<{ name: string }>(deps.apiPath("/api/v2/files/root"));
      if (request !== requestGeneration || epoch !== deps.rootEpoch()) return false;
      sharedRootName.value = root.name;
      const query = new URLSearchParams({
        path: target,
        limit: "100",
        cursor: more ? fileNextCursor.value : "",
        sort: fileSortKey.value,
        dir: fileSortDirection.value,
      });
      const data = await deps.read<{
        entries: SharedFileEntry[]; nextCursor: string; canWrite: boolean;
      }>(deps.apiPath("/api/v2/files") + "?" + query.toString());
      if (request !== requestGeneration || epoch !== deps.rootEpoch()) return false;
      filesPath.value = target;
      if (!more) searchFolderBase.value = target;
      currentFolderCanWrite.value = data.canWrite === true;
      fileDirectoryLoaded.value = true;
      searchingFiles.value = false;
      fileEntries.value = more ? [...fileEntries.value, ...data.entries] : data.entries;
      fileNextCursor.value = data.nextCursor;
      searchTruncated.value = false;
      if (!more) checkedFiles.value = [];
      return true;
    } catch (error) {
      if (request === requestGeneration && epoch === deps.rootEpoch() && !deps.isAbort(error)) {
        // A failed or partial directory read cannot prove read-only status.
        // Keep previously loaded content as a stale preview only; never
        // retain its writable capability.
        fileDirectoryLoaded.value = false;
        currentFolderCanWrite.value = false;
        filesError.value = "读取目录失败：" + describeRootOperationFailure(error);
      }
      return false;
    } finally {
      if (request === requestGeneration) filesLoading.value = false;
    }
  }

  async function runFileSearch() {
    const query = fileSearch.value.trim();
    if (!query) {
      filesError.value = "";
      if (searchingFiles.value) {
        await clearFileSearch();
      }
      return;
    }
    const request = ++requestGeneration;
    const epoch = deps.rootEpoch();
    deps.onDirectoryLeave();
    clearRevealHighlight();
    if (!searchingFiles.value) {
      preSearchPath.value = filesPath.value;
      searchFolderBase.value = filesPath.value;
      preSearchScrollTop.value = deps.captureScrollTop?.() ?? null;
    }
    const baseFolder = searchFolderBase.value || ".";
    const searchBase = fileSearchScope.value === "folder" && baseFolder !== "." ? baseFolder : ".";
    filesPath.value = ".";
    fileEntries.value = [];
    fileNextCursor.value = "";
    checkedFiles.value = [];
    searchTruncated.value = false;
    searchingFiles.value = true;
    lastExecutedQuery.value = query;
    currentFolderCanWrite.value = false;
    fileDirectoryLoaded.value = false;
    deps.onOpenFiles();
    filesLoading.value = true;
    filesError.value = "";
    const historyKey = deps.historyStorageKey?.() ?? "";
    if (historyKey) {
      recentSearches.value = recordFileSearchHistory(historyKey, query);
    }
    try {
      const params = new URLSearchParams({ path: searchBase, query });
      if (searchViaSpotlight.value) params.set("engine", "spotlight");
      if (fileSearchKind.value) params.set("kind", fileSearchKind.value);
      const result = await deps.read<{
        entries: SharedFileEntry[]; truncated: boolean; canWrite: boolean;
      }>(deps.apiPath("/api/v2/files/search") + "?" + params.toString());
      if (request !== requestGeneration || epoch !== deps.rootEpoch()) return;
      fileEntries.value = rankSearchEntries(result.entries, query);
      fileNextCursor.value = "";
      searchTruncated.value = result.truncated;
      currentFolderCanWrite.value = result.canWrite === true;
      fileDirectoryLoaded.value = true;
    } catch (error) {
      if (request === requestGeneration && epoch === deps.rootEpoch() && !deps.isAbort(error)) {
        fileDirectoryLoaded.value = false;
        currentFolderCanWrite.value = false;
        filesError.value = "搜索失败：" + describeRootOperationFailure(error);
      }
    } finally {
      if (request === requestGeneration) filesLoading.value = false;
    }
  }

  async function selectSearchKind(kind: FileSearchKind) {
    fileSearchKind.value = kind;
    if (!fileSearch.value.trim() && lastExecutedQuery.value) {
      fileSearch.value = lastExecutedQuery.value;
    }
    if (searchingFiles.value || fileSearch.value.trim()) {
      await runFileSearch();
    }
  }

  async function setSearchScope(scope: FileSearchScope) {
    fileSearchScope.value = scope;
    if (!fileSearch.value.trim() && lastExecutedQuery.value) {
      fileSearch.value = lastExecutedQuery.value;
    }
    if (searchingFiles.value || fileSearch.value.trim()) {
      await runFileSearch();
    }
  }

  async function applyRecentSearch(term: string) {
    fileSearch.value = term;
    await runFileSearch();
  }

  function deleteRecentSearch(term: string) {
    recentSearches.value = removeFileSearchHistory(deps.historyStorageKey?.() ?? "", term);
  }

  function clearRecentSearches() {
    recentSearches.value = clearFileSearchHistory(deps.historyStorageKey?.() ?? "");
  }

  async function clearFileSearch() {
    const wasSearching = searchingFiles.value;
    const returnPath = wasSearching ? preSearchPath.value : filesPath.value;
    const returnScroll = wasSearching ? preSearchScrollTop.value : null;
    fileSearch.value = "";
    lastExecutedQuery.value = "";
    fileSearchKind.value = "";
    preSearchScrollTop.value = null;
    filesError.value = "";
    if (wasSearching) {
      const ok = await loadFiles(returnPath || ".");
      if (ok && returnScroll !== null) {
        deps.restoreScrollTop?.(returnScroll);
      }
    }
  }

  async function revealEntryFolder(entry: SharedFileEntry): Promise<string | null> {
    const targetDir = parentDirOfPath(entry.path);
    const epoch = deps.rootEpoch();
    revealingFilePath.value = entry.path;
    fileSearch.value = "";
    lastExecutedQuery.value = "";
    fileSearchKind.value = "";
    preSearchScrollTop.value = null;
    try {
      const ok = await loadFiles(targetDir);
      if (!ok || epoch !== deps.rootEpoch()) return null;
      let pagesLoaded = 0;
      while (
        epoch === deps.rootEpoch() &&
        fileNextCursor.value &&
        pagesLoaded < 15 &&
        !fileEntries.value.some((item) => item.path === entry.path)
      ) {
        pagesLoaded += 1;
        const pageOk = await loadFiles(targetDir, true);
        if (!pageOk) break;
      }
      if (epoch !== deps.rootEpoch()) return null;
      clearRevealHighlight();
      revealedFilePath.value = entry.path;
      if (typeof window !== "undefined") {
        revealHighlightTimer = window.setTimeout(() => {
          revealedFilePath.value = "";
          revealHighlightTimer = null;
        }, 2200);
      }
      return entry.path;
    } finally {
      if (revealingFilePath.value === entry.path) revealingFilePath.value = "";
    }
  }

  async function extractZip(entry: SharedFileEntry) {
    if (!deps.write || extracting.value) return;
    const epoch = deps.rootEpoch();
    const gen = ++extractGeneration;
    extracting.value = true;
    filesError.value = "";
    try {
      await deps.write(deps.apiPath("/api/v2/files/extract"), { path: entry.path });
      if (epoch !== deps.rootEpoch()) return;
      await loadFiles(filesPath.value);
      if (epoch === deps.rootEpoch()) deps.onExtracted?.(entry.name);
    } catch (error) {
      if (epoch === deps.rootEpoch() && !deps.isAbort(error)) {
        filesError.value = "解压失败：" + describeRootOperationFailure(error);
      }
    } finally {
      if (gen === extractGeneration) extracting.value = false;
    }
  }

  return {
    filesPath, currentFolderCanWrite, fileDirectoryLoaded, sharedRootName, fileEntries,
    fileNextCursor, fileSortKey, fileSortDirection, failedThumbnails,
    fileSearch, lastExecutedQuery, fileSearchKind, fileSearchScope, searchFolderBase,
    searchViaSpotlight, searchingFiles, searchTruncated, recentSearches,
    revealedFilePath, revealingFilePath,
    checkedFiles, filesLoading, extracting, filesError,
    loadFiles, runFileSearch, selectSearchKind, setSearchScope,
    applyRecentSearch, deleteRecentSearch, clearRecentSearches, syncSearchHistory,
    clearFileSearch, revealEntryFolder, extractZip, reset,
  };
}
