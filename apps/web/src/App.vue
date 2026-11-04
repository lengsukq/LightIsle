<script setup lang="ts">
import { computed, defineAsyncComponent, h, onMounted, onUnmounted, ref, watch } from "vue";
import {
  Activity, ArrowDownToLine, ArrowUpRight, Clapperboard, CloudOff,
  Folder, HardDrive, Images, LayoutDashboard, Moon, Monitor,
  RefreshCcw, Server, Settings2, ShieldCheck, Sun, WifiOff, FileText, FolderPlus,
  UploadCloud, ChevronRight, ChevronLeft, Download, Trash2,
  Search, LogOut, Sparkles, Laptop, Workflow
} from "lucide-vue-next";
import { useShellAppearance } from "./useShellAppearance";
import { useHostTelemetry } from "./useHostTelemetry";
import { useAccountSessions } from "./useAccountSessions";
import { useAccountManagement, type ManagedAccount } from "./useAccountManagement";
import { useFileBrowser } from "./useFileBrowser";
import { useFileUploads } from "./useFileUploads";
import { useFileShares, type SharedFileEntry } from "./useFileShares";
import { useTaskCenter, type BackendTask, type TaskRun } from "./useTaskCenter";
// Heavy media libraries are requested only when their pages are opened.
// Keep an accessible loading/error state instead of rendering a blank page.
const asyncPageState = (message: string, role: string) => ({
  render: () => h("p", { role, class: "page-status" }, message),
});
const AutomationView = defineAsyncComponent(()=>import("./AutomationView.vue"));
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
import DiskManagement from "./DiskManagement.vue";
import UserStoragePanel from "./UserStoragePanel.vue";
import DavAccess from "./DavAccess.vue";
import FileOperationDialog from "./FileOperationDialog.vue";
import { performFileOperationAndRefresh } from "./fileListRefresh.js";
import { createFileOperationsClient } from "./fileOperationsClient.js";
import { trashPresentationState } from "./filePageState.js";
import { taskHistoryErrorLabel, taskOperationLabel, taskRunStatusLabel } from "./taskHistoryPresentation.js";
import AuditLogView from "./AuditLogView.vue";
import AlertsView from "./AlertsView.vue";
import OpsDiagnostics from "./OpsDiagnostics.vue";
import AppleSelect from "./AppleSelect.vue";
import OverviewPage from "./OverviewPage.vue";
import type { PersonalSpaceSummary } from "./overviewPageModels.js";
import { rootApiPath, rootMediaPath } from "./rootApi.js";
import { createRootRequestTransport, rootContextKey } from "./rootRequestTransport.js";
import { chooseDiscoveredRoot, describeRootContext, describeRootOperationFailure, readRootDiscoveryResponse, rootDiscoveryNetworkError } from "./rootDiscovery.js";
import { describeUserFacingError } from "./userFacingError.js";
import { routePersonalCategory } from "./personalStorageRouting.js";
import { createRootContextLifecycle } from "./rootContextLifecycle";
import { useFileTrash, type FileTrashEntry } from "./useFileTrash";

