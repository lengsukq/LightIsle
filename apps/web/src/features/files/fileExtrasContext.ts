import { ref, type InjectionKey, type Ref } from "vue";
import { readApiFailure } from "../../api/apiFailure.ts";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import type { SharedFileEntry } from "./useFileShares.ts";
import { useCollectLinks, type CollectLink } from "./fileCollectLinksApi.ts";
import {
  useFileInsights,
  useFilePins,
  type FileInsightItem,
  type FileInsightMode,
  type FilePin,
} from "./filePinsAndInsights.ts";
import { classifyFileReader } from "./fileReaderSupport.ts";

export interface FileExtrasContext {
  // Collect links
  collectModalOpen: Ref<boolean>;
  collectModalTab: Ref<"create" | "list">;
  collectTargetFolder: Ref<SharedFileEntry | null>;
  collectLinks: Ref<CollectLink[]>;
  collectLinksLoading: Ref<boolean>;
  collectLinksLoaded: Ref<boolean>;
  collectLinksError: Ref<string>;
  collectCreating: Ref<boolean>;
  collectCreateError: Ref<string>;
  collectCreatedUrl: Ref<string>;
  collectCreatedLink: Ref<CollectLink | null>;
  collectCopiedStatus: Ref<string>;
  collectRevokingId: Ref<string>;
  openCollectCreateModal: (folder: SharedFileEntry) => void;
  openCollectManageModal: (folder?: SharedFileEntry | null) => void;
  closeCollectModal: () => void;
  loadCollectLinks: (force?: boolean) => Promise<void>;
  createCollectLink: ReturnType<typeof useCollectLinks>["createCollectLink"];
  copyCollectCreatedUrl: ReturnType<typeof useCollectLinks>["copyCreatedUrl"];
  revokeCollectLink: ReturnType<typeof useCollectLinks>["revokeCollectLink"];
  clearCollectCreated: () => void;

  // Pins
  pins: Ref<FilePin[]>;
  pinsLoading: Ref<boolean>;
  pinsLoaded: Ref<boolean>;
  pinsError: Ref<string>;
  togglingPinPath: Ref<string>;
  isPinned: (path: string) => boolean;
  loadPins: (force?: boolean) => Promise<void>;
  togglePin: (entry: Pick<SharedFileEntry, "path" | "name">) => Promise<boolean>;
  addPin: (path: string, label?: string) => Promise<boolean>;
  removePin: (path: string) => Promise<boolean>;
  openPinItem: (pin: FilePin) => Promise<void>;

  // Insights
  insightsModalOpen: Ref<boolean>;
  insightsMode: Ref<FileInsightMode>;
  insightsScopePath: Ref<string>;
  insightsMinBytes: Ref<number>;
  insightsRecentDays: Ref<number>;
  insightsResult: ReturnType<typeof useFileInsights>["result"];
  insightsLoading: Ref<boolean>;
  insightsError: Ref<string>;
  insightsTrashingPath: Ref<string>;
  openInsightsModal: (mode: FileInsightMode) => void;
  closeInsightsModal: () => void;
  loadInsights: ReturnType<typeof useFileInsights>["loadInsights"];
  trashInsightItem: (item: FileInsightItem) => Promise<boolean>;
  openInsightFolder: (item: FileInsightItem) => Promise<void>;
  previewInsightItem: (item: FileInsightItem) => Promise<void>;

  // Readers
  markdownEditorFile: Ref<SharedFileEntry | null>;
  officePreviewFile: Ref<SharedFileEntry | null>;
  comicEpubFile: Ref<SharedFileEntry | null>;
  openFileWithReaders: (entry: SharedFileEntry) => Promise<void>;
  openAsTextEditor: (entry: SharedFileEntry) => void;
  openAsArchiveReader: (entry: SharedFileEntry) => void;
}

export const FILE_EXTRAS_CTX: InjectionKey<FileExtrasContext> = Symbol("lightisle-file-extras");

