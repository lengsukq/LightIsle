<script setup lang="ts">
import { computed, defineAsyncComponent, h, onMounted, onUnmounted, ref, watch } from "vue";
import {
  Activity, ArrowDownToLine, ArrowUpRight, Clapperboard, CloudOff,
  Folder, HardDrive, Images, LayoutDashboard, Moon, Monitor,
  RefreshCcw, Server, Settings2, ShieldCheck, Sun, WifiOff, FileText, FolderPlus,
  UploadCloud, ChevronRight, ChevronLeft, Download, Trash2, CopyCheck,
  Search, LogOut, Sparkles, Laptop, Workflow, LayoutGrid, List, MoreHorizontal, X
} from "lucide-vue-next";
import { useShellAppearance } from "./useShellAppearance.ts";
import { useHostTelemetry } from "./useHostTelemetry.ts";
import { useAccountSessions } from "./useAccountSessions.ts";
import AgentConnections from "./AgentConnections.vue";
import { useAccountManagement } from "./useAccountManagement.ts";
import { useFileBrowser } from "./useFileBrowser.ts";
import { useFileUploads } from "./useFileUploads.ts";
import { useFileShares, type SharedFileEntry } from "./useFileShares.ts";
import { useTaskCenter, type BackendTask, type TaskRun } from "./useTaskCenter.ts";
// Heavy media libraries are requested only when their pages are opened.
// Keep an accessible loading/error state instead of rendering a blank page.
const asyncPageState = (message: string, role: string) => ({
  render: () => h("p", { role, class: "page-status" }, message),
});
const AutomationView = defineAsyncComponent(()=>import("./AutomationView.vue"));
const AppsCenterView = defineAsyncComponent(()=>import("./AppsCenterView.vue"));
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
import UploadMaintenance from "./UploadMaintenance.vue";
import PendingMedia from "./PendingMedia.vue";
import DiskManagement from "./DiskManagement.vue";
import SmbManagement from "./SmbManagement.vue";
import UserStoragePanel from "./UserStoragePanel.vue";
import DuplicateFilesPanel from "./DuplicateFilesPanel.vue";
import DavAccess from "./DavAccess.vue";
import BetaDiagnosticReport from "./BetaDiagnosticReport.vue";
import { bindDiagnosticAccount, resetDiagnostics } from "./betaDiagnostics.ts";
import ConfirmModal from "./ConfirmModal.vue";
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
import { clearRuntimeMemoryCache, installImageResourceObserver } from "./useIsleCache.ts";
import { apiFetch } from "./apiClient.ts";
import PendingReservations from "./PendingReservations.vue";
import ComputerFilesView from "./ComputerFilesView.vue";
import UploadCleanupRules from "./UploadCleanupRules.vue";
import { rootApiPath, rootMediaPath } from "./rootApi.ts";
import { createRootRequestTransport, rootContextKey } from "./rootRequestTransport.ts";
import { chooseDiscoveredRoot, describeRootContext, describeRootOperationFailure, readRootDiscoveryResponse, rootDiscoveryNetworkError } from "./rootDiscovery.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { apiErrorFromResponse, readApiFailure } from "./apiFailure.ts";
import { routePersonalCategory } from "./personalStorageRouting.ts";
import { createRootContextLifecycle } from "./rootContextLifecycle.ts";
import { useFileTrash, type FileTrashEntry } from "./useFileTrash.ts";
import { useFileActionsAndGrants } from "./useFileActionsAndGrants.ts";
import { useOverviewAndDisclosures } from "./useOverviewAndDisclosures.ts";

