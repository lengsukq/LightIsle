<script setup lang="ts">
import { computed, defineAsyncComponent, h, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import {
  Activity, ArrowDownToLine, Clapperboard,
  Folder, FolderOpen, HardDrive, Images, LayoutDashboard, Moon, Monitor,
  RefreshCcw, Settings2, ShieldCheck, Sun, WifiOff, FileText, FolderPlus,
  UploadCloud, ChevronRight, ChevronLeft, Download, Trash2, CopyCheck,
  LogOut, Sparkles, Workflow, LayoutGrid, List
} from "lucide-vue-next";
import FileSearchControls from "./FileSearchControls.vue";
import FileSearchStatusBar from "./FileSearchStatusBar.vue";
import {
  buildFileSearchHistoryKey,
  FILE_SEARCH_KIND_OPTIONS,
  folderLabelOfPath,
  highlightSearchSegments,
  parentDirOfPath,
  scrollRevealedFileIntoView,
} from "./fileSearchUtils.ts";
import { hasActiveModalLayer, pushModalLayer, type ModalLayerHandle } from "./modalStack.ts";
import { useShellAppearance } from "./useShellAppearance.ts";
import { useHostTelemetry } from "./useHostTelemetry.ts";
import { useAccountSessions } from "./useAccountSessions.ts";
import { useAccountManagement } from "./useAccountManagement.ts";
import { useFileBrowser } from "./useFileBrowser.ts";
import { useFileUploads } from "./useFileUploads.ts";
import { useFileShares, type SharedFileEntry } from "./useFileShares.ts";
import { useTaskCenter } from "./useTaskCenter.ts";
import UploadMaintenance from "./UploadMaintenance.vue";
import PendingMedia from "./PendingMedia.vue";
import DiskManagement from "./DiskManagement.vue";
import SmbManagement from "./SmbManagement.vue";
import TailscaleGuideCard from "./TailscaleGuideCard.vue";
import UserStoragePanel from "./UserStoragePanel.vue";
import DuplicateFilesPanel from "./DuplicateFilesPanel.vue";
import DavAccess from "./DavAccess.vue";
import BetaDiagnosticReport from "./BetaDiagnosticReport.vue";
import { bindDiagnosticAccount, resetDiagnostics } from "./betaDiagnostics.ts";
import ConfirmModal from "./ConfirmModal.vue";
import AuthScene from "./AuthScene.vue";
import MobileNavDrawer from "./MobileNavDrawer.vue";
import { requestAlert, requestConfirm } from "./useConfirmDialog.ts";
import FileOperationDialog from "./FileOperationDialog.vue";
import IsleModal from "./IsleModal.vue";
import IsleButton from "./IsleButton.vue";
import IsleCard from "./IsleCard.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleChip from "./IsleChip.vue";
import IsleEmpty from "./IsleEmpty.vue";
import IsleImageViewer from "./IsleImageViewer.vue";
import IsleVideoPlayer from "./IsleVideoPlayer.vue";
import { trashPresentationState } from "./filePageState.ts";
import OpsTaskCenter from "./OpsTaskCenter.vue";
import AuditLogView from "./AuditLogView.vue";
import AlertsView from "./AlertsView.vue";
import OpsDiagnostics from "./OpsDiagnostics.vue";
import AppleSelect from "./AppleSelect.vue";
import OverviewPage from "./OverviewPage.vue";
import CacheManagementPanel from "./CacheManagementPanel.vue";
import { clearRuntimeMemoryCache } from "./useIsleCache.ts";
import PendingReservations from "./PendingReservations.vue";
import ComputerFilesView from "./ComputerFilesView.vue";
import UploadCleanupRules from "./UploadCleanupRules.vue";
import { describeUserFacingError } from "./userFacingError.ts";
import { formatDateTime } from "./dateTimeFormat.ts";
import { readApiFailure } from "./apiFailure.ts";
import { useFileTrash } from "./useFileTrash.ts";
import { type ShellPage as Page, type ShellSettingsGroup as SettingsGroup } from "./shellRouteGuard.ts";
import { useFileActionsAndGrants } from "./useFileActionsAndGrants.ts";
import { useOverviewAndDisclosures } from "./useOverviewAndDisclosures.ts";
import { createJsonRootClient } from "./api/jsonRootClient.ts";
import { useRootContextController } from "./composables/useRootContextController.ts";
import { useAppBrowserLifecycle } from "./composables/useAppBrowserLifecycle.ts";

// Heavy media libraries are requested only when their pages are opened.
const asyncPageState = (message: string, role: string) => ({
  render: () => h("p", { role, class: "page-status" }, message),
});
const AutomationView = defineAsyncComponent(() => import("./AutomationView.vue"));
const AppsCenterView = defineAsyncComponent(() => import("./AppsCenterView.vue"));
const PhotosView = defineAsyncComponent({
  loader: () => import("./PhotosView.vue"),
  loadingComponent: asyncPageState("正在加载图库…", "status"),
  errorComponent: asyncPageState("图库资源加载失败，请刷新页面。", "alert"),
  delay: 150,
});
const CinemaView = defineAsyncComponent({
  loader: () => import("./CinemaView.vue"),
  loadingComponent: asyncPageState("正在加载影院…", "status"),
  errorComponent: asyncPageState("影院资源加载失败，请刷新页面。", "alert"),
  delay: 150,
});
const DownloadsView = defineAsyncComponent({
  loader: () => import("./DownloadsView.vue"),
  loadingComponent: asyncPageState("正在加载下载中心…", "status"),
  errorComponent: asyncPageState("下载中心资源加载失败，请刷新页面。", "alert"),
  delay: 150,
});

type FileEntry = SharedFileEntry;

const items = [
  { key: "overview" as Page, title: "主页概览", shortTitle: "概览", icon: Sparkles, color: "blue", group: "space" },
  { key: "files" as Page, title: "私人文件", shortTitle: "文件", icon: Folder, color: "cyan", group: "space" },
  { key: "computer" as Page, title: "电脑文件", shortTitle: "电脑", icon: Monitor, color: "blue", group: "space" },
  { key: "photos" as Page, title: "时光相册", shortTitle: "相册", icon: Images, color: "pink", group: "space" },
  { key: "cinema" as Page, title: "私人影院", shortTitle: "影院", icon: Clapperboard, color: "orange", group: "space" },
  { key: "downloads" as Page, title: "下载中心", shortTitle: "下载", icon: ArrowDownToLine, color: "cyan", group: "space" },
  { key: "apps" as Page, title: "应用中心", shortTitle: "应用", icon: LayoutDashboard, color: "purple", group: "space" },
  { key: "automation" as Page, title: "自动化", shortTitle: "自动化", icon: Workflow, color: "purple", group: "system" },
  { key: "settings" as Page, title: "偏好设置", shortTitle: "设置", icon: Settings2, color: "purple", group: "system" },
];

const startingPage = new URLSearchParams(location.search).get("page");
const validPages = new Set<Page>(["overview", "files", "computer", "photos", "cinema", "downloads", "apps", "automation", "settings"]);
const active = ref<Page>(validPages.has(startingPage as Page) ? (startingPage as Page) : "overview");
const visitedPages = ref<Record<Page, boolean>>({
  overview: true,
  files: active.value === "files",
  computer: active.value === "computer",
  photos: active.value === "photos",
  cinema: active.value === "cinema",
  downloads: active.value === "downloads",
  apps: active.value === "apps",
  automation: active.value === "automation",
  settings: active.value === "settings",
});

const fileSortKeyOptions = [
  { value: "name", label: "名称" },
  { value: "mtime", label: "修改时间" },
  { value: "size", label: "文件大小" },
];
const fileSortDirectionOptions = [
  { value: "asc", label: "升序" },
  { value: "desc", label: "降序" },
];
const shareHourOptions = [
  { value: 1, label: "1 小时" },
  { value: 6, label: "6 小时" },
  { value: 24, label: "1 天" },
  { value: 72, label: "3 天" },
  { value: 168, label: "7 天" },
];

const authChecking = ref(true);
const configured = ref(false);
const authServiceError = ref("");
const user = ref<{ username: string; role: "admin" | "member" } | null>(null);
const authUsername = ref("");
const authPassword = ref("");
const showAuthPassword = ref(false);
const authError = ref("");
const authSubmitting = ref(false);
const showDuplicatesModal = ref(false);
const shareOutcomeWarning = ref(false);
const photoBatchOutcomeWarning = ref(false);
const settingsGroup = ref<SettingsGroup>("account");
const newFolderInputRef = ref<HTMLInputElement | null>(null);
const lastCheckedFileIndex = ref<number | null>(null);
let moreMenuLayer: ModalLayerHandle | null = null;

const settingsGroups = computed(() => {
  const options: Array<{ key: SettingsGroup; label: string }> = [
    { key: "account", label: "账号与安全" },
    { key: "files", label: "文件与连接" },
    { key: "cache", label: "缓存管理" },
  ];
  if (user.value?.role === "admin") {
    options.push(
      { key: "storage", label: "存储与磁盘" },
      { key: "ops", label: "任务与通知" },
    );
  }
  return options;
});

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

function resetRootScopedState() {
  resetFileTrash();
  resetFileBrowser();
  resetFileActionsAndGrantsForRoot();
  resetFileShares();
  resetTaskCenter();
  resetUploadsForRoot();
}

const {
  rootDiscoveryState,
  myStoragePolicy,
  personalRouteError,
  manualRootSection,
  sharedRoots,
  selectedRootID,
  rootDiscoveryError,
  rootDiscoveryLoading,
  rootSwitching,
  rootContextEpoch,
  selectedRoot,
  multiRootMode,
  selectedRootGeneration,
  rootSelectionValue,
  rootSelectionOptions,
  rootViewKey,
  rootFeatureContextReady,
  rootContextPresentation,
  scopedApiPath,
  scopedMediaPath,
  rootTransport,
  currentRootContextKey,
  getLastRootDiscoveryAt,
  resetAllRootControllerState,
  bindPolicyReader,
  loadPersonalStoragePolicy: loadPersonalStoragePolicyWithReader,
  autoRouteSection,
  refreshRootDiscovery,
  handleRootChange,
} = useRootContextController({
  isAuthenticated: () => user.value !== null,
  isAdmin: () => user.value?.role === "admin",
  activeSection: () => active.value,
  isFileDirectoryLoaded: () => fileDirectoryLoaded.value,
  isUploadBusy: () => uploadBusy.value,
  hasActiveUpload: () => hasActiveUpload(),
  cancelAndWaitForUpload: () => cancelAndWaitForUpload(),
  resetRootScopedFeatures: resetRootScopedState,
  loadFiles: (path) => loadFiles(path),
  refreshTaskCenter: () => refreshTaskCenter(),
  loadMyShares: () => loadMyShares(),
  clearClientSessionState: (msg) => clearClientSessionState(msg),
  isAbortError,
});

const rootContextPageVisible = computed(
  () => ["files", "photos", "cinema"].includes(active.value) && rootContextPresentation.value.kind !== "ready",
);
const rootDiscoveryNoticeVisible = computed(
  () => !!rootDiscoveryError.value && rootContextPresentation.value.kind === "ready",
);

const rootFetch = rootTransport.request;
const { jsonGet, jsonWrite, downloadsApi } = createJsonRootClient({
  rootFetch,
  snapshotEndpoint: rootTransport.snapshot,
  assertSnapshotCurrent: rootTransport.assertCurrent,
  isAuthenticated: () => user.value !== null,
  onSessionExpired: (msg) => clearClientSessionState(msg),
  onRootGenerationChanged: () => {
    void refreshRootDiscovery();
  },
});
bindPolicyReader(jsonGet);
const loadPersonalStoragePolicy = () => loadPersonalStoragePolicyWithReader(jsonGet);

const {
  tasks, taskError, taskLoaded, taskLoading, taskHistory, taskHistoryNextCursor,
  taskHistoryLoading, taskHistoryError,
  reloadTasks, reloadTaskHistory, refreshTaskCenter,
  taskControl, startMediaTask,
  reset: resetTaskCenter,
} = useTaskCenter({
  role: () => user.value?.role,
  ready: () => rootFeatureContextReady.value,
  activePage: () => active.value,
  getJson: <T>(url: string) => jsonGet<T>(url),
  rootFetch: (url, init) => rootFetch(url, init),
  scopedApiPath: (path) => scopedApiPath(path),
  isAbortError,
});

const {
  accounts, userError,
  currentPassword, nextPassword, repeatPassword, passwordBusy, passwordError,
  newUsername, newPassword, creatingUser, createUserError, createUserNotice,
  memberActionBusy, memberActionError, memberActionNotice,
  resetTargetUser, resetMemberNewPassword, resetMemberRepeatPassword, resetMemberBusy, resetMemberError,
  computerFilesStatus, computerGrantUser, computerGrantMode, computerGrantFolders,
  computerGrantFolderInput, computerGrantBusy, computerGrantReady, computerGrantError, computerGrantNotice, computerGrantModeOptions,
  loadAccounts, loadComputerFilesStatus, createMemberAccount, toggleMemberEnabled,
  openResetMemberPassword, closeResetMemberPassword, submitResetMemberPassword,
  editComputerGrants, addComputerGrantFolder, removeComputerGrantFolder, saveComputerGrants,
  changeOwnPassword, resetAccountState,
} = useAccountManagement({
  isAdmin: () => user.value?.role === "admin",
  read: <T>(path: string) => jsonGet<T>(path),
  write: <T>(path: string, method: "POST" | "PATCH" | "PUT", body?: object) =>
    jsonWrite<T>(path, method, body ?? {}),
  logout: () => logout(),
  onOwnPasswordChanged: () => {
    authError.value = "密码已更新，其他设备上的会话也已失效，请使用新密码重新登录。";
  },
  confirm: (opts) => requestConfirm(opts),
});

const showComputerFilesNav = computed(() =>
  user.value?.role === "admin" || Boolean(computerFilesStatus.value?.enabled && computerFilesStatus.value.mode !== "none"),
);

const {
  loginSessions, sessionsLoading, sessionsLoaded, sessionsTruncated,
  sessionsError, sessionsMessage, loadLoginSessions, revokeLoginSession,
  reset: resetLoginSessions,
} = useAccountSessions({
  authenticated: () => user.value !== null,
  read: <T>(path: string) => jsonGet<T>(path),
  logoutCurrent: () => logout(),
  onCurrentLogout: () => {
    authError.value = "当前设备已退出，请重新登录。";
  },
  confirm: (message: string) => requestConfirm(message),
  revoke: async (path: string) => {
    const response = await fetch(path, {
      method: "DELETE",
      credentials: "same-origin",
      headers: { "X-LightIsle-Request": "1" },
    });
    if (!response.ok) throw await readApiFailure(response);
  },
});

const {
  sharingFile, shareHours, sharePassword, shareMaxDownloads, shareCreating,
  shareCreatedLink, shareError, shareCopied, shareLinkInput, activeShares,
  sharesLoading, sharesError, sharesLoaded,
  openShareDialog, createFileShare, copyShareLink, loadMyShares,
  revokeFileShare, reset: resetFileShares,
} = useFileShares({
  canList: () => user.value !== null && rootFeatureContextReady.value,
  context: () => `${user.value?.username ?? ""}:${rootContextEpoch.value}:${selectedRootID.value}:${selectedRootGeneration.value}`,
  apiPath: scopedApiPath,
  mediaPath: scopedMediaPath,
  read: <T>(path: string) => jsonGet<T>(path),
  write: <T>(path: string, body: object) => jsonWrite<T>(path, "POST", body),
  remove: async (path: string) => {
    const response = await rootFetch(path, {
      method: "DELETE",
      credentials: "same-origin",
      headers: { "X-LightIsle-Request": "1" },
    });
    if (!response.ok) throw await readApiFailure(response);
  },
  confirm: (message: string) => requestConfirm(message),
  origin: () => window.location.origin,
});

const fileSearchHistoryKey = computed(() =>
  buildFileSearchHistoryKey(user.value?.username, multiRootMode.value ? selectedRootID.value : "primary"),
);

const {
  filesPath, currentFolderCanWrite, fileDirectoryLoaded, sharedRootName, fileEntries, fileNextCursor,
  fileSortKey, fileSortDirection, failedThumbnails, fileSearch, lastExecutedQuery, fileSearchKind,
  fileSearchScope, searchFolderBase, searchViaSpotlight, searchingFiles, searchTruncated, recentSearches,
  revealedFilePath, revealingFilePath, checkedFiles, filesLoading, extracting, filesError,
  loadFiles, runFileSearch, selectSearchKind, setSearchScope, applyRecentSearch, deleteRecentSearch,
  clearRecentSearches, syncSearchHistory, clearFileSearch, revealEntryFolder, extractZip, reset: resetFileBrowser,
} = useFileBrowser({
  authenticated: () => user.value !== null,
  rootAvailable: () =>
    rootDiscoveryState.value !== "error" &&
    !(multiRootMode.value && !selectedRootID.value),
  rootError: () => rootDiscoveryError.value,
  rootEpoch: () => rootContextEpoch.value,
  apiPath: scopedApiPath,
  read: <T>(path: string) => jsonGet<T>(path),
  write: <T>(path: string, body: object) => jsonWrite<T>(path, "POST", body),
  isAbort: isAbortError,
  onOpenFiles: () => {
    active.value = "files";
  },
  onDirectoryLeave: () => {
    uploadContinuation.value = null;
  },
  onExtracted: (name: string) => {
    fileOperationNotice.value = "已解压「" + name + "」到同名文件夹。";
  },
  captureScrollTop: () =>
    active.value === "files" && !showingTrash.value && typeof window !== "undefined" ? window.scrollY : null,
  restoreScrollTop: (top: number) => {
    void nextTick(() => requestAnimationFrame(() => { if (typeof window !== "undefined") window.scrollTo({ top, behavior: "auto" }); }));
  },
  historyStorageKey: () => fileSearchHistoryKey.value,
});
watch(fileSearchHistoryKey, () => syncSearchHistory(), { immediate: true });
const fileSearchKindLabel = computed(() => FILE_SEARCH_KIND_OPTIONS.find((k) => k.value === fileSearchKind.value)?.label ?? "");
const fileSearchFolderLabel = computed(() => folderLabelOfPath(searchFolderBase.value, sharedRootName.value || "共享根目录"));
async function revealFileFolder(entry: FileEntry) {
  const revealed = await revealEntryFolder(entry);
  if (!revealed) return;
  await nextTick();
  requestAnimationFrame(() => scrollRevealedFileIntoView(revealed));
}
let photosJumpSeq = 0;
const photosJumpTarget = ref<{ view: "similar" | "map" | "people"; seq: number } | null>(null);
function jumpToPhotosView(view: "similar" | "map" | "people") {
  active.value = "photos";
  photosJumpTarget.value = { view, seq: ++photosJumpSeq };
}
function jumpToDuplicates() { active.value = "files"; showingTrash.value = false; showDuplicatesModal.value = true; }
function jumpToTrash() { active.value = "files"; void openTrash(); }
function jumpToSettingsGroup(group: SettingsGroup) { active.value = "settings"; settingsGroup.value = group; }

const {
  trashItems, trashRetention, trashLoading, trashBusy, trashError, trashNotice, showingTrash,
  loadTrash, openTrash, restoreTrash, purgeTrashItem, reset: resetFileTrash,
} = useFileTrash({
  epoch: () => rootContextEpoch.value,
  path: scopedApiPath,
  read: <T>(path: string) => jsonGet<T>(path),
  write: (path: string) => jsonWrite(path, "POST"),
  remove: async (path: string) => {
    const response = await rootFetch(path, {
      method: "DELETE",
      headers: { "X-LightIsle-Request": "1" },
      credentials: "same-origin",
    });
    if (!response.ok) throw await readApiFailure(response);
  },
  refreshFiles: () => loadFiles(),
  isAbort: isAbortError,
  errorLabel: describeUserFacingError,
  confirm: (message: string) => requestConfirm(message),
});
const trashPresentation = computed(() =>
  trashPresentationState({ loading: trashLoading.value, error: trashError.value, entries: trashItems.value }),
);

const {
  selectedUpload, uploadPercent, uploadStage, uploadCurrent,
  uploadTotal, uploadFileName, uploadSize, uploadTransferred, uploadDropActive,
  uploadAutoRenameConflicts, uploadCompleted, uploadResult, uploadFailure,
  uploadBusy, uploadContinuation, canContinueUploads,
  cancelCurrentUpload, cancelAndWaitForUpload, hasActiveUpload, resetUploadsForRoot,
  chooseUploadFiles, startUpload, dragOverUpload, dragLeaveUpload, dropUpload,
  continueIncompleteUploads, closeUploadActivity,
} = useFileUploads({
  username: () => user.value?.username,
  selectedRootID: () => selectedRootID.value,
  selectedRootGeneration: () => selectedRootGeneration.value,
  rootEpoch: () => rootContextEpoch.value,
  multiRoot: () => multiRootMode.value,
  filesPath: () => filesPath.value,
  currentFolderCanWrite: () => currentFolderCanWrite.value,
  filesLoading: () => filesLoading.value,
  showingTrash: () => showingTrash.value,
  searchingFiles: () => searchingFiles.value,
  filesError,
  rootFetch,
  read: <T>(path: string, signal?: AbortSignal) => jsonGet<T>(path, signal),
  write: <T>(path: string, method: "POST" | "PATCH", body: object = {}, signal?: AbortSignal) =>
    jsonWrite<T>(path, method, body, signal),
  loadFiles: () => loadFiles(),
  describeError: describeUserFacingError,
});

const {
  grantUser, grants, grantError, grantNotice, grantPathInput, grantCanWrite, grantBusy,
  fileOperationDialog, fileOperationNotice, newFolderName, trashTarget, fileActionBusy,
  previewItem, previewText, previewError, previewURL,
  showPreviewPlaylist, previewAutoplayNext, previewVideoPlaylist,
  currentPreviewVideoIndex, prevPreviewVideo, nextPreviewVideo,
  previewImagePlaylist, currentPreviewImageIndex, prevPreviewImage, nextPreviewImage,
  onPreviewVideoEnded,
  pathSegments,
  selectedFilesAllWritable, selectedPathsFallback,
  thumbnailKey, thumbnailEligible, fileThumbnailURL, closeFileMenu, markThumbnailFailure,
  canWriteEntry, operateFile, listOperationFolders, commitFileOperation, finishFileOperation,
  editGrants, saveGrant, toggleGrantWrite, removeGrant,
  previewFile, goUp, makeFolder, batchTrash, downloadFile,
  selectFallbackPaths, copySelectedPaths, removeFile, resetFileActionsAndGrantsForRoot,
} = useFileActionsAndGrants({
  userRole: () => user.value?.role,
  selectedRootID: () => selectedRootID.value,
  rootFeatureContextReady: () => rootFeatureContextReady.value,
  rootContextEpoch: () => rootContextEpoch.value,
  currentRootContextKey,
  filesPath,
  sharedRootName,
  currentFolderCanWrite,
  fileDirectoryLoaded,
  fileEntries,
  checkedFiles,
  filesError,
  showingTrash,
  searchingFiles,
  failedThumbnails,
  scopedApiPath,
  scopedMediaPath,
  rootFetch,
  jsonGet,
  jsonWrite,
  loadFiles,
  loadTrash,
  isAbortError,
});

const { stats, error, polling, cpu, usedMemory, usedDisk, diskActivity, update, clear: clearTelemetry, bytes, percent } =
  useHostTelemetry(() => user.value?.role);

const {
  showHardwareSpecs, isAdminDashboard,
  advancedUploadsOpen, advancedDiagnosticsOpen, pendingUploadsOpen,
  pendingMediaOpen, adminPendingMediaOpen,
  togglePendingMedia, togglePendingUploads,
  toggleAdvanced, resetOverviewAndDisclosures,
  overviewIdentity, overviewSearch, overviewTelemetry, overviewPersonalSpace, overviewPending,
} = useOverviewAndDisclosures({
  user, fileSearch, searchViaSpotlight, filesLoading, searchingFiles, recentSearches,
  telemetry: { stats, error, polling, cpu, usedMemory, usedDisk, diskActivity, bytes, percent },
  sharedRoots, rootDiscoveryError, rootDiscoveryState, selectedRoot, taskLoaded, taskLoading, taskError, tasks,
});

const {
  theme, atmosphere, atmospheres, sidebarExpanded, moreMenuOpen, fileViewMode,
  setFileViewMode, createFolderOpen, cycleAtmosphere, switchTheme, toggleSidebar,
} = useShellAppearance();

watch(createFolderOpen, (openState) => {
  if (openState) void nextTick(() => newFolderInputRef.value?.focus());
});

async function submitCreateFolder() {
  if (await makeFolder()) createFolderOpen.value = false;
}

watch(filesPath, () => {
  lastCheckedFileIndex.value = null;
});

watch(moreMenuOpen, (openState) => {
  if (openState) {
    moreMenuLayer?.dispose();
    moreMenuLayer = pushModalLayer({
      onEsc: () => { moreMenuOpen.value = false; },
      lockScroll: true,
    });
  } else {
    moreMenuLayer?.dispose();
    moreMenuLayer = null;
  }
});

function closeOtherFileMenus(except?: HTMLDetailsElement | null) {
  if (typeof document === "undefined") return;
  document.querySelectorAll<HTMLDetailsElement>("details.file-entry-more[open]").forEach((el) => {
    if (el !== except) el.open = false;
  });
}

function onFileMenuToggle(event: Event) {
  const el = event.currentTarget as HTMLDetailsElement | null;
  if (el?.open) closeOtherFileMenus(el);
}

function openFileContextMenu(event: MouseEvent) {
  const row = event.currentTarget as HTMLElement | null;
  const details = row?.querySelector<HTMLDetailsElement>("details.file-entry-more");
  if (!details) return;
  closeOtherFileMenus(details);
  details.open = true;
  void nextTick(() => details.querySelector<HTMLElement>("button")?.focus());
}

function onFileCheckboxClick(entry: FileEntry, index: number, event: MouseEvent) {
  if (event.shiftKey && lastCheckedFileIndex.value !== null && lastCheckedFileIndex.value !== index) {
    const start = Math.min(lastCheckedFileIndex.value, index);
    const end = Math.max(lastCheckedFileIndex.value, index);
    const targetChecked = !checkedFiles.value.includes(entry.path);
    const next = new Set(checkedFiles.value);
    for (let i = start; i <= end; i += 1) {
      const candidate = fileEntries.value[i];
      if (!candidate) continue;
      if (targetChecked) {
        if (next.size < 50) next.add(candidate.path);
      } else {
        next.delete(candidate.path);
      }
    }
    checkedFiles.value = Array.from(next);
    event.preventDefault();
  }
  lastCheckedFileIndex.value = index;
}

function handleShellPointerDown(event: PointerEvent) {
  const target = event.target as HTMLElement | null;
  const insideMenu = target?.closest("details.file-entry-more") as HTMLDetailsElement | null;
  closeOtherFileMenus(insideMenu);
}

function handleShellKeydown(event: KeyboardEvent) {
  if (event.defaultPrevented || hasActiveModalLayer() || !user.value) return;
  const target = event.target as HTMLElement | null;
  if (target?.closest("input, textarea, select, [contenteditable='true']")) return;
  if (active.value === "files" && !showingTrash.value && !filesLoading.value) {
    if (event.key === "Escape") {
      if (checkedFiles.value.length > 0) {
        event.preventDefault();
        checkedFiles.value = [];
        return;
      }
      if (searchingFiles.value) {
        event.preventDefault();
        void clearFileSearch();
        return;
      }
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a" && fileEntries.value.length > 0) {
      event.preventDefault();
      const slice = fileEntries.value.slice(0, 50).map((item) => item.path);
      const allChecked = slice.every((p) => checkedFiles.value.includes(p));
      checkedFiles.value = allChecked ? [] : slice;
    }
  }
}

onMounted(() => {
  window.addEventListener("pointerdown", handleShellPointerDown, true);
  window.addEventListener("keydown", handleShellKeydown);
});

onUnmounted(() => {
  moreMenuLayer?.dispose();
  moreMenuLayer = null;
  window.removeEventListener("pointerdown", handleShellPointerDown, true);
  window.removeEventListener("keydown", handleShellKeydown);
});

function clearClientSessionState(expiredMessage = "") {
  resetPollingTimers();
  resetDiagnostics();
  clearTelemetry();
  clearRuntimeMemoryCache();
  user.value = null;
  resetAccountState();
  resetOverviewAndDisclosures();
  active.value = "overview";
  settingsGroup.value = "account";
  showDuplicatesModal.value = false;
  photosJumpTarget.value = null;
  shareOutcomeWarning.value = false;
  photoBatchOutcomeWarning.value = false;
  moreMenuOpen.value = false;
  createFolderOpen.value = false;
  lastCheckedFileIndex.value = null;
  authPassword.value = "";
  showAuthPassword.value = false;
  resetAllRootControllerState();
  resetRootScopedState();
  currentFolderCanWrite.value = false;
  checkedFiles.value = [];
  resetLoginSessions();
  resetFileShares();
  visitedPages.value = {
    overview: true,
    files: false,
    computer: false,
    photos: false,
    cinema: false,
    downloads: false,
    apps: false,
    automation: false,
    settings: false,
  };
  if (expiredMessage) {
    authError.value = expiredMessage;
  }
}

async function hydrateAuthenticatedSession(role: "admin" | "member") {
  resetPollingTimers();
  void update();
  await Promise.all([
    refreshRootDiscovery(true),
    loadPersonalStoragePolicy(),
    loadComputerFilesStatus(),
  ]);
  await autoRouteSection();
  if (active.value === "files" && !fileDirectoryLoaded.value) await loadFiles();
  if (role === "admin") await loadAccounts();
}

async function checkAuth() {
  authChecking.value = true;
  authServiceError.value = "";
  authError.value = "";
  try {
    const status = await jsonGet<{ configured: boolean }>("/api/v2/auth/status");
    configured.value = status.configured;
    if (status.configured) {
      try {
        const identity = await jsonGet<{ id: number; username: string; role: "admin" | "member" }>("/api/v2/auth/me");
        bindDiagnosticAccount(identity.id);
        user.value = identity;
        await hydrateAuthenticatedSession(identity.role);
      } catch (e) {
        clearClientSessionState();
        if (!(e instanceof Error && (e.message === "HTTP 401" || e.message === "authentication_required"))) {
          authServiceError.value = "无法读取本机账户状态，请确认 LightIsle.app 仍在运行后重试。";
        }
      }
    }
  } catch {
    configured.value = false;
    clearClientSessionState();
    authServiceError.value = "无法连接本机账户服务，请确认 LightIsle.app 已打开并正在运行。";
  } finally {
    authChecking.value = false;
  }
}

async function submitAuth() {
  authError.value = "";
  if (!configured.value) {
    authError.value = "请先打开 Mac 上的 LightIsle.app 完成管理员初始化。";
    return;
  }
  authSubmitting.value = true;
  try {
    const result = await jsonWrite<{ id: number; username: string; role: "admin" | "member" }>(
      "/api/v2/auth/login",
      "POST",
      { username: authUsername.value, password: authPassword.value },
    );
    bindDiagnosticAccount(result.id);
    user.value = result;
    authPassword.value = "";
    await hydrateAuthenticatedSession(result.role);
  } catch (e) {
    const code = e instanceof Error ? e.message : "request_failed";
    authError.value =
      ({
        invalid_credentials: "用户名或密码不正确。请核对 Mac App「设置 → 管理员安全」显示的账号名，确认输入新密码而非浏览器保存的旧密码。",
        too_many_attempts: "登录尝试过多，请稍后再试",
      } as Record<string, string>)[code] ?? describeUserFacingError(e);
  } finally {
    authSubmitting.value = false;
  }
}

async function logout() {
  await cancelAndWaitForUpload();
  try {
    await jsonWrite("/api/v2/auth/logout", "POST");
  } catch {
    await requestAlert("NAS 未能确认会话已撤销，请检查连接后重新退出。");
    return;
  }
  clearClientSessionState();
}

const { resetPollingTimers } = useAppBrowserLifecycle({
  active,
  validPages,
  visitedPages,
  settingsGroup,
  moreMenuOpen,
  manualRootSection,
  personalRouteError,
  hasMyStoragePolicy: () => Boolean(myStoragePolicy.value),
  multiRootMode: () => multiRootMode.value,
  searchingFiles: () => searchingFiles.value,
  fileDirectoryLoaded: () => fileDirectoryLoaded.value,
  isAuthenticated: () => user.value !== null,
  isAdmin: () => user.value?.role === "admin",
  computerFilesAllowed: () => showComputerFilesNav.value,
  computerFilesResolved: () => computerFilesStatus.value !== null,
  rootFeatureContextReady: () => rootFeatureContextReady.value,
  rootDiscoveryLoading: () => rootDiscoveryLoading.value,
  getLastRootDiscoveryAt,
  taskLoading: () => taskLoading.value,
  hasRunningTasks: () => tasks.value.some((task) => task.running),
  rootViewKey: () => rootViewKey.value,
  checkAuth,
  updateHostTelemetry: update,
  reloadTasks,
  refreshTaskCenter,
  refreshRootDiscovery,
  autoRouteSection: (page) => autoRouteSection(page),
  loadFiles: () => loadFiles(),
  onShareOutcomeUncertain: () => {
    shareOutcomeWarning.value = true;
  },
  onPhotoBatchOutcomeUncertain: () => {
    photoBatchOutcomeWarning.value = true;
  },
});
</script>

<template src="./AppShell.html"></template>