type Account = ManagedAccount;
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
const rootSelectionOptions=computed(()=>[
  ...sharedRoots.value.map(root => ({
    value: root.rootID,
    label: root.name+(root.isDefault?" · 默认":""),
    hint: root.online ? undefined : "离线",
  })),
]);
const fileSortKeyOptions = [
  { value: "name", label: "名称" },
  { value: "mtime", label: "修改时间" },
  { value: "size", label: "文件大小" },
];
const fileSortDirectionOptions = [
  { value: "asc", label: "升序" },
  { value: "desc", label: "降序" },
];
const roleOptions = [
  { value: "member", label: "普通用户" },
  { value: "admin", label: "管理员" },
];
const shareHourOptions = [
  { value: 1, label: "1 小时" },
  { value: 6, label: "6 小时" },
  { value: 24, label: "1 天" },
  { value: 72, label: "3 天" },
  { value: 168, label: "7 天" },
];
const rootViewKey=computed(()=>`${selectedRootID.value}:${selectedRootGeneration.value}`);
const rootFeatureContextReady=computed(()=>multiRootMode.value&&!!selectedRoot.value);
const rootContextPresentation=computed(()=>describeRootContext({
  state:rootDiscoveryState.value,error:rootDiscoveryError.value,
  hasContext:rootFeatureContextReady.value,rootCount:sharedRoots.value.length,
  selectedRoot:selectedRoot.value
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
const storagePanelRevision = ref(0);
type FileGrant = {userId:number;path:string;canWrite:boolean};
const grantUser = ref<Account|null>(null);
const grants = ref<FileGrant[]>([]);
const grantPath = ref(".");
const grantWrite = ref(false);
const grantBusy = ref(false);
const grantError = ref("");
const {
  tasks, taskError, taskHistory, taskHistoryNextCursor,
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
  accounts, newUsername, newPassword, newRole, resetMember, resetPassword,
  resetConfirm, resetBusy, resetError, resetNotice, userError, userBusy,
  currentPassword, nextPassword, repeatPassword, passwordBusy, passwordError,
  loadAccounts, addAccount, toggleAccount, closeMemberReset, submitMemberReset,
  changeOwnPassword, openMemberReset: beginMemberReset, resetAccountState,
} = useAccountManagement({
  isAdmin: () => user.value?.role === "admin",
  read: <T>(path: string) => jsonGet<T>(path),
  write: <T>(path: string, method: "POST" | "PATCH", body?: object) =>
    jsonWrite<T>(path, method, body ?? {}),
  confirm: (message: string) => window.confirm(message),
  logout: () => logout(),
  onOwnPasswordChanged: () => {
    authError.value = "密码已更新，其他设备上的会话也已失效，请使用新密码重新登录。";
  },
  storageRoot: () =>
    multiRootMode.value && selectedRoot.value?.online
      ? { id: selectedRootID.value, generation: selectedRootGeneration.value }
      : null,
  assignStorage: async (accountId, category, root) => {
    const response = await rootFetch(
      `/api/v2/roots/${encodeURIComponent(root.id)}/users/${accountId}/storage/${category}`,
      {
        method: "PUT",
        credentials: "same-origin",
        headers: {
          "X-LightIsle-Request": "1",
          "X-LightIsle-Root-Generation": String(root.generation),
        },
      },
    );
    if (!response.ok) {
      const data = await response.json().catch(() => ({})) as { error?: string };
      throw new Error(data.error ?? ("HTTP " + response.status));
    }
  },
  storageChanged: () => { storagePanelRevision.value++; },
});
const {
  loginSessions, sessionsLoading, sessionsLoaded, sessionsTruncated,
  sessionsError, sessionsMessage, loadLoginSessions, revokeLoginSession,
  reset: resetLoginSessions,
} = useAccountSessions({
  authenticated: () => user.value !== null,
  read: <T>(path: string) => jsonGet<T>(path),
  logoutCurrent: () => logout(),
  onCurrentLogout: () => { authError.value = "当前设备已退出，请重新登录。"; },
  confirm: (message: string) => window.confirm(message),
  revoke: async (path: string) => {
    const response = await fetch(path, {
      method: "DELETE",
      credentials: "same-origin",
      headers: { "X-LightIsle-Request": "1" },
    });
    if (!response.ok) throw new Error("HTTP " + response.status);
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
    if (!response.ok) throw new Error("HTTP " + response.status);
  },
  confirm: (message: string) => window.confirm(message),
  origin: () => window.location.origin,
});
type SettingsGroup="account"|"files"|"storage"|"ops";
const settingsGroup=ref<SettingsGroup>("account");
const settingsGroups=computed(()=>{
  const admin=user.value?.role==="admin";
  const options: Array<{key:SettingsGroup,label:string}> = [{key:"account",label:"账号与安全"},{key:"files",label:"文件与分享"}];
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
  filesPath, currentFolderCanWrite, sharedRootName, fileEntries, fileNextCursor,
  fileSortKey, fileSortDirection, failedThumbnails, fileSearch,
  searchViaSpotlight, searchingFiles, searchTruncated, checkedFiles,
  filesLoading, filesError, loadFiles, runFileSearch, reset: resetFileBrowser,
} = useFileBrowser({
  authenticated: () => user.value !== null,
  rootAvailable: () =>
    rootDiscoveryState.value !== "error" &&
    !(multiRootMode.value && !selectedRootID.value),
  rootError: () => rootDiscoveryError.value,
  rootEpoch: () => rootContextEpoch.value,
  apiPath: scopedApiPath,
  read: <T>(path: string) => jsonGet<T>(path),
  isAbort: isAbortError,
  onOpenFiles: () => { active.value = "files"; },
  onDirectoryLeave: () => { uploadContinuation.value = null; },
});
const fileOperationDialog=ref<{item:FileEntry;action:"move"|"copy"}|null>(null);
const fileOperationNotice=ref("");
const newFolderName=ref("");
function thumbnailKey(item:FileEntry){return item.path+"@"+item.modified;}
function thumbnailEligible(item:FileEntry){return item.type==="file"&&/\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v)$/i.test(item.name);}
function fileThumbnailURL(item:FileEntry,size=512){
  return scopedMediaPath("/api/v2/files/thumbnail?path="+encodeURIComponent(item.path)+"&size="+size);
}
function markThumbnailFailure(item:FileEntry){
  failedThumbnails.value=new Set([...failedThumbnails.value,thumbnailKey(item)]);
}
function scopedApiPath(path:string){
  if(rootDiscoveryState.value!=="multi"||!selectedRootID.value)return "";
  return rootApiPath(selectedRootID.value,path);
}
function scopedMediaPath(path:string){
  if(rootDiscoveryState.value!=="multi"||!selectedRootID.value)return "";
  return rootMediaPath(selectedRootID.value,selectedRootGeneration.value,path);
}
function isAbortError(error:unknown){return error instanceof Error&&error.name==="AbortError";}
// The download center is daemon-wide, not root-scoped: plain same-origin
// JSON with the CSRF header, throwing stable server reason codes.
async function downloadsApi(path:string,init:RequestInit={}):Promise<unknown>{
  const headers=new Headers(init.headers);
  if(init.method&&init.method!=="GET")headers.set("X-LightIsle-Request","1");
  const response=await fetch(path,{...init,headers,credentials:"same-origin",cache:"no-store"});
  if(!response.ok){
    const failure=await response.json().catch(()=>({})) as {error?:string};
    throw new Error(failure.error||"HTTP "+response.status);
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
  onGenerationChanged:()=>{void refreshRootDiscovery();}
});
const rootRequestSnapshot=rootTransport.snapshot;
const assertRootRequestCurrent=rootTransport.assertCurrent;
const rootFetch=rootTransport.request;
function currentRootContextKey(){return rootContextKey(rootRequestContext());}
function resetRootScopedState(){
  resetFileTrash();
  resetFileBrowser();
  fileOperationDialog.value=null;fileOperationNotice.value="";
  newFolderName.value="";
  previewItem.value=null;previewText.value="";previewError.value="";trashTarget.value=null;
  resetFileShares();
  grantUser.value=null;grants.value=[];grantPath.value=".";grantWrite.value=false;grantBusy.value=false;grantError.value="";
  resetTaskCenter();
  resetUploadsForRoot();
}
async function switchRoot(rootID:string,force=false){
  if(!multiRootMode.value||rootSwitching.value)return;
  const target=sharedRoots.value.find(root=>root.rootID===rootID)??null;
  if(!target)return;
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
  if(active.value==="files")void loadFiles(".");
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
    if(section==="files"&&active.value==="files")await loadFiles(".");
    return;
  }
  if(uploadBusy.value||hasActiveUpload()){
    personalRouteError.value="当前上传尚未完成。请先完成或取消上传，再切换到这个个人目录。";
    return;
  }
  if(selectedRootID.value!==match.rootID){await switchRoot(match.rootID);}
  if(section==="files"&&active.value==="files"&&!rootSwitching.value&&selectedRootID.value===match.rootID){
    await loadFiles(match.path);
  }
}
async function refreshRootDiscovery(){
  if(rootSwitching.value)return;
  const request=rootLifecycle.beginDiscovery();
  lastRootDiscoveryAt=Date.now();
  rootDiscoveryLoading.value=true;
  try{
    const response=await fetch("/api/v2/roots",{credentials:"same-origin",cache:"no-store"});
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
const trashTarget=ref<FileEntry|null>(null);
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
    if (!response.ok) throw new Error("HTTP " + response.status);
  },
  refreshFiles: () => loadFiles(),
  isAbort: isAbortError,
  errorLabel: describeUserFacingError,
  confirm: (message: string) => window.confirm(message),
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

const previewItem=ref<FileEntry|null>(null);
const previewText=ref("");
const previewError=ref("");
const pathSegments=computed(()=>{
  const p=filesPath.value;
  if(p===".")return [{name:sharedRootName.value,path:"."}];
  const parts=p.split("/");
  return [{name:sharedRootName.value,path:"."},...parts.map((name,index)=>({name,path:parts.slice(0,index+1).join("/")}))];
});
function operateFile(item:FileEntry,action:"move"|"copy"){
  if(action==="move"&&!canWriteEntry(item))return;
  if(showingTrash.value||searchingFiles.value)return;
  fileOperationNotice.value="";
  fileOperationDialog.value={item,action};
}
const fileOperations=createFileOperationsClient({
  apiPath:scopedApiPath,
  get:jsonGet,
  write:jsonWrite,
  getEpoch:()=>rootContextEpoch.value
});
function listOperationFolders(path:string,cursor:string){
  return fileOperations.listFolders<{entries:FileEntry[];nextCursor:string;canWrite:boolean}>(path,cursor);
}
async function commitFileOperation(target:string,conflict:""|"skip"|"rename"){
  const dialog=fileOperationDialog.value;
  if(!dialog)throw new Error("操作已经取消");
  return fileOperations.commit<{done:boolean;finalTo:string;skipped:boolean}>(
    {action:dialog.action,from:dialog.item.path,to:target,conflict});
}
function finishFileOperation(message:string){
  fileOperationDialog.value=null;
  fileOperationNotice.value=message;
  void loadFiles();
}
async function editGrants(account:Account){
  if(!rootFeatureContextReady.value){grantError.value="请先选择共享目录，再管理该目录的授权。";return;}
  grantUser.value=account;grantPath.value=".";grantWrite.value=false;grantError.value="";
  try{
    const endpoint=`/api/v2/roots/${encodeURIComponent(selectedRootID.value)}/users/${account.id}/file-grants`;
    const data=await jsonGet<{grants:FileGrant[]}>(endpoint);
    grants.value=data.grants;
  }catch(e){if(!isAbortError(e))grantError.value="读取文件权限失败："+String(e);}
}
async function saveGrant(path=grantPath.value,remove=false){
  if(!grantUser.value||!rootFeatureContextReady.value)return;
  grantBusy.value=true;grantError.value="";
  try{
    const endpoint=`/api/v2/roots/${encodeURIComponent(selectedRootID.value)}/users/${grantUser.value.id}/file-grants`;
    const response=await rootFetch(remove?endpoint+"?path="+encodeURIComponent(path):endpoint,{
      method:remove?"DELETE":"PUT",credentials:"same-origin",
      headers:{"Content-Type":"application/json","X-LightIsle-Request":"1"},
      ...(!remove?{body:JSON.stringify({path,canWrite:grantWrite.value})}:{})
    });
    if(!response.ok){const result=await response.json().catch(()=>({error:"request_failed"}));throw new Error(result.error??"request_failed");}
    await editGrants(grantUser.value);
  }catch(e){if(!isAbortError(e))grantError.value="更新权限失败："+describeUserFacingError(e);}
  finally{grantBusy.value=false;}
}
async function previewFile(item:FileEntry){
  previewItem.value=item;previewText.value="";previewError.value="";
  const scopeEpoch=rootContextEpoch.value;
  if(/\.(txt|md|json|log)$/i.test(item.name)){
    try{
      const response=await rootFetch(scopedApiPath("/api/v2/files/preview")+"?path="+encodeURIComponent(item.path),{credentials:"same-origin"});
      if(!response.ok)throw new Error("格式不支持或文件太大");
      const text=await response.text();
      if(scopeEpoch===rootContextEpoch.value)previewText.value=text;
    }catch(e){if(scopeEpoch===rootContextEpoch.value&&!isAbortError(e))previewError.value=describeUserFacingError(e);}
  }else if(!/\.(jpe?g|png|gif|webp|heic|heif|pdf|mp4|webm|m4v)$/i.test(item.name)){
    previewError.value="该文件暂不支持在线预览，请下载后使用本机应用打开。";
  }
}
const previewURL=computed(()=>{
  const item=previewItem.value;
  if(!item)return "";
  if(/\.(heic|heif)$/i.test(item.name))return fileThumbnailURL(item,2048);
  return scopedMediaPath("/api/v2/files/preview?path="+encodeURIComponent(item.path));
});
function goUp(){
  if(filesPath.value===".")return;
  const p=filesPath.value.split("/");p.pop();
  void loadFiles(p.length?p.join("/"):".");
}
async function makeFolder(){
  if(!currentFolderCanWrite.value)return;
  const name=newFolderName.value.trim();
  if(!name)return;
  const full=filesPath.value==="."?name:filesPath.value+"/"+name;
  filesError.value="";
  try{
    await jsonWrite(scopedApiPath("/api/v2/files/folders"),"POST",{path:full});
    newFolderName.value="";await loadFiles();
  }catch(e){if(!isAbortError(e))filesError.value="新建文件夹失败："+describeUserFacingError(e);}
}
async function batchTrash(){
  if(!checkedFiles.value.length)return;
  if(checkedFiles.value.length>50){filesError.value="每次最多选择 50 项文件，请缩小选择范围。";return;}
  if(checkedFiles.value.some(path=>!fileEntries.value.some(entry=>entry.path===path&&canWriteEntry(entry)))){
    filesError.value="所选项目包含只读或已变更的项目，请刷新后重试。";return;
  }
  const scope=currentRootContextKey();
  const selected=checkedFiles.value.slice();
  if(!window.confirm("将选中的 "+checkedFiles.value.length+" 项移到回收站？"))return;
  if(scope!==currentRootContextKey()||selected.length!==checkedFiles.value.length||
    !selected.every(path=>checkedFiles.value.includes(path)&&fileEntries.value.some(entry=>entry.path===path&&canWriteEntry(entry)))){
    filesError.value="共享目录或选择已变化，未执行批量删除。";return;
  }
  try{
    const result=await jsonWrite<{results:{success:boolean;path:string}[]}>(scopedApiPath("/api/v2/files/batch"),"POST",
      {action:"trash",paths:selected});
    const failed=result.results.filter(x=>!x.success).length;
    if(failed)filesError.value=failed+" 项处理失败，请刷新列表核对已完成的文件后重试。";
    await loadFiles();
  }catch(e){if(!isAbortError(e))filesError.value="批量操作失败："+describeUserFacingError(e);}
}
async function downloadFile(item:FileEntry){
  if(item.type==="folder"){
    try{
      const response=await rootFetch(scopedApiPath("/api/v2/files/archive")+"?path="+encodeURIComponent(item.path),{
        method:"HEAD",credentials:"same-origin",cache:"no-store",
      });
      if(!response.ok){
        filesError.value=response.status===413
          ?"这个文件夹超过 ZIP 下载的限制（2 GiB、2,000 项或 16 层），请打开文件夹分批下载。"
          :response.status===429?"当前打包下载较多，请稍后重试。"
          :response.status===403?"没有读取该文件夹的权限。"
          :response.status===404?"该文件夹已不存在，请刷新列表。"
          :"无法准备文件夹下载（HTTP "+response.status+"），请重试。";
        return;
      }
    }catch(e){
      if(isAbortError(e))return;
      filesError.value="准备文件夹下载失败："+describeUserFacingError(e);
      return;
    }
  }
  filesError.value="";
  const a=document.createElement("a");
  a.href=scopedMediaPath((item.type==="folder"?"/api/v2/files/archive?path=":"/api/v2/files/content?path=")+encodeURIComponent(item.path));
  a.download=item.type==="folder"?item.name+".zip":item.name;
  a.rel="noopener";
  document.body.appendChild(a);a.click();a.remove();
}
function canWriteEntry(item:FileEntry){return item.canWrite===true||user.value?.role==="admin";}
async function removeFile(){
  if(!trashTarget.value)return;
  const name=trashTarget.value.name,filepath=trashTarget.value.path;
  trashTarget.value=null;filesError.value="";
  try{
    const response=await rootFetch(scopedApiPath("/api/v2/files")+"?path="+encodeURIComponent(filepath),{
      method:"DELETE",credentials:"same-origin",headers:{"X-LightIsle-Request":"1"}
    });
    if(!response.ok)throw new Error("HTTP "+response.status);
    await loadFiles();
    if(showingTrash.value)await loadTrash();
  }catch(e){if(!isAbortError(e))filesError.value="移动 "+name+" 到回收站失败："+describeUserFacingError(e);}
}
async function jsonGet<T>(endpoint:string,signal?:AbortSignal):Promise<T> {
  const snapshot=rootRequestSnapshot(endpoint);
  const response=await rootFetch(endpoint,{cache:"no-store",credentials:"same-origin",signal});
  if (!response.ok) {
    const result=await response.json().catch(()=>({})) as {error?:string};
    assertRootRequestCurrent(snapshot);
    if(snapshot&&result.error==="root_generation_changed"){
      void refreshRootDiscovery();
      throw new Error("共享目录已变化，请刷新根列表后重新选择。");
    }
    throw new Error(result.error??("HTTP "+response.status));
  }
  const result=await response.json() as T;
  assertRootRequestCurrent(snapshot);
  return result;
}
async function jsonWrite<T>(endpoint:string,method:"POST"|"PATCH",body:object = {},signal?:AbortSignal):Promise<T> {
  const snapshot=rootRequestSnapshot(endpoint);
  const response=await rootFetch(endpoint,{
    method,credentials:"same-origin",
    headers:{"Content-Type":"application/json","X-LightIsle-Request":"1"},
    body:JSON.stringify(body),signal
  });
  if (!response.ok) {
    const result=await response.json().catch(()=>({error:"request_failed"})) as {error?:string};
    assertRootRequestCurrent(snapshot);
    if(snapshot&&result.error==="root_generation_changed"){
      void refreshRootDiscovery();
      throw new Error("共享目录已变化，请刷新根列表后重新选择。");
    }
    throw new Error(result.error??"request_failed");
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
        const identity=await jsonGet<{username:string;role:"admin"|"member"}>("/api/v2/auth/me");
        user.value=identity;
        await refreshRootDiscovery();
        await loadPersonalStoragePolicy();
        await autoRouteSection();
        await loadFiles();
        if(identity.role==="admin") await loadAccounts();
      } catch(e) {
        user.value=null;
        if(!(e instanceof Error&&(e.message==="HTTP 401"||e.message==="authentication_required"))){
          authServiceError.value="无法读取本机账户状态，请确认 LightIsle.app 仍在运行后重试。";
        }
      }
    }
  } catch {
    configured.value=false;
    user.value=null;
    authServiceError.value="无法连接本机账户服务，请确认 LightIsle.app 已打开并正在运行。";
  }
  finally {authChecking.value=false;}
}
async function submitAuth(){
  authError.value="";
  if(!configured.value){authError.value="请先打开 Mac 上的 LightIsle.app 完成管理员初始化。";return;}
  authSubmitting.value=true;
  try {
    const result=await jsonWrite<{username:string;role:"admin"|"member"}>("/api/v2/auth/login","POST",{
      username:authUsername.value,password:authPassword.value
    });
    user.value=result;
    authPassword.value="";
    await update();
    await refreshRootDiscovery();
    await loadPersonalStoragePolicy();
    await autoRouteSection();
    await loadFiles();
    if(result.role==="admin") await loadAccounts();
  } catch(e) {
    const code=e instanceof Error?e.message:"request_failed";
    authError.value=({
      invalid_credentials:"用户名或密码不正确。请核对 Mac App「设置 → 管理员安全」显示的账号名，确认输入新密码而非浏览器保存的旧密码。",
      too_many_attempts:"登录尝试过多，请稍后再试",
    } as Record<string,string>)[code]??("操作失败："+code);
  } finally {authSubmitting.value=false;}
}
async function logout(){
  await cancelAndWaitForUpload();
  try {await jsonWrite("/api/v2/auth/logout","POST");}
  catch {
    window.alert("NAS 未能确认会话已撤销，请检查连接后重新退出。");
    return;
  }
  rootContextEpoch.value=rootLifecycle.invalidate();
  clearTelemetry();
  user.value=null;resetAccountState();active.value="overview";
  myStoragePolicy.value=null;personalRouteError.value="";manualRootSection.value="";
  rootLifecycle.invalidateDiscovery();rootSwitching.value=false;rootDiscoveryState.value="unknown";sharedRoots.value=[];selectedRootID.value="";selectedRootSnapshot.value=null;rootDiscoveryError.value="";lastRootDiscoveryAt=0;
  resetRootScopedState();
  currentFolderCanWrite.value=false;checkedFiles.value=[];
  resetLoginSessions();
  resetFileShares();
}
function openMemberReset(account:Account){
  beginMemberReset(account);
  grantUser.value = null;
}
type Page = "overview" | "files" | "photos" | "cinema" | "downloads" | "automation" | "settings";
const items = [
  { key: "overview" as Page, title: "主页概览", icon: Sparkles, color: "blue", group: "space" },
  { key: "files" as Page, title: "私人文件", icon: Folder, color: "cyan", group: "space" },
  { key: "photos" as Page, title: "时光相册", icon: Images, color: "pink", group: "space" },
  { key: "cinema" as Page, title: "私人影院", icon: Clapperboard, color: "orange", group: "space" },
  { key: "downloads" as Page, title: "下载中心", icon: ArrowDownToLine, color: "cyan", group: "space" },
  { key: "automation" as Page, title: "自动化", icon: Workflow, color: "purple", group: "system" },
  { key: "settings" as Page, title: "偏好设置", icon: Settings2, color: "purple", group: "system" },
];
const showHardwareSpecs = ref(false);
const isAdminDashboard = computed(() => user.value?.role === "admin");
const personalSpace = ref<PersonalSpaceSummary | null>(null);
const personalSpaceError = ref("");
let personalSpaceRequest = 0;
watch([()=>user.value?.username,()=>user.value?.role], async ([username,role])=>{
  const generation = ++personalSpaceRequest;
  personalSpace.value = null;
  personalSpaceError.value = "";
  if(!username || role!=="member") return;
  try{
    const response = await fetch("/api/v2/me/storage",{credentials:"same-origin",cache:"no-store"});
    if(!response.ok)throw new Error("HTTP "+response.status);
    const data=await response.json() as PersonalSpaceSummary;
    if(generation===personalSpaceRequest)personalSpace.value=data;
  }catch(e){
    if(generation===personalSpaceRequest)personalSpaceError.value="个人空间信息暂时不可用，请在设置中刷新。";
  }
},{immediate:true});
const advancedUploadsOpen = ref(false);
const advancedDiagnosticsOpen = ref(false);
function toggleAdvanced(kind: "uploads" | "diagnostics", event: Event) {
  const open = (event.target as HTMLDetailsElement)?.open === true;
  if (kind === "uploads") advancedUploadsOpen.value = open;
  else advancedDiagnosticsOpen.value = open;
}
const startingPage = new URLSearchParams(location.search).get("page");
const active = ref<Page>(
  startingPage === "photos" ? "photos" :
  startingPage === "cinema" ? "cinema" :
  startingPage === "files" ? "files" :
  startingPage === "settings" ? "settings" :
  "overview"
);
const { stats, error, polling, cpu, usedMemory, usedDisk, diskActivity, update, clear: clearTelemetry, bytes, percent } =
  useHostTelemetry(() => user.value?.role);
const overviewIdentity = computed(() => ({
  username: user.value?.username ?? "",
  isAdmin: isAdminDashboard.value,
}));
const overviewSearch = computed(() => ({
  query: fileSearch.value,
  spotlight: searchViaSpotlight.value,
  filesLoading: filesLoading.value,
  searchingFiles: searchingFiles.value,
}));
const overviewTelemetry = computed(() => ({
  error: error.value,
  stats: stats.value,
  polling: polling.value,
  cpu: cpu.value,
  usedMemory: usedMemory.value,
  usedDisk: usedDisk.value,
  diskActivity: diskActivity.value,
  expanded: showHardwareSpecs.value,
  bytes,
  percent,
}));
const overviewPersonalSpace = computed(() => ({
  summary: personalSpace.value,
  error: personalSpaceError.value,
  bytes,
}));
const { theme, atmosphere, atmospheres, sidebarExpanded, cycleAtmosphere, switchTheme, toggleSidebar } = useShellAppearance();
let interval: number | undefined;
let lastMemberHealthCheck=0;
function handleRootChange(event: Event | string){
  manualRootSection.value=active.value;
  personalRouteError.value="";
  const val = typeof event === "string" ? event : (event?.target as HTMLSelectElement)?.value ?? "";
  void switchRoot(val);
}
onMounted(() => {
  void checkAuth();
  window.addEventListener("lightisle-root-generation-changed", refreshRootDiscovery);
  interval = window.setInterval(() => {if (document.hidden) return;if(user.value){if(user.value.role==='admin'||Date.now()-lastMemberHealthCheck>30000){lastMemberHealthCheck=Date.now();void update();}if(active.value==="settings"&&user.value.role==='admin')void reloadTasks();if(Date.now()-lastRootDiscoveryAt>30000)void refreshRootDiscovery();}}, 5000);
});
onUnmounted(() => {
  if (interval) clearInterval(interval);
  window.removeEventListener("lightisle-root-generation-changed", refreshRootDiscovery);
});
watch(active,(next)=>{
  manualRootSection.value="";
  if(["files","photos","cinema"].includes(next)&&user.value){
    if(multiRootMode.value)void autoRouteSection(next);
    else if(next==="files"&&!searchingFiles.value)void loadFiles();
  } else personalRouteError.value="";
  if(next==="settings"&&user.value?.role==="admin")void refreshTaskCenter();
});
</script>

<template src="./AppShell.html"></template>

