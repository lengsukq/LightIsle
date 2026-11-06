<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import {describeRootOperationFailure} from "./rootDiscovery.js";
import {describeUserFacingError} from "./userFacingError.js";
import {createBrowserMediaBackstack} from "./browserMediaBackstack.js";
import {apiErrorFromResponse} from "./apiFailure.js";
import { Heart, Star, RefreshCw, Images, Film, Plus, X, FolderPlus, ChevronDown, ChevronLeft, ChevronRight, Info, MapPin, Pencil, Trash2, Sparkles, ArrowUp, Search } from "lucide-vue-next";
import { validateAlbumName } from "./albumNameValidation.js";
import { createLatestRequestGate } from "./latestRequestGate.js";
import { createMediaStatusPoller } from "./mediaStatusPoller.js";
import { mediaQueryKey, transitionMediaQuery } from "./mediaQueryContext.js";
import { createPhotoTimelineLayout, getPhotoTimelineWindow } from "./photoTimelineLayout.js";
import { buildTimelineYears, timelineJumpIndex, timelineYearsFromMonths, timelineScrubIndexAt } from "./photoTimelineJump.js";
import { rootApiPath, rootMediaPath } from "./rootApi.js";
import PhotoMapView from "./PhotoMapView.vue";
import type { MapStripAsset, MapTransport } from "./photoMapTransport.js";
import { LayoutList, Map as MapIcon } from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";
import { trashMediaOriginals } from "./mediaTrash.js";
import { usePhotoViewer } from "./usePhotoViewer";
import { usePhotoSlideshow } from "./usePhotoSlideshow";
import { dateLabel, capturedLabel, formatBytes, formatExposure, formatAperture, formatDuration, coordinateLabel, albumError } from "./photoPresentation";

type Asset={id:number;path:string;name:string;type:"photo"|"video";size:number;takenAt:number;favorite:boolean;personalFavorite?:boolean;canWrite?:boolean;
 capturedAt?:string;latitude?:number;longitude?:number;cameraMake?:string;cameraModel?:string;lensModel?:string;iso?:number;fNumber?:number;exposureSeconds?:number;focalLength?:number;width?:number;height?:number;durationSeconds?:number};