export function useFileWorkspaceExtras(options: {
  canList: () => boolean;
  context: () => string;
  filesPath: Ref<string>;
  scopedApiPath: (path: string) => string;
  scopedMediaPath: (path: string) => string;
  rootFetch: (endpoint: string, init?: RequestInit) => Promise<Response>;
  jsonGet: <T>(endpoint: string) => Promise<T>;
  jsonWrite: <T>(endpoint: string, method: "POST" | "PUT" | "PATCH" | "DELETE", body?: object) => Promise<T>;
  loadFiles: (path?: string) => Promise<unknown>;
  revealEntryFolder: (entry: SharedFileEntry) => Promise<string | null>;
  legacyPreviewFile: (entry: SharedFileEntry) => Promise<void>;
  isAbortError: (error: unknown) => boolean;
}) {
  const collectModalOpen = ref(false);
  const collectModalTab = ref<"create" | "list">("create");
  const collectTargetFolder = ref<SharedFileEntry | null>(null);

  const insightsModalOpen = ref(false);

  const markdownEditorFile = ref<SharedFileEntry | null>(null);
  const officePreviewFile = ref<SharedFileEntry | null>(null);
  const comicEpubFile = ref<SharedFileEntry | null>(null);

  async function deleteWithHeader(path: string) {
    const response = await options.rootFetch(path, {
      method: "DELETE",
      credentials: "same-origin",
      headers: { "X-LightIsle-Request": "1" },
    });
    if (!response.ok) throw await readApiFailure(response);
  }

  const collect = useCollectLinks({
    canList: options.canList,
    context: options.context,
    apiPath: options.scopedApiPath,
    mediaPath: options.scopedMediaPath,
    read: options.jsonGet,
    write: (path, body) => options.jsonWrite(path, "POST", body),
    remove: deleteWithHeader,
    confirm: (opts) => requestConfirm(opts),
    origin: () => (typeof window !== "undefined" ? window.location.origin : ""),
  });

  const pinsState = useFilePins({
    canList: options.canList,
    context: options.context,
    apiPath: options.scopedApiPath,
    read: options.jsonGet,
    write: (path, body) => options.jsonWrite(path, "POST", body),
    remove: deleteWithHeader,
    isAbort: options.isAbortError,
  });

  const insights = useFileInsights({
    canList: options.canList,
    context: options.context,
    apiPath: options.scopedApiPath,
    read: options.jsonGet,
    trashFile: (relPath) => deleteWithHeader(options.scopedApiPath("/api/v2/files") + "?path=" + encodeURIComponent(relPath)),
    confirm: (opts) => requestConfirm(opts),
    onFileTrashed: () => options.loadFiles(),
    isAbort: options.isAbortError,
  });

  function openCollectCreateModal(folder: SharedFileEntry) {
    if (folder.type !== "folder") return;
    collect.clearCreated();
    collectTargetFolder.value = folder;
    collectModalTab.value = "create";
    collectModalOpen.value = true;
    void collect.loadCollectLinks();
  }

  function openCollectManageModal(folder: SharedFileEntry | null = null) {
    collect.clearCreated();
    collectTargetFolder.value = folder;
    collectModalTab.value = "list";
    collectModalOpen.value = true;
    void collect.loadCollectLinks(true);
  }

  function closeCollectModal() {
    collectModalOpen.value = false;
    collect.clearCreated();
  }

  function openInsightsModal(mode: FileInsightMode) {
    insightsModalOpen.value = true;
    void insights.loadInsights({ mode, path: "." });
  }

  function closeInsightsModal() {
    insightsModalOpen.value = false;
  }

  function closeAllReaders() {
    markdownEditorFile.value = null;
    officePreviewFile.value = null;
    comicEpubFile.value = null;
  }

  async function openFileWithReaders(entry: SharedFileEntry) {
    if (entry.type === "folder") {
      await options.loadFiles(entry.path);
      return;
    }
    const kind = classifyFileReader(entry.name);
    if (kind === "markdown" || kind === "text") {
      closeAllReaders();
      markdownEditorFile.value = entry;
      return;
    }
    if (kind === "docx" || kind === "xlsx" || kind === "csv") {
      closeAllReaders();
      officePreviewFile.value = entry;
      return;
    }
    if (kind === "comic" || kind === "epub" || kind === "zip") {
      closeAllReaders();
      comicEpubFile.value = entry;
      return;
    }
    await options.legacyPreviewFile(entry);
  }

  function openAsTextEditor(entry: SharedFileEntry) {
    closeAllReaders();
    markdownEditorFile.value = entry;
  }

  function openAsArchiveReader(entry: SharedFileEntry) {
    closeAllReaders();
    comicEpubFile.value = entry;
  }

  async function openPinItem(pin: FilePin) {
    if (!pin.exists) return;
    if (pin.kind === "folder") {
      await options.loadFiles(pin.path);
      return;
    }
    const name = pin.path.split("/").pop() || pin.label || pin.path;
    await openFileWithReaders({
      name,
      path: pin.path,
      type: "file",
      size: pin.size ?? 0,
      modified: pin.modified ?? "",
      canWrite: pin.canWrite,
    });
  }

  async function openInsightFolder(item: FileInsightItem) {
    insightsModalOpen.value = false;
    await options.revealEntryFolder({
      name: item.name,
      path: item.path,
      type: "file",
      size: item.size,
      modified: item.modified,
      canWrite: item.canWrite,
    });
  }

  async function previewInsightItem(item: FileInsightItem) {
    await openFileWithReaders({
      name: item.name,
      path: item.path,
      type: "file",
      size: item.size,
      modified: item.modified,
      canWrite: item.canWrite,
    });
  }

  function resetAllExtras() {
    collectModalOpen.value = false;
    collectTargetFolder.value = null;
    insightsModalOpen.value = false;
    closeAllReaders();
    collect.reset();
    pinsState.reset();
    insights.reset();
  }

  const contextValue: FileExtrasContext = {
    collectModalOpen,
    collectModalTab,
    collectTargetFolder,
    collectLinks: collect.collectLinks,
    collectLinksLoading: collect.linksLoading,
    collectLinksLoaded: collect.linksLoaded,
    collectLinksError: collect.linksError,
    collectCreating: collect.creating,
    collectCreateError: collect.createError,
    collectCreatedUrl: collect.createdUrl,
    collectCreatedLink: collect.createdLink,
    collectCopiedStatus: collect.copiedStatus,
    collectRevokingId: collect.revokingId,
    openCollectCreateModal,
    openCollectManageModal,
    closeCollectModal,
    loadCollectLinks: collect.loadCollectLinks,
    createCollectLink: collect.createCollectLink,
    copyCollectCreatedUrl: collect.copyCreatedUrl,
    revokeCollectLink: collect.revokeCollectLink,
    clearCollectCreated: collect.clearCreated,

    pins: pinsState.pins,
    pinsLoading: pinsState.pinsLoading,
    pinsLoaded: pinsState.pinsLoaded,
    pinsError: pinsState.pinsError,
    togglingPinPath: pinsState.togglingPinPath,
    isPinned: pinsState.isPinned,
    loadPins: pinsState.loadPins,
    togglePin: pinsState.togglePin,
    addPin: pinsState.addPin,
    removePin: pinsState.removePin,
    openPinItem,

    insightsModalOpen,
    insightsMode: insights.mode,
    insightsScopePath: insights.scopePath,
    insightsMinBytes: insights.minBytes,
    insightsRecentDays: insights.recentDays,
    insightsResult: insights.result,
    insightsLoading: insights.loading,
    insightsError: insights.error,
    insightsTrashingPath: insights.trashingPath,
    openInsightsModal,
    closeInsightsModal,
    loadInsights: insights.loadInsights,
    trashInsightItem: insights.trashInsightItem,
    openInsightFolder,
    previewInsightItem,

    markdownEditorFile,
    officePreviewFile,
    comicEpubFile,
    openFileWithReaders,
    openAsTextEditor,
    openAsArchiveReader,
  };

  return {
    extrasContext: contextValue,
    resetAllExtras,
  };
}
