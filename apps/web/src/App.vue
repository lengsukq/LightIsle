<script setup lang="ts">
import { computed, defineAsyncComponent, h, onUnmounted, provide, ref, watch } from "vue";
import {
  ArrowDownToLine, Clapperboard, Download, FileText, Folder, HardDrive, Images,
  LayoutDashboard, LogOut, Monitor, Moon, PanelLeftClose, PanelLeftOpen,
  RefreshCcw, Settings2, Sparkles, Sun, Trash2, WifiOff,
} from "lucide-vue-next";
import { buildFileSearchHistoryKey } from "./features/files/fileSearchUtils.ts";
import { pushModalLayer, type ModalLayerHandle } from "./utils/modalStack.ts";
import { useShellAppearance } from "./styles/useShellAppearance.ts";
import { useHostTelemetry } from "./features/overview/useHostTelemetry.ts";
import { useAccountSessions } from "./features/auth/useAccountSessions.ts";
import { useAccountManagement } from "./features/settings/useAccountManagement.ts";
import { useFileBrowser } from "./features/files/useFileBrowser.ts";
import { useFileUploads } from "./features/files/useFileUploads.ts";
import { useFileShares } from "./features/files/useFileShares.ts";
import { useTaskCenter } from "./features/settings/useTaskCenter.ts";
import { bindDiagnosticAccount, resetDiagnostics } from "./features/settings/betaDiagnostics.ts";
import ConfirmModal from "./components/ui/ConfirmModal.vue";
import AuthScene from "./features/auth/AuthScene.vue";
import MobileNavDrawer from "./components/ui/MobileNavDrawer.vue";
import ThemePickerPopover from "./components/ui/ThemePickerPopover.vue";
import { requestAlert, requestConfirm } from "./composables/useConfirmDialog.ts";
import IsleModal from "./components/ui/IsleModal.vue";
import IsleButton from "./components/ui/IsleButton.vue";
import IsleBanner from "./components/ui/IsleBanner.vue";
import IsleEmpty from "./components/ui/IsleEmpty.vue";
import IsleSlidingIndicator from "./components/ui/IsleSlidingIndicator.vue";
import { useFileMediaLightbox } from "./composables/useFileMediaLightbox.ts";
import type { Movie } from "./features/cinema/cinemaTypes.ts";
import AppleSelect from "./components/ui/AppleSelect.vue";
import { clearRuntimeMemoryCache } from "./features/settings/useIsleCache.ts";
import { describeUserFacingError } from "./api/userFacingError.ts";
import { readApiFailure } from "./api/apiFailure.ts";
import { useFileTrash } from "./features/files/useFileTrash.ts";
import { type ShellPage as Page, type ShellSettingsGroup as SettingsGroup } from "./utils/shellRouteGuard.ts";
import { useFileActionsAndGrants } from "./features/files/useFileActionsAndGrants.ts";
import { useOverviewAndDisclosures } from "./features/overview/useOverviewAndDisclosures.ts";
import { apiFetch, configureApiSessionHandler } from "./api/apiClient.ts";
import { createJsonRootClient } from "./api/jsonRootClient.ts";
import { useRootContextController } from "./composables/useRootContextController.ts";
import { useAppBrowserLifecycle } from "./composables/useAppBrowserLifecycle.ts";
import { useSlidingIndicator } from "./composables/useSlidingIndicator.ts";
import {
  createShellLifecycleBridge,
  FILES_VIEW_CTX,
  SETTINGS_VIEW_CTX,
} from "./contexts/shellContexts.ts";
import { FILE_EXTRAS_CTX, useFileWorkspaceExtras } from "./features/files/fileExtrasContext.ts";