type Album={id:number;name:string;count:number;coverAssetId?:number};
type FolderAlbum={name:string;path:string};
type Status={running:boolean;scanned:number;found:number;lastError?:string;lastDone?:number};
const props=defineProps<{admin:boolean;rootId?:string;rootGeneration?:number}>();
const assets=ref<Asset[]>([]);
const albums=ref<Album[]>([]);
const privateAlbums=ref<Album[]>([]);
const activeAlbum=ref(0);
const activePrivateAlbum=ref(0);
const folderAlbums=ref<FolderAlbum[]>([]);
const folderCursor=ref("");
const folderError=ref("");
const folderLoading=ref(false);
const folderName=ref("");
const folderTarget=ref("");
const activeFolderAlbum=ref<FolderAlbum|null>(null);
const favoritesOnly=ref(false);
const personalOnly=ref(false);
const onThisDayOnly=ref(false);
const typeFilter=ref<""|"photo"|"video">("");
const searchInput=ref("");
const searchApplied=ref("");
let searchTimer:number|undefined;
function photoQueryKey(){return mediaQueryKey({root:props.rootId??"",generation:props.rootGeneration??0,album:activeAlbum.value,privateAlbum:activePrivateAlbum.value,directory:activeFolderAlbum.value?.path??"",favorites:favoritesOnly.value,personal:personalOnly.value,onThisDay:onThisDayOnly.value,type:typeFilter.value,q:searchApplied.value})}
function setTypeFilter(kind:""|"photo"|"video"){
 if(typeFilter.value===kind)return;
 typeFilter.value=kind;
 void load(true);
}
function closeAlbumMenu(event:Event){
 const menu=(event.target as HTMLElement)?.closest("details.photo-albums-menu");
 if(menu instanceof HTMLDetailsElement)menu.open=false;
}
watch(searchInput,value=>{
 if(searchTimer)clearTimeout(searchTimer);
 searchTimer=window.setTimeout(()=>{
  const term=value.trim();
  if(term===searchApplied.value)return;
  searchApplied.value=term;
  void load(true);
 },400);
});
let pageQueryKey=photoQueryKey();
const nextCursor=ref(0);
const timelineCursorStart=ref(0);
const fullTimelineMonths=ref<Array<{year:number;month:number;count:number;firstIndex:number}>>([]);
function isFullTimelineView(){
 return !activeAlbum.value&&!activePrivateAlbum.value&&!activeFolderAlbum.value&&!favoritesOnly.value&&
  !personalOnly.value&&!onThisDayOnly.value&&!typeFilter.value&&!searchApplied.value;
}
async function refreshTimelineIndex(){
 const root=rootEpoch;
 try{
  const result=await api<{months:Array<{year:number;month:number;count:number;firstIndex:number}>}>(apiPath("/api/v2/photos/timeline"));
  if(!disposed&&root===rootEpoch)fullTimelineMonths.value=result.months;
 }catch{
  if(!disposed&&root===rootEpoch)fullTimelineMonths.value=[];
 }
}
const loading=ref(false);
const galleryLoaded=ref(false);
const loadError=ref("");
const loadErrorReset=ref(true);
const scanActionError=ref("");
const scanStatusLoading=ref(false);
const scanStatusLoaded=ref(false);
const scanStatusError=ref("");
const sharedAlbumsError=ref("");
const privateAlbumsError=ref("");
const sharedAlbumsLoading=ref(false);
const privateAlbumsLoading=ref(false);
const message=ref("");
const trashSelecting=ref(false);
const trashBusy=ref(false);
const trashIDs=ref<Set<number>>(new Set());
function toggleTrashID(id:number) {
 const next=new Set(trashIDs.value);
 if(next.has(id))next.delete(id);
 else if(next.size<50)next.add(id);
 trashIDs.value=next;
}
async function trashPhotos(items:Asset[]) {
 if(trashBusy.value||!items.length)return;
 if(items.length>50||items.some(item=>!canWriteAsset(item))){
  message.value="每次最多删除50项，且必须拥有对应原文件的写入权限。";
  return;
 }
 const root=rootEpoch,view=viewGeneration;
 const selectedIDs=items.map(item=>item.id);
 const paths=items.map(item=>item.path);
 if(!window.confirm(`将这 ${items.length} 项照片/视频原文件移入回收站？之后可在文件管理中恢复。`))return;
 const current=()=>!disposed&&root===rootEpoch&&view===viewGeneration &&
  selectedIDs.every((id,i)=>assets.value.some(item=>item.id===id&&item.path===paths[i]));
 if(!current()){message.value="媒体列表或存储目录已变化，请重新选择。";return}
 trashBusy.value=true;
 try{
  const result=await trashMediaOriginals(paths,
   batch=>api<{results:Array<{path?:string;success:boolean}>}>(
    apiPath("/api/v2/files/batch"),"POST",{action:"trash",paths:batch}),
   current);
  if(result.cancelled){message.value="原硬盘或列表已变化，请返回原目录检查回收站。";return}
  if(selected.value&&selectedIDs.includes(selected.value.id))closeModal(false);
  trashIDs.value=new Set();trashSelecting.value=false;
  message.value=`已移入回收站 ${result.completed}/${items.length} 项${result.failed.length?"；其余项目请检查权限或文件状态。":"。"}`;
  await load(true);
 }catch(error){if(root===rootEpoch)message.value="移入回收站失败："+describeRootOperationFailure(error)}
 finally{trashBusy.value=false}
}
function trashSelectedPhotos(){
 const items=assets.value.filter(item=>trashIDs.value.has(item.id));
 if(items.length!==trashIDs.value.size){message.value="选择的媒体已变化，请重新选择。";return}
 void trashPhotos(items);
}
const scan=ref<Status>({running:false,scanned:0,found:0});
const selected=ref<Asset|null>(null);
const {viewerStage,viewerScale,viewerOffset,viewerTransform,viewerAnimate,viewerPointers,
  viewerPreviewLoading,viewerPreviewError,viewerOriginalLoading,viewerOriginalError,
  browserDecodable,cancelViewerLoads,startViewerStages,requestViewerOriginal,viewerSrc,
  toggleViewerZoom,viewerPointerDown,viewerPointerMove,viewerPointerUp,viewerWheel}=usePhotoViewer({
  selected,mediaPath,original,thumb,
  move(delta){const index=selectedIndex.value+delta;if(index<0||index>=modalAssets.value.length)return false;showAssetAt(index);return true;},
});
const selectedIndex=ref(-1);
const thumbnailFailed=ref<Record<number,boolean>>({});
const pendingFavorites=ref<Record<number,boolean>>({});
const creating=ref(false);
const albumName=ref("");
const addAlbum=ref(0);
const addPrivateAlbum=ref(0);
const creatingPrivate=ref(false);
const editingPrivate=ref<Album|null>(null);
const privateAlbumName=ref("");
const albumBusy=ref(false);
const creationReturnsToAlbums=ref(false);
const failedAlbumCovers=ref<Record<string,boolean>>({});
const editingAlbum=ref<Album|null>(null);
const photosPage=ref<HTMLElement|null>(null);
const gridElement=ref<HTMLElement|null>(null);
const loadMarker=ref<HTMLElement|null>(null);
const galleryDialog=ref<HTMLElement|null>(null);
const modalCloseButton=ref<HTMLButtonElement|null>(null);
const containerWidth=ref(0);
const viewportTop=ref(0);
const viewportHeight=ref(0);
const scrubberInView=ref(false);
const focusedIndex=ref(0);
let timer:number|undefined;
let lastCompletedScan=0;
let rootEpoch=0;
let disposed=false;
let viewportFrame=0;
let resizeObserver:ResizeObserver|undefined;
let loadObserver:IntersectionObserver|undefined;
const listRequests=createLatestRequestGate();
const albumRequests=createLatestRequestGate();
const privateAlbumRequests=createLatestRequestGate();
const folderAlbumRequests=createLatestRequestGate();
let viewGeneration=0;
let selectionGeneration=0;
function apiPath(path:string){return rootApiPath(props.rootId,path)}
function mediaPath(path:string){return rootMediaPath(props.rootId,props.rootGeneration??0,path)}
async function api<T>(url:string,method="GET",body?:object,signal?:AbortSignal):Promise<T>{
 const rootID=props.rootId,rootGeneration=props.rootGeneration??0;
 const headers=new Headers(method==="GET"?{}:{"Content-Type":"application/json","X-LightIsle-Request":"1"});
 if(rootID)headers.set("X-LightIsle-Root-Generation",String(rootGeneration));
 const response=await fetch(url,{
  method,credentials:"same-origin",
  headers,
  body:body?JSON.stringify(body):undefined,cache:"no-store",signal
 });
 if(!response.ok){
  const data=await response.json().catch(()=>({error:"request_failed"})) as {error?:string};
  if(rootID&&(props.rootId!==rootID||props.rootGeneration!==rootGeneration||disposed))throw makeRootAbortError();
  if(rootID&&response.status===409&&data.error==="root_generation_changed"){
   window.dispatchEvent(new Event("lightisle-root-generation-changed"));
   throw new Error("共享目录已变化，请刷新根列表后重新选择。");
  }
  throw apiErrorFromResponse(response,data);
 }
 const result=await response.json() as T;
 if(rootID&&(props.rootId!==rootID||props.rootGeneration!==rootGeneration||disposed))throw makeRootAbortError();
 return result;
}
function makeRootAbortError(){const error=new Error("root_context_changed");error.name="AbortError";return error;}
async function togglePersonalFavorite(asset:Asset){
 if(pendingFavorites.value[asset.id])return;
 const selection=selectionGeneration;
 pendingFavorites.value[asset.id]=true;
 try{
  const next=!asset.personalFavorite;
  await api(apiPath("/api/v2/photos/"+asset.id+"/personal-favorite"),"POST",{favorite:next});
  const current=assets.value.find(item=>item.id===asset.id);
  if(current)current.personalFavorite=next;
  if(selected.value?.id===asset.id)selected.value.personalFavorite=next;
  if(personalOnly.value&&!next){
   const selectedID=selected.value?.id;
   const previousIndex=selectedIndex.value;
   if(selectedID===asset.id)closeModal(false);
   await load(true);
   if(selectedID&&selectedID!==asset.id){
    const nextIndex=assets.value.findIndex(item=>item.id===selectedID);
    if(nextIndex>=0)selectedIndex.value=nextIndex;
   }else if(selectedID===asset.id&&assets.value.length){
    await focusTile(Math.min(previousIndex,assets.value.length-1));
   }
  }
 }catch(e){if(selection===selectionGeneration&&selected.value?.id===asset.id)message.value="个人收藏失败："+describeUserFacingError(e)}
 finally{delete pendingFavorites.value[asset.id]}
}
const scanStatusPoller=createMediaStatusPoller(
 signal=>api<{status:Status;count:number}>(apiPath("/api/v2/photos/status"),"GET",undefined,signal),
 {
  onValue:result=>{
   const previous=scan.value.lastDone;
   scan.value=result.status;scanStatusLoaded.value=true;scanStatusError.value="";scanStatusLoading.value=false;
   if(!scan.value.running&&scan.value.lastDone&&scan.value.lastDone!==previous&&scan.value.lastDone>lastCompletedScan){
    lastCompletedScan=scan.value.lastDone;
    void load(true);void refreshAlbums();void refreshPrivateAlbums();void refreshTimelineIndex();
   }
  },
  onError:error=>{scanStatusError.value=describeRootOperationFailure(error);scanStatusLoading.value=false;},
 },
);
function status(){scanStatusLoading.value=true;return scanStatusPoller.refresh()}
async function load(reset=false){
 if(loading.value&&!reset)return;
 const transition=transitionMediaQuery(pageQueryKey,photoQueryKey());
 if(transition.clearContent){
  pageQueryKey=transition.queryKey;assets.value=[];nextCursor.value=0;galleryLoaded.value=false;focusedIndex.value=0;
  timelineCursorStart.value=0;
 }
 const request=listRequests.begin();
 loading.value=true;
 loadError.value="";
 if(reset){focusedIndex.value=0;timelineCursorStart.value=0;}
 try {
  const query=new URLSearchParams({limit:"48",cursor:String(reset?0:nextCursor.value)});
  if(activeAlbum.value)query.set("album",String(activeAlbum.value));
  if(activePrivateAlbum.value)query.set("privateAlbum",String(activePrivateAlbum.value));
  if(activeFolderAlbum.value)query.set("directory",activeFolderAlbum.value.path);
  if(favoritesOnly.value)query.set("favorites","1");
  if(personalOnly.value)query.set("personal","1");
  if(onThisDayOnly.value)query.set("onThisDay","1");
  if(typeFilter.value)query.set("type",typeFilter.value);
  if(searchApplied.value)query.set("q",searchApplied.value);
  const result=await api<{assets:Asset[];nextCursor:number}>(apiPath("/api/v2/photos")+"?"+query.toString(),"GET",undefined,request.signal);
  if(!request.isCurrent())return;
  assets.value=reset?result.assets:[...assets.value,...result.assets];
  nextCursor.value=result.nextCursor;
  if(reset)galleryLoaded.value=true;
  message.value="";
  await nextTick();if(request.isCurrent())updateViewport();
 }catch(e){if(request.isCurrent()&&!(e instanceof Error&&e.name==="AbortError")){loadError.value="加载照片失败："+describeRootOperationFailure(e);loadErrorReset.value=reset}}
 finally{
  if(request.isCurrent()){
   loading.value=false;
   // IntersectionObserver may remain continuously intersecting on a very
   // tall display after the next page. In that case it does not fire a new
   // transition; continue until the sentinel moves below the viewport.
   if(nextCursor.value&&!loadError.value){
    requestAnimationFrame(()=>{
     const marker=loadMarker.value;
     if(!disposed&&!loading.value&&marker&&marker.getBoundingClientRect().top<window.innerHeight+650){
      void load(false);
     }
    });
   }
  }
 }
}
function retryLoad(){void load(loadErrorReset.value)}
async function refreshAlbums(){
 const request=albumRequests.begin();
 sharedAlbumsLoading.value=true;
 try{
  const result=await api<{albums:Album[]}>(apiPath("/api/v2/photos/albums"),"GET",undefined,request.signal);
  if(!disposed&&request.isCurrent()){albums.value=result.albums;sharedAlbumsError.value=""}
 }catch(error){if(!disposed&&request.isCurrent()&&!(error instanceof Error&&error.name==="AbortError"))sharedAlbumsError.value=albumError(error)}
 finally{if(!disposed&&request.isCurrent())sharedAlbumsLoading.value=false}
}
async function refreshPrivateAlbums(isCurrent:()=>boolean=()=>true){
 const request=privateAlbumRequests.begin();
 privateAlbumsLoading.value=true;
 try{
  const result=await api<{albums:Album[]}>(apiPath("/api/v2/photos/private-albums"),"GET",undefined,request.signal);
  if(!disposed&&request.isCurrent()){privateAlbums.value=result.albums;privateAlbumsError.value=""}
 }catch(e){if(request.isCurrent()&&!disposed&&isCurrent()&&!(e instanceof Error&&e.name==="AbortError"))privateAlbumsError.value=albumError(e)}
 finally{if(!disposed&&request.isCurrent())privateAlbumsLoading.value=false}
}
async function refreshFolderAlbums(more=false){
 if(folderLoading.value)return;
 const request=folderAlbumRequests.begin();folderLoading.value=true;folderError.value="";
 try{
  const query=new URLSearchParams();if(more&&folderCursor.value)query.set("cursor",folderCursor.value);
  const result=await api<{albums:FolderAlbum[];nextCursor:string}>(apiPath("/api/v2/photos/folder-albums")+(query.size?"?"+query:""),"GET",undefined,request.signal);
  if(!disposed&&request.isCurrent()){folderAlbums.value=more?[...folderAlbums.value,...result.albums]:result.albums;folderCursor.value=result.nextCursor}
 }catch(error){if(!disposed&&request.isCurrent()&&!(error instanceof Error&&error.name==="AbortError"))folderError.value=describeRootOperationFailure(error)}
 finally{if(request.isCurrent())folderLoading.value=false}
}
async function createFolderAlbum(){
 if(albumBusy.value)return;
 const validation=validateAlbumName(folderName.value);
 if(!validation.valid||/[\/\\]/.test(validation.name)){message.value="相册名称需为 1–60 个字符，不能包含斜杠或控制字符。";return}
 const root=rootEpoch,name=validation.name;albumBusy.value=true;message.value="";
 try{
  await api(apiPath("/api/v2/photos/folder-albums"),"POST",{name});
  if(root!==rootEpoch)return;
  folderName.value="";await refreshFolderAlbums();message.value="已在照片目录中新建文件夹相册。";
 }catch(error){if(root===rootEpoch)message.value="创建文件夹相册失败："+albumError(error)}
 finally{albumBusy.value=false}
}
async function deleteFolderAlbum(album:FolderAlbum){
 if(albumBusy.value||!window.confirm(`删除空相册“${album.name}”？含有照片或其他文件的相册不能删除。`))return;
 const root=rootEpoch;albumBusy.value=true;message.value="";
 try{
  await api(apiPath("/api/v2/photos/folder-albums/")+encodeURIComponent(album.name),"DELETE");
  if(root!==rootEpoch)return;
  if(activeFolderAlbum.value?.path===album.path)changeView(0,false);
  await refreshFolderAlbums();message.value="空相册文件夹已删除。";
 }catch(error){if(root===rootEpoch)message.value="删除相册失败："+describeRootOperationFailure(error)}
 finally{albumBusy.value=false}
}
function openFolderAlbum(album:FolderAlbum){
 viewGeneration+=1;selectionGeneration+=1;activeFolderAlbum.value=album;activeAlbum.value=0;activePrivateAlbum.value=0;
 favoritesOnly.value=false;personalOnly.value=false;onThisDayOnly.value=false;searchInput.value="";searchApplied.value="";
 selected.value=null;selectedIndex.value=-1;focusedIndex.value=0;viewMode.value="timeline";void load(true);
}
async function addSelectedToFolder(action:"copy"|"move"){
 const asset=selected.value, destination=folderAlbums.value.find(item=>item.path===folderTarget.value);
 if(!asset||!destination||albumBusy.value)return;
 if(action==="move"&&!canWriteAsset(asset)){message.value="没有移动原文件的权限，可以选择复制。";return}
 const root=rootEpoch,view=viewGeneration,selection=selectionGeneration,from=asset.path,to=destination.path+"/"+asset.name;
 if(from===to){message.value="照片已经在这个相册中。";return}
 if(action==="move"&&!window.confirm(`将“${asset.name}”移动到“${destination.name}”？原位置将不再保留该文件。`))return;
 if(root!==rootEpoch||view!==viewGeneration||selection!==selectionGeneration||selected.value?.id!==asset.id)return;
 albumBusy.value=true;message.value="";
 try{
  await api(apiPath("/api/v2/files/operations"),"POST",{action,from,to,conflict:""});
  if(root!==rootEpoch)return;
  if(action==="move")closeModal(false);
  await load(true);
  if(root===rootEpoch)message.value=action==="copy"?"照片已复制到相册，图库正在更新。":"照片已移动到相册，图库正在更新。";
 }catch(error){if(root===rootEpoch)message.value=(action==="copy"?"复制":"移动")+"到相册失败："+describeRootOperationFailure(error)}
 finally{albumBusy.value=false}
}
const folderAlbumOptions=computed(()=>[{value:"",label:"选择文件夹相册…"},...folderAlbums.value.map(album=>({value:album.path,label:album.name}))]);
const currentPrivateAlbum=computed(()=>privateAlbums.value.find(item=>item.id===activePrivateAlbum.value));
function editPrivateAlbum(album:Album){
 editingPrivate.value=album;privateAlbumName.value=album.name;creatingPrivate.value=true;
}
function cancelPrivateAlbum(){
 creatingPrivate.value=false;editingPrivate.value=null;privateAlbumName.value="";
 if(creationReturnsToAlbums.value){viewMode.value="albums";creationReturnsToAlbums.value=false}
}
async function savePrivateAlbum(){
 if(albumBusy.value)return;
 const validation=validateAlbumName(privateAlbumName.value);
 if(!validation.valid){message.value="私人相册名称需为 1–60 个字符，不能包含控制字符。";return}
 const view=viewGeneration,editingID=editingPrivate.value?.id??0;
 const formIsCurrent=()=>view===viewGeneration&&creatingPrivate.value&&
  (editingPrivate.value?.id??0)===editingID&&privateAlbumName.value.trim()===validation.name;
 albumBusy.value=true;message.value="";
 try{
  if(editingPrivate.value){
   await api(apiPath("/api/v2/photos/private-albums/"+editingPrivate.value.id),"PATCH",{name:validation.name});
  }else{
   await api(apiPath("/api/v2/photos/private-albums"),"POST",{name:validation.name});
  }
  await refreshPrivateAlbums(formIsCurrent);
  if(formIsCurrent()){
   cancelPrivateAlbum();
   message.value="私人相册已保存，其他账号不可查看。";
  }
 }catch(e){if(formIsCurrent())message.value="私人相册保存失败："+albumError(e)}
 finally{albumBusy.value=false}
}
async function deletePrivateAlbum(){
 const album=currentPrivateAlbum.value;
 if(!album||albumBusy.value||!window.confirm("仅删除你的私人相册「"+album.name+"」及其中的关联记录，原始照片不会被删除。确认吗？"))return;
 const albumID=album.id,wasCurrent=activePrivateAlbum.value===album.id;
 const view=viewGeneration;
 albumBusy.value=true;
 try{
  await api(apiPath("/api/v2/photos/private-albums/"+albumID),"DELETE");
  const sameView=view===viewGeneration;
  if(wasCurrent&&activePrivateAlbum.value===albumID)changeView(0,false);
  await refreshPrivateAlbums(()=>view===viewGeneration);
  if(sameView)message.value="私人相册已删除，原始文件及共享相册不受影响。";
 }catch(e){if(view===viewGeneration)message.value="删除私人相册失败："+albumError(e)}
 finally{albumBusy.value=false}
}
async function addSelectedPrivate(){
 if(!selected.value||!addPrivateAlbum.value||albumBusy.value)return;
 const assetID=selected.value.id,albumID=addPrivateAlbum.value;
 const selection=selectionGeneration,view=viewGeneration;
 albumBusy.value=true;message.value="";
 try{
  await api(apiPath("/api/v2/photos/private-albums/"+albumID+"/items"),"POST",{assetId:assetID});
  await refreshPrivateAlbums(()=>selection===selectionGeneration&&view===viewGeneration&&selected.value?.id===assetID);
  if(selection===selectionGeneration&&view===viewGeneration&&selected.value?.id===assetID&&addPrivateAlbum.value===albumID)message.value="已加入我的私人相册";
 }catch(e){if(selection===selectionGeneration&&view===viewGeneration&&selected.value?.id===assetID)message.value="加入私人相册失败："+albumError(e)}
 finally{albumBusy.value=false}
}
async function removeSelectedPrivate(){
 if(!selected.value||!activePrivateAlbum.value||albumBusy.value)return;
 const assetID=selected.value.id,albumID=activePrivateAlbum.value,removedIndex=selectedIndex.value;
 const selection=selectionGeneration,view=viewGeneration;
 albumBusy.value=true;
 try{
  await api(apiPath("/api/v2/photos/private-albums/"+albumID+"/items/"+assetID),"DELETE");
  const shouldClose=activePrivateAlbum.value===albumID&&selected.value?.id===assetID;
  const retainedSelection=shouldClose?0:(selected.value?.id??0);
  if(shouldClose)closeModal(false);
  if(activePrivateAlbum.value===albumID){
   await load(true);
   if(retainedSelection&&activePrivateAlbum.value===albumID){
    const index=assets.value.findIndex(item=>item.id===retainedSelection);
    if(index>=0)selectedIndex.value=index;
   }
  }
  await refreshPrivateAlbums(()=>view===viewGeneration&&activePrivateAlbum.value===albumID);
  if(view===viewGeneration&&activePrivateAlbum.value===albumID){
   if(shouldClose){
    if(assets.value.length)await focusTile(Math.min(removedIndex,assets.value.length-1));
    else{
     await nextTick();
     photosPage.value?.querySelector<HTMLButtonElement>(`[data-private-album-filter="${albumID}"]`)?.focus();
    }
   }
   message.value="照片已从私人相册移出，原文件不受影响。";
  }
 }catch(e){if(selection===selectionGeneration&&view===viewGeneration&&selected.value?.id===assetID)message.value="移出私人相册失败："+albumError(e)}
 finally{albumBusy.value=false}
}
async function startScan(){
 const context=rootEpoch;scanActionError.value="";
 try{await api(apiPath("/api/v2/photos/scan"),"POST");if(context!==rootEpoch)return;message.value="正在后台扫描授权的共享目录";scanStatusPoller.invalidate();await status()}
 catch(e){if(context===rootEpoch)scanActionError.value="无法启动扫描："+describeUserFacingError(e)}
}
async function toggleFavorite(asset:Asset){
 if(!props.admin&&asset.canWrite!==true)return;
 if(pendingFavorites.value[asset.id])return;
 pendingFavorites.value[asset.id]=true;
 const next=!asset.favorite,selection=selectionGeneration;
 try{
  await api(apiPath("/api/v2/photos/"+asset.id+"/favorite"),"POST",{favorite:next});
  const current=assets.value.find(item=>item.id===asset.id);
  if(current)current.favorite=next;
  if(selected.value?.id===asset.id)selected.value.favorite=next;
 }catch(e){if(selection===selectionGeneration&&selected.value?.id===asset.id)message.value="收藏失败："+describeUserFacingError(e)}
 finally{delete pendingFavorites.value[asset.id]}
}
async function createAlbum(){
 if(!props.admin)return;
 const validation=validateAlbumName(albumName.value);
 const name=validation.name;
 if(!validation.valid){
  message.value=validation.reason==="empty"?"请输入相册名称。":"相册名称需为 1–60 个字符，且不能包含控制字符。";
  return;
 }
 albumBusy.value=true;message.value="";
 try{
  if(editingAlbum.value){
   const album=await api<Album>(apiPath("/api/v2/photos/albums/"+editingAlbum.value.id),"PATCH",{name});
   albums.value=albums.value.map(item=>item.id===album.id?album:item);
   message.value="相册名称已更新。";
  }else{
   await api(apiPath("/api/v2/photos/albums"),"POST",{name});
   message.value="相册已创建。";
  }
  albumName.value="";creating.value=false;editingAlbum.value=null;await refreshAlbums();
  if(creationReturnsToAlbums.value){viewMode.value="albums";creationReturnsToAlbums.value=false}
 }catch(e){
  const failure=(editingAlbum.value?"修改相册失败：":"创建相册失败：")+albumError(e);
  if(e instanceof Error&&e.message==="not_found"&&editingAlbum.value){
   const id=editingAlbum.value.id;await refreshAlbums();
   if(!albums.value.some(album=>album.id===id)){activeAlbum.value=0;favoritesOnly.value=false;cancelAlbumForm();await load(true)}
  }
  message.value=failure;
 }
 finally{albumBusy.value=false}
}
function beginAlbumRename(album:Album){
 if(!props.admin)return;
 editingAlbum.value=album;albumName.value=album.name;creating.value=true;message.value="";
}
function cancelAlbumForm(){
 creating.value=false;editingAlbum.value=null;albumName.value="";
 if(creationReturnsToAlbums.value){viewMode.value="albums";creationReturnsToAlbums.value=false}
}
const currentAlbum=computed(()=>albums.value.find(album=>album.id===activeAlbum.value));
async function deleteCurrentAlbum(){
 const album=currentAlbum.value;
 if(!props.admin||!album||albumBusy.value)return;
 const confirmed=window.confirm(`仅删除「${album.name}」相册及其照片关系；原始照片和视频仍保留，也不会删除收藏。确定删除吗？`);
 if(!confirmed)return;
 const albumID=album.id,view=viewGeneration;
 albumBusy.value=true;message.value="";
 try{
  await api(apiPath("/api/v2/photos/albums/"+albumID),"DELETE");
  albums.value=albums.value.filter(item=>item.id!==albumID);
  if(activeAlbum.value===albumID){
   activeAlbum.value=0;favoritesOnly.value=false;selected.value=null;selectedIndex.value=-1;selectionGeneration+=1;
   cancelAlbumForm();
   await load(true);
  }
  await refreshAlbums();
  if(view===viewGeneration)message.value="相册已删除，照片和视频原件仍保留。";
 }catch(e){
  if(view===viewGeneration)message.value=albumError(e);
  if(e instanceof Error&&e.message==="not_found"){
   await refreshAlbums();
   if(activeAlbum.value===albumID&&!albums.value.some(item=>item.id===albumID)){activeAlbum.value=0;favoritesOnly.value=false;await load(true);if(view===viewGeneration)message.value="相册已不存在，图库已刷新。"}
  }
 }finally{albumBusy.value=false}
}
async function addSelected(){
 if(!props.admin)return;
 if(!selected.value || !addAlbum.value)return;
 if(albumBusy.value)return;
 const assetID=selected.value.id,albumID=addAlbum.value,selection=selectionGeneration,view=viewGeneration;
 albumBusy.value=true;
 try{
  await api(apiPath("/api/v2/photos/albums/"+albumID+"/items"),"POST",{assetId:assetID});
  await refreshAlbums();
  if(selection===selectionGeneration&&view===viewGeneration&&selected.value?.id===assetID&&addAlbum.value===albumID)message.value="已加入相册";
 }catch(e){if(selection===selectionGeneration&&view===viewGeneration&&selected.value?.id===assetID)message.value="加入相册失败："+(e instanceof Error?e.message:"未知错误")}
 finally{albumBusy.value=false}
}
async function removeSelectedFromAlbum(){
 if(!props.admin||!selected.value||!activeAlbum.value||albumBusy.value)return;
 const albumId=activeAlbum.value,assetId=selected.value.id;
 const removedIndex=selectedIndex.value,selection=selectionGeneration,view=viewGeneration;
 albumBusy.value=true;message.value="";
 try{
  await api(apiPath(`/api/v2/photos/albums/${albumId}/items/${assetId}`),"DELETE");
  const shouldClose=activeAlbum.value===albumId&&selected.value?.id===assetId;
  const retainedSelection=shouldClose?0:(selected.value?.id??0);
  if(shouldClose)closeModal(false);
  await refreshAlbums();
  if(activeAlbum.value===albumId){
   await load(true);
   if(retainedSelection){const index=assets.value.findIndex(item=>item.id===retainedSelection);if(index>=0)selectedIndex.value=index}
   if(view===viewGeneration){
    if(shouldClose&&assets.value.length)await focusTile(Math.min(removedIndex,assets.value.length-1));
    message.value="已从相册移出，原始文件仍保留。";
   }
  }
 }catch(e){
  if(view===viewGeneration&&selection===selectionGeneration&&selected.value?.id===assetId&&e instanceof Error&&e.message==="not_found"){
   await refreshAlbums();await load(true);message.value="这张照片已不在当前相册，列表已刷新。原始文件仍保留。";
  }else if(view===viewGeneration&&selection===selectionGeneration&&selected.value?.id===assetId)message.value="移出相册失败："+albumError(e);
 }finally{albumBusy.value=false}
}
function changeView(album:number,favorites:boolean,mine=false,privateID=0){
 if(activeAlbum.value===album&&favoritesOnly.value===favorites&&personalOnly.value===mine&&activePrivateAlbum.value===privateID&&!onThisDayOnly.value&&!activeFolderAlbum.value)return;
 viewGeneration+=1;
 activeAlbum.value=album;favoritesOnly.value=favorites;personalOnly.value=mine;activePrivateAlbum.value=privateID;activeFolderAlbum.value=null;onThisDayOnly.value=false;searchInput.value="";searchApplied.value="";selected.value=null;selectedIndex.value=-1;focusedIndex.value=0;
 selectionGeneration+=1;
 void load(true);
 requestAnimationFrame(()=>{
  const root=photosPage.value;
  if(root)window.scrollTo({top:Math.max(0,root.getBoundingClientRect().top+window.scrollY-100),behavior:"auto"});
 });
}
function showOnThisDay(){
 if(onThisDayOnly.value)return;
 viewGeneration+=1;
 activeAlbum.value=0;favoritesOnly.value=false;personalOnly.value=false;activePrivateAlbum.value=0;activeFolderAlbum.value=null;onThisDayOnly.value=true;searchInput.value="";searchApplied.value="";
 selected.value=null;selectedIndex.value=-1;focusedIndex.value=0;selectionGeneration+=1;
 void load(true);
 window.scrollTo({top:0,behavior:"auto"});
}
// Timeline jump: year/month selects scroll to the matching month group. The
// browse label mirrors the first visible header so the controls follow both
// directions of navigation.
const timelineYears=computed(()=>{
 if(isFullTimelineView()&&fullTimelineMonths.value.length){
  return timelineYearsFromMonths(fullTimelineMonths.value);
 }
 return buildTimelineYears(assets.value.map(asset=>asset.takenAt));
});
const jumpYear=ref(0);
const jumpMonth=ref(0);
const jumpMonths=computed(()=>timelineYears.value.find(entry=>entry.year===jumpYear.value)?.months??[]);
const yearOptions=computed(()=>timelineYears.value.map(entry=>({
  value: entry.year,
  label: `${entry.year} 年`,
  hint: `${entry.count} 项`,
})));
const monthOptions=computed(()=>jumpMonths.value.map(entry=>({
  value: entry.month,
  label: entry.title,
  hint: `${entry.count} 项`,
})));
const albumOptions=computed(()=>[
  { value: 0, label: "选择一个相册…" },
  ...albums.value.map(album=>({
    value: album.id,
    label: album.name,
    hint: `${album.count} 张`,
  })),
]);
const privateAlbumOptions=computed(()=>[
  { value: 0, label: "选择要加入的相册…" },
  ...privateAlbums.value.map(album=>({
    value: album.id,
    label: album.name,
    hint: `${album.count} 张`,
  })),
]);
const browseTitle=computed(()=>visibleHeaders.value[0]?.title??"");
function scrollToTimelineIndex(index:number){
 const grid=gridElement.value;
 const targetGroup=timelineLayout.value.groups.find(item=>item.startIndex===index);
 if(!grid||!targetGroup)return;
 const targetTop=grid.getBoundingClientRect().top+window.scrollY+targetGroup.top;
 window.scrollTo({top:Math.max(0,targetTop-120),behavior:"auto"});
 measureViewport();
}
async function loadAtTimelineCursor(cursor:number){
 if(loading.value||!isFullTimelineView())return false;
 const request=listRequests.begin();
 loading.value=true;loadError.value="";
 try{
  const query=new URLSearchParams({limit:"48",cursor:String(cursor)});
  const result=await api<{assets:Asset[];nextCursor:number}>(apiPath("/api/v2/photos")+"?"+query.toString(),"GET",undefined,request.signal);
  if(!request.isCurrent())return false;
  assets.value=result.assets;
  nextCursor.value=result.nextCursor;
  timelineCursorStart.value=cursor;
  focusedIndex.value=0;galleryLoaded.value=true;
  await nextTick();
  updateViewport();
  return true;
 }catch(error){
  if(request.isCurrent()&&!(error instanceof Error&&error.name==="AbortError")){
   loadError.value="跳转年月失败："+describeRootOperationFailure(error);
  }
  return false;
 }finally{if(request.isCurrent())loading.value=false}
}
async function jumpToTimeline(){
 const index=timelineJumpIndex(timelineYears.value,jumpYear.value,jumpMonth.value);
 if(index<0)return;
 if(isFullTimelineView()&&fullTimelineMonths.value.length){
  const relative=index-timelineCursorStart.value;
  if(relative<0||relative>=assets.value.length){
   if(await loadAtTimelineCursor(index)){
    scrollToTimelineIndex(0);
   }
   return;
  }
  scrollToTimelineIndex(relative);
 }else{
  scrollToTimelineIndex(index);
 }
}
function onJumpYearChange(){
 jumpMonth.value=jumpMonths.value.length?jumpMonths.value[jumpMonths.value.length-1].month:0;
 jumpToTimeline();
}
const scrubMonths=computed(()=>timelineYears.value.flatMap(year=>year.months.map(month=>({
 year:year.year,month:month.month,title:month.title,firstIndex:month.firstIndex,
}))));
const scrubbing=ref(false);
const scrubPreview=ref(0);
let scrubPointerId:number|null=null;
const scrubCurrentIndex=computed(()=>{
 if(scrubbing.value)return scrubPreview.value;
 const visible=assets.value[Math.min(assets.value.length-1,virtualWindow.value.startIndex)];
 if(visible&&visible.takenAt>0){
  const taken=new Date(visible.takenAt*1000);
  const found=scrubMonths.value.findIndex(entry=>entry.year===taken.getFullYear()&&entry.month===taken.getMonth()+1);
  if(found>=0)return found;
 }
 const fallback=scrubMonths.value.findIndex(entry=>entry.firstIndex>=timelineCursorStart.value);
 return Math.max(0,fallback);
});
function scrubAtPointer(event:PointerEvent){
 const rail=event.currentTarget as HTMLElement;
 const rect=rail.getBoundingClientRect();
 const index=timelineScrubIndexAt(event.clientY-rect.top,rect.height,scrubMonths.value.length);
 if(index>=0)scrubPreview.value=index;
}
function startScrub(event:PointerEvent){
 if(event.button!==0||loading.value||!scrubMonths.value.length)return;
 scrubbing.value=true;scrubPointerId=event.pointerId;
 scrubAtPointer(event);
 (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
 event.preventDefault();
}
function moveScrub(event:PointerEvent){
 if(!scrubbing.value||scrubPointerId!==event.pointerId)return;
 scrubAtPointer(event);
}
function stopScrub(event:PointerEvent,commit=true){
 if(!scrubbing.value||scrubPointerId!==event.pointerId)return;
 const rail=event.currentTarget as HTMLElement;
 if(rail.hasPointerCapture(event.pointerId))rail.releasePointerCapture(event.pointerId);
 const selectedIndex=scrubPreview.value;
 scrubbing.value=false;scrubPointerId=null;
 if(!commit)return;
 const month=scrubMonths.value[selectedIndex];
 if(!month)return;
 jumpYear.value=month.year;jumpMonth.value=month.month;
 void jumpToTimeline();
}
function scrubKeydown(event:KeyboardEvent){
 if(loading.value||!scrubMonths.value.length)return;
 let index=scrubCurrentIndex.value;
 if(event.key==="ArrowDown")index+=1;
 else if(event.key==="ArrowUp")index-=1;
 else if(event.key==="PageDown")index+=6;
 else if(event.key==="PageUp")index-=6;
 else if(event.key==="Home")index=0;
 else if(event.key==="End")index=scrubMonths.value.length-1;
 else return;
 event.preventDefault();
 const month=scrubMonths.value[Math.max(0,Math.min(scrubMonths.value.length-1,index))];
 jumpYear.value=month.year;jumpMonth.value=month.month;
 void jumpToTimeline();
}
function scrollToTop(){
 if(timelineCursorStart.value>0){void load(true);return}
 window.scrollTo({top:0,behavior:"auto"});
}
// Timeline ↔ map modes share one query context; the map only renders located
// assets and opens the shared viewer for strip selections.
const viewMode=ref<"timeline"|"albums"|"map">("timeline");
function openAlbumFromOverview(album:Album,personal:boolean){
 viewMode.value="timeline";
 changeView(personal?0:album.id,false,false,personal?album.id:0);
}
function startAlbumFromOverview(personal:boolean){
 creationReturnsToAlbums.value=true;
 viewMode.value="timeline";
 if(personal){creatingPrivate.value=true;editingPrivate.value=null;privateAlbumName.value=""}
 else{creating.value=true;editingAlbum.value=null;albumName.value=""}
 void nextTick(()=>{
  const element=photosPage.value;
  if(element)window.scrollTo({top:Math.max(0,element.getBoundingClientRect().top+window.scrollY-80),behavior:"auto"});
 });
}
const photoMap=ref<{focusAsset:(latitude:number,longitude:number)=>void}|null>(null);
const mapTransport:MapTransport={
  loadGeo:()=>api<{points:{id:number;lat:number;lon:number;takenAt:number;type:string}[];total:number;truncated:boolean}>(apiPath("/api/v2/photos/geo")),
  loadMapStatus:()=>api<{tiandituConfigured:boolean}>("/api/v2/map/status"),
  loadAssetsByIds:async ids=>{
    if(!ids.length)return [];
    const query=new URLSearchParams({limit:String(Math.min(120,Math.max(1,ids.length))),cursor:"0",ids:ids.join(",")});
    const result=await api<{assets:Asset[]}>(apiPath("/api/v2/photos")+"?"+query.toString());
    // Preserve personal/shared favorites, write permissions and full EXIF
    // metadata; the map viewer must not invent false defaults.
    return result.assets;
  },
  thumbnail:id=>mediaPath("/api/v2/photos/"+id+"/thumbnail"),
};
const mapSelection=ref<Asset[]>([]);
const modalAssets=computed(()=>viewMode.value==="map"?mapSelection.value:assets.value);
const {slideshow,stopSlideshow,toggleSlideshow}=usePhotoSlideshow({
 selected,selectedIndex,modalAssets,showAssetAt,
});
function openMapAsset(item:MapStripAsset,group:MapStripAsset[]){
 stopSlideshow();
  mapSelection.value=group.map(asset=>({...asset}));
  const index=mapSelection.value.findIndex(asset=>asset.id===item.id);
  showAssetAt(index>=0?index:0);
  void nextTick(()=>modalCloseButton.value?.focus());
}
async function showOnMap(latitude:number,longitude:number){
  closeModal(false);
  viewMode.value="map";
  await nextTick();
  photoMap.value?.focusAsset(latitude,longitude);
}
function toggleAlbumCreate(){
 if(creating.value){cancelAlbumForm();return}
 editingAlbum.value=null;albumName.value="";creating.value=true;message.value="";
}
const timelineLayout=computed(()=>createPhotoTimelineLayout(assets.value.map(asset=>asset.takenAt),containerWidth.value));
const virtualWindow=computed(()=>getPhotoTimelineWindow(timelineLayout.value,viewportTop.value,viewportHeight.value));
const visibleAssets=computed(()=>assets.value.slice(virtualWindow.value.startIndex,virtualWindow.value.endIndex));
const visibleHeaders=computed(()=>virtualWindow.value.headers);
function tileStyle(index:number){
 const position=timelineLayout.value.positions[index];
 return {left:`${position.left}px`,top:`${position.top}px`,width:`${timelineLayout.value.tileSize}px`,height:`${timelineLayout.value.tileSize}px`};
}
function updateViewport(){
 if(viewportFrame)cancelAnimationFrame(viewportFrame);
 viewportFrame=requestAnimationFrame(()=>{
  measureViewport();
 });
}
function measureViewport(){
 const element=gridElement.value;
 if(!element){scrubberInView.value=false;return;}
 containerWidth.value=element.clientWidth;
 viewportTop.value=Math.max(0,-element.getBoundingClientRect().top);
 viewportHeight.value=window.innerHeight;
 const rect=element.getBoundingClientRect();
 scrubberInView.value=rect.top<window.innerHeight-90&&rect.bottom>150;
}
async function focusTile(index:number){
 if(index<0)return;
 if(index>=assets.value.length&&nextCursor.value&&!loading.value){await load(false)}
 const safeIndex=Math.min(index,assets.value.length-1);
 if(safeIndex<0)return;
 focusedIndex.value=safeIndex;
 const grid=gridElement.value;
 if(grid){
  const targetTop=grid.getBoundingClientRect().top+window.scrollY+timelineLayout.value.positions[safeIndex].top;
  if(targetTop<window.scrollY||targetTop+timelineLayout.value.tileSize>window.scrollY+window.innerHeight){
   window.scrollTo({top:Math.max(0,targetTop-window.innerHeight/3),behavior:"auto"});
  }
 }
 measureViewport();
 await nextTick();
 gridElement.value?.querySelector<HTMLButtonElement>(`[data-photo-index="${safeIndex}"]`)?.focus();
}
function onTileKeydown(event:KeyboardEvent,index:number){
 const columns=timelineLayout.value.columns;
 let next=index;
 if(event.key==="ArrowRight")next=index+1;
 else if(event.key==="ArrowLeft")next=index-1;
 else if(event.key==="ArrowDown")next=index+columns;
 else if(event.key==="ArrowUp")next=index-columns;
 else if(event.key==="Home")next=0;
 else if(event.key==="End")next=assets.value.length-1;
 else if(event.key==="PageDown")next=Math.min(assets.value.length-1,index+columns*Math.max(1,Math.floor(window.innerHeight/timelineLayout.value.rowPitch)));
 else if(event.key==="PageUp")next=Math.max(0,index-columns*Math.max(1,Math.floor(window.innerHeight/timelineLayout.value.rowPitch)));
 else return;
 event.preventDefault();void focusTile(next);
}
function selectModalAsset(asset:Asset,index:number){selectionGeneration+=1;selected.value=asset;selectedIndex.value=index;addAlbum.value=0;addPrivateAlbum.value=0;message.value=""}
// Every navigation path into a new photo resets the zoom and restarts the
// progressive stages; otherwise a HEIC photo after a zoomed JPEG would keep
// the previous stage's source.
function showAssetAt(index:number){
  const asset=modalAssets.value[index];
  if(!asset)return;
  selectModalAsset(asset,index);
  viewerAnimate.value=true;viewerScale.value=1;viewerOffset.value={x:0,y:0};
  startViewerStages(asset);
}
function openAsset(asset:Asset,index:number){
  if(!selected.value)viewerBackstack?.push();
  showAssetAt(index);
  void nextTick(()=>modalCloseButton.value?.focus());
}
let viewerBackstack:ReturnType<typeof createBrowserMediaBackstack>|null=null;
let restoreTileFocus=true;
function closeModal(restoreFocus=true){
 restoreTileFocus=restoreFocus;
 if(selected.value&&viewerBackstack?.back())return;
 finishCloseModal(restoreFocus);
}
function finishCloseModal(restoreFocus=true){
 const previousIndex=selectedIndex.value;
 stopSlideshow();
 cancelViewerLoads();
 selectionGeneration+=1;
 viewerInfo.value=false;
 selected.value=null;selectedIndex.value=-1;
 if(restoreFocus&&viewMode.value!=="map"&&previousIndex>=0)void focusTile(previousIndex);
}
function modalKeydown(event:KeyboardEvent){
 if(!selected.value)return;
 if(event.key==="Escape"){event.preventDefault();closeModal();return}
 if(event.key==="Tab"){
  const dialog=galleryDialog.value;
  if(!dialog)return;
  const focusable=Array.from(dialog.querySelectorAll<HTMLElement>(
   'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),video[controls],[tabindex]:not([tabindex="-1"])',
  )).filter(element=>element.offsetWidth>0||element.offsetHeight>0||element===document.activeElement);
  if(!focusable.length){event.preventDefault();dialog.focus();return}
  const first=focusable[0],last=focusable[focusable.length-1];
  const active=document.activeElement;
  if(!focusable.includes(active as HTMLElement)){event.preventDefault();(event.shiftKey?last:first).focus();return}
  if(event.shiftKey&&active===first){event.preventDefault();last.focus()}
  else if(!event.shiftKey&&active===last){event.preventDefault();first.focus()}
  return;
 }
 if(event.target instanceof HTMLVideoElement)return;
 if(event.target instanceof HTMLInputElement||event.target instanceof HTMLSelectElement||event.target instanceof HTMLTextAreaElement)return;
 if(event.key==="ArrowLeft"&&selectedIndex.value>0){event.preventDefault();showAssetAt(selectedIndex.value-1)}
 if(event.key==="ArrowRight"&&selectedIndex.value+1<modalAssets.value.length){event.preventDefault();showAssetAt(selectedIndex.value+1)}
}
const viewerInfo=ref(false);
function hasCaptureDetails(asset:Asset){
 return Boolean(asset.cameraMake||asset.cameraModel||asset.lensModel||asset.iso||asset.fNumber||asset.exposureSeconds||asset.focalLength||asset.width||asset.capturedAt);
}
function canWriteAsset(asset:Asset){return props.admin||asset.canWrite===true}
function thumb(asset:Asset){return mediaPath("/api/v2/photos/"+asset.id+"/thumbnail")}
function original(asset:Asset){return mediaPath("/api/v2/files/preview?path="+encodeURIComponent(asset.path))}
onMounted(()=>{
 disposed=false;
 viewerBackstack=createBrowserMediaBackstack(window,"lightisle-photos",async()=>{
  finishCloseModal(restoreTileFocus);
  restoreTileFocus=true;
  return true;
 });
 void load(true);void refreshAlbums();void refreshPrivateAlbums();void refreshFolderAlbums();void refreshTimelineIndex();void status();timer=window.setInterval(()=>{if(document.hidden)return;void status()},4500);
 viewportHeight.value=window.innerHeight;updateViewport();
 window.addEventListener("scroll",updateViewport,{passive:true});window.addEventListener("resize",updateViewport);window.addEventListener("keydown",modalKeydown);
 if(typeof ResizeObserver!=="undefined"){
  resizeObserver=new ResizeObserver(updateViewport);
  if(gridElement.value)resizeObserver.observe(gridElement.value);
 }
 if(typeof IntersectionObserver!=="undefined"){
  loadObserver=new IntersectionObserver(entries=>{
   if(entries.some(entry=>entry.isIntersecting)&&nextCursor.value&&!loading.value&&!loadError.value)void load(false);
  },{rootMargin:"650px 0px"});
  if(loadMarker.value)loadObserver.observe(loadMarker.value);
 }
});
watch([()=>props.rootId,()=>props.rootGeneration],()=>{
 viewerBackstack?.reset();
 rootEpoch+=1;viewGeneration+=1;selectionGeneration+=1;
 listRequests.cancel();albumRequests.cancel();privateAlbumRequests.cancel();folderAlbumRequests.cancel();scanStatusPoller.invalidate();
 assets.value=[];albums.value=[];privateAlbums.value=[];folderAlbums.value=[];folderCursor.value="";folderError.value="";folderLoading.value=false;folderTarget.value="";activeFolderAlbum.value=null;activeAlbum.value=0;activePrivateAlbum.value=0;
 favoritesOnly.value=false;personalOnly.value=false;nextCursor.value=0;loading.value=false;galleryLoaded.value=false;
 timelineCursorStart.value=0;fullTimelineMonths.value=[];
 scrubbing.value=false;scrubPointerId=null;scrubberInView.value=false;
 viewMode.value="timeline";creationReturnsToAlbums.value=false;failedAlbumCovers.value={};
 onThisDayOnly.value=false;jumpYear.value=0;jumpMonth.value=0;typeFilter.value="";searchInput.value="";searchApplied.value="";if(searchTimer)clearTimeout(searchTimer);
 pageQueryKey=photoQueryKey();
 loadError.value="";loadErrorReset.value=true;sharedAlbumsError.value="";privateAlbumsError.value="";sharedAlbumsLoading.value=false;privateAlbumsLoading.value=false;scanActionError.value="";
 scanStatusLoaded.value=false;scanStatusLoading.value=false;scanStatusError.value="";
 scan.value={running:false,scanned:0,found:0};lastCompletedScan=0;
 selected.value=null;selectedIndex.value=-1;message.value="";focusedIndex.value=0;
 trashIDs.value=new Set();trashSelecting.value=false;trashBusy.value=false;
 creating.value=false;creatingPrivate.value=false;editingAlbum.value=null;editingPrivate.value=null;
 void load(true);void refreshAlbums();void refreshPrivateAlbums();void refreshFolderAlbums();void refreshTimelineIndex();void status();
},{flush:"sync"});
watch(loadMarker,element=>{
 loadObserver?.disconnect();
 if(element)loadObserver?.observe(element);
});
watch(gridElement,element=>{
 if(resizeObserver){resizeObserver.disconnect();if(element)resizeObserver.observe(element)}
 updateViewport();
},{flush:"post"});
onUnmounted(()=>{
 disposed=true;
 viewerBackstack?.dispose();viewerBackstack=null;
 cancelViewerLoads();
 stopSlideshow();
 if(timer)clearInterval(timer);if(searchTimer)clearTimeout(searchTimer);if(viewportFrame)cancelAnimationFrame(viewportFrame);resizeObserver?.disconnect();loadObserver?.disconnect();listRequests.cancel();albumRequests.cancel();privateAlbumRequests.cancel();folderAlbumRequests.cancel();scanStatusPoller.dispose();
 window.removeEventListener("scroll",updateViewport);window.removeEventListener("resize",updateViewport);window.removeEventListener("keydown",modalKeydown);
});
</script>

<template>
  <div ref="photosPage" class="content photos-page">
    <div class="section-heading">
      <div><h2>照片图库</h2><p>你的每个瞬间，保存在自己的 Mac 上。</p></div>
      <button v-if="admin" type="button" class="refresh" @click="startScan" :disabled="scan.running&&!scanStatusError">
        <RefreshCw :size="16" :class="{spinning:scan.running&&!scanStatusError}" /> {{scan.running&&!scanStatusError?"扫描中…":"扫描媒体"}}
      </button>
    </div>
    <div class="timeline-tools">
      <button type="button" class="album-create" :disabled="trashBusy" @click="trashSelecting=!trashSelecting;trashIDs=new Set()">{{trashSelecting?"退出多选":"多选删除"}}</button>
      <template v-if="trashSelecting">
        <span>已选 {{trashIDs.size}} 项（最多50项）</span>
        <button type="button" class="album-create" :disabled="trashBusy" @click="trashIDs=new Set(assets.filter(canWriteAsset).slice(0,50).map(item=>item.id))">全选可删除项</button>
        <button type="button" class="album-create album-delete" :disabled="trashBusy||!trashIDs.size" @click="trashSelectedPhotos"><Trash2 :size="15"/> 移入回收站</button>
</template>
    </div>
    <div v-if="scan.running&&!scanStatusError" class="scan-banner">正在后台整理媒体 · 已检查 {{scan.scanned}} 项 · 发现 {{scan.found}} 项</div>
    <div v-if="scanStatusError&&assets.length" class="form-error" role="alert">扫描状态读取失败：{{scanStatusError}} <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span><button type="button" class="refresh" :disabled="scanStatusLoading" @click="status">{{scanStatusLoading?"正在重试…":"重试状态"}}</button></div>
    <p v-if="scanStatusLoaded&&scan.lastError&&assets.length" class="form-error">上次扫描：{{describeUserFacingError(scan.lastError)}}</p>
    <p v-if="message" class="gallery-message">{{message}}</p>
    <p v-if="scanActionError&&assets.length" class="gallery-message" role="alert">{{scanActionError}}</p>
    <div class="photo-mode-tabs" role="tablist" aria-label="照片浏览方式">
      <button type="button" role="tab" :aria-selected="viewMode==='timeline'" :class="{chosen:viewMode==='timeline'}" @click="viewMode='timeline'"><LayoutList :size="15"/> 时间线</button>
      <button type="button" role="tab" :aria-selected="viewMode==='albums'" :class="{chosen:viewMode==='albums'}" @click="viewMode='albums';refreshFolderAlbums()"><Images :size="15"/> 相册</button>
      <button type="button" role="tab" :aria-selected="viewMode==='map'" :class="{chosen:viewMode==='map'}" @click="viewMode='map'"><MapIcon :size="15"/> 地图回溯</button>
    </div>
    <PhotoMapView v-if="viewMode==='map'" :key="(props.rootId??'legacy')+':'+(props.rootGeneration??0)" ref="photoMap" :transport="mapTransport" @open-asset="openMapAsset"/>
    <section v-else-if="viewMode==='albums'" class="photo-album-overview" aria-label="相册总览">
      <header class="photo-album-overview-header">
        <div><h3>整理与分享</h3><p>文件夹相册直接保存在你的照片目录中，加入照片时可选择复制或移动。</p></div>
      </header>
      <div class="photo-album-section-heading"><h4>照片目录中的相册</h4><button type="button" class="refresh" :disabled="folderLoading" @click="refreshFolderAlbums()">刷新</button></div>
      <form class="album-new" @submit.prevent="createFolderAlbum"><FolderPlus :size="18"/><input v-model="folderName" maxlength="120" aria-label="文件夹相册名称" placeholder="新相册名称" required/><button type="submit" :disabled="albumBusy">新建相册</button></form>
      <div v-if="folderError" class="gallery-message" role="alert">文件夹相册读取失败：{{folderError}} <button type="button" class="refresh" @click="refreshFolderAlbums()">重试</button></div>
      <div v-if="folderAlbums.length" class="photo-album-card-grid">
        <div v-for="album in folderAlbums" :key="album.path">
          <button type="button" class="photo-album-card" @click="openFolderAlbum(album)"><span class="photo-album-cover"><FolderPlus :size="30"/></span><strong :title="album.name">{{album.name}}</strong><small>照片目录中的文件夹</small></button>
          <button type="button" class="refresh" :disabled="albumBusy" @click="deleteFolderAlbum(album)">删除空相册</button>
        </div>
      </div>
      <div v-else-if="!folderError&&!folderLoading&&!folderCursor" class="photo-album-empty"><Images :size="23"/><span>照片目录中还没有文件夹相册。</span></div>
      <button v-if="folderCursor" type="button" class="refresh" :disabled="folderLoading" @click="refreshFolderAlbums(true)">加载更多文件夹</button>
      <div v-if="privateAlbumsError" class="gallery-message" role="alert">私人相册读取失败：{{privateAlbumsError}} <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="refreshPrivateAlbums()">重试</button></div>
      <div class="photo-album-section-heading"><h4>旧版私人相册 ({{privateAlbums.length}})</h4><small>保留原有照片关联</small></div>
      <div v-if="privateAlbums.length" class="photo-album-card-grid">
        <button v-for="album in privateAlbums" :key="'personal-'+album.id" type="button" class="photo-album-card" @click="openAlbumFromOverview(album,true)">
          <span class="photo-album-cover">
            <img v-if="album.coverAssetId&&!failedAlbumCovers['personal:'+album.id]" :src="mediaPath('/api/v2/photos/'+album.coverAssetId+'/thumbnail')" :alt="album.name+'封面'" loading="lazy" @error="failedAlbumCovers['personal:'+album.id]=true"/>
            <Images v-else :size="30"/>
          </span>
          <strong :title="album.name">{{album.name}}</strong><small>{{album.count}} 项 · 仅自己可见</small>
        </button>
      </div>
      <div v-else-if="!privateAlbumsError" class="photo-album-empty"><Images :size="23"/><span>还没有私人相册。创建后可将照片加入个人收藏集。</span></div>
      <div class="photo-album-section-heading"><h4>旧版共享相册 ({{albums.length}})</h4><small>保留原有照片关联</small></div>
      <div v-if="sharedAlbumsError" class="gallery-message" role="alert">共享相册读取失败：{{sharedAlbumsError}} <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="refreshAlbums">重试</button></div>
      <div v-if="albums.length" class="photo-album-card-grid">
        <button v-for="album in albums" :key="'shared-'+album.id" type="button" class="photo-album-card" @click="openAlbumFromOverview(album,false)">
          <span class="photo-album-cover">
            <img v-if="album.coverAssetId&&!failedAlbumCovers['shared:'+album.id]" :src="mediaPath('/api/v2/photos/'+album.coverAssetId+'/thumbnail')" :alt="album.name+'封面'" loading="lazy" @error="failedAlbumCovers['shared:'+album.id]=true"/>
            <Images v-else :size="30"/>
          </span>
          <strong :title="album.name">{{album.name}}</strong><small>{{album.count}} 项 · 共享</small>
        </button>
      </div>
      <div v-else-if="!sharedAlbumsError" class="photo-album-empty"><Images :size="23"/><span>{{admin?'还没有共享相册，可以创建一个与家人共享。':'管理员创建的共享相册会显示在这里。'}}</span></div>
    </section>
    <template v-else>
    <div class="timeline-tools">
      <div class="type-tabs" role="group" aria-label="媒体类型">
        <button type="button" :class="{chosen:!typeFilter}" @click="setTypeFilter('')">全部</button>
        <button type="button" :class="{chosen:typeFilter==='photo'}" @click="setTypeFilter('photo')"><Images :size="14"/> 照片</button>
        <button type="button" :class="{chosen:typeFilter==='video'}" @click="setTypeFilter('video')"><Film :size="14"/> 视频</button>
      </div>
      <label class="timeline-search">
        <Search :size="14"/>
        <input v-model="searchInput" placeholder="搜索文件名或文件夹" aria-label="搜索照片和视频" enterkeyhint="search">
        <button v-if="searchInput" type="button" title="清除搜索" @click="searchInput=''"><X :size="13"/></button>
      </label>
    </div>
    <div class="album-toolbar">
      <div class="album-tabs album-primary-tabs">
        <button type="button" :class="{chosen:activeAlbum===0&&!activePrivateAlbum&&!activeFolderAlbum&&!favoritesOnly&&!personalOnly&&!onThisDayOnly}" @click="changeView(0,false)"><Images :size="15"/> 全部照片</button>
        <button type="button" :class="{chosen:personalOnly}" @click="changeView(0,false,true)"><Star :size="15"/> 我的收藏</button>
        <button type="button" :class="{chosen:favoritesOnly}" @click="changeView(0,true)"><Heart :size="15"/> 共享收藏</button>
      </div>
      <details class="photo-albums-menu">
        <summary :aria-label="'浏览相册，共 '+(albums.length+privateAlbums.length+folderAlbums.length)+' 个'"><FolderPlus :size="16"/> {{activeFolderAlbum?.name||currentPrivateAlbum?.name||currentAlbum?.name||'相册'}} <small>({{albums.length+privateAlbums.length+folderAlbums.length}})</small></summary>
        <div class="photo-albums-menu-panel">
          <div class="album-tabs">
            <button type="button" :class="{chosen:onThisDayOnly}" @click="closeAlbumMenu($event);showOnThisDay()"><Sparkles :size="15"/> 那年今天</button>
            <button v-for="album in folderAlbums" :key="album.path" type="button" :class="{chosen:activeFolderAlbum?.path===album.path}" @click="closeAlbumMenu($event);openFolderAlbum(album)"><FolderPlus :size="14"/> {{album.name}}</button>
            <button v-for="album in albums" :key="album.id" type="button" :class="{chosen:activeAlbum===album.id}" @click="closeAlbumMenu($event);changeView(album.id,false)">{{album.name}} <small>{{album.count}}</small></button>
            <button v-for="album in privateAlbums" :key="'private-'+album.id" :data-private-album-filter="album.id" type="button" :class="{chosen:activePrivateAlbum===album.id}" @click="closeAlbumMenu($event);changeView(0,false,false,album.id)"><FolderPlus :size="14"/> {{album.name}} <small>{{album.count}}</small></button>
          </div>
          <div class="photo-albums-menu-create">
            <button type="button" class="album-create" @click="closeAlbumMenu($event);viewMode='albums';refreshFolderAlbums()"><Plus :size="17"/> 新建文件夹相册</button>
          </div>
        </div>
      </details>
    </div>
    <div v-if="sharedAlbumsError&&!selected" class="gallery-message" role="alert">共享相册读取失败：{{sharedAlbumsError}} <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="refreshAlbums">{{sharedAlbumsLoading?"正在重试…":"重试共享相册"}}</button></div>
    <div v-if="privateAlbumsError&&!selected" class="gallery-message" role="alert">私人相册读取失败：{{privateAlbumsError}} <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="refreshPrivateAlbums()">{{privateAlbumsLoading?"正在重试…":"重试私人相册"}}</button></div>
    <div v-if="activeFolderAlbum" class="album-management"><span>文件夹相册：{{activeFolderAlbum.name}}</span><button type="button" class="refresh" @click="viewMode='albums';refreshFolderAlbums()">返回相册</button></div>
    <div v-if="currentPrivateAlbum" class="album-management">
      <span>我的私人相册：{{currentPrivateAlbum.name}}（只有当前账号可查看）</span>
      <button type="button" :disabled="albumBusy" @click="editPrivateAlbum(currentPrivateAlbum)"><Pencil :size="14"/> 改名</button>
      <button type="button" :disabled="albumBusy" class="album-delete" @click="deletePrivateAlbum"><Trash2 :size="14"/> 删除</button>
    </div>
    <form v-if="creatingPrivate" class="album-new" @submit.prevent="savePrivateAlbum">
      <FolderPlus :size="18"/>
      <input v-model="privateAlbumName" maxlength="120" aria-label="私人相册名称" placeholder="私人相册名称（最多60个字符）" required/>
      <button type="submit" :disabled="albumBusy">{{albumBusy?"保存中…":editingPrivate?"保存修改":"创建私人相册"}}</button>
      <button type="button" class="album-cancel" :disabled="albumBusy" @click="cancelPrivateAlbum">取消</button>
    </form>
    <div v-if="admin&&currentAlbum" class="album-management">
      <span>当前相册：{{currentAlbum.name}}</span>
      <button type="button" :disabled="albumBusy" @click="beginAlbumRename(currentAlbum)"><Pencil :size="14"/>改名</button>
      <button type="button" class="album-delete" :disabled="albumBusy" @click="deleteCurrentAlbum"><Trash2 :size="14"/>删除相册</button>
    </div>
    <form v-if="admin&&creating" class="album-new" @submit.prevent="createAlbum">
      <FolderPlus :size="18"/><input v-model="albumName" maxlength="120" aria-label="相册名称，最多60个字符" placeholder="相册名称（最多60个字符）" required/>
      <button type="submit" :disabled="albumBusy">{{albumBusy?"保存中…":editingAlbum?"保存修改":"创建"}}</button>
      <button type="button" class="album-cancel" :disabled="albumBusy" @click="cancelAlbumForm">取消</button>
    </form>
    <div v-if="!assets.length && (loadError || scanActionError || scanStatusError || scanStatusLoaded&&scan.lastError)" class="gallery-empty" role="alert">
      <Images :size="40" :stroke-width="1.2" />
      <h3>{{loadError?"暂时无法读取图库":scanActionError?"扫描无法启动":scanStatusError?"无法确认扫描状态":"上次扫描未完成"}}</h3>
      <p>{{loadError || scanActionError || (scanStatusError?"扫描状态暂不可用："+scanStatusError:"上次扫描未完成："+describeUserFacingError(scan.lastError))}}</p>
      <button v-if="loadError" type="button" class="refresh" :disabled="loading" @click="retryLoad">重试读取图库</button>
      <button v-if="scanStatusError" type="button" class="refresh" :disabled="scanStatusLoading" @click="status">重试读取扫描状态</button>
      <button v-if="admin&&(!loadError||scanActionError||scan.lastError)" type="button" class="refresh" :disabled="scan.running&&!scanStatusError" @click="startScan">重新扫描</button>
      <p v-if="!admin">可在设置的「缺失媒体」中重新检查自己的目录；其他目录请联系管理员。</p>
    </div>
    <div v-else-if="!assets.length&&(loading||!galleryLoaded||(!scanStatusLoaded&&!scanStatusError)||scan.running&&!scanStatusError)" class="gallery-empty">{{scan.running&&!scanStatusError?"正在扫描媒体…":!scanStatusLoaded&&!scanStatusError?"正在确认媒体扫描状态…":"正在读取媒体索引…"}}</div>
    <div v-else-if="!assets.length" class="gallery-empty">
      <Images :size="40" :stroke-width="1.2" />
      <h3>{{searchApplied?'没有匹配「'+searchApplied+'」的媒体':activeFolderAlbum?'文件夹相册还没有照片':currentPrivateAlbum?'私人相册还没有照片':currentAlbum?'此相册还没有照片':onThisDayOnly?'今天还没有那年今天的回忆':personalOnly?'还没有个人收藏':favoritesOnly?'还没有共享收藏':typeFilter==='video'?'这里还没有视频':typeFilter==='photo'?'这里还没有照片':'这里还没有照片或视频'}}</h3>
      <p v-if="activeFolderAlbum">可以在文件管理中放入照片，或在照片预览中选择复制或移动到此相册。新文件会在扫描后显示。</p>
      <p v-else-if="currentPrivateAlbum">打开全部照片，预览照片后选择自己的私人相册并点击「加入我的相册」。其他账号不会看到这里的相册名称和照片清单。</p>
      <p v-else-if="currentAlbum">打开全部照片，预览照片后选择此相册并点击「加入相册」。</p>
      <p v-else-if="onThisDayOnly">还没有照片拍摄于历史上的今天。带拍摄时间的照片（相机 JPEG、iPhone 照片与视频）会在多年后的同一天出现在这里。</p>
      <p v-else-if="favoritesOnly">在照片预览中点击收藏，已授权查看该照片的成员都可以看到。</p>
      <p v-else-if="personalOnly">预览自己有权限查看的照片，点击星形按钮保存到仅自己可见的收藏夹。</p>
      <p v-else>在文件管理中上传照片或视频，然后点击「扫描媒体」。<span v-if="!admin">请让管理员执行扫描。</span></p>
      <button v-if="activeFolderAlbum||currentAlbum||currentPrivateAlbum||favoritesOnly||personalOnly||onThisDayOnly" type="button" class="refresh" @click="changeView(0,false)">浏览全部照片</button>
    </div>
    <p v-if="loadError&&assets.length" class="form-error" role="alert">{{loadError}} 当前仍显示上次成功读取的内容。 <button type="button" class="refresh" :disabled="loading" @click="retryLoad">重试加载</button></p>
    <div v-if="assets.length&&timelineYears.length&&!onThisDayOnly" class="timeline-jump">
      <div class="timeline-jump-field"><span>年份</span>
        <AppleSelect v-model="jumpYear" :options="yearOptions" size="sm" aria-label="选择年份" @change="onJumpYearChange" />
      </div>
      <div class="timeline-jump-field"><span>月份</span>
        <AppleSelect v-model="jumpMonth" :options="monthOptions" :disabled="!jumpMonths.length" size="sm" aria-label="选择月份" @change="jumpToTimeline" />
      </div>
      <span v-if="browseTitle" class="timeline-jump-current">正在浏览 {{browseTitle}}</span>
      <button type="button" class="timeline-jump-top" title="回到最新照片" @click="scrollToTop"><ArrowUp :size="14"/> 最新</button>
    </div>
    <div v-if="assets.length" ref="gridElement" class="photo-grid" role="group" aria-label="按年月排列的照片和视频" :style="{height:timelineLayout.totalHeight+'px'}">
      <div v-for="header in visibleHeaders" :key="header.startIndex" class="photo-month-heading" :style="{top:header.top+'px'}" role="heading" aria-level="3">
        {{header.title}} <small>{{header.count}} 项<span v-if="nextCursor"> · 已加载</span></small>
      </div>
      <button v-for="(asset,visibleIndex) in visibleAssets" :key="asset.id" type="button" class="photo-tile"
        :aria-pressed="trashSelecting?trashIDs.has(asset.id):undefined"
        :class="{ 'photo-trash-selected': trashSelecting&&trashIDs.has(asset.id) }"
        :data-photo-index="virtualWindow.startIndex+visibleIndex"
        :tabindex="virtualWindow.startIndex+visibleIndex===focusedIndex?0:-1"
        :style="tileStyle(virtualWindow.startIndex+visibleIndex)"
        @focus="focusedIndex=virtualWindow.startIndex+visibleIndex"
        @keydown="onTileKeydown($event,virtualWindow.startIndex+visibleIndex)"
        @click="trashSelecting?toggleTrashID(asset.id):openAsset(asset,virtualWindow.startIndex+visibleIndex)">
        <img v-if="!thumbnailFailed[asset.id]" :src="thumb(asset)" loading="lazy" :alt="asset.name" @error="thumbnailFailed[asset.id]=true"/>
        <div v-else class="video-placeholder"><Film v-if="asset.type==='video'" :size="26"/><Images v-else :size="26"/><small>{{asset.type==='video'?"视频":"预览暂不可用"}}</small></div>
        <span v-if="asset.favorite" class="photo-liked"><Heart :size="16" fill="currentColor"/></span>
        <span v-if="asset.personalFavorite" class="photo-private-liked" title="我的收藏"><Star :size="14" fill="currentColor"/></span>
        <span v-if="trashSelecting" class="photo-trash-indicator">{{trashIDs.has(asset.id)?"✓":"○"}}</span>
        <small class="photo-date">{{dateLabel(asset.takenAt)}}</small>
      </button>
    </div>
    <div v-if="scrubberInView&&isFullTimelineView()&&viewMode==='timeline'&&!selected&&fullTimelineMonths.length>1&&scrubMonths.length>1"
      class="photo-timeline-scrubber" :class="{'is-dragging':scrubbing}">
      <div v-if="scrubbing" class="photo-scrubber-preview" aria-live="off"
        :style="{top:(scrubPreview+.5)/scrubMonths.length*100+'%'}">{{scrubMonths[scrubPreview]?.title}}</div>
      <div class="photo-scrubber-track" role="slider" tabindex="0" aria-label="按年月快速浏览照片"
        aria-orientation="vertical" :aria-valuemin="0" :aria-valuemax="scrubMonths.length-1"
        :aria-valuenow="scrubCurrentIndex" :aria-valuetext="scrubMonths[scrubCurrentIndex]?.title"
        title="拖动选择年月，松手跳转" @pointerdown="startScrub" @pointermove="moveScrub"
        @pointerup="stopScrub($event)" @pointercancel="stopScrub($event,false)"
        @keydown="scrubKeydown">
        <span class="photo-scrubber-line"></span>
        <template v-for="(month,i) in scrubMonths" :key="month.year+'-'+month.month">
          <span v-if="i===0||scrubMonths[i-1]?.year!==month.year" class="photo-scrubber-year-tick"
            :style="{top:(i+.5)/scrubMonths.length*100+'%'}"></span>
        </template>
        <span class="photo-scrubber-thumb" :style="{top:(scrubCurrentIndex+.5)/scrubMonths.length*100+'%'}"></span>
      </div>
    </div>
    <div ref="loadMarker" class="gallery-load">
      <button v-if="nextCursor" type="button" @click="load()" :disabled="loading">{{loading?"自动加载中…":"加载更多"}}</button>
      <span v-else-if="assets.length">已显示 {{assets.length}} 项</span>
    </div>
    <p class="footnote">照片和视频缩略图按需生成 JPEG 缓存；图库不修改或复制你的原始媒体。</p>
    </template>
  </div>
  <Teleport to="body">
  <div v-if="selected" class="dialog-backdrop" @click.self="closeModal()">
    <div ref="galleryDialog" class="gallery-modal" :class="{'gallery-modal--info':viewerInfo}" role="dialog" aria-modal="true" aria-label="照片详细信息" tabindex="-1">
      <div class="gallery-modal-toolbar">
        <div><strong>{{selected.name}}</strong><small>{{dateLabel(selected.takenAt)}} · {{selected.type==="video"?"视频":"照片"}}</small></div>
        <div class="gallery-modal-actions">
          <button v-if="canWriteAsset(selected)" type="button" :disabled="pendingFavorites[selected.id]" @click="toggleFavorite(selected)" :title="selected.favorite?'取消收藏':'收藏'"><Heart :size="19" :fill="selected.favorite?'currentColor':'none'"/></button>
          <span v-else class="gallery-readonly-favorite">此共享收藏仅可查看</span>
          <button type="button" :disabled="pendingFavorites[selected.id]" @click="togglePersonalFavorite(selected)" :title="selected.personalFavorite?'从我的收藏移除':'加入我的收藏'"><Star :size="19" :fill="selected.personalFavorite?'currentColor':'none'"/></button>
          <button v-if="selected.type==='photo'&&modalAssets.length>1" type="button" @click="toggleSlideshow" :title="slideshow?'暂停幻灯片':'开始幻灯片，每4秒一张'">{{slideshow?'暂停轮播':'幻灯片'}}</button>
          <button type="button" :class="{chosen:viewerInfo}" :aria-expanded="viewerInfo" aria-controls="photo-viewer-info" aria-label="拍摄信息与相册" @click="viewerInfo=!viewerInfo" title="拍摄信息"><Info :size="19"/></button>
          <button v-if="canWriteAsset(selected)" type="button" :disabled="trashBusy" @click="trashPhotos([selected])" title="移入回收站"><Trash2 :size="19"/></button>
          <button ref="modalCloseButton" type="button" @click="closeModal()" title="关闭"><X :size="19"/></button>
        </div>
      </div>
      <div class="gallery-media-layout">
      <div v-if="viewerInfo" id="photo-viewer-info" class="viewer-info" role="region" aria-label="当前媒体信息">
        <div class="viewer-info-heading"><strong>媒体信息</strong><button type="button" aria-label="关闭媒体信息" @click="viewerInfo=false"><X :size="18"/></button></div>
        <dl>
          <div v-if="capturedLabel(selected)"><dt>拍摄时间</dt><dd>{{capturedLabel(selected)}}</dd></div>
          <div v-if="selected.cameraMake||selected.cameraModel"><dt>相机</dt><dd>{{[selected.cameraMake,selected.cameraModel].filter(Boolean).join(" ")}}</dd></div>
          <div v-if="selected.lensModel"><dt>镜头</dt><dd>{{selected.lensModel}}</dd></div>
          <div v-if="selected.iso||selected.fNumber||selected.exposureSeconds||selected.focalLength"><dt>参数</dt><dd>{{[selected.iso?"ISO "+selected.iso:"",selected.fNumber?formatAperture(selected.fNumber):"",selected.exposureSeconds?formatExposure(selected.exposureSeconds):"",selected.focalLength?selected.focalLength+"mm":""].filter(Boolean).join(" · ")}}</dd></div>
          <div v-if="selected.width&&selected.height"><dt>分辨率</dt><dd>{{selected.width}} × {{selected.height}}</dd></div>
          <div v-if="selected.durationSeconds"><dt>时长</dt><dd>{{formatDuration(selected.durationSeconds)}}</dd></div>
          <div><dt>文件</dt><dd>{{formatBytes(selected.size)}}</dd></div>
          <div v-if="selected.latitude!=null&&selected.longitude!=null"><dt>位置</dt><dd class="viewer-location"><MapPin :size="13"/> {{coordinateLabel(selected.latitude,selected.longitude)}} <button type="button" class="viewer-map-link" @click="showOnMap(selected.latitude!,selected.longitude!)">在地图上查看</button></dd></div>
        </dl>
      </div>
      <div class="gallery-stage">
        <button v-if="selectedIndex>0" type="button" class="viewer-nav prev" title="上一张" aria-label="上一张" @click="showAssetAt(selectedIndex-1)"><ChevronLeft :size="26"/></button>
        <div v-if="selected.type==='photo'" class="gallery-viewer" :class="{gesturing:!viewerAnimate}"
          @dblclick="viewerPointers.size===0&&toggleViewerZoom()"
          @pointerdown="viewerPointerDown" @pointermove="viewerPointerMove" @pointerup="viewerPointerUp" @pointercancel="viewerPointerUp"
          @wheel="viewerWheel">
          <img :src="viewerSrc(selected)" :alt="selected.name" class="gallery-modal-image" draggable="false"
            :style="{transform:viewerTransform,cursor:viewerScale>1?'grab':'zoom-in'}"/>
          <button v-if="browserDecodable(selected)&&viewerStage!=='original'" type="button" class="gallery-original-quality" :disabled="viewerOriginalLoading" @dblclick.stop @pointerdown.stop @click.stop="requestViewerOriginal">{{viewerOriginalLoading?"正在加载原图…":viewerOriginalError?"重试原始画质":"原始画质"}}</button>
          <span class="gallery-viewer-hint">{{viewerScale>1?"拖拽平移 · 滚轮或双指缩放":"双击 / 滚轮 / 双指缩放 · 左右滑动翻页"}}{{viewerPreviewLoading?" · 正在加载高清版本…":viewerPreviewError&&viewerStage!=="original"?" · 预览加载失败，可尝试原始画质或下载原件":""}}</span>
        </div>
        <video v-else controls playsinline :src="original(selected)" class="gallery-modal-video"/>
        <button v-if="selectedIndex+1<modalAssets.length" type="button" class="viewer-nav next" title="下一张" aria-label="下一张" @click="showAssetAt(selectedIndex+1)"><ChevronRight :size="26"/></button>
      </div>
      </div>
      <div class="gallery-modal-footer">
        <div v-if="folderAlbums.length" class="private-album-picker">
          <span>文件夹相册</span><AppleSelect v-model="folderTarget" :options="folderAlbumOptions" size="sm" aria-label="选择文件夹相册" />
          <button type="button" :disabled="!folderTarget||albumBusy" @click="addSelectedToFolder('copy')">复制到相册</button>
          <button type="button" :disabled="!folderTarget||albumBusy||!canWriteAsset(selected)" @click="addSelectedToFolder('move')">移动到相册</button>
        </div>
        <template v-if="admin">
        <AppleSelect v-model="addAlbum" :options="albumOptions" size="sm" aria-label="选择相册" />
        <button type="button" :disabled="!addAlbum||albumBusy" @click="addSelected">加入相册 <ChevronDown :size="14"/></button>
        <button v-if="activeAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="removeSelectedFromAlbum">移出此相册</button>
        </template>
        <div v-if="sharedAlbumsError&&selected" class="gallery-modal-feedback" role="alert">共享相册读取失败：{{sharedAlbumsError}} <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="refreshAlbums">{{sharedAlbumsLoading?"正在重试…":"重试"}}</button></div>
        <div v-if="privateAlbums.length" class="private-album-picker">
          <span>私人相册</span>
          <AppleSelect v-model="addPrivateAlbum" :options="privateAlbumOptions" size="sm" aria-label="选择我的私人相册" />
          <button type="button" :disabled="!addPrivateAlbum||albumBusy" @click="addSelectedPrivate">加入 <ChevronDown :size="14"/></button>
        </div>
        <span v-else-if="privateAlbumsError&&selected" class="private-album-hint" role="alert">私人相册读取失败：{{privateAlbumsError}} <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="refreshPrivateAlbums()">{{privateAlbumsLoading?"正在重试…":"重试"}}</button></span>
        <span v-else-if="!privateAlbumsError" class="private-album-hint">没有旧版私人相册；可在相册页新建文件夹相册。</span>
        <button v-if="activePrivateAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="removeSelectedPrivate">移出此相册</button>
      </div>
      <p v-if="message" class="gallery-modal-feedback" role="status">{{message}}</p>
    </div>
  </div>
  </Teleport>
</template>

<style scoped src="./PhotosView.css"></style>

