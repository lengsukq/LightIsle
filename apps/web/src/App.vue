<script setup lang="ts">
import { computed, defineAsyncComponent, h, onMounted, onUnmounted, ref, watch } from "vue";
import {
  Activity, ArrowDownToLine, ArrowUpRight, Clapperboard, CloudOff,
  Folder, HardDrive, Images, LayoutDashboard, Moon, Monitor,
  RefreshCcw, Server, Settings2, ShieldCheck, Sun, WifiOff, FileText, FolderPlus,
  UploadCloud, ChevronRight, ChevronLeft, Download, Trash2,
  Search, LogOut, Sparkles, Laptop
} from "lucide-vue-next";
import { applyTheme, type Theme } from "./theme";
// Heavy media libraries are requested only when their pages are opened.
// Keep an accessible loading/error state instead of rendering a blank page.
const asyncPageState = (message: string, role: string) => ({
  render: () => h("p", { role, class: "page-status" }, message),
});
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
import UploadMaintenance from "./UploadMaintenance.vue";
import DiskManagement from "./DiskManagement.vue";
import DavAccess from "./DavAccess.vue";
import FileOperationDialog from "./FileOperationDialog.vue";
import { fingerprintFile, isWithinUploadSizeLimit, supportsContentFingerprint, uploadSessionIdentity } from "./uploadIdentity.js";
import { adoptUploadTask, refreshAfterPublishedUpload } from "./uploadLifecycle.js";
import { createUploadResumeStorage } from "./uploadResumeStorage.js";
import { performFileOperationAndRefresh } from "./fileListRefresh.js";
import { createFileOperationsClient } from "./fileOperationsClient.js";
import { createUploadContinuation, trashPresentationState, uploadContextMatches, uploadContinuationIsCurrent, type UploadBatchContext, type UploadContinuation } from "./filePageState.js";
import { taskHistoryErrorLabel, taskOperationLabel, taskRunStatusLabel } from "./taskHistoryPresentation.js";
import AuditLogView from "./AuditLogView.vue";
import AlertsView from "./AlertsView.vue";
import OpsDiagnostics from "./OpsDiagnostics.vue";
import { rootApiPath, rootMediaPath } from "./rootApi.js";
import { createRootRequestTransport, rootContextKey, makeRootAbortError } from "./rootRequestTransport.js";
import { describeRootContext, describeRootOperationFailure, readRootDiscoveryResponse, rootDiscoveryNetworkError } from "./rootDiscovery.js";