const asyncPageState = (message: string, role: string) => ({
  render: () => h("p", { role, class: "page-status" }, message),
});
const OverviewPage = defineAsyncComponent(() => import("./features/overview/OverviewPage.vue"));
const FilesView = defineAsyncComponent({
  loader: () => import("./features/files/FilesView.vue"),
  loadingComponent: asyncPageState("正在加载文件空间…", "status"),
  errorComponent: asyncPageState("文件页面加载失败，请刷新页面。", "alert"),
  delay: 150,
});
const ComputerFilesView = defineAsyncComponent({
  loader: () => import("./features/files/ComputerFilesView.vue"),
  loadingComponent: asyncPageState("正在加载电脑文件…", "status"),
  errorComponent: asyncPageState("电脑文件页面加载失败，请刷新页面。", "alert"),
  delay: 150,
});
const SettingsView = defineAsyncComponent({
  loader: () => import("./features/settings/SettingsView.vue"),
  loadingComponent: asyncPageState("正在加载偏好设置…", "status"),
  errorComponent: asyncPageState("设置页面加载失败，请刷新页面。", "alert"),
  delay: 150,
});
const AppWorkbenchStage = defineAsyncComponent(() => import("./features/apps/AppWorkbenchStage.vue"));
const DuplicateFilesPanel = defineAsyncComponent(() => import("./features/files/DuplicateFilesPanel.vue"));
const FileOperationDialog = defineAsyncComponent(() => import("./features/files/FileOperationDialog.vue"));
const FileShareModal = defineAsyncComponent(() => import("./features/files/FileShareModal.vue"));
const FileExtrasModals = defineAsyncComponent(() => import("./features/files/FileExtrasModals.vue"));
const PhotoViewerModal = defineAsyncComponent(() => import("./features/photos/PhotoViewerModal.vue"));
const AppsCenterView = defineAsyncComponent(() => import("./features/apps/AppsCenterView.vue"));
const PhotosView = defineAsyncComponent({
  loader: () => import("./features/photos/PhotosView.vue"),
  loadingComponent: asyncPageState("正在加载图库…", "status"),
  errorComponent: asyncPageState("图库资源加载失败，请刷新页面。", "alert"),
  delay: 150,
});
const CinemaView = defineAsyncComponent({
  loader: () => import("./features/cinema/CinemaView.vue"),
  loadingComponent: asyncPageState("正在加载影院…", "status"),
  errorComponent: asyncPageState("影院资源加载失败，请刷新页面。", "alert"),
  delay: 150,
});
const DownloadsView = defineAsyncComponent({
  loader: () => import("./features/downloads/DownloadsView.vue"),
  loadingComponent: asyncPageState("正在加载下载中心…", "status"),
  errorComponent: asyncPageState("下载中心资源加载失败，请刷新页面。", "alert"),
  delay: 150,
});

