import { ref } from "vue";
import { describeRootOperationFailure } from "./rootDiscovery.js";
import type { SharedFileEntry } from "./useFileShares";

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
};

/// File list, search and pagination belong to a physical-root-specific view.
/// Other operations (upload, trash, preview) operate on the current snapshot
/// and remain separate so no network response can silently change their root.
export function useFileBrowser(deps: BrowserDependencies) {
  const filesPath = ref(".");
  const currentFolderCanWrite = ref(false);
  const fileDirectoryLoaded = ref(false);
  const sharedRootName = ref("共享文件");
  const fileEntries = ref<SharedFileEntry[]>([]);
  const fileNextCursor = ref("");
  const fileSortKey = ref<"name" | "size" | "mtime">("name");
  const fileSortDirection = ref<"asc" | "desc">("asc");
  const failedThumbnails = ref(new Set<string>());
  const fileSearch = ref("");
  const searchViaSpotlight = ref(false);
  const searchingFiles = ref(false);
  const searchTruncated = ref(false);
  const checkedFiles = ref<string[]>([]);
  const filesLoading = ref(false);
  const filesError = ref("");
  let requestGeneration = 0;

  function reset() {
    requestGeneration++;
    filesPath.value = ".";
    currentFolderCanWrite.value = false;
    fileDirectoryLoaded.value = false;
    sharedRootName.value = "共享文件";
    fileEntries.value = [];
    fileNextCursor.value = "";
    fileSearch.value = "";
    searchingFiles.value = false;
    searchTruncated.value = false;
    checkedFiles.value = [];
    filesLoading.value = false;
    filesError.value = "";
    failedThumbnails.value = new Set();
  }

  async function loadFiles(target = filesPath.value, more = false) {
    if (!deps.authenticated()) return;
    const request = ++requestGeneration;
    const epoch = deps.rootEpoch();
    if (!more && target !== filesPath.value) deps.onDirectoryLeave();
    if (!deps.rootAvailable()) {
      reset();
      filesError.value = deps.rootError() || "当前账号没有可访问的共享目录。";
      return;
    }
    filesLoading.value = true;
    filesError.value = "";
    if (!more) searchTruncated.value = false;
    try {
      const root = await deps.read<{ name: string }>(deps.apiPath("/api/v2/files/root"));
      if (request !== requestGeneration || epoch !== deps.rootEpoch()) return;
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
      if (request !== requestGeneration || epoch !== deps.rootEpoch()) return;
      filesPath.value = target;
      currentFolderCanWrite.value = data.canWrite === true;
      fileDirectoryLoaded.value = true;
      searchingFiles.value = false;
      fileEntries.value = more ? [...fileEntries.value, ...data.entries] : data.entries;
      fileNextCursor.value = data.nextCursor;
      searchTruncated.value = false;
      if (!more) checkedFiles.value = [];
    } catch (error) {
      if (request === requestGeneration && epoch === deps.rootEpoch() && !deps.isAbort(error)) {
        // A failed or partial directory read cannot prove read-only status.
        // Keep previously loaded content as a stale preview only; never
        // retain its writable capability.
        fileDirectoryLoaded.value = false;
        currentFolderCanWrite.value = false;
        filesError.value = "读取目录失败：" + describeRootOperationFailure(error);
      }
    } finally {
      if (request === requestGeneration) filesLoading.value = false;
    }
  }

  async function runFileSearch() {
    const query = fileSearch.value.trim();
    if (query.length < 2) {
      filesError.value = "至少输入两个搜索字符";
      deps.onOpenFiles();
      return;
    }
    const request = ++requestGeneration;
    const epoch = deps.rootEpoch();
    deps.onDirectoryLeave();
    filesPath.value = ".";
    fileEntries.value = [];
    fileNextCursor.value = "";
    checkedFiles.value = [];
    searchTruncated.value = false;
    searchingFiles.value = true;
    currentFolderCanWrite.value = false;
    fileDirectoryLoaded.value = false;
    deps.onOpenFiles();
    filesLoading.value = true;
    filesError.value = "";
    try {
      const engine = searchViaSpotlight.value ? "&engine=spotlight" : "";
      const result = await deps.read<{
        entries: SharedFileEntry[]; truncated: boolean; canWrite: boolean;
      }>(deps.apiPath("/api/v2/files/search") + "?path=.&query=" +
        encodeURIComponent(query) + engine);
      if (request !== requestGeneration || epoch !== deps.rootEpoch()) return;
      fileEntries.value = result.entries;
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

  async function extractZip(entry: SharedFileEntry) {
    if (!deps.write) return;
    const epoch = deps.rootEpoch();
    filesError.value = "";
    try {
      await deps.write(deps.apiPath("/api/v2/files/extract"), { path: entry.path });
      if (epoch !== deps.rootEpoch()) return;
      await loadFiles(filesPath.value);
    } catch (error) {
      if (epoch === deps.rootEpoch() && !deps.isAbort(error)) {
        filesError.value = "解压失败：" + describeRootOperationFailure(error);
      }
    }
  }

  return {
    filesPath, currentFolderCanWrite, fileDirectoryLoaded, sharedRootName, fileEntries,
    fileNextCursor, fileSortKey, fileSortDirection, failedThumbnails,
    fileSearch, searchViaSpotlight, searchingFiles, searchTruncated,
    checkedFiles, filesLoading, filesError, loadFiles, runFileSearch, extractZip,
    reset,
  };
}