type Account = { id:number; username:string; role:"admin"|"member"; enabled:boolean; createdAt:number };
type SharedRoot = {rootID:string;name:string;generation:number;online:boolean;compatibility?:boolean};
type RootDiscoveryState = "unknown"|"legacy"|"multi"|"error";
const LEGACY_ROOT_SELECTION="__legacy__";
const ROOT_SELECTION_STORAGE_KEY="lightisle_root_choice_v2";
const rootDiscoveryState=ref<RootDiscoveryState>("unknown");
const sharedRoots=ref<SharedRoot[]>([]);
const selectedRootID=ref("");
const selectedRootSnapshot=ref<SharedRoot|null>(null);
const legacyRootSelected=ref(false);
const rootDiscoveryError=ref("");
const rootDiscoveryLoading=ref(false);
const rootSwitching=ref(false);
const rootContextEpoch=ref(0);
let trashRequestGeneration=0;
let rootContextController=new AbortController();
let rootDiscoveryRequest=0;
let lastRootDiscoveryAt=0;
const selectedRoot=computed(()=>selectedRootSnapshot.value);
const multiRootMode=computed(()=>rootDiscoveryState.value==="multi");
const selectedRootGeneration=computed(()=>selectedRoot.value?.generation??0);
const rootSelectionValue=computed(()=>legacyRootSelected.value?LEGACY_ROOT_SELECTION:selectedRootID.value);
const rootViewKey=computed(()=>multiRootMode.value&&!legacyRootSelected.value?`${selectedRootID.value}:${selectedRootGeneration.value}`:"legacy");
const rootFeatureContextReady=computed(()=>rootDiscoveryState.value==="legacy"||(multiRootMode.value&&(legacyRootSelected.value||!!selectedRoot.value)));
const rootContextPresentation=computed(()=>describeRootContext({
  state:rootDiscoveryState.value,error:rootDiscoveryError.value,
  hasContext:rootFeatureContextReady.value,rootCount:sharedRoots.value.length,
  selectedRoot:legacyRootSelected.value?null:selectedRoot.value
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
const accounts = ref<Account[]>([]);
type FileGrant = {userId:number;path:string;canWrite:boolean};
const grantUser = ref<Account|null>(null);
const grants = ref<FileGrant[]>([]);
const grantPath = ref(".");
const grantWrite = ref(false);
const grantBusy = ref(false);
const grantError = ref("");
type BackendTask = {kind:"gallery"|"cinema"|"backup";running:boolean;progress:number;found?:number;bytes?:number;lastDone?:number;lastError?:string;operation?:string};
type TaskRun = {id:number;kind:"gallery"|"cinema"|"backup";operation:string;running:boolean;progress:number;bytes:number;startedAt:number;lastDone:number;lastError:string;attempts:number};
const maxLoadedTaskHistory = 1000;
const tasks = ref<BackendTask[]>([]);
const taskError = ref("");
const taskHistory = ref<TaskRun[]>([]);
const taskHistoryNextCursor = ref("");
const taskHistoryLoading = ref(false);
const taskHistoryError = ref("");
let taskHistoryGeneration = 0;
let taskHistoryLatestRefreshing = false;
const newUsername = ref("");
const newPassword = ref("");
const newRole = ref<"admin"|"member">("member");
const resetMember = ref<Account|null>(null);
const resetPassword = ref("");
const resetConfirm = ref("");
const resetBusy = ref(false);
const resetError = ref("");
const resetNotice = ref("");
const userError = ref("");
const userBusy = ref(false);
const currentPassword = ref("");
const nextPassword = ref("");
const repeatPassword = ref("");
const passwordBusy = ref(false);
const passwordError = ref("");
type LoginSession = {id:string;createdAt:number;expiresAt:number;current:boolean};
const loginSessions = ref<LoginSession[]>([]);
const sessionsLoading = ref(false);
const sessionsLoaded = ref(false);
const sessionsTruncated = ref(false);
const sessionsError = ref("");
const sessionsMessage = ref("");
type FileEntry = {name:string;path:string;type:"folder"|"file";size:number;modified:string;canWrite?:boolean};
type FileShare = {id:string;path:string;createdAt:number;expiresAt:number;kind?:string;hasPassword?:boolean;maxDownloads?:number;downloadCount?:number};
const sharingFile = ref<FileEntry|null>(null);
const shareHours = ref(24);
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
const sharePassword=ref("");
const shareMaxDownloads=ref(0);
const shareCreating = ref(false);
const shareCreatedLink = ref("");
const shareError = ref("");
const shareCopied = ref("");
const shareLinkInput = ref<HTMLInputElement|null>(null);
const activeShares = ref<FileShare[]>([]);
const sharesLoading = ref(false);
const sharesError = ref("");
const sharesLoaded = ref(false);
const filesPath=ref(".");
const currentFolderCanWrite=ref(false);
const sharedRootName=ref("共享文件");
const fileEntries=ref<FileEntry[]>([]);
const fileNextCursor=ref("");
const fileSortKey=ref<"name"|"size"|"mtime">("name");
const fileSortDirection=ref<"asc"|"desc">("asc");
const fileOperationDialog=ref<{item:FileEntry;action:"move"|"copy"}|null>(null);
const fileOperationNotice=ref("");
let fileListRequestGeneration=0;
const failedThumbnails=ref(new Set<string>());
function thumbnailKey(item:FileEntry){return item.path+"@"+item.modified;}
function thumbnailEligible(item:FileEntry){return item.type==="file"&&/\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v)$/i.test(item.name);}
function fileThumbnailURL(item:FileEntry,size=512){
  return scopedMediaPath("/api/v1/files/thumbnail?path="+encodeURIComponent(item.path)+"&size="+size);
}
function markThumbnailFailure(item:FileEntry){
  failedThumbnails.value=new Set([...failedThumbnails.value,thumbnailKey(item)]);
}
const fileSearch=ref("");
const searchViaSpotlight=ref(false);
const searchingFiles=ref(false);
const searchTruncated=ref(false);
const checkedFiles=ref<string[]>([]);
const uploadProgress=ref("");
const uploadPercent=ref(0);
const uploadStage=ref<"idle"|"hashing"|"uploading"|"done"|"error"|"cancelled">("idle");
const uploadCurrent=ref(0);
const uploadTotal=ref(0);
const uploadFileName=ref("");
const uploadSize=ref(0);
const uploadTransferred=ref(0);
const uploadDropActive=ref(false);
const uploadAutoRenameConflicts=ref(false);
const uploadCompleted=ref(0);
const uploadResult=ref("");
const uploadFailure=ref("");
const filesLoading=ref(false);
const filesError=ref("");
const newFolderName=ref("");
const uploadBusy=ref(false);
let uploadAbortController:AbortController|null=null;
let uploadCancelled=false;
let uploadGeneration=0;
let activeUploadPromise:Promise<void>|null=null;
const uploadResumeStorage=createUploadResumeStorage(()=>sessionStorage);
function cancelCurrentUpload(){uploadCancelled=true;uploadAbortController?.abort();}
function scopedApiPath(path:string){
  if(rootDiscoveryState.value==="error"||(multiRootMode.value&&!legacyRootSelected.value&&!selectedRootID.value))return "";
  return rootApiPath(multiRootMode.value&&!legacyRootSelected.value?selectedRootID.value:undefined,path);
}
function scopedMediaPath(path:string){
  if(rootDiscoveryState.value==="error"||(multiRootMode.value&&!legacyRootSelected.value&&!selectedRootID.value))return "";
  return rootMediaPath(multiRootMode.value&&!legacyRootSelected.value?selectedRootID.value:undefined,selectedRootGeneration.value,path);
}
const makeAbortError=makeRootAbortError;
function isAbortError(error:unknown){return error instanceof Error&&error.name==="AbortError";}
function rootRequestContext(){return {
  rootID:selectedRootID.value,generation:selectedRootGeneration.value,epoch:rootContextEpoch.value,
  multiRoot:multiRootMode.value,legacySelected:legacyRootSelected.value,
  discoveryState:rootDiscoveryState.value,switching:rootSwitching.value,
  signal:rootContextController.signal
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
  trashRequestGeneration++;
  failedThumbnails.value=new Set();
  fileListRequestGeneration++;
  fileOperationDialog.value=null;fileOperationNotice.value="";
  filesPath.value=".";currentFolderCanWrite.value=false;fileEntries.value=[];fileNextCursor.value="";
  sharedRootName.value="共享文件";
  fileSearch.value="";searchingFiles.value=false;searchTruncated.value=false;checkedFiles.value=[];
  filesLoading.value=false;filesError.value="";newFolderName.value="";showingTrash.value=false;trashItems.value=[];trashLoading.value=false;trashError.value="";
  previewItem.value=null;previewText.value="";previewError.value="";trashTarget.value=null;
  sharingFile.value=null;shareHours.value=24;shareCreating.value=false;shareCreatedLink.value="";shareError.value="";shareCopied.value="";
  activeShares.value=[];sharesLoading.value=false;sharesError.value="";sharesLoaded.value=false;
  grantUser.value=null;grants.value=[];grantPath.value=".";grantWrite.value=false;grantBusy.value=false;grantError.value="";
  tasks.value=[];taskError.value="";taskHistory.value=[];taskHistoryNextCursor.value="";taskHistoryLoading.value=false;taskHistoryError.value="";
  taskHistoryGeneration++;taskHistoryLatestRefreshing=false;
  uploadProgress.value="";uploadBusy.value=false;uploadStage.value="idle";uploadDropActive.value=false;uploadFailure.value="";
  uploadContinuation.value=null;
}
async function switchRoot(rootID:string,force=false){
  if(!multiRootMode.value||rootSwitching.value)return;
  const chooseLegacy=rootID===LEGACY_ROOT_SELECTION;
  const target=chooseLegacy?null:sharedRoots.value.find(root=>root.rootID===rootID)??null;
  if(!chooseLegacy&&rootID&&!target)return;
  if(!force&&((chooseLegacy&&legacyRootSelected.value)||(!chooseLegacy&&!legacyRootSelected.value&&target?.rootID===selectedRootID.value&&target?.generation===selectedRoot.value?.generation))){selectedRootSnapshot.value=target;return;}
  rootDiscoveryRequest++;
  rootDiscoveryLoading.value=false;
  rootSwitching.value=true;
  rootContextController.abort();rootContextController=new AbortController();
  rootContextEpoch.value++;
  resetRootScopedState();
  const switchEpoch=rootContextEpoch.value;
  if(activeUploadPromise){
    uploadGeneration++;
    cancelCurrentUpload();
    await activeUploadPromise.catch(()=>{});
  }
  if(switchEpoch!==rootContextEpoch.value||!user.value){rootSwitching.value=false;return;}
  selectedRootID.value=target?.rootID??"";
  selectedRootSnapshot.value=target;
  legacyRootSelected.value=chooseLegacy;
  try{if(chooseLegacy)sessionStorage.setItem(ROOT_SELECTION_STORAGE_KEY,LEGACY_ROOT_SELECTION);else if(target)sessionStorage.setItem(ROOT_SELECTION_STORAGE_KEY,target.rootID);else sessionStorage.removeItem(ROOT_SELECTION_STORAGE_KEY);}catch{}
  rootSwitching.value=false;
  if((target||chooseLegacy)&&active.value==="files")void loadFiles(".");
  if((target||chooseLegacy)&&active.value==="settings"&&user.value?.role==="admin")void refreshTaskCenter();
  if((target||chooseLegacy)&&active.value==="settings")void loadMyShares();
}
async function refreshRootDiscovery(){
  if(rootSwitching.value)return;
  const request=++rootDiscoveryRequest;
  lastRootDiscoveryAt=Date.now();
  rootDiscoveryLoading.value=true;
  try{
    const response=await fetch("/api/v2/roots",{credentials:"same-origin",cache:"no-store"});
    if(request!==rootDiscoveryRequest||rootSwitching.value)return;
    const discovery=await readRootDiscoveryResponse(response);
    if(request!==rootDiscoveryRequest||rootSwitching.value)return;
    if(discovery.kind==="legacy"){
      rootDiscoveryError.value="";
      if(multiRootMode.value){await switchRoot(LEGACY_ROOT_SELECTION);}
      else if(currentRootContextKey()!=="v1:compatibility"){
        rootContextController.abort();rootContextController=new AbortController();rootContextEpoch.value++;
      }
      rootDiscoveryState.value="legacy";sharedRoots.value=[];rootDiscoveryError.value="";legacyRootSelected.value=false;
      if(user.value)void loadFiles(".");
      return;
    }
    if(discovery.kind==="error"){
      rootDiscoveryError.value=discovery.message;
      if(rootDiscoveryState.value!=="multi")rootDiscoveryState.value="error";
      console.warn("root discovery failed",discovery.message);
      return;
    }
    const result=discovery;
    const wasMulti=multiRootMode.value;
    const previous=selectedRoot.value;
    sharedRoots.value=Array.isArray(result.roots)?result.roots.filter(root=>root.compatibility!==true&&typeof root.rootID==="string"&&Number.isSafeInteger(root.generation)&&root.generation>0):[];
    rootDiscoveryState.value="multi";rootDiscoveryError.value="";
    let preferred="";
    try{preferred=sessionStorage.getItem(ROOT_SELECTION_STORAGE_KEY)??"";}catch{}
    const current=sharedRoots.value.find(root=>root.rootID===selectedRootID.value);
    const remembered=preferred&&preferred!==LEGACY_ROOT_SELECTION?sharedRoots.value.find(root=>root.rootID===preferred):null;
    const target=current??(!selectedRootID.value&&!legacyRootSelected.value?remembered:null);
    if(target){await switchRoot(target.rootID,previous?.rootID===target.rootID&&previous.generation!==target.generation);return;}
    if(!legacyRootSelected.value||selectedRootID.value)await switchRoot(LEGACY_ROOT_SELECTION);
    else if(!wasMulti){rootContextController.abort();rootContextController=new AbortController();rootContextEpoch.value++;resetRootScopedState();}
  }catch(error){
    if(request!==rootDiscoveryRequest)return;
    rootDiscoveryError.value=rootDiscoveryNetworkError(error);
    if(rootDiscoveryState.value!=="multi")rootDiscoveryState.value="error";
    if(!isAbortError(error))console.warn("root discovery failed",error);
  }finally{
    if(request===rootDiscoveryRequest)rootDiscoveryLoading.value=false;
  }
}
const trashTarget=ref<FileEntry|null>(null);
type TrashEntry = {id:string;name:string;originalPath:string;deletedAt:string};
const trashItems=ref<TrashEntry[]>([]);
const trashRetention=ref<{enabled:boolean;days:number}|null>(null);
const trashLoading=ref(false);
const trashError=ref("");
const showingTrash=ref(false);
const uploadContinuation=ref<UploadContinuation<File>|null>(null);
const currentUploadContext=computed<UploadBatchContext>(()=>({
  username:user.value?.username??"",
  rootID:multiRootMode.value&&!legacyRootSelected.value?selectedRootID.value:"",
  rootGeneration:multiRootMode.value&&!legacyRootSelected.value?selectedRootGeneration.value:0,
  rootEpoch:rootContextEpoch.value,
  directory:filesPath.value
}));
const trashPresentation=computed(()=>trashPresentationState({loading:trashLoading.value,error:trashError.value,entries:trashItems.value}));
const canContinueUploads=computed(()=>!uploadBusy.value&&!filesLoading.value&&currentFolderCanWrite.value&&
  !showingTrash.value&&!searchingFiles.value&&uploadContinuationIsCurrent(uploadContinuation.value,currentUploadContext.value));
watch(()=>user.value?.username,()=>{uploadContinuation.value=null;});
const previewItem=ref<FileEntry|null>(null);
const previewText=ref("");
const previewError=ref("");
const selectedUpload=ref<HTMLInputElement|null>(null);
const pathSegments=computed(()=>{
  const p=filesPath.value;
  if(p===".")return [{name:sharedRootName.value,path:"."}];
  const parts=p.split("/");
  return [{name:sharedRootName.value,path:"."},...parts.map((name,index)=>({name,path:parts.slice(0,index+1).join("/")}))];
});
async function loadFiles(target=filesPath.value,more=false){
  if(!user.value)return;
  const request=++fileListRequestGeneration;
  const context=rootContextEpoch.value;
  if(!more&&target!==filesPath.value)uploadContinuation.value=null;
  if(rootDiscoveryState.value==="error"||(multiRootMode.value&&!legacyRootSelected.value&&!selectedRootID.value)){
    fileEntries.value=[];fileNextCursor.value="";filesPath.value=".";currentFolderCanWrite.value=false;
    filesError.value=rootDiscoveryError.value||"当前账号没有可访问的共享目录。";return;
  }
  filesLoading.value=true;filesError.value="";
  if(!more){searchTruncated.value=false;}
  try{
    const root=await jsonGet<{name:string}>(scopedApiPath("/api/v1/files/root"));
    if(request!==fileListRequestGeneration||context!==rootContextEpoch.value)return;
    sharedRootName.value=root.name;
    const cursor=more?fileNextCursor.value:"";
    const query=new URLSearchParams({path:target,limit:"100",cursor,sort:fileSortKey.value,dir:fileSortDirection.value});
    const data=await jsonGet<{entries:FileEntry[];nextCursor:string;canWrite:boolean}>(scopedApiPath("/api/v1/files")+"?"+query.toString());
    if(request!==fileListRequestGeneration||context!==rootContextEpoch.value)return;
    filesPath.value=target;
    currentFolderCanWrite.value=data.canWrite===true;
    searchingFiles.value=false;
    fileEntries.value=more?[...fileEntries.value,...data.entries]:data.entries;
    fileNextCursor.value=data.nextCursor;
    searchTruncated.value=false;
    if(!more)checkedFiles.value=[];
  }catch(e){if(request===fileListRequestGeneration&&!isAbortError(e))filesError.value="读取目录失败："+describeRootOperationFailure(e);}
  finally{if(request===fileListRequestGeneration)filesLoading.value=false;}
}
async function reloadTasks(){
  if(user.value?.role!=="admin"||!rootFeatureContextReady.value)return;
  try{
    tasks.value=(await jsonGet<{tasks:BackendTask[]}>(scopedApiPath("/api/v1/tasks"))).tasks;
    taskError.value="";
    if(active.value==="settings"&&(tasks.value.some(task=>task.running)||taskHistory.value.some(run=>run.running)))void refreshLatestTaskHistory();
  }
  catch(e){if(!isAbortError(e))taskError.value="读取任务状态失败："+String(e);}
}
async function reloadTaskHistory(reset=true){
  if(user.value?.role!=="admin"||!rootFeatureContextReady.value)return;
  if(!reset&&taskHistoryLoading.value)return;
  if(reset)taskHistoryGeneration+=1;
  const generation=taskHistoryGeneration;
  const cursor=reset?"":taskHistoryNextCursor.value;
  if(!reset&&!cursor)return;
  taskHistoryLoading.value=true;
  taskHistoryError.value="";
  const query=new URLSearchParams({limit:"20"});
  if(cursor)query.set("before",cursor);
  try{
    const page=await jsonGet<{runs:TaskRun[];nextCursor:string}>(scopedApiPath("/api/v1/tasks/history")+"?"+query.toString());
    if(generation!==taskHistoryGeneration)return;
    if(reset)taskHistory.value=page.runs.slice(0,maxLoadedTaskHistory);
    else{
      const existing=new Set(taskHistory.value.map(run=>run.id));
      taskHistory.value=[...taskHistory.value,...page.runs.filter(run=>!existing.has(run.id))].slice(0,maxLoadedTaskHistory);
    }
    taskHistoryNextCursor.value=taskHistory.value.length>=maxLoadedTaskHistory?"":page.nextCursor;
  }catch{
    if(generation===taskHistoryGeneration)taskHistoryError.value="读取任务记录失败，请重试。";
  }finally{
    if(generation===taskHistoryGeneration)taskHistoryLoading.value=false;
  }
}
async function refreshTaskCenter(){
  await Promise.all([reloadTasks(),reloadTaskHistory(true)]);
}
async function refreshLatestTaskHistory(){
  if(taskHistoryLoading.value||taskHistoryLatestRefreshing||user.value?.role!=="admin"||!rootFeatureContextReady.value)return;
  taskHistoryLatestRefreshing=true;
  const generation=taskHistoryGeneration;
  try{
    const page=await jsonGet<{runs:TaskRun[];nextCursor:string}>(scopedApiPath("/api/v1/tasks/history")+"?limit=20");
    if(generation!==taskHistoryGeneration)return;
    const latestIDs=new Set(page.runs.map(run=>run.id));
    taskHistory.value=[...page.runs,...taskHistory.value.filter(run=>!latestIDs.has(run.id))].slice(0,maxLoadedTaskHistory);
    taskHistoryNextCursor.value=taskHistory.value.length>=maxLoadedTaskHistory?"":page.nextCursor;
  }catch{/* Keep the last successful history visible while polling. */}
  finally{taskHistoryLatestRefreshing=false;}
}
async function taskControl(task:BackendTask,action:"cancel"|"retry"){
  try{
    const response=await rootFetch(scopedApiPath(`/api/v1/tasks/${task.kind}/${action}`),{method:"POST",headers:{"X-LightIsle-Request":"1"},credentials:"same-origin"});
    if(!response.ok)throw new Error("HTTP "+response.status);
    await refreshTaskCenter();
  }catch(e){if(!isAbortError(e))taskError.value="任务操作失败："+String(e);}
}
function startMediaTask(kind:"gallery"|"cinema"){
  void taskControl({kind,running:false,progress:0},"retry");
}
async function runFileSearch(){
  const query=fileSearch.value.trim();
  if(query.length<2){filesError.value="至少输入两个搜索字符";active.value="files";return;}
  uploadContinuation.value=null;
  filesPath.value=".";
  fileEntries.value=[];
  fileNextCursor.value="";
  checkedFiles.value=[];
  searchTruncated.value=false;
  searchingFiles.value=true;
  currentFolderCanWrite.value=false;
  active.value="files";
  filesLoading.value=true;filesError.value="";
  try{
    const engine=searchViaSpotlight.value?"&engine=spotlight":"";
    const result=await jsonGet<{entries:FileEntry[];truncated:boolean;canWrite:boolean}>(scopedApiPath("/api/v1/files/search")+"?path=.&query="+encodeURIComponent(query)+engine);
    fileEntries.value=result.entries;fileNextCursor.value="";searchTruncated.value=result.truncated;
    currentFolderCanWrite.value=result.canWrite===true;
  }catch(e){if(!isAbortError(e))filesError.value="搜索失败："+String(e);}
  finally{filesLoading.value=false;}
}
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
async function purgeTrashItem(item:TrashEntry){
  if(!window.confirm(`永久删除“${item.name}”？此操作无法撤销。`))return;
  trashError.value="";
  try{
    const res=await rootFetch(scopedApiPath("/api/v1/files/trash/"+encodeURIComponent(item.id)),{method:"DELETE",headers:{"X-LightIsle-Request":"1"},credentials:"same-origin"});
    if(!res.ok)throw new Error("HTTP "+res.status);
    await loadTrash();
  }catch(e){if(!isAbortError(e))trashError.value="永久删除失败："+String(e);}
}
async function editGrants(account:Account){
  if(!rootFeatureContextReady.value){grantError.value="请先选择共享目录，再管理该目录的授权。";return;}
  grantUser.value=account;grantPath.value=".";grantWrite.value=false;grantError.value="";
  try{
    const endpoint=multiRootMode.value&&!legacyRootSelected.value?`/api/v2/roots/${encodeURIComponent(selectedRootID.value)}/users/${account.id}/file-grants`:`/api/v1/users/${account.id}/file-grants`;
    const data=await jsonGet<{grants:FileGrant[]}>(endpoint);
    grants.value=data.grants;
  }catch(e){if(!isAbortError(e))grantError.value="读取文件权限失败："+String(e);}
}
async function saveGrant(path=grantPath.value,remove=false){
  if(!grantUser.value||!rootFeatureContextReady.value)return;
  grantBusy.value=true;grantError.value="";
  try{
    const endpoint=multiRootMode.value&&!legacyRootSelected.value?`/api/v2/roots/${encodeURIComponent(selectedRootID.value)}/users/${grantUser.value.id}/file-grants`:`/api/v1/users/${grantUser.value.id}/file-grants`;
    const response=await rootFetch(remove?endpoint+"?path="+encodeURIComponent(path):endpoint,{
      method:remove?"DELETE":"PUT",credentials:"same-origin",
      headers:{"Content-Type":"application/json","X-LightIsle-Request":"1"},
      ...(!remove?{body:JSON.stringify({path,canWrite:grantWrite.value})}:{})
    });
    if(!response.ok){const result=await response.json().catch(()=>({error:"request_failed"}));throw new Error(result.error??"request_failed");}
    await editGrants(grantUser.value);
  }catch(e){if(!isAbortError(e))grantError.value="更新权限失败："+(e instanceof Error?e.message:"未知错误");}
  finally{grantBusy.value=false;}
}
async function loadTrash(){
  const request=++trashRequestGeneration;
  const epoch=rootContextEpoch.value;
  trashLoading.value=true;trashError.value="";
  try{
    const result=await jsonGet<{entries:TrashEntry[]}>(scopedApiPath("/api/v1/files/trash"));
    if(request!==trashRequestGeneration||epoch!==rootContextEpoch.value)return;
    trashItems.value=result.entries.sort((a,b)=>b.deletedAt.localeCompare(a.deletedAt));
    void jsonGet<{enabled:boolean;days:number}>(scopedApiPath("/api/v1/trash/retention")).then(value=>{
      if(request===trashRequestGeneration&&epoch===rootContextEpoch.value)trashRetention.value=value;
    }).catch(()=>{});
  }catch(e){if(request===trashRequestGeneration&&epoch===rootContextEpoch.value&&!isAbortError(e))trashError.value="读取回收站失败："+(e instanceof Error?e.message:"未知错误");}
  finally{
    if(request===trashRequestGeneration){
      trashLoading.value=false;
      if(epoch!==rootContextEpoch.value)trashError.value="共享目录已变化，请重新加载回收站。";
    }
  }
}
async function openTrash(){
  showingTrash.value=!showingTrash.value;
  if(showingTrash.value)await loadTrash();
}
async function restoreTrash(entry:TrashEntry){
  trashError.value="";
  try{
    await jsonWrite(scopedApiPath("/api/v1/files/trash/"+encodeURIComponent(entry.id)+"/restore"),"POST");
    await loadTrash();
    await loadFiles();
  }catch(e){if(!isAbortError(e))trashError.value="恢复失败（原路径可能已被占用或不存在）："+(e instanceof Error?e.message:"未知错误");}
}
async function previewFile(item:FileEntry){
  previewItem.value=item;previewText.value="";previewError.value="";
  const scopeEpoch=rootContextEpoch.value;
  if(/\.(txt|md|json|log)$/i.test(item.name)){
    try{
      const response=await rootFetch(scopedApiPath("/api/v1/files/preview")+"?path="+encodeURIComponent(item.path),{credentials:"same-origin"});
      if(!response.ok)throw new Error("格式不支持或文件太大");
      const text=await response.text();
      if(scopeEpoch===rootContextEpoch.value)previewText.value=text;
    }catch(e){if(scopeEpoch===rootContextEpoch.value&&!isAbortError(e))previewError.value=e instanceof Error?e.message:"无法预览";}
  }else if(!/\.(jpe?g|png|gif|webp|heic|heif|pdf|mp4|webm|m4v)$/i.test(item.name)){
    previewError.value="该文件暂不支持在线预览，请下载后使用本机应用打开。";
  }
}
const previewURL=computed(()=>{
  const item=previewItem.value;
  if(!item)return "";
  if(/\.(heic|heif)$/i.test(item.name))return fileThumbnailURL(item,2048);
  return scopedMediaPath("/api/v1/files/preview?path="+encodeURIComponent(item.path));
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
    await jsonWrite(scopedApiPath("/api/v1/files/folders"),"POST",{path:full});
    newFolderName.value="";await loadFiles();
  }catch(e){if(!isAbortError(e))filesError.value="新建文件夹失败："+(e instanceof Error?e.message:"未知错误");}
}
function uploadErrorLabel(err:unknown):string {
  const code=err instanceof Error?err.message:"unknown_error";
  const messages:Record<string,string>={
    file_already_exists:"目标目录中已经存在同名文件。为防止覆盖原文件，请先重命名后重新上传。",
    upload_busy:"该文件正在被另一项上传占用，请等待后重试。",
    upload_inventory_limit:"上传任务数量达到上限，请清理过期任务后重试。",
    insufficient_storage_space:"目标硬盘剩余空间不足，已停止写入且保留上传进度。请清理空间后选择同一文件继续。",
    shared_volume_offline:"存储硬盘已离线，请接回原硬盘并重新连接。",
    permission_denied:"文件夹或磁盘不可写，请检查目录权限和磁盘格式。",
    file_permission_denied:"当前账户没有此文件夹的写入权限。",
    upload_too_large:"文件超过 32 GiB 上限。",
    upload_owner_mismatch:"续传记录与当前账号不匹配，请重新选择文件。",
    upload_outcome_uncertain:"服务未能确认文件是否写入成功，请先刷新目录核对，避免重复上传。",
    storage_durability_failure:"存储设备未能确认数据持久写入，请检查磁盘连接和健康状态。",
    invalid_chunk_size:"上传分块异常，请重新选择文件。",
    root_scope_unavailable:"共享目录尚未准备好，请刷新后重试。",
    root_generation_changed:"共享目录已变化，请刷新并重新选择目标。",
  };
  if(code.startsWith("chunk_error_"))return "传输连接异常（"+code.slice(12)+"），请检查网络后重新选择同一文件续传。";
  return messages[code]??"上传失败："+code;
}
function chooseUploadFiles(){
  if(uploadBusy.value || filesLoading.value || showingTrash.value || !currentFolderCanWrite.value)return;
  if(selectedUpload.value){selectedUpload.value.value="";selectedUpload.value.click();}
}
function startUpload(e:Event){
  const input=e.target as HTMLInputElement;
  const files=Array.from(input.files??[]);
  input.value=""; // Selecting the same file again must trigger a new change event.
  enqueueUploads(files);
}
function dragOverUpload(e:DragEvent){if(currentFolderCanWrite.value&&!showingTrash.value&&!uploadBusy.value){e.preventDefault();uploadDropActive.value=true;}}
function dragLeaveUpload(e:DragEvent){if(!e.currentTarget || !(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node|null))uploadDropActive.value=false;}
function dropUpload(e:DragEvent){
  e.preventDefault();uploadDropActive.value=false;
  if(!currentFolderCanWrite.value||uploadBusy.value||showingTrash.value)return;
  enqueueUploads(Array.from(e.dataTransfer?.files??[]));
}
function launchUploadBatch(files:File[],context:UploadBatchContext){
  const running=uploadSelected(files,context);
  activeUploadPromise=running;
  const finished=()=>{if(activeUploadPromise===running)activeUploadPromise=null;};
  void running.then(finished,finished);
}
function enqueueUploads(files:File[]){
  if(!currentFolderCanWrite.value){filesError.value="当前目录为只读，请选择有写入权限的目录。";return;}
  if(!files.length)return;
  if(uploadBusy.value)return;
  uploadContinuation.value=null;
  launchUploadBatch(files,currentUploadContext.value);
}
function continueIncompleteUploads(){
  const continuation=uploadContinuation.value;
  if(!continuation||!canContinueUploads.value){uploadContinuation.value=null;return;}
  uploadContinuation.value=null;
  launchUploadBatch(continuation.files,continuation.context);
}
function closeUploadActivity(){
  uploadContinuation.value=null;
  uploadStage.value="idle";uploadResult.value="";uploadProgress.value="";uploadFailure.value="";
}
async function uploadSelected(files:File[],batchContext:UploadBatchContext){
  uploadContinuation.value=null;
  const uploadConflictPolicy=uploadAutoRenameConflicts.value?"rename":"";
  const uploadUsername=batchContext.username;
  if(!uploadUsername){filesError.value="登录状态已失效，请重新登录后上传。";return;}
  if(!uploadContextMatches(batchContext,currentUploadContext.value))return;
  const uploadDirectory=batchContext.directory;
  const uploadRootID=batchContext.rootID;
  const uploadRootGeneration=batchContext.rootGeneration;
  const uploadRootEpoch=batchContext.rootEpoch;
  const uploadPath=(path:string)=>rootApiPath(uploadRootID||undefined,path);
  const generation=++uploadGeneration;
  const isCurrentUpload=()=>generation===uploadGeneration&&user.value?.username===uploadUsername&&
    rootContextEpoch.value===uploadRootEpoch&&selectedRootID.value===uploadRootID&&selectedRootGeneration.value===uploadRootGeneration;
  uploadBusy.value=true;filesError.value="";uploadCancelled=false;
  uploadCompleted.value=0;uploadCurrent.value=0;uploadTotal.value=files.length;
  uploadResult.value="";uploadFailure.value="";uploadStage.value="hashing";uploadPercent.value=0;
  for(const [fileIndex,file] of files.entries()){
    uploadCurrent.value=fileIndex+1;uploadFileName.value=file.name;
    uploadSize.value=file.size;uploadTransferred.value=0;uploadPercent.value=0;
    if(uploadCancelled||!isCurrentUpload())break;
    if(!isWithinUploadSizeLimit(file.size)){
      uploadStage.value="error";uploadFailure.value="文件超过 32 GiB 上限，未开始校验或上传。";
      break;
    }
    let taskId="";
    let savedKey="";
    let resumable=false;
    const controller=new AbortController();
    uploadAbortController=controller;
    const ensureCurrentUpload=()=>{
      if(uploadCancelled||!isCurrentUpload()){
        controller.abort();
        const error=new Error("upload_cancelled");error.name="AbortError";throw error;
      }
    };
    try{
      const dest=uploadDirectory==="."?file.name:uploadDirectory+"/"+file.name;
      const legacyKey=uploadRootID?"":"lightisle_upload_"+dest+"_"+file.size;
      let key="";
      let prefix="";
      if(supportsContentFingerprint()){
        uploadStage.value="hashing";
        uploadProgress.value=file.name+" · 正在完整校验文件内容 0%";
        const fingerprint=await fingerprintFile(file,{
          signal:controller.signal,
          onProgress:(processed,total)=>{
            uploadPercent.value=Math.round(100*processed/Math.max(total,1));
            uploadProgress.value=file.name+" · 正在完整校验文件内容 "+Math.round(100*processed/Math.max(total,1))+"%";
          }
        });
        ensureCurrentUpload();
        const identity=await uploadSessionIdentity(uploadUsername,dest,file,fingerprint,globalThis.crypto,uploadRootID,uploadRootGeneration);
        ensureCurrentUpload();
        key=identity.key;
        prefix=identity.prefix;
        resumable=true;
        savedKey=key;
      }else{
        uploadStage.value="uploading";
        uploadProgress.value=file.name+" · 当前连接不支持内容校验，此次上传无法断点续传";
      }

      const staleIDs=uploadResumeStorage.collectStaleIDs({legacyKey,prefix,key});
      await Promise.all(staleIDs.map(id=>abortUpload(id,uploadPath)));
      ensureCurrentUpload();

      const Upload=(id:string)=>uploadPath("/api/v1/uploads/"+encodeURIComponent(id));
      let state:{id:string;offset:number;size:number;path?:string};
      let saved:string|null=null;
      if(resumable){
        const previous=uploadResumeStorage.read(key);
        saved=previous.saved;
        if(!previous.resumable){resumable=false;savedKey="";}
      }
      if(saved){
        taskId=saved;
        try{state=await jsonGet<typeof state>(Upload(saved),controller.signal);ensureCurrentUpload();}
        catch(err){
          if(uploadCancelled)throw err;
          // jsonGet surfaces the server's JSON error code ("not_found") rather
          // than the HTTP status. Recreate only a genuinely missing upload;
          // permission and generation errors must remain visible to the user.
          if(!(err instanceof Error)||err.message!=="not_found")throw err;
          uploadResumeStorage.remove(key);
          taskId="";
          state=await jsonWrite<typeof state>(uploadPath("/api/v1/uploads"),"POST",{path:dest,size:file.size,onConflict:uploadConflictPolicy},controller.signal);
          state=adoptUploadTask(state,id=>{taskId=id;},ensureCurrentUpload);
        }
      }else{
        state=await jsonWrite<typeof state>(uploadPath("/api/v1/uploads"),"POST",{path:dest,size:file.size,onConflict:uploadConflictPolicy},controller.signal);
        state=adoptUploadTask(state,id=>{taskId=id;},ensureCurrentUpload);
      }
      taskId=state.id;
      if(state.path&&state.path!==dest)uploadFileName.value=state.path+"（自动改名）";
      uploadStage.value="uploading";uploadTransferred.value=state.offset;
      uploadPercent.value=Math.round(100*state.offset/Math.max(file.size,1));
      if(resumable){
        if(!uploadResumeStorage.save(key,state.id)){resumable=false;savedKey="";}
      }
      while(state.offset<file.size){
        if(uploadCancelled)throw new Error("cancelled");
        const chunk=file.slice(state.offset,Math.min(state.offset+4*1024*1024,file.size));
        const response=await rootFetch(Upload(state.id),{method:"PATCH",credentials:"same-origin",
          headers:{"X-LightIsle-Request":"1","X-Upload-Offset":String(state.offset)},body:chunk,signal:controller.signal});
        ensureCurrentUpload();
        if(!response.ok){
          if(response.status===409){state=await jsonGet<typeof state>(Upload(state.id),controller.signal);continue;}
          if(response.status===507)throw new Error("insufficient_storage_space");
          throw new Error("chunk_error_"+response.status);
        }
        state=await response.json() as typeof state;
        ensureCurrentUpload();
        uploadTransferred.value=state.offset;
        uploadPercent.value=Math.round(100*state.offset/Math.max(file.size,1));
        uploadProgress.value=file.name+" · "+Math.round(100*state.offset/Math.max(file.size,1))+"%";
      }
      if(uploadCancelled)throw new Error("cancelled");
      await jsonWrite(Upload(state.id)+"/complete","POST",{},controller.signal);
      ensureCurrentUpload();
      if(resumable)uploadResumeStorage.remove(key);
      uploadCompleted.value+=1;uploadPercent.value=100;uploadProgress.value="";
    }catch(err){
      if(uploadCancelled){
        if(taskId)await abortUpload(taskId,uploadPath);
        if(savedKey)uploadResumeStorage.remove(savedKey);
        uploadProgress.value="";
        if(isCurrentUpload()){uploadStage.value="cancelled";uploadFailure.value="已取消上传和文件校验。";}
      }else{
        if(taskId&&!resumable)await abortUpload(taskId,uploadPath);
        if(isCurrentUpload()){uploadStage.value="error";uploadFailure.value="上传「"+file.name+"」失败："+uploadErrorLabel(err)+
          (resumable?"；重新选择相同文件可从已完成部分继续。":"；当前连接不支持完整内容校验，无法安全续传，请重新选择文件从头上传。");
        }
      }
      break;
    }finally{uploadAbortController=null;}
  }
  if(isCurrentUpload()){
    uploadBusy.value=false;
    if(uploadCancelled&&!uploadFailure.value){uploadFailure.value="已取消上传和文件校验。";uploadStage.value="cancelled";}
    if(uploadCompleted.value===files.length){uploadStage.value="done";uploadResult.value="已成功上传 "+uploadCompleted.value+" 个文件。";}
    else if(uploadCompleted.value>0){uploadResult.value="已完成 "+uploadCompleted.value+" / "+files.length+" 个文件。";}
    const uploadContextStillVisible=uploadContextMatches(batchContext,currentUploadContext.value)&&!showingTrash.value&&!searchingFiles.value;
    uploadContinuation.value=uploadContextStillVisible&&uploadCompleted.value<files.length
      ?createUploadContinuation(files,uploadCompleted.value,batchContext)
      :null;
    if(uploadContextStillVisible)await refreshAfterPublishedUpload(uploadCompleted.value,()=>loadFiles());
  }
}
async function abortUpload(id:string,path:(path:string)=>string=scopedApiPath){
  await rootFetch(path("/api/v1/uploads/"+encodeURIComponent(id)),{
    method:"DELETE",headers:{"X-LightIsle-Request":"1"},credentials:"same-origin"
  },true).catch(()=>{});
}
async function batchTrash(){
  if(!checkedFiles.value.length)return;
  if(checkedFiles.value.some(path=>!fileEntries.value.some(entry=>entry.path===path&&canWriteEntry(entry)))){
    filesError.value="所选项目包含只读或已变更的项目，请刷新后重试。";return;
  }
  if(!window.confirm("将选中的 "+checkedFiles.value.length+" 项移到回收站？"))return;
  try{
    const result=await jsonWrite<{results:{success:boolean;path:string}[]}>(scopedApiPath("/api/v1/files/batch"),"POST",
      {action:"trash",paths:checkedFiles.value.slice(0,50)});
    const failed=result.results.filter(x=>!x.success).length;
    if(failed)filesError.value=failed+" 项处理失败";
    await loadFiles();
  }catch(e){if(!isAbortError(e))filesError.value="批量操作失败："+(e instanceof Error?e.message:"未知错误");}
}
function openShareDialog(item:FileEntry){
  if(item.type!=="file"&&item.type!=="folder")return;
  sharingFile.value=item;
  shareHours.value=24;
  sharePassword.value="";shareMaxDownloads.value=0;
  shareError.value="";shareCreatedLink.value="";shareCopied.value="";
}
async function createFileShare(){
  const item=sharingFile.value;
  if(!item||shareCreating.value)return;
  if(sharePassword.value.length>0&&(Array.from(sharePassword.value).length<4||new TextEncoder().encode(sharePassword.value).length>128)){
    shareError.value="访问密码应为 4 至 128 字节，也可以留空不设置密码。";
    return;
  }
  if(!Number.isInteger(shareMaxDownloads.value)||shareMaxDownloads.value<0||shareMaxDownloads.value>100000){
    shareError.value="最大下载次数必须在 0 至 100000 之间，0 表示不限制。";
    return;
  }
  shareCreating.value=true;shareError.value="";shareCopied.value="";
  try{
    const rootID=multiRootMode.value&&!legacyRootSelected.value?selectedRootID.value:"";
    const generation=rootID?selectedRootGeneration.value:0;
    const result=await jsonWrite<{token:string;share:FileShare}>(scopedApiPath("/api/v1/file-shares"),"POST",
      {path:item.path,hours:shareHours.value,password:sharePassword.value,maxDownloads:shareMaxDownloads.value});
    if(rootID!==selectedRootID.value||generation!==selectedRootGeneration.value)return;
    shareCreatedLink.value=window.location.origin+scopedMediaPath("/api/v1/public/file/"+encodeURIComponent(result.token));
    await loadMyShares();
  }catch(e){
    if(isAbortError(e))return;
    const code=e instanceof Error?e.message:"request_failed";
    shareError.value=({
      too_many_shares:"当前账号已经创建 100 个有效链接，请撤销旧链接后重试。",
      file_too_large_to_share:"单文件超过 2 GiB，暂不能创建分享。",
      unsupported_file_identity:"无法确认所选对象的身份，请刷新文件列表后重试。",
      file_permission_denied:"你已失去此文件的读取权限。",
      invalid_share_request:"分享参数无效，请检查密码长度和下载次数。",
    } as Record<string,string>)[code]??("无法创建分享："+code);
  }finally{shareCreating.value=false;}
}
async function copyShareLink(){
  if(!shareCreatedLink.value)return;
  try{
    await navigator.clipboard.writeText(shareCreatedLink.value);
    shareCopied.value="已复制";
  }catch{
    shareLinkInput.value?.select();
    shareCopied.value="已选中链接，请手动复制";
  }
}
async function loadMyShares(){
  if(!user.value||sharesLoading.value||!rootFeatureContextReady.value)return;
  sharesLoading.value=true;sharesError.value="";
  try{
    const result=await jsonGet<{shares:FileShare[]}>(scopedApiPath("/api/v1/file-shares"));
    activeShares.value=result.shares;sharesLoaded.value=true;
  }catch(e){if(!isAbortError(e))sharesError.value="读取分享列表失败："+(e instanceof Error?e.message:"请求失败");}
  finally{sharesLoading.value=false;}
}
async function revokeFileShare(share:FileShare){
  if(!window.confirm("停止分享“"+share.path+"”？已经发出的下载链接将立即失效。"))return;
  try{
    const response=await rootFetch(scopedApiPath("/api/v1/file-shares/"+encodeURIComponent(share.id)),{
      method:"DELETE",credentials:"same-origin",headers:{"X-LightIsle-Request":"1"}
    });
    if(!response.ok)throw new Error("HTTP "+response.status);
    await loadMyShares();
    if(sharingFile.value?.path===share.path)shareCreatedLink.value="";
  }catch(e){if(!isAbortError(e))sharesError.value="撤销分享失败："+(e instanceof Error?e.message:"请求失败");}
}
async function downloadFile(item:FileEntry){
  if(item.type==="folder"){
    try{
      const response=await rootFetch(scopedApiPath("/api/v1/files/archive")+"?path="+encodeURIComponent(item.path),{
        method:"HEAD",credentials:"same-origin",cache:"no-store",
      });
      if(!response.ok){
        filesError.value=response.status===413
          ?"这个文件夹超过 ZIP 下载的限制（2 GiB、2,000 项或 16 层），请打开文件夹分批下载。"
          :response.status===403?"没有读取该文件夹的权限。"
          :response.status===404?"该文件夹已不存在，请刷新列表。"
          :"无法准备文件夹下载（HTTP "+response.status+"），请重试。";
        return;
      }
    }catch(e){
      if(isAbortError(e))return;
      filesError.value="准备文件夹下载失败："+(e instanceof Error?e.message:"网络异常");
      return;
    }
  }
  filesError.value="";
  const a=document.createElement("a");
  a.href=scopedMediaPath((item.type==="folder"?"/api/v1/files/archive?path=":"/api/v1/files/content?path=")+encodeURIComponent(item.path));
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
    const response=await rootFetch(scopedApiPath("/api/v1/files")+"?path="+encodeURIComponent(filepath),{
      method:"DELETE",credentials:"same-origin",headers:{"X-LightIsle-Request":"1"}
    });
    if(!response.ok)throw new Error("HTTP "+response.status);
    await loadFiles();
    if(showingTrash.value)await loadTrash();
  }catch(e){if(!isAbortError(e))filesError.value="移动 "+name+" 到回收站失败："+(e instanceof Error?e.message:"未知错误");}
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
    const status=await jsonGet<{configured:boolean}>("/api/v1/auth/status");
    configured.value=status.configured;
    if(status.configured){
      try {
        const identity=await jsonGet<{username:string;role:"admin"|"member"}>("/api/v1/auth/me");
        user.value=identity;
        await refreshRootDiscovery();
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
    const result=await jsonWrite<{username:string;role:"admin"|"member"}>("/api/v1/auth/login","POST",{
      username:authUsername.value,password:authPassword.value
    });
    user.value=result;
    authPassword.value="";
    await update();
    await refreshRootDiscovery();
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
  if(activeUploadPromise){
    uploadGeneration+=1;
    cancelCurrentUpload();
    await activeUploadPromise.catch(()=>{});
  }
  try {await jsonWrite("/api/v1/auth/logout","POST");}catch {/* local service might have closed */}
  rootContextController.abort();rootContextController=new AbortController();
  user.value=null;stats.value=null;accounts.value=[];active.value="overview";
  rootDiscoveryRequest++;rootContextEpoch.value++;rootSwitching.value=false;rootDiscoveryState.value="unknown";sharedRoots.value=[];selectedRootID.value="";selectedRootSnapshot.value=null;legacyRootSelected.value=false;rootDiscoveryError.value="";lastRootDiscoveryAt=0;
  resetRootScopedState();
  currentFolderCanWrite.value=false;checkedFiles.value=[];
  currentPassword.value="";nextPassword.value="";repeatPassword.value="";
  loginSessions.value=[];sessionsLoaded.value=false;sessionsTruncated.value=false;sessionsError.value="";sessionsMessage.value="";
  resetMember.value=null;resetPassword.value="";resetConfirm.value="";resetError.value="";resetNotice.value="";
  sharingFile.value=null;shareCreatedLink.value="";shareError.value="";shareCopied.value="";
  activeShares.value=[];sharesLoaded.value=false;sharesError.value="";
}
function openMemberReset(account:Account){
  if(account.role!=="member"||!account.enabled)return;
  resetMember.value=account;
  resetPassword.value="";resetConfirm.value="";resetError.value="";resetNotice.value="";
  grantUser.value=null;
}
function closeMemberReset(){
  if(resetBusy.value)return;
  resetMember.value=null;resetPassword.value="";resetConfirm.value="";resetError.value="";
}
async function submitMemberReset(){
  const account=resetMember.value;
  if(!account||resetBusy.value||user.value?.role!=="admin")return;
  resetError.value="";
  if(resetPassword.value.length<12||resetPassword.value.length>256||resetPassword.value.trim()!==resetPassword.value){
    resetError.value="密码长度需为 12–256 位，且两端不能有空格。";return;
  }
  if(resetPassword.value!==resetConfirm.value){resetError.value="两次输入的密码不一致。";return;}
  if(!window.confirm("确认修改“"+account.username+"”的登录密码？该成员的所有会话将被撤销。"))return;
  resetBusy.value=true;
  try{
    await jsonWrite("/api/v1/users/"+encodeURIComponent(String(account.id))+"/password","POST",{password:resetPassword.value});
    resetMember.value=null;resetPassword.value="";resetConfirm.value="";
    resetNotice.value="已更新“"+account.username+"”的密码并使原有会话失效。";
  }catch(e){
    const code=e instanceof Error?e.message:"request_failed";
    resetError.value=({
      invalid_new_password:"新密码不符合安全要求。",
      protected_account:"该账号不可重置或已停用。",
      user_not_found:"找不到该账号，请刷新列表。",
    } as Record<string,string>)[code]??("重置失败："+code);
  }finally{resetBusy.value=false;}
}
async function loadLoginSessions(){
  if(!user.value||sessionsLoading.value)return;
  sessionsLoading.value=true;sessionsError.value="";sessionsMessage.value="";
  try {
    const result=await jsonGet<{sessions:LoginSession[];truncated:boolean}>("/api/v1/auth/sessions");
    loginSessions.value=result.sessions;sessionsTruncated.value=result.truncated;sessionsLoaded.value=true;
  }catch(e){sessionsError.value="读取会话失败："+(e instanceof Error?e.message:"未知错误");}
  finally{sessionsLoading.value=false;}
}
async function revokeLoginSession(target:LoginSession|"others"){
  if(sessionsLoading.value)return;
  const confirmed=window.confirm(target==="others"
    ?"确定退出其他所有设备？当前设备会保持登录。"
    :target.current?"确定退出当前设备？需要重新输入密码。":"确定退出这个会话？");
  if(!confirmed)return;
  sessionsLoading.value=true;sessionsError.value="";sessionsMessage.value="";
  try{
    const endpoint=target==="others"?"/api/v1/auth/sessions/others":"/api/v1/auth/sessions/"+encodeURIComponent(target.id);
    const response=await fetch(endpoint,{method:"DELETE",credentials:"same-origin",headers:{"X-LightIsle-Request":"1"}});
    if(!response.ok)throw new Error("HTTP "+response.status);
    if(target!=="others"&&target.current){
      await logout();
      authError.value="当前设备已退出，请重新登录。";
    }else{
      sessionsLoading.value=false;
      await loadLoginSessions();
      sessionsMessage.value="已撤销所选会话，其他设备下次请求时将需要重新登录。";
    }
  }catch(e){sessionsError.value="退出设备失败："+(e instanceof Error?e.message:"未知错误");}
  finally{sessionsLoading.value=false;}
}
async function changeOwnPassword(){
  if(passwordBusy.value)return;
  passwordError.value="";
  if(nextPassword.value.length<12||nextPassword.value.length>256||nextPassword.value.trim()!==nextPassword.value){
    passwordError.value="新密码必须为 12–256 位，且不能以空格开头或结尾。";return;
  }
  if(nextPassword.value!==repeatPassword.value){passwordError.value="两次输入的新密码不一致。";return;}
  if(currentPassword.value===nextPassword.value){passwordError.value="新密码不能与旧密码相同。";return;}
  passwordBusy.value=true;
  try{
    await jsonWrite("/api/v1/auth/password","POST",{currentPassword:currentPassword.value,newPassword:nextPassword.value});
    currentPassword.value="";nextPassword.value="";repeatPassword.value="";
    await logout();
    authError.value="密码已更新，其他设备上的会话也已失效，请使用新密码重新登录。";
  }catch(e){
    const code=e instanceof Error?e.message:"request_failed";
    passwordError.value=({
      current_password_invalid:"当前密码不正确。",
      invalid_new_password:"新密码不符合安全要求。",
      too_many_attempts:"尝试次数过多，请稍后再试。",
    } as Record<string,string>)[code]??("修改密码失败："+code);
  }finally{passwordBusy.value=false;}
}
async function loadAccounts(){
  if(user.value?.role!=="admin")return;
  try {
    const result=await jsonGet<{users:Account[]}>("/api/v1/users");
    accounts.value=result.users;
  }catch(e){userError.value="读取账号列表失败";}
}
async function addAccount(){
  userError.value="";userBusy.value=true;
  try{
    await jsonWrite("/api/v1/users","POST",{username:newUsername.value,password:newPassword.value,role:newRole.value});
    newUsername.value="";newPassword.value="";await loadAccounts();
  }catch(e){
    const code=e instanceof Error?e.message:"";
    userError.value=code==="username_exists"?"用户名已存在":code==="invalid_account"?"用户名或密码不满足要求":"创建失败："+code;
  }finally{userBusy.value=false;}
}
async function toggleAccount(account:Account){
  userError.value="";
  try{
    await jsonWrite("/api/v1/users/"+account.id,"PATCH",{enabled:!account.enabled});
    await loadAccounts();
  }catch(e){userError.value="更新账号失败："+(e instanceof Error?e.message:"未知错误");}
}
type ServerStats = {
  timestamp: string; hostname: string; architecture: string;
  cpuCount: number; cpuPercent: number | null;
  memoryTotal: number; memoryUsed: number; diskTotal: number; diskFree: number;
  diskIo?: { device: string; readBps?: number | null; writeBps?: number | null }[] | null;
};
type Page = "overview" | "files" | "photos" | "cinema" | "settings";
const items = [
  { key: "overview" as Page, title: "主页概览", icon: Sparkles, color: "blue", group: "space" },
  { key: "files" as Page, title: "私人文件", icon: Folder, color: "cyan", group: "space" },
  { key: "photos" as Page, title: "时光相册", icon: Images, color: "pink", group: "space" },
  { key: "cinema" as Page, title: "私人影院", icon: Clapperboard, color: "orange", group: "space" },
  { key: "settings" as Page, title: "偏好设置", icon: Settings2, color: "purple", group: "system" },
];
const showHardwareSpecs = ref(false);
const startingPage = new URLSearchParams(location.search).get("page");
const active = ref<Page>(
  startingPage === "photos" ? "photos" :
  startingPage === "cinema" ? "cinema" :
  startingPage === "files" ? "files" :
  startingPage === "settings" ? "settings" :
  "overview"
);
const stats = ref<ServerStats | null>(null);
const error = ref<string | null>(null);
const polling = ref(false);
const theme = ref<Theme>("light");
let interval: number | undefined;
let abortController: AbortController | undefined;

const percent = (value: number) => Math.min(100, Math.max(0, Math.round(value)));
const usedMemory = computed(() => stats.value&&!error.value ? stats.value.memoryUsed / stats.value.memoryTotal * 100 : null);
const usedDisk = computed(() => stats.value&&!error.value ? (stats.value.diskTotal - stats.value.diskFree) / stats.value.diskTotal * 100 : null);
const cpu = computed(() => stats.value&&!error.value ? stats.value.cpuPercent ?? null : null);
const diskActivity = computed(() => {
  const entries = stats.value && !error.value ? stats.value.diskIo : null;
  if (!entries || !entries.length) return null;
  let read = 0, write = 0;
  for (const item of entries) { read += item.readBps ?? 0; write += item.writeBps ?? 0; }
  if (read <= 0 && write <= 0) return null;
  return "读 " + bytes(read) + "/s · 写 " + bytes(write) + "/s";
});
function bytes(value: number): string {
  if (!Number.isFinite(value)) return "—";
  const units = ["B", "GB", "TB", "PB"];
  if (value < 1024 * 1024 * 1024) return (value / (1024 * 1024)).toFixed(1) + " MB";
  let n = value / (1024 * 1024 * 1024), i = 1;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return n.toFixed(n < 10 ? 1 : 0) + " " + units[i];
}
async function update() {
  if(!user.value)return;
  if (polling.value) return;
  polling.value = true;
  abortController?.abort();
  const controller = new AbortController();
  abortController = controller;
  try {
    const res = await fetch("/api/v1/system", { cache: "no-store", signal: controller.signal });
    if (!res.ok) throw new Error("HTTP " + res.status);
    stats.value = await res.json() as ServerStats;
    error.value = null;
  } catch (e) {
    if (!controller.signal.aborted) error.value = e instanceof Error ? e.message : "连接失败";
  } finally { polling.value = false; }
}
type Atmosphere = "aurora" | "azure" | "sunset" | "nebula";

const atmospheres: { id: Atmosphere; name: string; icon: string }[] = [
  { id: "aurora", name: "七彩极光", icon: "🌈" },
  { id: "azure", name: "琉璃晴海", icon: "🌊" },
  { id: "sunset", name: "落日晚霞", icon: "🌅" },
  { id: "nebula", name: "幻紫星云", icon: "🌌" },
];

const atmosphere = ref<Atmosphere>("aurora");

function applyAtmosphere(atmo: Atmosphere) {
  atmosphere.value = atmo;
  document.documentElement.dataset.atmosphere = atmo;
  try {
    localStorage.setItem("lightisle_atmosphere", atmo);
  } catch {}
}

function cycleAtmosphere() {
  const currentIndex = atmospheres.findIndex((a) => a.id === atmosphere.value);
  const next = atmospheres[(currentIndex + 1) % atmospheres.length];
  applyAtmosphere(next.id);
}

function switchTheme() {
  theme.value = theme.value === "light" ? "dark" : "light";
  applyTheme(theme.value);
}
function handleRootChange(event:Event){void switchRoot((event.target as HTMLSelectElement).value);}
onMounted(() => {
  const isDark = matchMedia("(prefers-color-scheme: dark)").matches;
  theme.value = isDark ? "dark" : "light";
  applyTheme(theme.value);

  const savedAtmo = localStorage.getItem("lightisle_atmosphere") as Atmosphere | null;
  if (savedAtmo && atmospheres.some((a) => a.id === savedAtmo)) {
    applyAtmosphere(savedAtmo);
  } else {
    applyAtmosphere("aurora");
  }

  void checkAuth();
  window.addEventListener("lightisle-root-generation-changed", refreshRootDiscovery);
  interval = window.setInterval(() => {if(user.value){void update();if(active.value==="settings")void reloadTasks();if(Date.now()-lastRootDiscoveryAt>30000)void refreshRootDiscovery();}}, 5000);
});
onUnmounted(() => { if (interval) clearInterval(interval); abortController?.abort();window.removeEventListener("lightisle-root-generation-changed",refreshRootDiscovery); });
watch(active,(next)=>{if(next==="files"&&user.value&&!searchingFiles.value)void loadFiles();if(next==="settings"&&user.value?.role==="admin")void refreshTaskCenter();});
</script>

<template>
  <div class="aurora-ambient" aria-hidden="true">
    <div class="aurora-orb aurora-orb-1"></div>
    <div class="aurora-orb aurora-orb-2"></div>
    <div class="aurora-orb aurora-orb-3"></div>
    <div class="aurora-orb aurora-orb-4"></div>
    <div class="aurora-orb aurora-orb-5"></div>
  </div>

  <div v-if="authChecking" class="auth-scene">
    <div class="auth-card" style="text-align: center; align-items: center;">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <h2>轻屿 LightIsle</h2>
      <p>正在读取本机账户安全状态…</p>
    </div>
  </div>
  <div v-else-if="authServiceError" class="auth-scene">
    <div class="auth-card">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <span class="eyebrow">LOCAL SERVICE</span>
      <h1>暂时无法连接轻屿</h1>
      <p class="form-error" role="alert">{{ authServiceError }}</p>
      <button type="button" class="auth-submit" :disabled="authChecking" @click="checkAuth">{{authChecking?"正在重试…":"重试连接"}}</button>
    </div>
  </div>
  <div v-else-if="!configured" class="auth-scene">
    <div class="auth-card">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <span class="eyebrow">FIRST RUN SETUP</span>
      <h1>请先在 Mac 上初始化轻屿</h1>
      <p>首次管理员账号必须在 LightIsle.app 的原生初始化页面创建。Web 只提供用户登录、文件、相册与影视服务，不向外开放未授权注册。</p>
      <button type="button" class="auth-submit" @click="checkAuth">已在 Mac 完成初始化，刷新状态</button>
      <small>管理员创建其他成员账号的入口位于登录后的 Web「设置」中。</small>
    </div>
  </div>
  <div v-else-if="!user" class="auth-scene">
    <form class="auth-card" @submit.prevent="submitAuth">
      <div class="auth-logo"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></div>
      <span class="eyebrow">YOUR PRIVATE SPACE</span>
      <h1>欢迎回到轻屿</h1>
      <p>使用管理员在 Mac 初始化或之后创建的账号登录你的私人空间。</p>
      <label>用户名<input v-model.trim="authUsername" required maxlength="32" minlength="3" autocomplete="username" placeholder="输入账号用户名" /></label>
      <label>密码<input v-model="authPassword" required type="password" minlength="12" autocomplete="current-password" placeholder="输入至少 12 位密码" /></label>
      <p v-if="authError" class="form-error" role="alert">{{ authError }}</p>
      <button class="auth-submit" :disabled="authSubmitting" type="submit">{{ authSubmitting ? "正在验证…" : "登录轻屿空间" }}</button>
      <small>数据安全保护 · 原片与文件均存放于本地 Mac</small>
    </form>
  </div>
  <div v-else class="shell">
    <aside class="sidebar">
      <div class="brand">
        <span class="brand-symbol"><img src="/brand-icon.svg" alt="轻屿 Logo" class="brand-image" /></span>
        <div class="brand-meta">
          <div class="brand-title-line"><b>轻屿</b><span class="brand-version-badge">v0.1</span></div>
          <small>LightIsle Space</small>
        </div>
      </div>

      <nav aria-label="主导航" class="side-nav-sections">
        <div class="side-section">
          <span class="side-label">生活空间</span>
          <div class="side-nav side-group-card">
            <button
              v-for="item in items.filter(i => i.group === 'space')"
              :key="item.key"
              :class="{ chosen: active === item.key }"
              @click="active = item.key"
              type="button"
            >
              <span :class="['nav-squircle', item.color]">
                <component :is="item.icon" :size="14" :stroke-width="2.1" />
              </span>
              <span class="nav-item-label">{{ item.title }}</span>
              <ChevronRight :size="13" class="nav-chevron" />
            </button>
          </div>
        </div>

        <div class="side-section">
          <span class="side-label">系统管理</span>
          <div class="side-nav side-group-card">
            <button
              v-for="item in items.filter(i => i.group === 'system')"
              :key="item.key"
              :class="{ chosen: active === item.key }"
              @click="active = item.key"
              type="button"
            >
              <span :class="['nav-squircle', item.color]">
                <component :is="item.icon" :size="14" :stroke-width="2.1" />
              </span>
              <span class="nav-item-label">{{ item.title }}</span>
              <ChevronRight :size="13" class="nav-chevron" />
            </button>
          </div>
        </div>
      </nav>

      <div class="sidebar-bottom">
        <span class="host-status-squircle" :class="{ off: !!error }">
          <span class="dot" :class="{ off: !!error }"></span>
        </span>
        <div class="host-status-text">
          <small>宿主状态</small>
          <span>{{ error ? "服务已断开" : "已登录 · " + user.username }}</span>
        </div>
      </div>
    </aside>

    <main class="main">
      <header class="topbar glass">
        <div class="breadcrumb">
          <img src="/brand-icon.svg" alt="轻屿 Logo" class="breadcrumb-logo" />
          <span>轻屿</span>
          <span class="crumb-slash">/</span>
          <strong>{{ items.find(i => i.key === active)?.title }}</strong>
        </div>
        <div class="top-actions">
          <span class="status-pill">
            <span class="dot" :class="{ off: !!error }"></span>
            {{ error ? "连接中断" : "轻屿在线" }}
          </span>
          <button
            class="atmosphere-capsule"
            type="button"
            @click="cycleAtmosphere"
            :aria-label="'切换色彩氛围，当前：' + (atmospheres.find(a => a.id === atmosphere)?.name ?? '七彩极光')"
            :title="'切换色彩氛围（当前：' + (atmospheres.find(a => a.id === atmosphere)?.name ?? '七彩极光') + '）'"
          >
            <span class="atmosphere-icon">{{ atmospheres.find(a => a.id === atmosphere)?.icon }}</span>
            <span class="atmosphere-text">{{ atmospheres.find(a => a.id === atmosphere)?.name }}</span>
          </button>
          <button class="circle-action" type="button" @click="switchTheme" :aria-label="theme === 'dark' ? '切换浅色' : '切换深色'">
            <Sun v-if="theme === 'dark'" :size="17" /><Moon v-else :size="17" />
          </button>
          <div class="user-capsule">
            <span class="user-avatar">{{ (user.username || 'U').charAt(0).toUpperCase() }}</span>
            <div class="user-meta">
              <span class="user-name">{{ user.username }}</span>
              <span class="user-role">{{ user.role === "admin" ? "管理员" : "成员" }}</span>
            </div>
            <button class="logout-btn" type="button" @click="logout" title="退出空间">
              <LogOut :size="14" />
            </button>
          </div>
        </div>
      </header>

      <div v-if="multiRootMode" class="root-context-embedded">
        <label class="root-context-control"><span>共享目录</span>
          <select :value="rootSelectionValue" :disabled="rootSwitching" aria-label="选择共享目录" @change="handleRootChange">
            <option :value="LEGACY_ROOT_SELECTION">原共享目录（兼容）</option>
            <option v-for="root in sharedRoots" :key="root.rootID" :value="root.rootID">{{root.name}}{{root.online?"":" · 离线"}}</option>
          </select>
        </label>
      </div>
      <div v-if="rootDiscoveryNoticeVisible" class="root-discovery-notice" role="alert">
        <span>{{rootDiscoveryError}}</span>
        <button type="button" class="root-discovery-retry" :disabled="rootDiscoveryLoading" @click="refreshRootDiscovery">{{rootDiscoveryLoading?"正在检查…":"重试"}}</button>
      </div>
      <div v-if="rootSwitching" class="scan-banner root-switching" role="status">正在安全切换共享目录…</div>

      <Transition name="ios-fade" mode="out-in">
        <div v-if="!rootSwitching" :key="active">
          <div v-if="active === 'overview'" class="content">
            <!-- 1. Hero with warm welcoming & integrated Spotlight Search -->
            <div class="hero">
              <div class="hero-text">
                <p class="eyebrow">LIGHTISLE SANCTUARY</p>
                <h1>让记忆如水般流淌，<br /><span>静享专属你的私密数字栖息地。</span></h1>
                <p class="hero-desc">照片、家庭影音与珍贵档案，安放于这台 Mac。安全、优雅，触手可及。</p>
                <div class="hero-search-bar">
                  <Search :size="16" class="search-icon" />
                  <input
                    v-model.trim="fileSearch"
                    maxlength="128"
                    type="search"
                    :placeholder="searchViaSpotlight ? 'Spotlight 搜索文件名与可索引的内容…' : '搜索共享目录中的文件和文件夹名称…'"
                    aria-label="搜索共享目录中的文件和文件夹名称"
                    @keydown.enter="runFileSearch"
                  />
                  <button type="button" :disabled="filesLoading || fileSearch.length < 2" @click="runFileSearch">
                    {{ filesLoading&&searchingFiles ? "搜索中…" : "搜索共享目录" }}
                  </button>
                  <button v-if="searchingFiles" type="button" class="back-pill" @click="loadFiles()">返回目录</button>
                </div>
                <div class="hero-actions">
                  <label class="hero-status">
                    <input v-model="searchViaSpotlight" type="checkbox" aria-label="使用 macOS Spotlight 搜索文件内容" />
                    Spotlight 内容搜索（未索引时回退文件名搜索）
                  </label>
                  <span class="hero-status"><span class="dot" :class="{ off: !!error }"></span>{{ error ? "连接异常" : "Mac 本地服务已连接 · 局域网需在 Mac 设置中开启" }}</span>
                  <span class="version">本地私有空间</span>
                </div>
              </div>
              <div class="hero-art" aria-hidden="true">
                <div class="orb orb-a"></div><div class="orb orb-b"></div><div class="orb orb-c"></div>
                <div class="hero-glass"><img src="/brand-icon.svg" alt="" class="hero-brand-image" /></div>
              </div>
            </div>

            <!-- 2. Personal Sanctuaries (Content First!) -->
            <div class="section-heading apps-heading">
              <div><h2>数字生活空间</h2><p>由这台 Mac 本地安全守护，随时随地跨设备流畅存取与浏览</p></div>
              <span class="planned-tag">Mac 本地原生存储</span>
            </div>
            <div class="sanctuary-grid">
              <button type="button" class="sanctuary-card" @click="active = 'files'">
                <div class="sanctuary-icon file"><Folder :size="26" /></div>
                <div class="sanctuary-body">
                  <div class="sanctuary-head">
                    <h3>私人文件</h3>
                    <ArrowUpRight :size="18" class="feature-arrow" />
                  </div>
                  <p>轻屿专属目录中的文档、资料与数据，支持断点续传与极速存取。</p>
                  <div class="sanctuary-footer">
                    <span class="sanctuary-chip">即时存取</span>
                    <span class="sanctuary-action">浏览文件 &rarr;</span>
                  </div>
                </div>
              </button>

              <button type="button" class="sanctuary-card" @click="active = 'photos'">
                <div class="sanctuary-icon photos"><Images :size="26" /></div>
                <div class="sanctuary-body">
                  <div class="sanctuary-head">
                    <h3>时光相册</h3>
                    <ArrowUpRight :size="18" class="feature-arrow" />
                  </div>
                  <p>原图原片安全保存在本地 Mac，硬件加速缩略图，智能珍藏美好回忆。</p>
                  <div class="sanctuary-footer">
                    <span class="sanctuary-chip">原画保存</span>
                    <span class="sanctuary-action">翻阅相册 &rarr;</span>
                  </div>
                </div>
              </button>

              <button type="button" class="sanctuary-card" @click="active = 'cinema'">
                <div class="sanctuary-icon cinema"><Clapperboard :size="26" /></div>
                <div class="sanctuary-body">
                  <div class="sanctuary-head">
                    <h3>私人影院</h3>
                    <ArrowUpRight :size="18" class="feature-arrow" />
                  </div>
                  <p>家庭影院原画无损串流，多语言外挂字幕，跨设备同步断点续播。</p>
                  <div class="sanctuary-footer">
                    <span class="sanctuary-chip">无损串流</span>
                    <span class="sanctuary-action">开启放映 &rarr;</span>
                  </div>
                </div>
              </button>
            </div>

            <!-- 3. Mac Sanctuary Vitality (Warm Consolidated Card) -->
            <div class="section-heading">
              <div><h2>轻屿运行体征</h2><p>这台 Mac 正在安全守护你的私人空间与网络存取</p></div>
              <button class="refresh" type="button" @click="update" :disabled="polling">
                <RefreshCcw :size="15" :class="{ spinning: polling }" /> 刷新体征
              </button>
            </div>
            <div v-if="error" class="error-notice"><WifiOff :size="17" /> 无法读取系统状态：{{ error }}。请确认 Mac App 仍在运行。</div>

            <section class="vitality-container">
              <div class="vitality-card">
                <div class="vitality-header">
                  <div class="vitality-host">
                    <div class="host-icon-bubble"><Monitor :size="22" /></div>
                    <div>
                      <strong>{{ stats?.architecture ? 'Apple Silicon Mac (' + stats.architecture + ')' : '宿主 Mac 设备' }}</strong>
                      <small>{{ stats && !error ? '系统健康 · 核心进程安静就绪 · 无外部数据上传' : error ? '暂未取得系统状态' : polling ? '正在读取系统状态…' : '等待状态采样' }}</small>
                    </div>
                  </div>
                  <button type="button" class="toggle-specs-btn" @click="showHardwareSpecs = !showHardwareSpecs">
                    {{ showHardwareSpecs ? "收起详细指标" : "查看硬件详情" }}
                  </button>
                </div>

                <div class="vitality-metrics-row">
                  <div class="vitality-chip">
                    <span class="chip-label"><Activity :size="14" class="chip-icon violet" /> 处理器负载</span>
                    <strong class="chip-val">{{ stats && !error ? (cpu == null ? '—' : percent(cpu) + '%') : '—' }}</strong>
                    <small class="chip-sub">{{ stats && !error ? (stats.cpuCount ?? '—') + ' 个计算核心' : error ? '状态暂未取得' : polling ? '正在读取状态…' : '等待状态采样' }}</small>
                  </div>
                  <div class="vitality-chip">
                    <span class="chip-label"><Server :size="14" class="chip-icon blue" /> 统一内存</span>
                    <strong class="chip-val">{{ stats && !error && usedMemory != null ? percent(usedMemory) + '%' : '—' }}</strong>
                    <small class="chip-sub">{{ stats && !error ? bytes(stats.memoryUsed) + ' 已用' : error ? '状态暂未取得' : polling ? '正在读取状态…' : '等待状态采样' }}</small>
                  </div>
                  <div class="vitality-chip">
                    <span class="chip-label"><HardDrive :size="14" class="chip-icon teal" /> 空间余量</span>
                    <strong class="chip-val">{{ stats && !error ? bytes(stats.diskFree) : error ? '暂未取得空间数据' : polling ? '读取中…' : '等待采样' }}</strong>
                    <small class="chip-sub">本地安全存储</small>
                  </div>
                </div>

                <!-- Optional expandable detailed tracks for power users -->
                <div v-if="showHardwareSpecs" class="vitality-detail-grid">
                  <div class="spec-detail-item">
                    <div class="spec-detail-top"><span>CPU 利用率</span><span>{{ cpu == null ? '—' : percent(cpu) + '%' }}</span></div>
                    <div class="progress-track"><div class="progress-bar purple" :style="{ width: cpu == null ? '0' : percent(cpu) + '%' }"></div></div>
                  </div>
                  <div class="spec-detail-item">
                    <div class="spec-detail-top"><span>统一内存占用</span><span>{{ stats && !error ? bytes(stats.memoryUsed) + ' / ' + bytes(stats.memoryTotal) : '—' }}</span></div>
                    <div class="progress-track"><div class="progress-bar bright-blue" :style="{ width: usedMemory == null ? '0' : percent(usedMemory) + '%' }"></div></div>
                  </div>
                  <div class="spec-detail-item">
                    <div class="spec-detail-top"><span>存储磁盘空间</span><span>{{ usedDisk == null ? '—' : percent(usedDisk) + '%' }}</span></div>
                    <div class="progress-track"><div class="progress-bar aqua" :style="{ width: usedDisk == null ? '0' : percent(usedDisk) + '%' }"></div></div>
                  </div>
                  <div class="spec-detail-item">
                    <div class="spec-detail-top"><span>磁盘活动</span><span>{{ diskActivity ?? '空闲' }}</span></div>
                  </div>
                </div>
              </div>
            </section>

            <div class="footnote"><ShieldCheck :size="15" /> <span>家庭私有云与个人数据均保存在本地 Mac，操作全程受安全会话保护。</span></div>
          </div>
          <div v-else-if="rootContextPageVisible" class="content">
            <section class="content-empty root-state-card" :class="'root-state-'+rootContextPresentation.kind" :role="rootContextPresentation.role" :aria-live="rootContextPresentation.role==='status'?'polite':undefined">
              <RefreshCcw v-if="rootContextPresentation.kind==='loading'" :size="40" :stroke-width="1.5" class="spinning" aria-hidden="true"/>
              <WifiOff v-else-if="rootContextPresentation.kind==='error'" :size="40" :stroke-width="1.5" aria-hidden="true"/>
              <HardDrive v-else-if="rootContextPresentation.kind==='offline'" :size="40" :stroke-width="1.5" aria-hidden="true"/>
              <Folder v-else-if="active==='files'" :size="40" :stroke-width="1.5" aria-hidden="true"/>
              <Images v-else-if="active==='photos'" :size="40" :stroke-width="1.5" aria-hidden="true"/>
              <Clapperboard v-else :size="40" :stroke-width="1.5" aria-hidden="true"/>
              <h2>{{rootContextPresentation.title}}</h2>
              <p>{{rootContextPresentation.message}}</p>
              <button v-if="rootContextPresentation.action" type="button" class="content-empty-action" :disabled="rootDiscoveryLoading" @click="refreshRootDiscovery">
                <RefreshCcw :size="16" :class="{spinning:rootDiscoveryLoading}"/> {{rootDiscoveryLoading?"正在检查…":rootContextPresentation.action}}
              </button>
            </section>
          </div>
          <div v-else-if="active === 'files'" class="content">
            <div class="section-heading">
              <div><h2>文件管理 · {{ sharedRootName }}</h2><p>按页浏览、续传上传及回收站；仅操作已授权的共享目录。</p></div>
              <button class="refresh" type="button" @click="showingTrash?loadTrash():loadFiles()" :disabled="showingTrash?trashLoading:filesLoading"><RefreshCcw :size="16" :class="{spinning:showingTrash&&trashLoading}" /> 刷新</button>
            </div>
            <section class="files-panel">
              <div class="files-toolbar">
                <div class="file-crumbs" aria-label="当前位置">
                  <button v-for="(segment,index) in pathSegments" :key="segment.path" type="button" @click="loadFiles(segment.path)">
                    <ChevronRight v-if="index" :size="14" /><span>{{ segment.name }}</span>
                  </button>
                </div>
                <div class="file-actions">
                  <label v-if="!showingTrash&&!searchingFiles" class="file-sort-control">排序
                    <select v-model="fileSortKey" :disabled="filesLoading" aria-label="文件排序字段" @change="loadFiles(filesPath)">
                      <option value="name">名称</option><option value="mtime">修改时间</option><option value="size">文件大小</option>
                    </select>
                    <select v-model="fileSortDirection" :disabled="filesLoading" aria-label="文件排序方向" @change="loadFiles(filesPath)">
                      <option value="asc">升序</option><option value="desc">降序</option>
                    </select>
                  </label>
                  <button v-if="currentFolderCanWrite&&!showingTrash" type="button" class="upload-primary-action" @click="chooseUploadFiles" :disabled="uploadBusy||filesLoading"><UploadCloud :size="16" /> {{ uploadBusy ? "正在上传" : "上传文件" }}</button>
                  <button type="button" @click="openTrash"><Trash2 :size="16"/> {{ showingTrash ? "退出回收站" : "回收站" }}</button>
                  <input ref="selectedUpload" type="file" class="visually-hidden" multiple @change="startUpload" />
                </div>
              </div>
              <section v-if="currentFolderCanWrite&&!showingTrash" class="upload-drop-area" :class="{ 'upload-drop-active': uploadDropActive, 'upload-drop-busy': uploadBusy }"
                aria-label="文件上传区" @dragover="dragOverUpload" @dragleave="dragLeaveUpload" @drop="dropUpload">
                <span class="upload-drop-symbol"><UploadCloud :size="22" :stroke-width="1.7"/></span>
                <div class="upload-drop-content">
                  <strong>{{uploadDropActive?"释放文件，上传到当前文件夹":"将文件拖放到这里，或者点击右上角上传文件"}}</strong>
                  <span>当前目录：{{pathSegments.map(segment=>segment.name).join(' / ')}} · 单文件最多 32 GiB · 自动校验与断点续传（需浏览器支持）</span>
                </div>
                <button v-if="!uploadBusy" type="button" class="upload-drop-select" @click="chooseUploadFiles">选择文件 <ChevronRight :size="14"/></button>
              </section>
              <label v-if="currentFolderCanWrite&&!showingTrash&&!searchingFiles" class="footnote" style="display:flex;align-items:center;gap:8px;cursor:pointer">
                <input v-model="uploadAutoRenameConflicts" type="checkbox" :disabled="uploadBusy" />
                上传时如果目标文件已经存在，自动改名另存（默认关闭；任何模式均不覆盖已有文件）
              </label>
              <section v-if="uploadBusy||uploadStage==='done'||uploadStage==='error'||uploadStage==='cancelled'" class="upload-activity-card" role="status" aria-live="polite">
                <div class="upload-activity-top">
                  <div class="upload-activity-heading">
                    <span class="upload-activity-mark"><UploadCloud :size="17"/></span>
                    <div>
                      <strong>{{uploadStage==='done'?'全部上传完成':uploadStage==='error'?'上传遇到问题':uploadStage==='cancelled'?'已取消上传':uploadStage==='hashing'?'正在校验文件':'正在上传文件'}}</strong>
                      <small>{{uploadResult||uploadFileName}} <template v-if="uploadBusy">· 第 {{uploadCurrent}} / {{uploadTotal}} 个</template></small>
                    </div>
                  </div>
                  <div class="upload-activity-actions">
                    <strong v-if="uploadBusy">{{uploadPercent}}%</strong>
                    <button v-if="uploadBusy" type="button" @click="cancelCurrentUpload">取消</button>
                    <button v-if="canContinueUploads" type="button" @click="continueIncompleteUploads">继续未完成文件（{{uploadContinuation?.files.length}}）</button>
                    <button v-if="!uploadBusy" type="button" @click="closeUploadActivity">关闭</button>
                  </div>
                </div>
                <div v-if="uploadBusy" class="upload-track" role="progressbar" :aria-valuenow="uploadPercent" aria-valuemin="0" aria-valuemax="100" :aria-label="uploadStage==='hashing'?'文件完整性校验进度':'文件上传进度'">
                  <div :style="{width:uploadPercent+'%'}"></div>
                </div>
                <p v-if="uploadBusy" class="upload-activity-caption">{{uploadStage==='hashing'?'校验文件内容，确保中断后不会错误续传':bytes(uploadTransferred)+' / '+bytes(uploadSize)+' 已上传'}} · {{uploadCompleted}} 个文件已完成</p>
                <p v-else-if="uploadStage==='error'||uploadStage==='cancelled'" class="upload-activity-caption upload-activity-error">{{uploadFailure}}</p>
                <p v-else-if="uploadStage==='done'" class="upload-activity-caption">文件已保存到上传时选择的目录。</p>
              </section>
              <div v-if="searchingFiles" class="footnote">
                {{searchViaSpotlight ? "macOS Spotlight 内容/名称索引搜索" : "共享目录名称搜索"}}：{{fileSearch}} · 仅搜索已授权目录，系统未索引时自动回退到文件名搜索。
                <button type="button" class="account-action" @click="loadFiles('.')">返回目录</button>
                <span v-if="searchTruncated">搜索已达到遍历或结果上限，请缩小关键词或到具体目录浏览。</span>
              </div>
              <div v-if="checkedFiles.length && !showingTrash" class="file-batch-bar">
                <span>已选 {{checkedFiles.length }} 项（每次最多 50 项）</span>
                <button type="button" @click="batchTrash" :disabled="checkedFiles.length>50"><Trash2 :size="15"/> 批量移到回收站</button>
              </div>
              <p v-if="!showingTrash&&!filesLoading&&!currentFolderCanWrite" class="footnote">当前目录为只读，可浏览和下载文件。</p>
              <form v-if="!showingTrash&&currentFolderCanWrite" class="create-folder-form" @submit.prevent="makeFolder">
                <FolderPlus :size="18" />
                <input v-model="newFolderName" maxlength="150" placeholder="新建文件夹名称" aria-label="新建文件夹名称" />
                <button :disabled="!newFolderName.trim()" type="submit">新建文件夹</button>
              </form>
              <div v-if="!showingTrash&&filesError" class="error-notice" role="alert">{{ filesError }}</div>
              <p v-if="!showingTrash&&fileOperationNotice" class="footnote" role="status">{{fileOperationNotice}}</p>
              <button v-if="searchingFiles&&filesError&&!filesLoading" type="button" class="refresh" @click="runFileSearch">重试搜索</button>
              <div v-if="showingTrash" class="trash-list">
                <div v-if="trashPresentation==='loading'" class="files-empty" role="status">正在读取回收站…</div>
                <div v-else-if="trashPresentation==='error'" class="files-empty" role="alert">
                  <span>{{trashError}}</span><button type="button" class="refresh" :disabled="trashLoading" @click="loadTrash">重试读取回收站</button>
                </div>
                <div v-else-if="trashPresentation==='empty'" class="files-empty">回收站是空的</div>
                <p v-if="showingTrash&&trashRetention" class="footnote">{{trashRetention.enabled?`回收站自动清理已开启：入站超过 ${trashRetention.days} 天的条目将在后台自动永久删除（可在 Mac App 中调整）。`:"回收站自动清理未开启；条目将一直保留，直到管理员手动永久删除。"}}</p>
                <div v-else v-for="entry in trashItems" :key="entry.id" class="file-entry">
                  <div class="file-name"><strong>{{ entry.name }}</strong><small>原路径：{{ entry.originalPath }} · {{ new Date(entry.deletedAt).toLocaleString() }}</small></div>
                  <button type="button" class="account-action" @click="restoreTrash(entry)">恢复</button>
                  <button v-if="user.role==='admin'" type="button" class="account-action" @click="purgeTrashItem(entry)">永久删除</button>
                </div>
              </div>
              <div v-if="!showingTrash && filesPath !== '.'" class="file-entry" role="button" tabindex="0" @click="goUp" @keydown.enter="goUp">
                <span class="file-icon"><ChevronLeft :size="22" /></span>
                <div class="file-name"><strong>返回上一级</strong><small>..</small></div>
              </div>
              <div v-if="!showingTrash && filesLoading" class="files-empty">{{searchingFiles?"正在搜索授权目录…":"正在读取目录…"}}</div>
              <div v-else-if="!showingTrash && !fileEntries.length" class="files-empty"><Folder :size="30"/><span>{{filesError?(searchingFiles?"搜索暂不可用，请重试。":"无法读取此目录。请刷新重试。"):searchingFiles?"没有找到匹配的文件或文件夹":"此文件夹目前是空的"}}</span></div>
              <div v-for="entry in showingTrash ? [] : fileEntries" :key="entry.path" class="file-entry">
                <input type="checkbox" :value="entry.path" v-model="checkedFiles" :disabled="!canWriteEntry(entry)" :aria-label="'选择 '+entry.name+(canWriteEntry(entry)?'':'（只读）')" class="file-checkbox"/>
                <button type="button" class="file-open" @click="entry.type === 'folder' ? loadFiles(entry.path) : previewFile(entry)" :title="entry.name">
                  <span class="file-icon" :class="entry.type">
                    <Folder v-if="entry.type === 'folder'" :size="21"/>
                    <img v-else-if="thumbnailEligible(entry)&&!failedThumbnails.has(thumbnailKey(entry))"
                      :src="fileThumbnailURL(entry)" :alt="entry.name+' 缩略图'" loading="lazy"
                      class="file-thumbnail" @error="markThumbnailFailure(entry)"/>
                    <FileText v-else :size="20"/>
                  </span>
                  <span class="file-name"><strong>{{ entry.name }}</strong><small>{{ entry.type === "folder" ? "文件夹" : bytes(entry.size) }} · {{ new Date(entry.modified).toLocaleString() }}</small></span>
                </button>
                <div class="file-entry-actions">
                  <button v-if="canWriteEntry(entry)" type="button" class="file-entry-text-action" @click="operateFile(entry,'move')" title="重命名或移动">移动</button>
                  <button type="button" class="file-entry-text-action" @click="operateFile(entry,'copy')" title="选择目标文件夹，并安全处理同名文件">复制</button>
                  <button v-if="entry.type==='file'||entry.type==='folder'" type="button" class="file-entry-text-action" @click="openShareDialog(entry)" :title="entry.type==='folder'?'创建可撤销的限时文件夹 ZIP 下载链接':'创建可撤销的限时下载链接'">分享</button>
                  <button v-if="entry.type === 'file'" type="button" @click="previewFile(entry)" title="预览"><Images :size="17"/></button>
                  <button type="button" @click="downloadFile(entry)" :title="entry.type==='folder'?'下载文件夹 ZIP（最多 2 GiB / 2000 项）':'下载'"><Download :size="17"/></button>
                  <button v-if="canWriteEntry(entry)" type="button" @click="trashTarget=entry" title="移到回收站"><Trash2 :size="17"/></button>
                </div>
              </div>
              <div v-if="!showingTrash && fileNextCursor" class="gallery-load">
                <button type="button" :disabled="filesLoading" @click="loadFiles(filesPath,true)">{{filesLoading?"加载中…":"加载更多文件"}}</button>
              </div>
            </section>
            <p class="footnote">支持断点续传上传、文件夹 ZIP 下载（最多 2 GiB / 2000 项）、按格式预览照片和视频。批量删除最多 50 项，恢复不会覆盖现有文件。</p>
          </div>
          <PhotosView v-else-if="active === 'photos'" :key="rootViewKey" :admin="user.role==='admin'" :root-id="multiRootMode?selectedRootID:undefined" :root-generation="selectedRootGeneration" />
          <CinemaView v-else-if="active === 'cinema'" :key="rootViewKey" :admin="user.role==='admin'" :root-id="multiRootMode?selectedRootID:undefined" :root-generation="selectedRootGeneration" />
          <div v-else-if="active === 'settings'" class="content">
            <div class="section-heading"><div><h2>偏好设置</h2><p>按类别管理账号、文件、存储与任务；管理员类别仅对管理员可见。</p></div><button class="refresh" @click="logout">退出登录</button></div>
            <nav class="settings-nav" aria-label="设置分类">
              <button v-for="group in settingsGroups" :key="group.key" type="button"
                :class="{active:settingsGroup===group.key}" @click="settingsGroup=group.key">{{group.label}}</button>
            </nav>
            <template v-if="settingsGroup==='files'">
            <DavAccess /></template>
            <template v-if="settingsGroup==='storage'">
            <DiskManagement v-if="user.role==='admin'" /></template>
            <section v-if="settingsGroup==='files'" class="account-panel" style="margin-bottom:20px">
              <div class="account-heading"><h3>我的文件分享</h3><button type="button" class="refresh" :disabled="sharesLoading||!rootFeatureContextReady" @click="loadMyShares">{{sharesLoading?"加载中…":"查看 / 刷新"}}</button></div>
              <p v-if="!rootFeatureContextReady" class="footnote">请先选择一个可访问的共享目录，再管理该目录中的分享。</p>
              <p>可以分享自己有权读取的单个文件或文件夹（文件夹打包为 ZIP 流式下载，超出体积或数量限制时会明确失败）。链接最长有效 7 天，可提前撤销；下载时仍会检查对象是否更换、用户是否停用以及目录授权是否有效。</p>
              <div v-for="share in activeShares" :key="share.id" class="account-row">
                <div>
                  <strong>{{share.path}}<span v-if="share.kind==='dir'" class="share-flag">文件夹 ZIP</span><span v-if="share.hasPassword" class="share-flag">密码保护</span><span v-if="(share.maxDownloads??0)>0" class="share-flag">限 {{share.maxDownloads}} 次下载<template v-if="(share.downloadCount??0)>0">（已用 {{share.downloadCount}}）</template></span></strong>
                  <small>创建：{{new Date(share.createdAt*1000).toLocaleString()}} · 到期：{{new Date(share.expiresAt*1000).toLocaleString()}}</small>
                </div>
                <button type="button" class="account-action" @click="revokeFileShare(share)">撤销链接</button>
              </div>
              <p v-if="sharesLoaded&&!activeShares.length" class="footnote">当前没有有效的分享链接。你可以在文件页选择“分享”创建。</p>
              <p v-if="sharesError" class="form-error" role="alert">{{sharesError}}</p>
              <p class="footnote">链接只在创建时展示一次，后续如需重新发送，请撤销旧链接后重新创建。</p>
            </section>
            <section v-if="settingsGroup==='ops'&&user.role==='admin'&&rootFeatureContextReady" class="account-panel" style="margin-bottom:20px">
              <div class="account-heading"><h3>后台任务中心</h3><button type="button" class="refresh" @click="refreshTaskCenter">刷新</button></div>
              <p>自动索引每 15 分钟核对一次共享文件目录。媒体扫描可取消和重新扫描；备份任务仅允许 Mac App 本机控制。</p>
              <div v-if="!tasks.length" class="account-row">
                <div><strong>尚无任务摘要</strong><small>可以手动开始媒体扫描；任务记录仅在任务实际启动后生成。</small></div>
                <div class="task-empty-actions">
                  <button type="button" class="account-action" @click="startMediaTask('gallery')">扫描图库</button>
                  <button type="button" class="account-action" @click="startMediaTask('cinema')">扫描影视</button>
                </div>
              </div>
              <div v-for="task in tasks" :key="task.kind" class="account-row">
                <div><strong>{{ task.kind==='gallery'?'图库索引':task.kind==='cinema'?'影视索引':'文件备份' }} · {{task.running?'进行中':'空闲'}}</strong>
                  <small>已处理 {{ task.progress }} 项{{task.lastError?' · '+taskHistoryErrorLabel(task.lastError):''}}{{task.lastDone?' · '+new Date(task.lastDone*1000).toLocaleString():''}}</small></div>
                <button v-if="task.kind!=='backup'" type="button" class="account-action" @click="taskControl(task,task.running?'cancel':'retry')">{{task.running?'取消扫描':task.lastDone||task.lastError?'重新扫描':'开始扫描'}}</button>
              </div>
              <p v-if="taskError" class="form-error" role="alert">{{taskError}}</p>
              <div class="account-heading task-history-heading"><h4>最近任务记录</h4><span>{{taskHistory.length}} 条</span></div>
              <p v-if="taskHistoryError" class="form-error" role="alert">
                {{taskHistoryError}} <button type="button" class="account-action" :disabled="taskHistoryLoading" @click="reloadTaskHistory(true)">重试</button>
              </p>
              <div v-if="taskHistoryLoading&&!taskHistory.length" class="files-empty">正在读取任务记录…</div>
              <div v-else-if="!taskHistory.length&&!taskHistoryError" class="files-empty">还没有任务记录</div>
              <div v-for="run in taskHistory" :key="run.id" class="account-row task-history-row">
                <div>
                  <strong>{{run.kind==='gallery'?'图库索引':run.kind==='cinema'?'影视索引':'文件备份'}} · {{taskOperationLabel(run.operation)}} · {{taskRunStatusLabel(run)}}</strong>
                  <small>开始于 {{run.startedAt?new Date(run.startedAt*1000).toLocaleString():'时间未知'}} · 已处理 {{run.progress}} 项{{run.bytes?' · '+bytes(run.bytes):''}} · 第 {{run.attempts}} 次</small>
                  <small v-if="run.lastError" class="task-history-error">{{taskHistoryErrorLabel(run.lastError)}}</small>
                </div>
              </div>
              <div v-if="taskHistoryNextCursor" class="gallery-load task-history-more">
                <button type="button" :disabled="taskHistoryLoading" @click="reloadTaskHistory(false)">{{taskHistoryLoading?'正在加载…':'加载更早记录'}}</button>
              </div>
            </section>
            <p v-else-if="user.role==='admin'" class="footnote">选择共享目录后可查看该目录的任务和上传维护状态。</p>
            <template v-if="settingsGroup==='storage'">
            <UploadMaintenance v-if="user.role==='admin'&&rootFeatureContextReady" :key="rootViewKey" :root-id="multiRootMode?selectedRootID:undefined" :root-generation="selectedRootGeneration" />
            </template>
            <template v-if="settingsGroup==='ops'">
            <OpsDiagnostics v-if="user.role==='admin'"/>
            <AuditLogView v-if="user.role==='admin'" />
            <AlertsView v-if="user.role==='admin'&&rootFeatureContextReady" :key="rootViewKey" :root-id="multiRootMode?selectedRootID:undefined" :root-generation="selectedRootGeneration" />
            </template>
            <section v-if="settingsGroup==='account'" class="account-panel" style="margin-bottom:20px">
              <div class="account-heading">
                <h3>登录会话</h3>
                <button type="button" class="refresh" :disabled="sessionsLoading" @click="loadLoginSessions">{{sessionsLoading?"处理中…":"查看 / 刷新"}}</button>
              </div>
              <p>查看账号仍有效的登录会话并撤销不再使用的设备。当前版本只记录会话时间，不记录设备名称或位置。</p>
              <div v-if="sessionsLoaded&&loginSessions.length>1" class="account-row">
                <div><strong>退出其他设备</strong><small>只保留当前设备的会话</small></div>
                <button type="button" class="account-action" :disabled="sessionsLoading" @click="revokeLoginSession('others')">全部退出</button>
              </div>
              <div v-for="session in loginSessions" :key="session.id" class="account-row">
                <div>
                  <strong>{{session.current?"当前设备":"其他登录会话"}}</strong>
                  <small>登录时间：{{new Date(session.createdAt*1000).toLocaleString()}} · 到期：{{new Date(session.expiresAt*1000).toLocaleString()}}</small>
                </div>
                <button type="button" class="account-action" :disabled="sessionsLoading" @click="revokeLoginSession(session)">{{session.current?"退出本机":"撤销会话"}}</button>
              </div>
              <p v-if="sessionsLoaded&&!loginSessions.length" class="footnote">没有可显示的有效会话。</p>
              <p v-if="sessionsTruncated" class="footnote">登录会话超过显示上限，仅显示最近 100 条。可以选择退出其他所有设备。</p>
              <p v-if="sessionsError" role="alert" class="form-error">{{sessionsError}}</p>
              <p v-if="sessionsMessage" role="status" class="footnote">{{sessionsMessage}}</p>
            </section>
            <section v-if="settingsGroup==='account'" class="account-panel" style="margin-bottom:20px">
              <h3>修改我的密码</h3>
              <p>需要验证当前密码。成功后会退出所有设备上的登录会话，请使用新密码重新登录。</p>
              <form class="account-form" @submit.prevent="changeOwnPassword">
                <label>当前密码<input v-model="currentPassword" type="password" autocomplete="current-password" required /></label>
                <label>新密码<input v-model="nextPassword" type="password" autocomplete="new-password" minlength="12" maxlength="256" required /></label>
                <label>确认新密码<input v-model="repeatPassword" type="password" autocomplete="new-password" minlength="12" maxlength="256" required /></label>
                <button type="submit" class="auth-submit" :disabled="passwordBusy">{{passwordBusy?"正在修改…":"更新密码并退出所有设备"}}</button>
              </form>
              <p v-if="passwordError" class="form-error" role="alert">{{passwordError}}</p>
            </section>
            <div v-if="settingsGroup==='account'&&user.role === 'admin'" class="account-manager">
              <section class="account-panel">
                <h3>创建新成员账号</h3>
                <p>新账号默认是普通用户。只有管理员能添加账号，禁止外部公开注册。</p>
                <form class="account-form" @submit.prevent="addAccount">
                  <label>用户名<input v-model.trim="newUsername" autocomplete="off" placeholder="3–32 位英文字母、数字等" minlength="3" maxlength="32" required /></label>
                  <label>初始密码<input v-model="newPassword" type="password" autocomplete="new-password" minlength="12" placeholder="至少 12 位密码" required /></label>
                  <label>用户角色<select v-model="newRole"><option value="member">普通用户</option><option value="admin">管理员</option></select></label>
                  <button type="submit" class="auth-submit" :disabled="userBusy">{{ userBusy ? "正在处理…" : "确认添加账号" }}</button>
                </form>
                <p v-if="userError" class="form-error">{{ userError }}</p>
              </section>
              <section class="account-panel">
                <div class="account-heading"><h3>已有空间成员</h3><button type="button" class="refresh" @click="loadAccounts">刷新</button></div>
                <div v-for="account in accounts" :key="account.id" class="account-row">
                  <div><strong>{{ account.username }}</strong><small>{{ account.role === "admin" ? "管理员" : "普通用户" }} · {{ account.enabled ? "已启用" : "已停用" }}</small></div>
                  <button v-if="account.role === 'member'" type="button" class="account-action" :disabled="multiRootMode&&!legacyRootSelected&&!selectedRootID" @click="editGrants(account)">目录权限</button>
                  <button v-if="account.role==='member'&&account.enabled" type="button" class="account-action" @click="openMemberReset(account)">重置密码</button>
                  <button v-if="account.id!==1 && account.username !== user.username" class="account-action" @click="toggleAccount(account)">{{ account.enabled ? "停用" : "启用" }}</button>
                  <span v-else class="protected-account">受保护</span>
                </div>
                <p v-if="resetNotice" class="footnote" role="status">{{resetNotice}}</p>
                <section v-if="resetMember" class="account-panel" style="margin-top:16px">
                  <div class="account-heading">
                    <h3>{{resetMember.username}} · 账号恢复</h3>
                    <button type="button" :disabled="resetBusy" @click="closeMemberReset">关闭</button>
                  </div>
                  <p>仅可修改普通成员的密码；成功后该成员需要在全部设备重新登录。首任管理员请使用 Mac 原生身份验证恢复。</p>
                  <form class="account-form" @submit.prevent="submitMemberReset">
                    <label>设置新密码<input v-model="resetPassword" type="password" autocomplete="new-password" minlength="12" maxlength="256" required /></label>
                    <label>确认新密码<input v-model="resetConfirm" type="password" autocomplete="new-password" minlength="12" maxlength="256" required /></label>
                    <button type="submit" class="auth-submit" :disabled="resetBusy">{{resetBusy?"正在处理…":"更新成员密码"}}</button>
                  </form>
                  <p v-if="resetError" class="form-error" role="alert">{{resetError}}</p>
                </section>
                <div v-if="grantUser" class="account-panel" style="margin-top:16px">
                  <div class="account-heading"><h3>{{ grantUser.username }} · 文件夹授权</h3><button type="button" @click="grantUser=null">关闭</button></div>
                  <p>成员默认无权访问文件。请填写{{multiRootMode?`“${selectedRoot?.name??"当前共享目录"}”`:"共享目录"}}内已存在的相对文件夹路径，`.` 表示整个共享目录；图库和影视目前仅对获授整个共享目录读取权限的成员开放。</p>
                  <div class="account-form">
                    <label>文件夹路径<input v-model.trim="grantPath" maxlength="512" placeholder="例如 家庭照片 或 ."/></label>
                    <label><input type="checkbox" v-model="grantWrite"/> 允许上传、创建和删除</label>
                    <button type="button" class="auth-submit" :disabled="grantBusy || !grantPath" @click="saveGrant()">保存目录权限</button>
                  </div>
                  <div v-for="g in grants" :key="g.path" class="account-row">
                    <div><strong>{{ g.path }}</strong><small>{{ g.canWrite?'读写':'只读' }}</small></div>
                    <button type="button" class="account-action" :disabled="grantBusy" @click="saveGrant(g.path,true)">撤销</button>
                  </div>
                  <p v-if="grantError" role="alert" class="form-error">{{ grantError }}</p>
                </div>
              </section>
            </div>
            <div v-else-if="settingsGroup==='account'" class="account-panel"><h3>当前用户</h3><p>{{ user.username }}（普通用户）</p><p>账号由管理员统一创建和维护。</p></div>
          </div>
        </div>
      </Transition>
    </main>
    <div v-if="trashTarget" class="dialog-backdrop" @click.self="trashTarget=null">
      <div class="confirm-dialog" role="alertdialog" aria-modal="true" aria-label="移到回收站">
        <div class="dialog-symbol"><Trash2 :size="23" /></div>
        <h3>移到回收站？</h3>
        <p>“{{ trashTarget.name }}”将从共享目录移至内部回收站，暂不会永久删除。</p>
        <div class="dialog-buttons"><button type="button" @click="trashTarget=null">取消</button><button class="destructive" type="button" @click="removeFile">确认移入</button></div>
      </div>
    </div>
    <div v-if="previewItem" class="dialog-backdrop" @click.self="previewItem=null">
      <div class="preview-dialog" role="dialog" aria-modal="true" aria-label="文件预览">
        <div class="preview-toolbar"><strong>{{ previewItem.name }}</strong><button type="button" @click="previewItem=null">关闭</button></div>
        <p v-if="previewError" class="form-error">{{ previewError }}</p>
        <pre v-else-if="/\.(txt|md|json|log)$/i.test(previewItem.name)" class="preview-text">{{ previewText }}</pre>
        <img v-else-if="/\.(jpe?g|png|gif|webp|heic|heif)$/i.test(previewItem.name)" :src="previewURL" :alt="previewItem.name" class="preview-image"/>
        <iframe v-else-if="/\.pdf$/i.test(previewItem.name)" :src="previewURL" :title="previewItem.name" class="preview-video" loading="lazy"></iframe>
        <video v-else-if="/\.(mp4|webm|m4v)$/i.test(previewItem.name)" :src="previewURL" controls playsinline class="preview-video"/>
      </div>
    </div>
    <div v-if="sharingFile" class="dialog-backdrop" @click.self="!shareCreating&&(sharingFile=null)">
      <div class="confirm-dialog" role="dialog" aria-modal="true" aria-label="文件下载分享">
        <h3>限时分享 · {{sharingFile.name}}</h3>
        <p v-if="sharingFile.type==='folder'">生成仅可下载此文件夹（打包为 ZIP，流式传输、不支持断点续传）的临时链接。获得链接的人无需登录，链接到期、文件夹被替换或授权撤销后失效。</p>
        <p v-else>生成仅可下载此文件的临时链接。获得链接的人无需登录，链接到期、文件变化或授权撤销后失效。</p>
        <form v-if="!shareCreatedLink" class="account-form" @submit.prevent="createFileShare">
          <label>有效期
            <select v-model.number="shareHours">
              <option :value="1">1 小时</option>
              <option :value="6">6 小时</option>
              <option :value="24">1 天</option>
              <option :value="72">3 天</option>
              <option :value="168">7 天</option>
            </select>
          </label>
          <label>访问密码（选填，至少 4 个字符）
            <input v-model="sharePassword" type="password" autocomplete="new-password" maxlength="128" placeholder="不设置密码则留空" />
          </label>
          <label>最多下载次数（0 = 不限制）
            <input v-model.number="shareMaxDownloads" type="number" min="0" max="100000" step="1" />
          </label>
          <button type="submit" class="auth-submit" :disabled="shareCreating">{{shareCreating?"正在生成…":"生成分享链接"}}</button>
        </form>
        <div v-else class="account-form">
          <label>分享链接（仅此时显示）
            <input ref="shareLinkInput" :value="shareCreatedLink" readonly @focus="shareLinkInput?.select()" />
          </label>
          <button type="button" class="auth-submit" @click="copyShareLink">复制分享链接</button>
          <p v-if="shareCopied" class="footnote" role="status">{{shareCopied}}</p>
        </div>
        <p v-if="shareError" class="form-error" role="alert">{{shareError}}</p>
        <div class="dialog-buttons"><button type="button" :disabled="shareCreating" @click="sharingFile=null;shareCreatedLink=''">完成</button></div>
      </div>
    </div>
    <FileOperationDialog v-if="fileOperationDialog" :key="rootViewKey+':'+fileOperationDialog.action+':'+fileOperationDialog.item.path"
      :item="fileOperationDialog.item" :action="fileOperationDialog.action"
      :list-folders="listOperationFolders" :perform="commitFileOperation"
      @close="fileOperationDialog=null" @complete="finishFileOperation"/>
    <nav class="mobile-nav glass" aria-label="移动导航">
      <button v-for="item in items.slice(0, 5)" :key="item.key" type="button" :class="{ chosen: active === item.key }" @click="active = item.key">
        <component :is="item.icon" :size="20" /><span>{{ item.title }}</span>
      </button>
    </nav>
  </div>
</template>