const items = [
  { key: "overview" as Page, title: "主页概览", shortTitle: "概览", icon: Sparkles, color: "blue", group: "space" },
  { key: "files" as Page, title: "私人文件", shortTitle: "文件", icon: Folder, color: "cyan", group: "space" },
  { key: "computer" as Page, title: "电脑文件", shortTitle: "电脑", icon: Monitor, color: "blue", group: "space" },
  { key: "photos" as Page, title: "时光相册", shortTitle: "相册", icon: Images, color: "pink", group: "space" },
  { key: "cinema" as Page, title: "私人影院", shortTitle: "影院", icon: Clapperboard, color: "orange", group: "space" },
  { key: "downloads" as Page, title: "下载中心", shortTitle: "下载", icon: ArrowDownToLine, color: "cyan", group: "space" },
  { key: "apps" as Page, title: "应用中心", shortTitle: "应用", icon: LayoutDashboard, color: "purple", group: "space" },
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
let moreMenuLayer: ModalLayerHandle | null = null;
let photosJumpSeq = 0;
const photosJumpTarget = ref<{ view: "similar" | "map" | "people"; seq: number } | null>(null);
let cinemaLaunchCounter = 0;
const pendingCinemaLaunch = ref<{ film: Movie; nonce: number } | null>(null);

const shellBridge = createShellLifecycleBridge();

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

function openMatchedCinemaFilm(film: Movie) {
  cinemaLaunchCounter += 1;
  pendingCinemaLaunch.value = { film, nonce: cinemaLaunchCounter };
  visitedPages.value.cinema = true;
  active.value = "cinema";
}
shellBridge.openMatchedCinemaFilm = openMatchedCinemaFilm;

const {
  rootDiscoveryState, myStoragePolicy, personalRouteError, manualRootSection,
  sharedRoots, selectedRootID, rootDiscoveryError, rootDiscoveryLoading,
  rootSwitching, rootContextEpoch, selectedRoot, multiRootMode, selectedRootGeneration,
  rootSelectionValue, rootSelectionOptions, rootViewKey, rootFeatureContextReady,
  rootContextPresentation, scopedApiPath, scopedMediaPath, rootTransport,
  currentRootContextKey, getLastRootDiscoveryAt, resetAllRootControllerState,
  bindPolicyReader, loadPersonalStoragePolicy: loadPersonalStoragePolicyWithReader,
  autoRouteSection, refreshRootDiscovery, handleRootChange,
} = useRootContextController({
  isAuthenticated: () => user.value !== null,
  isAdmin: () => user.value?.role === "admin",
  activeSection: () => active.value,
  isFileDirectoryLoaded: () => shellBridge.isFileDirectoryLoaded(),
  isUploadBusy: () => shellBridge.isUploadBusy(),
  hasActiveUpload: () => shellBridge.hasActiveUpload(),
  cancelAndWaitForUpload: () => shellBridge.cancelAndWaitForUpload(),
  resetRootScopedFeatures: () => shellBridge.resetRootScopedFeatures(),
  loadFiles: (path) => shellBridge.loadFiles(path),
  refreshTaskCenter: () => shellBridge.refreshTaskCenter(),
  loadMyShares: () => shellBridge.loadMyShares(),
  clearClientSessionState: (msg) => shellBridge.clearClientSessionState(msg),
  isAbortError,
});

const rootContextPageVisible = computed(
  () => ["files", "photos", "cinema"].includes(active.value) && rootContextPresentation.value.kind !== "ready",
);
const rootDiscoveryNoticeVisible = computed(
  () => !!rootDiscoveryError.value && rootContextPresentation.value.kind === "ready",
);

const rootFetch = rootTransport.request;
configureApiSessionHandler({
  isAuthenticated: () => user.value !== null,
  onSessionExpired: (msg) => shellBridge.clearClientSessionState(msg),
});
onUnmounted(() => {
  configureApiSessionHandler(null);
});
const { jsonGet, jsonWrite, downloadsApi } = createJsonRootClient({
  rootFetch,
  snapshotEndpoint: rootTransport.snapshot,
  assertSnapshotCurrent: rootTransport.assertCurrent,
  isAuthenticated: () => user.value !== null,
  onSessionExpired: (msg) => shellBridge.clearClientSessionState(msg),
  onRootGenerationChanged: () => { void refreshRootDiscovery(); },
});
bindPolicyReader(jsonGet);
const loadPersonalStoragePolicy = () => loadPersonalStoragePolicyWithReader(jsonGet);

const {
  tasks, taskError, taskLoaded, taskLoading, taskHistory, taskHistoryNextCursor,
  taskHistoryLoading, taskHistoryError,
  reloadTasks, reloadTaskHistory, refreshTaskCenter,
  taskControl, startMediaTask, reset: resetTaskCenter,
} = useTaskCenter({
  role: () => user.value?.role,
  ready: () => rootFeatureContextReady.value,
  activePage: () => active.value,
  getJson: <T>(url: string) => jsonGet<T>(url),
  rootFetch: (url, init) => rootFetch(url, init),
  scopedApiPath: (path) => scopedApiPath(path),
  isAbortError,
});
shellBridge.refreshTaskCenter = refreshTaskCenter;

const {
  accounts, userError,
  currentPassword, nextPassword, repeatPassword, passwordBusy, passwordError,
  newUsername, newPassword, creatingUser, createUserError, createUserNotice,
  lastCreatedMember, clearLastCreatedMember,
  memberActionBusy, memberActionError, memberActionNotice,
  resetTargetUser, resetMemberNewPassword, resetMemberRepeatPassword, resetMemberBusy, resetMemberError,
  computerFilesStatus,
  loadAccounts, loadComputerFilesStatus, createMemberAccount, toggleMemberEnabled,
  openResetMemberPassword, closeResetMemberPassword, submitResetMemberPassword,
  changeOwnPassword, resetAccountState,
} = useAccountManagement({
  isAdmin: () => user.value?.role === "admin",
  read: <T>(path: string) => jsonGet<T>(path),
  write: <T>(path: string, method: "POST" | "PATCH" | "PUT", body?: object) =>
    jsonWrite<T>(path, method, body ?? {}),
  logout: () => shellBridge.logout(),
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
  logoutCurrent: () => shellBridge.logout(),
  onCurrentLogout: () => {
    authError.value = "当前设备已退出，请重新登录。";
  },
  confirm: (message: string) => requestConfirm(message),
  revoke: async (path: string) => {
    const response = await apiFetch(path, { method: "DELETE" });
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
shellBridge.loadMyShares = loadMyShares;

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
  onOpenFiles: () => { active.value = "files"; },
  onDirectoryLeave: () => shellBridge.onDirectoryLeave(),
  onExtracted: (name: string) => shellBridge.onExtracted(name),
  captureScrollTop: () =>
    active.value === "files" && !shellBridge.isShowingTrash() && typeof window !== "undefined" ? window.scrollY : null,
  restoreScrollTop: (top: number) => {
    if (typeof window !== "undefined") requestAnimationFrame(() => window.scrollTo({ top, behavior: "auto" }));
  },
  historyStorageKey: () => fileSearchHistoryKey.value,
});
watch(fileSearchHistoryKey, () => syncSearchHistory(), { immediate: true });
shellBridge.isFileDirectoryLoaded = () => fileDirectoryLoaded.value;
shellBridge.loadFiles = loadFiles;

function jumpToPhotosView(view: "similar" | "map" | "people") {
  active.value = "photos";
  photosJumpTarget.value = { view, seq: ++photosJumpSeq };
}
function jumpToDuplicates() { active.value = "files"; showingTrash.value = false; showDuplicatesModal.value = true; }
function jumpToTrash() { active.value = "files"; void openTrash(); }
function jumpToSettingsGroup(group: SettingsGroup) { active.value = "settings"; settingsGroup.value = group; }

const {
  trashItems, trashRetention, trashRetentionError, trashLoading, trashBusy, trashError, trashNotice, showingTrash,
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
shellBridge.isShowingTrash = () => showingTrash.value;

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
shellBridge.isUploadBusy = () => uploadBusy.value;
shellBridge.hasActiveUpload = hasActiveUpload;
shellBridge.cancelAndWaitForUpload = cancelAndWaitForUpload;
shellBridge.onDirectoryLeave = () => { uploadContinuation.value = null; };

const {
  grantUser, grants, grantError, grantNotice, grantPathInput, grantCanWrite, grantBusy,
  fileOperationDialog, fileOperationNotice, newFolderName, trashTarget, fileActionBusy,
  previewItem, previewText, previewError, previewURL,
  fileMediaAssets, fileMediaSelected, fileMediaIndex, showFileMediaAt, closeFileMedia, fileEntryForMediaAsset,
  pathSegments, selectedFilesAllWritable, selectedPathsFallback,
  thumbnailKey, thumbnailEligible, fileThumbnailURL, closeFileMenu, markThumbnailFailure,
  canWriteEntry, operateFile, operateBatchMove, listOperationFolders, commitFileOperation, finishFileOperation,
  editGrants, saveGrant, toggleGrantWrite, removeGrant,
  previewFile, goUp, makeFolder, batchTrash, downloadFile, batchDownloadSelected,
  selectFallbackPaths, copySelectedPaths, removeFile, resetFileActionsAndGrantsForRoot,
} = useFileActionsAndGrants({
  userRole: () => user.value?.role, selectedRootID: () => selectedRootID.value,
  rootFeatureContextReady: () => rootFeatureContextReady.value, rootContextEpoch: () => rootContextEpoch.value,
  currentRootContextKey, filesPath, sharedRootName, currentFolderCanWrite, fileDirectoryLoaded, fileEntries,
  checkedFiles, filesError, showingTrash, searchingFiles, failedThumbnails,
  scopedApiPath, scopedMediaPath, rootFetch, jsonGet, jsonWrite, loadFiles, loadTrash, isAbortError,
  onCinemaFilmMatched: (film) => shellBridge.openMatchedCinemaFilm(film),
});
const { extrasContext: fileExtras, resetAllExtras: resetFileExtras } = useFileWorkspaceExtras({
  canList: () => user.value !== null && rootFeatureContextReady.value,
  context: () => `${user.value?.username ?? ""}:${rootContextEpoch.value}:${selectedRootID.value}:${selectedRootGeneration.value}`,
  filesPath,
  scopedApiPath,
  scopedMediaPath,
  rootFetch,
  jsonGet,
  jsonWrite,
  loadFiles,
  revealEntryFolder,
  legacyPreviewFile: previewFile,
  isAbortError,
});

shellBridge.onExtracted = (name: string) => { fileOperationNotice.value = "已解压「" + name + "」到同名文件夹。"; };
shellBridge.resetRootScopedFeatures = () => {
  resetFileTrash();
  resetFileBrowser();
  resetFileActionsAndGrantsForRoot();
  resetFileShares();
  resetFileExtras();
  resetTaskCenter();
  resetUploadsForRoot();
};

const { modalProps: fileMediaModalProps, modalEvents: fileMediaModalEvents } = useFileMediaLightbox({
  active: () => active.value === "files", isAdmin: () => user.value?.role === "admin",
  selected: fileMediaSelected, assets: fileMediaAssets, selectedIndex: fileMediaIndex,
  showAt: showFileMediaAt, close: closeFileMedia, scopedMediaPath, fileEntryForMediaAsset, downloadFile,
});

const { stats, error, polling, cpu, usedMemory, usedDisk, diskActivity, update, clear: clearTelemetry, bytes, percent } =
  useHostTelemetry(() => user.value?.role);

const {
  showHardwareSpecs,
  advancedDiagnosticsOpen, automationDisclosureOpen,
  pendingMediaOpen, adminPendingMediaOpen,
  togglePendingMedia,
  toggleAdvanced, resetOverviewAndDisclosures, refreshOverviewApps,
  pendingAppLaunch, openHomeApp, clearPendingAppLaunch, homeWorkbenchStageProps, homeWorkbenchStageEvents,
  overviewIdentity, overviewSearch, overviewTelemetry, overviewPersonalSpace, overviewApps, overviewPending,
} = useOverviewAndDisclosures({
  user, activePage: active, fileSearch, searchViaSpotlight, filesLoading, searchingFiles, recentSearches,
  telemetry: { stats, error, polling, cpu, usedMemory, usedDisk, diskActivity, bytes, percent },
  sharedRoots, rootDiscoveryError, rootDiscoveryState, selectedRoot, taskLoaded, taskLoading, taskError, tasks,
});

const {
  theme, atmosphere, atmospheres, sidebarExpanded, moreMenuOpen, fileViewMode,
  setFileViewMode, createFolderOpen, setAtmosphere, switchTheme, toggleSidebar,
} = useShellAppearance();

const spaceNavRef = ref<HTMLElement | null>(null);
const systemNavRef = ref<HTMLElement | null>(null);
const { indicatorStyle: spaceNavIndicatorStyle, indicatorReady: spaceNavIndicatorReady } = useSlidingIndicator({
  containerRef: spaceNavRef,
  activeSelector: "button.chosen",
  watchSources: [active, sidebarExpanded, showComputerFilesNav, () => user.value?.role],
});
const { indicatorStyle: systemNavIndicatorStyle, indicatorReady: systemNavIndicatorReady } = useSlidingIndicator({
  containerRef: systemNavRef,
  activeSelector: "button.chosen",
  watchSources: [active, sidebarExpanded, () => user.value?.role],
});

const stageEntering = ref(false);
let stageEnterTimer = 0;
watch(active, () => {
  stageEntering.value = true;
  if (typeof window !== "undefined") {
    if (stageEnterTimer) window.clearTimeout(stageEnterTimer);
    stageEnterTimer = window.setTimeout(() => {
      stageEntering.value = false;
      stageEnterTimer = 0;
    }, 240);
  }
});
onUnmounted(() => {
  if (typeof window !== "undefined" && stageEnterTimer) {
    window.clearTimeout(stageEnterTimer);
    stageEnterTimer = 0;
  }
});

watch([active, settingsGroup, () => user.value, rootFeatureContextReady], () => {
  if (!user.value) return;
  if (active.value === "automation" && user.value.role === "admin") {
    active.value = "settings";
    settingsGroup.value = "ops";
    automationDisclosureOpen.value = true;
    return;
  }
  if (active.value !== "settings") return;
  if (settingsGroup.value === "account" && !sessionsLoaded.value && !sessionsLoading.value) {
    void loadLoginSessions();
  } else if (settingsGroup.value === "files" && rootFeatureContextReady.value && !sharesLoaded.value && !sharesLoading.value) {
    void loadMyShares();
  } else if ((settingsGroup.value === "storage" || settingsGroup.value === "ops") && user.value.role === "admin" && !accounts.value.length) {
    void loadAccounts();
  }
}, { immediate: true });

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

onUnmounted(() => {
  moreMenuLayer?.dispose();
  moreMenuLayer = null;
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
  pendingCinemaLaunch.value = null;
  closeFileMedia();
  shareOutcomeWarning.value = false;
  photoBatchOutcomeWarning.value = false;
  moreMenuOpen.value = false;
  createFolderOpen.value = false;
  authPassword.value = "";
  showAuthPassword.value = false;
  resetAllRootControllerState();
  shellBridge.resetRootScopedFeatures();
  currentFolderCanWrite.value = false;
  checkedFiles.value = [];
  resetLoginSessions();
  resetFileShares();
  resetFileExtras();
  visitedPages.value = {
    overview: true, files: false, computer: false, photos: false, cinema: false,
    downloads: false, apps: false, automation: false, settings: false,
  };
  if (expiredMessage) authError.value = expiredMessage;
}
shellBridge.clearClientSessionState = clearClientSessionState;

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
        invalid_credentials: "用户名或密码不正确。请核对 Mac App「设置 → 账号与安全」显示的账号名，确认输入新密码而非浏览器保存的旧密码。",
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
shellBridge.logout = logout;

provide(FILES_VIEW_CTX, {
  active, user, filesPath, currentFolderCanWrite, fileDirectoryLoaded, sharedRootName,
  fileEntries, fileNextCursor, fileSortKey, fileSortDirection, failedThumbnails,
  fileSearch, lastExecutedQuery, fileSearchKind, fileSearchScope, searchFolderBase,
  searchViaSpotlight, searchingFiles, searchTruncated, recentSearches,
  revealedFilePath, revealingFilePath, checkedFiles, filesLoading, extracting, filesError,
  fileViewMode, createFolderOpen, newFolderName, fileActionBusy, fileOperationNotice,
  trashTarget, showDuplicatesModal, selectedFilesAllWritable, selectedPathsFallback, pathSegments,
  showingTrash, trashItems, trashRetention, trashRetentionError, trashLoading, trashBusy,
  trashError, trashNotice, selectedUpload, uploadPercent, uploadStage, uploadCurrent,
  uploadTotal, uploadFileName, uploadSize, uploadTransferred, uploadDropActive,
  uploadAutoRenameConflicts, uploadCompleted, uploadResult, uploadFailure, uploadBusy,
  uploadContinuation, canContinueUploads, bytes, setFileViewMode, loadFiles, runFileSearch,
  selectSearchKind, setSearchScope, applyRecentSearch, deleteRecentSearch, clearRecentSearches,
  clearFileSearch, revealEntryFolder, extractZip, loadTrash, openTrash, restoreTrash,
  purgeTrashItem, chooseUploadFiles, startUpload, dragOverUpload, dragLeaveUpload, dropUpload,
  cancelCurrentUpload, continueIncompleteUploads, closeUploadActivity, thumbnailKey,
  thumbnailEligible, fileThumbnailURL, closeFileMenu, markThumbnailFailure, canWriteEntry,
  operateFile, operateBatchMove, previewFile, goUp, makeFolder, batchTrash, downloadFile,
  batchDownloadSelected, selectFallbackPaths, copySelectedPaths, openShareDialog,
  jumpToSettingsGroup,
});
provide(FILE_EXTRAS_CTX, fileExtras);

provide(SETTINGS_VIEW_CTX, {
  active, settingsGroup, user, sharedRoots, selectedRootID, selectedRoot,
  selectedRootGeneration, multiRootMode, rootViewKey, rootDiscoveryState, rootDiscoveryError,
  rootFeatureContextReady, accounts, userError, currentPassword, nextPassword, repeatPassword,
  passwordBusy, passwordError, newUsername, newPassword, creatingUser, createUserError,
  createUserNotice, lastCreatedMember, clearLastCreatedMember, memberActionBusy,
  memberActionError, memberActionNotice, resetTargetUser, resetMemberNewPassword,
  resetMemberRepeatPassword, resetMemberBusy, resetMemberError, loadAccounts,
  createMemberAccount, toggleMemberEnabled, openResetMemberPassword, closeResetMemberPassword,
  submitResetMemberPassword, changeOwnPassword, grantUser, grants, grantError, grantNotice,
  grantPathInput, grantCanWrite, grantBusy, editGrants, saveGrant, toggleGrantWrite, removeGrant,
  loginSessions, sessionsLoading, sessionsLoaded, sessionsTruncated, sessionsError,
  sessionsMessage, loadLoginSessions, revokeLoginSession, activeShares, sharesLoading,
  sharesError, sharesLoaded, loadMyShares, revokeFileShare, tasks, taskError, taskHistory,
  taskHistoryError, taskHistoryLoading, taskHistoryNextCursor, refreshTaskCenter, taskControl,
  startMediaTask, reloadTaskHistory, advancedDiagnosticsOpen, automationDisclosureOpen,
  pendingMediaOpen, adminPendingMediaOpen, togglePendingMedia, toggleAdvanced, logout,
});

const { resetPollingTimers } = useAppBrowserLifecycle({
  active, validPages, visitedPages, settingsGroup, moreMenuOpen,
  manualRootSection, personalRouteError,
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
  onShareOutcomeUncertain: () => { shareOutcomeWarning.value = true; },
  onPhotoBatchOutcomeUncertain: () => { photoBatchOutcomeWarning.value = true; },
});
</script>

<template src="./AppShell.html"></template>