type SharedRoot = {rootID:string;name:string;generation:number;online:boolean;isDefault?:boolean};
type RootDiscoveryState = "unknown"|"multi"|"error";
const ROOT_SELECTION_STORAGE_KEY="lightisle_root_choice_v2";
const rootDiscoveryState=ref<RootDiscoveryState>("unknown");
type MyLocation={category:string;rootID:string;rootGeneration:number;relativePath:string};
const myStoragePolicy=ref<{locations:MyLocation[]}|null>(null);
const personalRouteError=ref("");
const manualRootSection=ref("");
const sharedRoots=ref<SharedRoot[]>([]);
const selectedRootID=ref("");
const selectedRootSnapshot=ref<SharedRoot|null>(null);
const rootDiscoveryError=ref("");
const rootDiscoveryLoading=ref(false);
const rootSwitching=ref(false);
const rootLifecycle=createRootContextLifecycle();
const rootContextEpoch=ref(rootLifecycle.epoch);
let lastRootDiscoveryAt=0;
const selectedRoot=computed(()=>selectedRootSnapshot.value);
const multiRootMode=computed(()=>rootDiscoveryState.value==="multi");
const selectedRootGeneration=computed(()=>selectedRoot.value?.generation??0);
const rootSelectionValue=computed(()=>selectedRootID.value);
const rootSelectionOptions=computed(()=>sharedRoots.value.map(root=>({
  value:root.rootID,label:root.name+(root.isDefault?" · 默认":""),hint:root.online?undefined:"离线",
})));
const fileSortKeyOptions=[{value:"name",label:"名称"},{value:"mtime",label:"修改时间"},{value:"size",label:"文件大小"}];
const fileSortDirectionOptions=[{value:"asc",label:"升序"},{value:"desc",label:"降序"}];
const shareHourOptions=[{value:1,label:"1 小时"},{value:6,label:"6 小时"},{value:24,label:"1 天"},{value:72,label:"3 天"},{value:168,label:"7 天"}];
const rootViewKey=computed(()=>`${selectedRootID.value}:${selectedRootGeneration.value}`);
const rootFeatureContextReady=computed(()=>multiRootMode.value&&!!selectedRoot.value);
const rootContextPresentation=computed(()=>describeRootContext({
  state:rootDiscoveryState.value,error:rootDiscoveryError.value,hasContext:rootFeatureContextReady.value,
  rootCount:sharedRoots.value.length,selectedRoot:selectedRoot.value
}));
const rootContextPageVisible=computed(()=>["files","photos","cinema"].includes(active.value)&&rootContextPresentation.value.kind!=="ready");
const rootDiscoveryNoticeVisible=computed(()=>!!rootDiscoveryError.value&&rootContextPresentation.value.kind==="ready");
const authChecking = ref(true);
const configured = ref(false);
const authServiceError = ref("");
const user = ref<{username:string;role:"admin"|"member"}|null>(null);
const authUsername = ref("");
const authPassword = ref("");
const authError = ref("");
const authSubmitting = ref(false);
const showDuplicatesModal = ref(false);
const shareOutcomeWarning = ref(false);
function handleShareOutcomeUncertain(){shareOutcomeWarning.value=true}
const photoBatchOutcomeWarning = ref(false);
function handlePhotoBatchOutcomeUncertain(){photoBatchOutcomeWarning.value=true}
const {
  tasks, taskError, taskLoaded, taskLoading, taskHistory, taskHistoryNextCursor,
  taskHistoryLoading, taskHistoryError,
  reloadTasks, reloadTaskHistory, refreshTaskCenter,
  refreshLatestTaskHistory, taskControl, startMediaTask,
  reset: resetTaskCenter,
} = useTaskCenter({
  role: () => user.value?.role,
  ready: () => rootFeatureContextReady.value,
  activePage: () => active.value,
  getJson: <T>(url: string) => jsonGet<T>(url),
  rootFetch: (url, init) => rootFetch(url, init),
  scopedApiPath: (path) => scopedApiPath(path),
  isAbortError: (error) => isAbortError(error),
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
  onCurrentLogout: () => { authError.value = "当前设备已退出，请重新登录。"; },
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
type FileEntry = SharedFileEntry;
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
type SettingsGroup="account"|"files"|"cache"|"storage"|"ops";
const settingsGroup=ref<SettingsGroup>("account");
const settingsGroups=computed(()=>{
  const admin=user.value?.role==="admin";
  const options: Array<{key:SettingsGroup,label:string}> = [{key:"account",label:"账号与安全"},{key:"files",label:"文件与分享"},{key:"cache",label:"缓存管理"}];
  if(admin){options.push({key:"storage",label:"存储与磁盘"},{key:"ops",label:"任务与通知"});}
  return options;
});
watch(settingsGroup,group=>{
  if(active.value!=="settings")return;
  const url=new URL(window.location.href);
  url.searchParams.set("group",group);
  window.history.replaceState(null,"",url.toString());
});
const {
  filesPath, currentFolderCanWrite, fileDirectoryLoaded, sharedRootName, fileEntries, fileNextCursor,
  fileSortKey, fileSortDirection, failedThumbnails, fileSearch, fileSearchKind,
  searchViaSpotlight, searchingFiles, searchTruncated, checkedFiles,
  filesLoading, filesError, loadFiles, runFileSearch, extractZip, reset: resetFileBrowser,
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
  onDirectoryLeave: () => { uploadContinuation.value = null; },
});
function scopedApiPath(path:string){
  if(rootDiscoveryState.value!=="multi"||!selectedRootID.value)return "";
  return rootApiPath(selectedRootID.value,path);
}
function scopedMediaPath(path:string){
  if(rootDiscoveryState.value!=="multi"||!selectedRootID.value)return "";
  return rootMediaPath(selectedRootID.value,selectedRootGeneration.value,path);
}
function isAbortError(error:unknown){return error instanceof Error&&error.name==="AbortError";}
// The download center is daemon-wide; reuse rootTransport + apiFetch so CSRF,
// same-origin credentials, and 401 session expiry handling stay unified.
async function downloadsApi(path:string,init:RequestInit={}):Promise<unknown>{
  const response=await rootFetch(path,init);
  if(!response.ok){
    if(response.status===401&&user.value!==null){
      clearClientSessionState("登录状态已失效，请重新登录。");
    }
    throw await readApiFailure(response);
  }
  return response.json();
}
function rootRequestContext(){return {
  rootID:selectedRootID.value,generation:selectedRootGeneration.value,epoch:rootContextEpoch.value,
  multiRoot:multiRootMode.value,legacySelected:false,
  discoveryState:rootDiscoveryState.value,switching:rootSwitching.value,
  signal:rootLifecycle.signal
};}
const rootTransport=createRootRequestTransport({
  getContext:rootRequestContext,
  onGenerationChanged:()=>{void refreshRootDiscovery();},
  fetcher:(endpoint,init)=>apiFetch(endpoint,init),
});
const rootRequestSnapshot=rootTransport.snapshot;
const assertRootRequestCurrent=rootTransport.assertCurrent;
const rootFetch=rootTransport.request;
function currentRootContextKey(){return rootContextKey(rootRequestContext());}
function resetRootScopedState(){
  resetFileTrash();
  resetFileBrowser();
  resetFileActionsAndGrantsForRoot();
  resetFileShares();
  resetTaskCenter();
  resetUploadsForRoot();
}
async function switchRoot(rootID:string,force=false,skipInitialFilesLoad=false){
  if(!multiRootMode.value||rootSwitching.value)return;
  const target=sharedRoots.value.find(root=>root.rootID===rootID)??null;
  if(!target)return;
  rootDiscoveryError.value="";
  if(!force&&target.rootID===selectedRootID.value&&target.generation===selectedRoot.value?.generation){selectedRootSnapshot.value=target;return;}
  rootLifecycle.invalidateDiscovery();
  rootDiscoveryLoading.value=false;
  rootSwitching.value=true;
  rootContextEpoch.value=rootLifecycle.invalidate();
  resetRootScopedState();
  const switchEpoch=rootContextEpoch.value;
  await cancelAndWaitForUpload();
  if(switchEpoch!==rootContextEpoch.value||!user.value){rootSwitching.value=false;return;}
  selectedRootID.value=target?.rootID??"";
  selectedRootSnapshot.value=target;
  try{sessionStorage.setItem(ROOT_SELECTION_STORAGE_KEY,target.rootID);}catch{}
  rootSwitching.value=false;
  if(active.value==="files"&&!skipInitialFilesLoad)void loadFiles(".");
  if(active.value==="settings"&&user.value?.role==="admin")void refreshTaskCenter();
  if(active.value==="settings")void loadMyShares();
}
async function loadPersonalStoragePolicy(){
  if(!user.value)return;
  try{
    const data=await jsonGet<{locations:MyLocation[]}>("/api/v2/me/storage");
    myStoragePolicy.value={locations:Array.isArray(data.locations)?data.locations:[]};
    personalRouteError.value="";
  }catch(error){
    myStoragePolicy.value=null;
    personalRouteError.value="无法确认个人硬盘配置："+describeRootOperationFailure(error)+"。请重试，不会自动使用其他硬盘。";
  }
}
async function autoRouteSection(section=active.value){
  if(!user.value||!multiRootMode.value||!["files","photos","cinema"].includes(section)||manualRootSection.value===section)return;
  if(!myStoragePolicy.value){
    if(!personalRouteError.value)personalRouteError.value="个人存储配置尚未读取，无法自动选择硬盘。";
    return;
  }
  const match=routePersonalCategory(myStoragePolicy.value,sharedRoots.value,section);
  if(match.kind==="offline"){
    personalRouteError.value="该分类绑定的硬盘已离线或发生更换。请重新连接原硬盘，或在 Mac 管理端移除登记后手动重建。不会自动改写到其他盘。";
    return;
  }
  personalRouteError.value="";
  if(match.kind==="shared"){
    const defaultRoot=sharedRoots.value.find(root=>root.isDefault&&root.online);
    if(!defaultRoot){
      personalRouteError.value="尚未配置在线的默认 NAS 存储。请先在 Mac 上设定默认根。";
      return;
    }
    if(selectedRootID.value!==defaultRoot.rootID)await switchRoot(defaultRoot.rootID);
    if(section==="files"&&active.value==="files"&&!fileDirectoryLoaded.value)await loadFiles(".");
    return;
  }
  if(uploadBusy.value||hasActiveUpload()){
    personalRouteError.value="当前上传尚未完成。请先完成或取消上传，再切换到这个个人目录。";
    return;
  }
  if(selectedRootID.value!==match.rootID){await switchRoot(match.rootID,false,section==="files");}
  if(section==="files"&&active.value==="files"&&!rootSwitching.value&&selectedRootID.value===match.rootID&&!fileDirectoryLoaded.value){
    await loadFiles(match.path);
  }
}
async function refreshRootDiscovery(skipPolicyRefresh=false){
  if(rootSwitching.value)return;
  const request=rootLifecycle.beginDiscovery();
  lastRootDiscoveryAt=Date.now();
  rootDiscoveryLoading.value=true;
  try{
    const response=await apiFetch("/api/v2/roots");
    if(response.status===401&&user.value!==null){
      clearClientSessionState("登录状态已失效，请重新登录。");
      return;
    }
    if(!rootLifecycle.isCurrentDiscovery(request)||rootSwitching.value)return;
    const discovery=await readRootDiscoveryResponse(response);
    if(!rootLifecycle.isCurrentDiscovery(request)||rootSwitching.value)return;
    if(discovery.kind==="error"){
      rootDiscoveryError.value=discovery.message;
      if(rootDiscoveryState.value!=="multi")rootDiscoveryState.value="error";
      console.warn("root discovery failed",discovery.message);
      return;
    }
    const result=discovery;
    const wasMulti=multiRootMode.value;
    const previous=selectedRoot.value;
    sharedRoots.value=Array.isArray(result.roots)?result.roots.filter(root=>typeof root.rootID==="string"&&Number.isSafeInteger(root.generation)&&root.generation>0):[];
    rootDiscoveryState.value="multi";rootDiscoveryError.value="";
    let preferred="";
    try{preferred=sessionStorage.getItem(ROOT_SELECTION_STORAGE_KEY)??"";}catch{}
    const choice=chooseDiscoveredRoot({
      roots:sharedRoots.value,
      selectedRootID:selectedRootID.value,
      legacySelected:false,
      preferredRootID:preferred,
      previousRoot:previous,
      wasMulti,
    });
    if(choice.kind==="root"){
      await switchRoot(choice.rootID,choice.force);
      if(!skipPolicyRefresh&&user.value){
        await loadPersonalStoragePolicy();
        if(["files","photos","cinema"].includes(active.value))await autoRouteSection(active.value);
      }
      return;
    }
    if(choice.kind==="missing"){
      // Do not automatically route a member's files to another disk when
      // their explicitly selected physical root disappears.
      rootDiscoveryError.value="之前选择的硬盘已移除或不可见。请重新连接原硬盘，或者明确选择其他共享目录。";
      if(previous?.online!==false){
        rootContextEpoch.value=rootLifecycle.invalidate();
        resetRootScopedState();
        await cancelAndWaitForUpload();
      }
      if(!rootLifecycle.isCurrentDiscovery(request))return;
      selectedRootSnapshot.value=previous?{...previous,online:false}:null;
      return;
    }
    if(choice.kind==="reset"){
      rootContextEpoch.value=rootLifecycle.invalidate();
      resetRootScopedState();
    }
  }catch(error){
    if(!rootLifecycle.isCurrentDiscovery(request))return;
    rootDiscoveryError.value=rootDiscoveryNetworkError(error);
    if(rootDiscoveryState.value!=="multi")rootDiscoveryState.value="error";
    if(!isAbortError(error))console.warn("root discovery failed",error);
  }finally{
    if(rootLifecycle.isCurrentDiscovery(request))rootDiscoveryLoading.value=false;
  }
}
type TrashEntry = FileTrashEntry;
const {
  trashItems, trashRetention, trashLoading, trashError, showingTrash,
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
const trashPresentation=computed(()=>trashPresentationState({loading:trashLoading.value,error:trashError.value,entries:trashItems.value}));
const {
  selectedUpload, uploadProgress, uploadPercent, uploadStage, uploadCurrent,
  uploadTotal, uploadFileName, uploadSize, uploadTransferred, uploadDropActive,
  uploadAutoRenameConflicts, uploadCompleted, uploadResult, uploadFailure,
  uploadBusy, uploadContinuation, currentUploadContext, canContinueUploads,
  cancelCurrentUpload, cancelAndWaitForUpload, hasActiveUpload, resetUploadsForRoot,
  chooseUploadFiles, startUpload, dragOverUpload, dragLeaveUpload, dropUpload,
  enqueueUploads, continueIncompleteUploads, closeUploadActivity,
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
  fileOperationDialog, fileOperationNotice, newFolderName, trashTarget,
  previewItem, previewText, previewError, previewURL,
  showPreviewPlaylist, previewAutoplayNext, previewVideoPlaylist,
  currentPreviewVideoIndex, prevPreviewVideo, nextPreviewVideo,
  isPreviewImage, previewImagePlaylist, currentPreviewImageIndex, prevPreviewImage, nextPreviewImage,
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
function clearClientSessionState(expiredMessage = "") {
  resetDiagnostics();
  rootContextEpoch.value = rootLifecycle.invalidate();
  clearTelemetry();
  clearRuntimeMemoryCache();
  user.value = null;
  resetAccountState();
  active.value = "overview";
  myStoragePolicy.value = null;
  personalRouteError.value = "";
  manualRootSection.value = "";
  rootLifecycle.invalidateDiscovery();
  rootSwitching.value = false;
  rootDiscoveryState.value = "unknown";
  sharedRoots.value = [];
  selectedRootID.value = "";
  selectedRootSnapshot.value = null;
  rootDiscoveryError.value = "";
  lastRootDiscoveryAt = 0;
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
async function jsonGet<T>(endpoint:string,signal?:AbortSignal):Promise<T> {
  const snapshot=rootRequestSnapshot(endpoint);
  const response=await rootFetch(endpoint,{cache:"no-store",credentials:"same-origin",signal});
  if (!response.ok) {
    if(response.status===401&&user.value!==null&&endpoint!=="/api/v2/auth/me"){
      clearClientSessionState("登录状态已失效，请重新登录。");
    }
    const result=await response.json().catch(()=>({})) as {error?:string};
    assertRootRequestCurrent(snapshot);
    if(snapshot&&result.error==="root_generation_changed"){
      void refreshRootDiscovery();
      throw new Error("共享目录已变化，请刷新根列表后重新选择。");
    }
    throw apiErrorFromResponse(response,result);
  }
  const result=await response.json() as T;
  assertRootRequestCurrent(snapshot);
  return result;
}
async function jsonWrite<T>(endpoint:string,method:"POST"|"PATCH"|"PUT"|"DELETE",body:object = {},signal?:AbortSignal):Promise<T> {
  const snapshot=rootRequestSnapshot(endpoint);
  const response=await rootFetch(endpoint,{
    method,credentials:"same-origin",
    headers:{"Content-Type":"application/json","X-LightIsle-Request":"1"},
    body:JSON.stringify(body),signal
  });
  if (!response.ok) {
    if(response.status===401&&user.value!==null&&endpoint!=="/api/v2/auth/logout"&&endpoint!=="/api/v2/auth/login"){
      clearClientSessionState("登录状态已失效，请重新登录。");
    }
    const result=await response.json().catch(()=>({error:"request_failed"})) as {error?:string};
    assertRootRequestCurrent(snapshot);
    if(snapshot&&result.error==="root_generation_changed"){
      void refreshRootDiscovery();
      throw new Error("共享目录已变化，请刷新根列表后重新选择。");
    }
    throw apiErrorFromResponse(response,result);
  }
  const result=await response.json() as T;
  assertRootRequestCurrent(snapshot);
  return result;
}
async function checkAuth(){
  authChecking.value=true;
  authServiceError.value="";
  authError.value="";
  try {
    const status=await jsonGet<{configured:boolean}>("/api/v2/auth/status");
    configured.value=status.configured;
    if(status.configured){
      try {
        const identity=await jsonGet<{id:number;username:string;role:"admin"|"member"}>("/api/v2/auth/me");
        bindDiagnosticAccount(identity.id);
        user.value=identity;
        await refreshRootDiscovery(true);
        await loadPersonalStoragePolicy();
        void loadComputerFilesStatus();
        await autoRouteSection();
        if(active.value==="files"&&!fileDirectoryLoaded.value) await loadFiles();
        if(identity.role==="admin") await loadAccounts();
      } catch(e) {
        clearClientSessionState();
        if(!(e instanceof Error&&(e.message==="HTTP 401"||e.message==="authentication_required"))){
          authServiceError.value="无法读取本机账户状态，请确认 LightIsle.app 仍在运行后重试。";
        }
      }
    }
  } catch {
    configured.value=false;
    clearClientSessionState();
    authServiceError.value="无法连接本机账户服务，请确认 LightIsle.app 已打开并正在运行。";
  }
  finally {authChecking.value=false;}
}
async function submitAuth(){
  authError.value="";
  if(!configured.value){authError.value="请先打开 Mac 上的 LightIsle.app 完成管理员初始化。";return;}
  authSubmitting.value=true;
  try {
    const result=await jsonWrite<{id:number;username:string;role:"admin"|"member"}>("/api/v2/auth/login","POST",{
      username:authUsername.value,password:authPassword.value
    });
    bindDiagnosticAccount(result.id);
    user.value=result;
    authPassword.value="";
    await update();
    await refreshRootDiscovery(true);
    await loadPersonalStoragePolicy();
    void loadComputerFilesStatus();
    await autoRouteSection();
    if(active.value==="files"&&!fileDirectoryLoaded.value) await loadFiles();
    if(result.role==="admin") await loadAccounts();
  } catch(e) {
    const code=e instanceof Error?e.message:"request_failed";
    authError.value=({
      invalid_credentials:"用户名或密码不正确。请核对 Mac App「设置 → 管理员安全」显示的账号名，确认输入新密码而非浏览器保存的旧密码。",
      too_many_attempts:"登录尝试过多，请稍后再试",
    } as Record<string,string>)[code]??describeUserFacingError(e);
  } finally {authSubmitting.value=false;}
}
async function logout(){
  await cancelAndWaitForUpload();
  try {await jsonWrite("/api/v2/auth/logout","POST");}
  catch {
    await requestAlert("NAS 未能确认会话已撤销，请检查连接后重新退出。");
    return;
  }
  clearClientSessionState();
}
type Page = "overview" | "files" | "computer" | "photos" | "cinema" | "downloads" | "apps" | "automation" | "settings";
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
const validPages = new Set<Page>(["overview","files","computer","photos","cinema","downloads","apps","automation","settings"]);
const validTabs = validPages;
const active = ref<Page>(validPages.has(startingPage as Page) ? (startingPage as Page) : "overview");
const activeTab = active;
const visitedPages = ref<Record<Page,boolean>>({
  overview:true,files:active.value==="files",computer:active.value==="computer",photos:active.value==="photos",
  cinema:active.value==="cinema",downloads:active.value==="downloads",apps:active.value==="apps",
  automation:active.value==="automation",settings:active.value==="settings",
});
let applyingBrowserNavigation=false;
function handleBrowserPageNavigation(){
 const page=new URL(window.location.href).searchParams.get("page")??"overview";
 const next=validPages.has(page as Page)?page as Page:"overview";
 if(next===active.value)return;
 applyingBrowserNavigation=true;
 active.value=next;
 queueMicrotask(()=>{applyingBrowserNavigation=false});
}
const { stats, error, polling, cpu, usedMemory, usedDisk, diskActivity, update, clear: clearTelemetry, bytes, percent } =
  useHostTelemetry(() => user.value?.role);
const {
  showHardwareSpecs, isAdminDashboard, personalSpace, personalSpaceError,
  advancedUploadsOpen, advancedDiagnosticsOpen, pendingUploadsOpen,
  pendingReservationsOpen, cleanupRulesOpen, pendingMediaOpen, adminPendingMediaOpen,
  togglePendingMedia, togglePendingUploads, togglePendingReservations,
  toggleCleanupRules, toggleAdvanced,
  overviewIdentity, overviewSearch, overviewTelemetry, overviewPersonalSpace, overviewPending,
} = useOverviewAndDisclosures({
  user, fileSearch, searchViaSpotlight, filesLoading, searchingFiles,
  telemetry: { stats, error, polling, cpu, usedMemory, usedDisk, diskActivity, bytes, percent },
  sharedRoots, rootDiscoveryError, rootDiscoveryState, selectedRoot, taskLoaded, taskLoading, taskError, tasks,
});
const { theme, atmosphere, atmospheres, sidebarExpanded, moreMenuOpen, fileViewMode, setFileViewMode, createFolderOpen, cycleAtmosphere, switchTheme, toggleSidebar } = useShellAppearance();
let interval: number | undefined;
let lastHostCheck=0;
let lastOverviewTaskRefresh=0;
watch([active,()=>user.value?.role,rootViewKey,rootFeatureContextReady],()=>{
  if(active.value==="overview"&&user.value?.role==="admin"&&rootFeatureContextReady.value){
    lastOverviewTaskRefresh=Date.now();
    void reloadTasks();
  }
},{immediate:true});
function handleRootChange(event: Event | string){
  manualRootSection.value=active.value;
  personalRouteError.value="";
  const val = typeof event === "string" ? event : (event?.target as HTMLSelectElement)?.value ?? "";
  void switchRoot(val);
}
function handleRootGenerationChangedEvent(){void refreshRootDiscovery();}
function handleVisibilityRefresh() {
  if (!document.hidden && user.value && !rootDiscoveryLoading.value && Date.now() - lastRootDiscoveryAt > 3000) {
    void refreshRootDiscovery();
  }
}
function pollVisiblePage() {
  if (document.hidden || !user.value) return;
  const now = Date.now();
  const admin = user.value.role === "admin";
  const overview = active.value === "overview";
  const taskSettings = active.value === "settings" && settingsGroup.value === "ops";
  if (now - lastHostCheck >= (admin && overview ? 5000 : 30000)) {
    lastHostCheck = now;
    void update();
  }
  if (admin && (overview || taskSettings) && rootFeatureContextReady.value && !taskLoading.value &&
      now - lastOverviewTaskRefresh >= (taskSettings && tasks.value.some(task => task.running) ? 5000 : 30000)) {
    lastOverviewTaskRefresh = now;
    void reloadTasks();
  }
  if (!rootDiscoveryLoading.value && now - lastRootDiscoveryAt >= 30000) void refreshRootDiscovery();
}
onMounted(() => {
 installImageResourceObserver();
 // The URL identifies the primary section; media overlays own subsequent
 // same-URL entries and are closed before the browser navigates to a tab.
 window.history.replaceState({...window.history.state,page:active.value},"",window.location.href);
 window.addEventListener("popstate",handleBrowserPageNavigation);
  void checkAuth();
  window.addEventListener("lightisle-root-generation-changed", handleRootGenerationChangedEvent);
  document.addEventListener("visibilitychange", handleVisibilityRefresh);
  window.addEventListener("lightisle-share-outcome-uncertain", handleShareOutcomeUncertain);
  window.addEventListener("lightisle-photo-batch-outcome-uncertain", handlePhotoBatchOutcomeUncertain);
  interval = window.setInterval(pollVisiblePage, 5000);
});
onUnmounted(() => {
  window.removeEventListener("popstate",handleBrowserPageNavigation);
  if (interval) clearInterval(interval);
  window.removeEventListener("lightisle-root-generation-changed", handleRootGenerationChangedEvent);
  document.removeEventListener("visibilitychange", handleVisibilityRefresh);
  window.removeEventListener("lightisle-share-outcome-uncertain", handleShareOutcomeUncertain);
  window.removeEventListener("lightisle-photo-batch-outcome-uncertain", handlePhotoBatchOutcomeUncertain);
});
watch(active,(next)=>{
  moreMenuOpen.value=false;
  visitedPages.value[next]=true;
  if(!applyingBrowserNavigation){
    const current=new URL(window.location.href);
    current.searchParams.set("page",next);
    // Drop the previous tab's media layer rather than allowing Back to
    // restore a stale root-scoped overlay after changing sections.
    const previous={...window.history.state};
    delete previous.__lightisleMediaLayer;
    window.history.replaceState(previous,"",window.location.href);
    window.history.pushState({page:next},"",current.toString());
  }
  manualRootSection.value="";
  if(["files","photos","cinema"].includes(next)&&user.value){
    if(personalRouteError.value||!myStoragePolicy.value){void refreshRootDiscovery();}
    else if(multiRootMode.value)void autoRouteSection(next);
    else if(next==="files"&&!searchingFiles.value&&!fileDirectoryLoaded.value)void loadFiles();
  } else personalRouteError.value="";
  if(next==="settings"&&user.value?.role==="admin")void refreshTaskCenter();
});
</script>

<template src="./AppShell.html"></template>

