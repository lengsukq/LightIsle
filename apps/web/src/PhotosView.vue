<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import {describeRootOperationFailure} from "./rootDiscovery.js";
import { Heart, Star, RefreshCw, Images, Film, Plus, X, FolderPlus, ChevronDown, ChevronLeft, ChevronRight, Info, MapPin, Pencil, Trash2, Sparkles, ArrowUp, Search } from "lucide-vue-next";
import { validateAlbumName } from "./albumNameValidation.js";
import { createLatestRequestGate } from "./latestRequestGate.js";
import { createMediaStatusPoller } from "./mediaStatusPoller.js";
import { mediaQueryKey, transitionMediaQuery } from "./mediaQueryContext.js";
import { createPhotoTimelineLayout, getPhotoTimelineWindow } from "./photoTimelineLayout.js";
import { buildTimelineYears, timelineJumpIndex, timelineYearsFromMonths } from "./photoTimelineJump.js";
import { rootApiPath, rootMediaPath } from "./rootApi.js";
import { normalizeViewerTransform, pinchDistance, pinchScale, swipeDirection, wheelZoomFactor, zoomAtAnchor } from "./viewerGestures.js";
import PhotoMapView from "./PhotoMapView.vue";
import type { MapStripAsset, MapTransport } from "./photoMapTransport.js";
import { LayoutList, Map as MapIcon } from "lucide-vue-next";

type Asset={id:number;path:string;name:string;type:"photo"|"video";size:number;takenAt:number;favorite:boolean;personalFavorite?:boolean;canWrite?:boolean;
 capturedAt?:string;latitude?:number;longitude?:number;cameraMake?:string;cameraModel?:string;lensModel?:string;iso?:number;fNumber?:number;exposureSeconds?:number;focalLength?:number;width?:number;height?:number;durationSeconds?:number};
type Album={id:number;name:string;count:number};
type Status={running:boolean;scanned:number;found:number;lastError?:string;lastDone?:number};
const props=defineProps<{admin:boolean;rootId?:string;rootGeneration?:number}>();
const assets=ref<Asset[]>([]);
const albums=ref<Album[]>([]);
const privateAlbums=ref<Album[]>([]);
const activeAlbum=ref(0);
const activePrivateAlbum=ref(0);
const favoritesOnly=ref(false);
const personalOnly=ref(false);
const onThisDayOnly=ref(false);
const typeFilter=ref<""|"photo"|"video">("");
const searchInput=ref("");
const searchApplied=ref("");
let searchTimer:number|undefined;
function photoQueryKey(){return mediaQueryKey({root:props.rootId??"",generation:props.rootGeneration??0,album:activeAlbum.value,privateAlbum:activePrivateAlbum.value,favorites:favoritesOnly.value,personal:personalOnly.value,onThisDay:onThisDayOnly.value,type:typeFilter.value,q:searchApplied.value})}
function setTypeFilter(kind:""|"photo"|"video"){
 if(typeFilter.value===kind)return;
 typeFilter.value=kind;
 void load(true);
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
 return !activeAlbum.value&&!activePrivateAlbum.value&&!favoritesOnly.value&&
  !personalOnly.value&&!onThisDayOnly.value&&!typeFilter.value&&!searchApplied.value;
}
async function refreshTimelineIndex(){
 const root=rootEpoch;
 try{
  const result=await api<{months:Array<{year:number;month:number;count:number;firstIndex:number}>}>(apiPath("/api/v1/photos/timeline"));
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
const scan=ref<Status>({running:false,scanned:0,found:0});
const selected=ref<Asset|null>(null);
// Lightbox viewer: progressive sources (512 thumb → 2048 preview → original
// when the browser can decode it) plus double-click zoom with drag panning.
const viewerStage=ref<"thumb"|"preview"|"original">("thumb");
const viewerScale=ref(1);
const viewerOffset=ref({x:0,y:0});
let viewerGeneration=0;
const viewerTransform=computed(()=>`translate(${viewerOffset.value.x}px,${viewerOffset.value.y}px) scale(${viewerScale.value})`);
function browserDecodable(asset:Asset){return /\.(jpe?g|png|gif|webp)$/i.test(asset.name);}
function viewerSource(asset:Asset){return mediaPath("/api/v1/files/thumbnail?path="+encodeURIComponent(asset.path)+"&size=2048");}
function startViewerStages(asset:Asset){
  const generation=++viewerGeneration;
  viewerStage.value="thumb";viewerScale.value=1;viewerOffset.value={x:0,y:0};
  const preload=(url:string)=>new Promise<void>(resolve=>{const image=new Image();image.onload=()=>resolve();image.onerror=()=>resolve();image.src=url;});
  void (async()=>{
    await preload(viewerSource(asset));
    if(generation===viewerGeneration&&selected.value?.id===asset.id)viewerStage.value="preview";
    if(!browserDecodable(asset))return;
    await preload(original(asset));
    if(generation===viewerGeneration&&selected.value?.id===asset.id)viewerStage.value="original";
  })();
}
function viewerSrc(asset:Asset){
  if(viewerStage.value==="thumb")return thumb(asset);
  if(viewerStage.value==="preview")return viewerSource(asset);
  return original(asset);
}
function toggleViewerZoom(){
  viewerAnimate.value=true;
  viewerScale.value=viewerScale.value>1?1:2.5;
  if(viewerScale.value===1)viewerOffset.value={x:0,y:0};
}
// Pointer gestures: two fingers pinch-zoom around their midpoint, one finger
// pans while zoomed and flips photos when at unity, the wheel zooms around
// the cursor. viewerAnimate keeps CSS transitions for discrete actions only
// so continuous gestures stay glued to the fingers.
const viewerAnimate=ref(true);
const viewerPointers=new Map<number,{x:number;y:number}>();
let pinchStart:{distance:number;scale:number;offset:{x:number;y:number};anchor:{x:number;y:number}}|null=null;
let panOrigin={x:0,y:0};
let panning=false;
let swipeOrigin:{x:number;y:number}|null=null;
function viewerCenteredAnchor(event:{clientX:number;clientY:number},element:HTMLElement){
  const rect=element.getBoundingClientRect();
  return {x:event.clientX-(rect.left+rect.width/2),y:event.clientY-(rect.top+rect.height/2)};
}
function viewerApply(state:{scale:number;x:number;y:number}){
  const normalized=normalizeViewerTransform(state);
  viewerScale.value=normalized.scale;viewerOffset.value={x:normalized.x,y:normalized.y};
}
function viewerPointerDown(event:PointerEvent){
  const element=event.currentTarget as HTMLElement;
  viewerPointers.set(event.pointerId,{x:event.clientX,y:event.clientY});
  element.setPointerCapture(event.pointerId);
  if(viewerPointers.size===2){
    const fingers=[...viewerPointers.values()];
    const [first,second]=fingers;
    pinchStart={
      distance:pinchDistance(first,second),
      scale:viewerScale.value,
      offset:{...viewerOffset.value},
      anchor:{
        x:(first.x+second.x)/2,y:(first.y+second.y)/2,
      },
    };
    // Convert the midpoint to the viewer's centered coordinates once.
    const rect=element.getBoundingClientRect();
    pinchStart.anchor={x:pinchStart.anchor.x-(rect.left+rect.width/2),y:pinchStart.anchor.y-(rect.top+rect.height/2)};
    swipeOrigin=null;panning=false;
  }else if(viewerPointers.size===1){
    viewerAnimate.value=false;
    if(viewerScale.value>1){
      panning=true;
      panOrigin={x:event.clientX-viewerOffset.value.x,y:event.clientY-viewerOffset.value.y};
    }else{
      swipeOrigin={x:event.clientX,y:event.clientY};
    }
  }
}
function viewerPointerMove(event:PointerEvent){
  if(!viewerPointers.has(event.pointerId))return;
  viewerPointers.set(event.pointerId,{x:event.clientX,y:event.clientY});
  if(pinchStart&&viewerPointers.size>=2){
    const fingers=[...viewerPointers.values()];
    const target=pinchScale(pinchStart.scale,pinchStart.distance,pinchDistance(fingers[0],fingers[1]));
    viewerApply(zoomAtAnchor({scale:pinchStart.scale,x:pinchStart.offset.x,y:pinchStart.offset.y},target/pinchStart.scale||1,pinchStart.anchor));
    return;
  }
  if(panning)viewerOffset.value={x:event.clientX-panOrigin.x,y:event.clientY-panOrigin.y};
}
function viewerPointerUp(event:PointerEvent){
  viewerPointers.delete(event.pointerId);
  if(viewerPointers.size<2)pinchStart=null;
  if(viewerPointers.size>0)return;
  panning=false;
  if(viewerScale.value<=1&&swipeOrigin){
    const direction=swipeDirection(swipeOrigin,{x:event.clientX,y:event.clientY});
    swipeOrigin=null;
    if(direction==="left"&&selectedIndex.value+1<modalAssets.value.length){showAssetAt(selectedIndex.value+1);return}
    if(direction==="right"&&selectedIndex.value>0){showAssetAt(selectedIndex.value-1);return}
  }
  swipeOrigin=null;
  viewerAnimate.value=true;
  viewerApply({scale:viewerScale.value,x:viewerOffset.value.x,y:viewerOffset.value.y});
}
function viewerWheel(event:WheelEvent){
  if(selected.value?.type!=="photo")return;
  event.preventDefault();
  viewerAnimate.value=false;
  const element=event.currentTarget as HTMLElement;
  const anchor=viewerCenteredAnchor(event,element);
  viewerApply(zoomAtAnchor({scale:viewerScale.value,x:viewerOffset.value.x,y:viewerOffset.value.y},wheelZoomFactor(event.deltaY),anchor));
}
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
const editingAlbum=ref<Album|null>(null);
const photosPage=ref<HTMLElement|null>(null);
const gridElement=ref<HTMLElement|null>(null);
const loadMarker=ref<HTMLElement|null>(null);
const galleryDialog=ref<HTMLElement|null>(null);
const modalCloseButton=ref<HTMLButtonElement|null>(null);
const containerWidth=ref(0);
const viewportTop=ref(0);
const viewportHeight=ref(0);
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
  throw new Error(data.error??String(response.status));
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
  await api(apiPath("/api/v1/photos/"+asset.id+"/personal-favorite"),"POST",{favorite:next});
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
 }catch(e){if(selection===selectionGeneration&&selected.value?.id===asset.id)message.value="个人收藏失败："+(e instanceof Error?e.message:"未知错误")}
 finally{delete pendingFavorites.value[asset.id]}
}
const scanStatusPoller=createMediaStatusPoller(
 signal=>api<{status:Status;count:number}>(apiPath("/api/v1/photos/status"),"GET",undefined,signal),
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
  if(favoritesOnly.value)query.set("favorites","1");
  if(personalOnly.value)query.set("personal","1");
  if(onThisDayOnly.value)query.set("onThisDay","1");
  if(typeFilter.value)query.set("type",typeFilter.value);
  if(searchApplied.value)query.set("q",searchApplied.value);
  const result=await api<{assets:Asset[];nextCursor:number}>(apiPath("/api/v1/photos")+"?"+query.toString(),"GET",undefined,request.signal);
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
  const result=await api<{albums:Album[]}>(apiPath("/api/v1/photos/albums"),"GET",undefined,request.signal);
  if(!disposed&&request.isCurrent()){albums.value=result.albums;sharedAlbumsError.value=""}
 }catch(error){if(!disposed&&request.isCurrent()&&!(error instanceof Error&&error.name==="AbortError"))sharedAlbumsError.value=albumError(error)}
 finally{if(!disposed&&request.isCurrent())sharedAlbumsLoading.value=false}
}
async function refreshPrivateAlbums(isCurrent:()=>boolean=()=>true){
 const request=privateAlbumRequests.begin();
 privateAlbumsLoading.value=true;
 try{
  const result=await api<{albums:Album[]}>(apiPath("/api/v1/photos/private-albums"),"GET",undefined,request.signal);
  if(!disposed&&request.isCurrent()){privateAlbums.value=result.albums;privateAlbumsError.value=""}
 }catch(e){if(request.isCurrent()&&!disposed&&isCurrent()&&!(e instanceof Error&&e.name==="AbortError"))privateAlbumsError.value=albumError(e)}
 finally{if(!disposed&&request.isCurrent())privateAlbumsLoading.value=false}
}
const currentPrivateAlbum=computed(()=>privateAlbums.value.find(item=>item.id===activePrivateAlbum.value));
function editPrivateAlbum(album:Album){
 editingPrivate.value=album;privateAlbumName.value=album.name;creatingPrivate.value=true;
}
function cancelPrivateAlbum(){creatingPrivate.value=false;editingPrivate.value=null;privateAlbumName.value=""}
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
   await api(apiPath("/api/v1/photos/private-albums/"+editingPrivate.value.id),"PATCH",{name:validation.name});
  }else{
   await api(apiPath("/api/v1/photos/private-albums"),"POST",{name:validation.name});
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
  await api(apiPath("/api/v1/photos/private-albums/"+albumID),"DELETE");
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
  await api(apiPath("/api/v1/photos/private-albums/"+albumID+"/items"),"POST",{assetId:assetID});
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
  await api(apiPath("/api/v1/photos/private-albums/"+albumID+"/items/"+assetID),"DELETE");
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
 try{await api(apiPath("/api/v1/photos/scan"),"POST");if(context!==rootEpoch)return;message.value="正在后台扫描授权的共享目录";scanStatusPoller.invalidate();await status()}
 catch(e){if(context===rootEpoch)scanActionError.value="无法启动扫描："+(e instanceof Error?e.message:"未知错误")}
}
async function toggleFavorite(asset:Asset){
 if(!props.admin&&asset.canWrite!==true)return;
 if(pendingFavorites.value[asset.id])return;
 pendingFavorites.value[asset.id]=true;
 const next=!asset.favorite,selection=selectionGeneration;
 try{
  await api(apiPath("/api/v1/photos/"+asset.id+"/favorite"),"POST",{favorite:next});
  const current=assets.value.find(item=>item.id===asset.id);
  if(current)current.favorite=next;
  if(selected.value?.id===asset.id)selected.value.favorite=next;
 }catch(e){if(selection===selectionGeneration&&selected.value?.id===asset.id)message.value="收藏失败："+(e instanceof Error?e.message:"未知错误")}
 finally{delete pendingFavorites.value[asset.id]}
}
function albumError(error:unknown){
 const code=error instanceof Error?error.message:"request_failed";
 const messages:Record<string,string>={
  invalid_album_name:"相册名称需为 1–60 个字符，且不能包含控制字符。",
  invalid_or_duplicate_album:"相册名称无效或已存在；请调整名称后重试。",
  invalid_request:"请求无效，请检查相册信息。",
  album_name_exists:"已有同名相册。",
  not_found:"相册或照片已不存在，图库已刷新。",
  volume_offline:"媒体所在磁盘当前不可用，请稍后重试。",
  gallery_unavailable:"图库当前不可用，请稍后重试。",
 };
 return messages[code]??describeRootOperationFailure(error);
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
   const album=await api<Album>(apiPath("/api/v1/photos/albums/"+editingAlbum.value.id),"PATCH",{name});
   albums.value=albums.value.map(item=>item.id===album.id?album:item);
   message.value="相册名称已更新。";
  }else{
   await api(apiPath("/api/v1/photos/albums"),"POST",{name});
   message.value="相册已创建。";
  }
  albumName.value="";creating.value=false;editingAlbum.value=null;await refreshAlbums()
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
function cancelAlbumForm(){creating.value=false;editingAlbum.value=null;albumName.value=""}
const currentAlbum=computed(()=>albums.value.find(album=>album.id===activeAlbum.value));
async function deleteCurrentAlbum(){
 const album=currentAlbum.value;
 if(!props.admin||!album||albumBusy.value)return;
 const confirmed=window.confirm(`仅删除「${album.name}」相册及其照片关系；原始照片和视频仍保留，也不会删除收藏。确定删除吗？`);
 if(!confirmed)return;
 const albumID=album.id,view=viewGeneration;
 albumBusy.value=true;message.value="";
 try{
  await api(apiPath("/api/v1/photos/albums/"+albumID),"DELETE");
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
  await api(apiPath("/api/v1/photos/albums/"+albumID+"/items"),"POST",{assetId:assetID});
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
  await api(apiPath(`/api/v1/photos/albums/${albumId}/items/${assetId}`),"DELETE");
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
 if(activeAlbum.value===album&&favoritesOnly.value===favorites&&personalOnly.value===mine&&activePrivateAlbum.value===privateID&&!onThisDayOnly.value)return;
 viewGeneration+=1;
 activeAlbum.value=album;favoritesOnly.value=favorites;personalOnly.value=mine;activePrivateAlbum.value=privateID;onThisDayOnly.value=false;searchInput.value="";searchApplied.value="";selected.value=null;selectedIndex.value=-1;focusedIndex.value=0;
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
 activeAlbum.value=0;favoritesOnly.value=false;personalOnly.value=false;activePrivateAlbum.value=0;onThisDayOnly.value=true;searchInput.value="";searchApplied.value="";
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
  const result=await api<{assets:Asset[];nextCursor:number}>(apiPath("/api/v1/photos")+"?"+query.toString(),"GET",undefined,request.signal);
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
function scrollToTop(){
 if(timelineCursorStart.value>0){void load(true);return}
 window.scrollTo({top:0,behavior:"auto"});
}
// Timeline ↔ map modes share one query context; the map only renders located
// assets and opens the shared viewer for strip selections.
const viewMode=ref<"timeline"|"map">("timeline");
const photoMap=ref<{focusAsset:(latitude:number,longitude:number)=>void}|null>(null);
const mapTransport:MapTransport={
  loadGeo:()=>api<{points:{id:number;lat:number;lon:number;takenAt:number;type:string}[];total:number;truncated:boolean}>(apiPath("/api/v1/photos/geo")),
  loadAssetsByIds:async ids=>{
    if(!ids.length)return [];
    const query=new URLSearchParams({limit:String(Math.min(120,Math.max(1,ids.length))),cursor:"0",ids:ids.join(",")});
    const result=await api<{assets:Asset[]}>(apiPath("/api/v1/photos")+"?"+query.toString());
    // Preserve personal/shared favorites, write permissions and full EXIF
    // metadata; the map viewer must not invent false defaults.
    return result.assets;
  },
  thumbnail:id=>mediaPath("/api/v1/photos/"+id+"/thumbnail"),
};
const mapSelection=ref<Asset[]>([]);
const modalAssets=computed(()=>viewMode.value==="map"?mapSelection.value:assets.value);
const slideshow=ref(false);
let slideshowTimer:number|undefined;
function stopSlideshow(){
 slideshow.value=false;
 if(slideshowTimer!==undefined){window.clearInterval(slideshowTimer);slideshowTimer=undefined}
}
function advanceSlideshow(){
 if(!selected.value||document.hidden)return;
 const items=modalAssets.value;
 if(items.length<2){stopSlideshow();return}
 for(let step=1;step<=items.length;step++){
  const index=(selectedIndex.value+step)%items.length;
  if(items[index]?.type==="photo"){showAssetAt(index);return}
 }
 stopSlideshow();
}
function toggleSlideshow(){
 if(slideshow.value){stopSlideshow();return}
 if(!selected.value||modalAssets.value.length<2)return;
 slideshow.value=true;
 slideshowTimer=window.setInterval(advanceSlideshow,4000);
}
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
 if(!element)return;
 containerWidth.value=element.clientWidth;
 viewportTop.value=Math.max(0,-element.getBoundingClientRect().top);
 viewportHeight.value=window.innerHeight;
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
  showAssetAt(index);
  void nextTick(()=>modalCloseButton.value?.focus());
}
function closeModal(restoreFocus=true){
 const previousIndex=selectedIndex.value;
 stopSlideshow();
 selectionGeneration+=1;
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
function dateLabel(timestamp:number){
 return new Date(timestamp*1000).toLocaleDateString("zh-CN",{year:"numeric",month:"long",day:"numeric"});
}
function capturedLabel(asset:Asset){
 if(!asset.capturedAt)return"";
 const parsed=new Date(asset.capturedAt);
 if(Number.isNaN(parsed.getTime()))return"";
 return parsed.toLocaleString("zh-CN",{year:"numeric",month:"long",day:"numeric",hour:"2-digit",minute:"2-digit"});
}
function formatBytes(size:number){
 if(size>=1<<30)return (size/(1<<30)).toFixed(2)+" GB";
 if(size>=1<<20)return (size/(1<<20)).toFixed(1)+" MB";
 if(size>=1<<10)return (size/1024).toFixed(0)+" KB";
 return size+" B";
}
function formatExposure(seconds:number){
 if(seconds>=1)return seconds.toFixed(1)+" s";
 const denominator=Math.round(1/seconds);
 return denominator>0&&Number.isFinite(denominator)?"1/"+denominator+" s":"";
}
function formatAperture(value:number){return"f/"+(value<10?value.toFixed(1):Math.round(value))}
function formatDuration(seconds:number){
 const total=Math.round(seconds);
 const m=Math.floor(total/60),s=total%60;
 return m+":"+String(s).padStart(2,"0");
}
function coordinateLabel(latitude:number,longitude:number){
 const ns=latitude>=0?"N":"S";
 const ew=longitude>=0?"E":"W";
 return Math.abs(latitude).toFixed(5)+"°"+ns+"，"+Math.abs(longitude).toFixed(5)+"°"+ew;
}
const viewerInfo=ref(false);
function hasCaptureDetails(asset:Asset){
 return Boolean(asset.cameraMake||asset.cameraModel||asset.lensModel||asset.iso||asset.fNumber||asset.exposureSeconds||asset.focalLength||asset.width||asset.capturedAt);
}
function canWriteAsset(asset:Asset){return props.admin||asset.canWrite===true}
function thumb(asset:Asset){return mediaPath("/api/v1/photos/"+asset.id+"/thumbnail")}
function original(asset:Asset){return mediaPath("/api/v1/files/preview?path="+encodeURIComponent(asset.path))}
onMounted(()=>{
 disposed=false;
 void load(true);void refreshAlbums();void refreshPrivateAlbums();void refreshTimelineIndex();void status();timer=window.setInterval(()=>{if(document.hidden)return;void status()},4500);
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
 rootEpoch+=1;viewGeneration+=1;selectionGeneration+=1;
 listRequests.cancel();albumRequests.cancel();privateAlbumRequests.cancel();scanStatusPoller.invalidate();
 assets.value=[];albums.value=[];privateAlbums.value=[];activeAlbum.value=0;activePrivateAlbum.value=0;
 favoritesOnly.value=false;personalOnly.value=false;nextCursor.value=0;loading.value=false;galleryLoaded.value=false;
 timelineCursorStart.value=0;fullTimelineMonths.value=[];
 onThisDayOnly.value=false;jumpYear.value=0;jumpMonth.value=0;typeFilter.value="";searchInput.value="";searchApplied.value="";if(searchTimer)clearTimeout(searchTimer);
 pageQueryKey=photoQueryKey();
 loadError.value="";loadErrorReset.value=true;sharedAlbumsError.value="";privateAlbumsError.value="";sharedAlbumsLoading.value=false;privateAlbumsLoading.value=false;scanActionError.value="";
 scanStatusLoaded.value=false;scanStatusLoading.value=false;scanStatusError.value="";
 scan.value={running:false,scanned:0,found:0};lastCompletedScan=0;
 selected.value=null;selectedIndex.value=-1;message.value="";focusedIndex.value=0;
 creating.value=false;creatingPrivate.value=false;editingAlbum.value=null;editingPrivate.value=null;
 void load(true);void refreshAlbums();void refreshPrivateAlbums();void refreshTimelineIndex();void status();
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
 stopSlideshow();
 if(timer)clearInterval(timer);if(searchTimer)clearTimeout(searchTimer);if(viewportFrame)cancelAnimationFrame(viewportFrame);resizeObserver?.disconnect();loadObserver?.disconnect();listRequests.cancel();albumRequests.cancel();privateAlbumRequests.cancel();scanStatusPoller.dispose();
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
    <div v-if="scan.running&&!scanStatusError" class="scan-banner">正在后台整理媒体 · 已检查 {{scan.scanned}} 项 · 发现 {{scan.found}} 项</div>
    <div v-if="scanStatusError&&assets.length" class="form-error" role="alert">扫描状态读取失败：{{scanStatusError}} <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span><button type="button" class="refresh" :disabled="scanStatusLoading" @click="status">{{scanStatusLoading?"正在重试…":"重试状态"}}</button></div>
    <p v-if="scanStatusLoaded&&scan.lastError&&assets.length" class="form-error">上次扫描：{{scan.lastError}}</p>
    <p v-if="message" class="gallery-message">{{message}}</p>
    <p v-if="scanActionError&&assets.length" class="gallery-message" role="alert">{{scanActionError}}</p>
    <div class="photo-mode-tabs" role="tablist" aria-label="照片浏览方式">
      <button type="button" role="tab" :aria-selected="viewMode==='timeline'" :class="{chosen:viewMode==='timeline'}" @click="viewMode='timeline'"><LayoutList :size="15"/> 时间线</button>
      <button type="button" role="tab" :aria-selected="viewMode==='map'" :class="{chosen:viewMode==='map'}" @click="viewMode='map'"><MapIcon :size="15"/> 地图回溯</button>
    </div>
    <PhotoMapView v-if="viewMode==='map'" ref="photoMap" :transport="mapTransport" @open-asset="openMapAsset"/>
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
      <div class="album-tabs">
        <button type="button" :class="{chosen:activeAlbum===0&&!activePrivateAlbum&&!favoritesOnly&&!personalOnly&&!onThisDayOnly}" @click="changeView(0,false)"><Images :size="15"/> 全部照片</button>
        <button type="button" :class="{chosen:onThisDayOnly}" @click="showOnThisDay"><Sparkles :size="15"/> 那年今天</button>
        <button type="button" :class="{chosen:favoritesOnly}" @click="changeView(0,true)"><Heart :size="15"/> 共享收藏</button>
        <button type="button" :class="{chosen:personalOnly}" @click="changeView(0,false,true)"><Star :size="15"/> 我的收藏</button>
        <button v-for="album in albums" :key="album.id" type="button" :class="{chosen:activeAlbum===album.id}" @click="changeView(album.id,false)">{{album.name}} <small>{{album.count}}</small></button>
        <button v-for="album in privateAlbums" :key="'private-'+album.id" :data-private-album-filter="album.id" type="button" :class="{chosen:activePrivateAlbum===album.id}" @click="changeView(0,false,false,album.id)"><FolderPlus :size="14"/> {{album.name}} <small>{{album.count}}</small></button>
      </div>
      <button v-if="admin" type="button" class="album-create" @click="toggleAlbumCreate"><Plus :size="17"/> 新建共享相册</button>
      <button type="button" class="album-create" @click="creatingPrivate=!creatingPrivate;editingPrivate=null;privateAlbumName=''"><Plus :size="17"/> 新建私人相册</button>
    </div>
    <div v-if="sharedAlbumsError&&!selected" class="gallery-message" role="alert">共享相册读取失败：{{sharedAlbumsError}} <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="refreshAlbums">{{sharedAlbumsLoading?"正在重试…":"重试共享相册"}}</button></div>
    <div v-if="privateAlbumsError&&!selected" class="gallery-message" role="alert">私人相册读取失败：{{privateAlbumsError}} <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="refreshPrivateAlbums()">{{privateAlbumsLoading?"正在重试…":"重试私人相册"}}</button></div>
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
      <p>{{loadError || scanActionError || (scanStatusError?"扫描状态暂不可用："+scanStatusError:"上次扫描未完成："+scan.lastError)}}</p>
      <button v-if="loadError" type="button" class="refresh" :disabled="loading" @click="retryLoad">重试读取图库</button>
      <button v-if="scanStatusError" type="button" class="refresh" :disabled="scanStatusLoading" @click="status">重试读取扫描状态</button>
      <button v-if="admin&&(!loadError||scanActionError||scan.lastError)" type="button" class="refresh" :disabled="scan.running&&!scanStatusError" @click="startScan">重新扫描</button>
      <p v-if="!admin">请联系管理员检查共享目录或重新执行扫描。</p>
    </div>
    <div v-else-if="!assets.length&&(loading||!galleryLoaded||(!scanStatusLoaded&&!scanStatusError)||scan.running&&!scanStatusError)" class="gallery-empty">{{scan.running&&!scanStatusError?"正在扫描媒体…":!scanStatusLoaded&&!scanStatusError?"正在确认媒体扫描状态…":"正在读取媒体索引…"}}</div>
    <div v-else-if="!assets.length" class="gallery-empty">
      <Images :size="40" :stroke-width="1.2" />
      <h3>{{searchApplied?'没有匹配「'+searchApplied+'」的媒体':currentPrivateAlbum?'私人相册还没有照片':currentAlbum?'此相册还没有照片':onThisDayOnly?'今天还没有那年今天的回忆':personalOnly?'还没有个人收藏':favoritesOnly?'还没有共享收藏':typeFilter==='video'?'这里还没有视频':typeFilter==='photo'?'这里还没有照片':'这里还没有照片或视频'}}</h3>
      <p v-if="currentPrivateAlbum">打开全部照片，预览照片后选择自己的私人相册并点击「加入我的相册」。其他账号不会看到这里的相册名称和照片清单。</p>
      <p v-else-if="currentAlbum">打开全部照片，预览照片后选择此相册并点击「加入相册」。</p>
      <p v-else-if="onThisDayOnly">还没有照片拍摄于历史上的今天。带拍摄时间的照片（相机 JPEG、iPhone 照片与视频）会在多年后的同一天出现在这里。</p>
      <p v-else-if="favoritesOnly">在照片预览中点击收藏，已授权查看该照片的成员都可以看到。</p>
      <p v-else-if="personalOnly">预览自己有权限查看的照片，点击星形按钮保存到仅自己可见的收藏夹。</p>
      <p v-else>在文件管理中上传照片或视频，然后点击「扫描媒体」。<span v-if="!admin">请让管理员执行扫描。</span></p>
      <button v-if="currentAlbum||currentPrivateAlbum||favoritesOnly||personalOnly||onThisDayOnly" type="button" class="refresh" @click="changeView(0,false)">浏览全部照片</button>
    </div>
    <p v-if="loadError&&assets.length" class="form-error" role="alert">{{loadError}} 当前仍显示上次成功读取的内容。 <button type="button" class="refresh" :disabled="loading" @click="retryLoad">重试加载</button></p>
    <div v-if="assets.length&&timelineYears.length&&!onThisDayOnly" class="timeline-jump">
      <label><span>年份</span>
        <select v-model.number="jumpYear" @change="onJumpYearChange">
          <option v-for="entry in timelineYears" :key="entry.year" :value="entry.year">{{entry.year}} 年 · {{entry.count}} 项</option>
        </select>
      </label>
      <label><span>月份</span>
        <select v-model.number="jumpMonth" @change="jumpToTimeline" :disabled="!jumpMonths.length">
          <option v-for="entry in jumpMonths" :key="entry.month" :value="entry.month">{{entry.title}} · {{entry.count}}</option>
        </select>
      </label>
      <span v-if="browseTitle" class="timeline-jump-current">正在浏览 {{browseTitle}}</span>
      <button type="button" class="timeline-jump-top" title="回到最新照片" @click="scrollToTop"><ArrowUp :size="14"/> 最新</button>
    </div>
    <div v-if="assets.length" ref="gridElement" class="photo-grid" role="group" aria-label="按年月排列的照片和视频" :style="{height:timelineLayout.totalHeight+'px'}">
      <div v-for="header in visibleHeaders" :key="header.startIndex" class="photo-month-heading" :style="{top:header.top+'px'}" role="heading" aria-level="3">
        {{header.title}} <small>{{header.count}} 项<span v-if="nextCursor"> · 已加载</span></small>
      </div>
      <button v-for="(asset,visibleIndex) in visibleAssets" :key="asset.id" type="button" class="photo-tile"
        :data-photo-index="virtualWindow.startIndex+visibleIndex"
        :tabindex="virtualWindow.startIndex+visibleIndex===focusedIndex?0:-1"
        :style="tileStyle(virtualWindow.startIndex+visibleIndex)"
        @focus="focusedIndex=virtualWindow.startIndex+visibleIndex"
        @keydown="onTileKeydown($event,virtualWindow.startIndex+visibleIndex)"
        @click="openAsset(asset,virtualWindow.startIndex+visibleIndex)">
        <img v-if="!thumbnailFailed[asset.id]" :src="thumb(asset)" loading="lazy" :alt="asset.name" @error="thumbnailFailed[asset.id]=true"/>
        <div v-else class="video-placeholder"><Film v-if="asset.type==='video'" :size="26"/><Images v-else :size="26"/><small>{{asset.type==='video'?"视频":"预览暂不可用"}}</small></div>
        <span v-if="asset.favorite" class="photo-liked"><Heart :size="16" fill="currentColor"/></span>
        <span v-if="asset.personalFavorite" class="photo-private-liked" title="我的收藏"><Star :size="14" fill="currentColor"/></span>
        <small class="photo-date">{{dateLabel(asset.takenAt)}}</small>
      </button>
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
    <div ref="galleryDialog" class="gallery-modal" role="dialog" aria-modal="true" aria-label="照片详细信息" tabindex="-1">
      <div class="gallery-modal-toolbar">
        <div><strong>{{selected.name}}</strong><small>{{dateLabel(selected.takenAt)}} · {{selected.type==="video"?"视频":"照片"}}</small></div>
        <div class="gallery-modal-actions">
          <button v-if="canWriteAsset(selected)" type="button" :disabled="pendingFavorites[selected.id]" @click="toggleFavorite(selected)" :title="selected.favorite?'取消收藏':'收藏'"><Heart :size="19" :fill="selected.favorite?'currentColor':'none'"/></button>
          <span v-else class="gallery-readonly-favorite">此共享收藏仅可查看</span>
          <button type="button" :disabled="pendingFavorites[selected.id]" @click="togglePersonalFavorite(selected)" :title="selected.personalFavorite?'从我的收藏移除':'加入我的收藏'"><Star :size="19" :fill="selected.personalFavorite?'currentColor':'none'"/></button>
          <button v-if="selected.type==='photo'&&modalAssets.length>1" type="button" @click="toggleSlideshow" :title="slideshow?'暂停幻灯片':'开始幻灯片，每4秒一张'">{{slideshow?'暂停轮播':'幻灯片'}}</button>
          <button type="button" :class="{chosen:viewerInfo}" @click="viewerInfo=!viewerInfo" title="拍摄信息"><Info :size="19"/></button>
          <button ref="modalCloseButton" type="button" @click="closeModal()" title="关闭"><X :size="19"/></button>
        </div>
      </div>
      <div v-if="viewerInfo" class="viewer-info">
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
          <span class="gallery-viewer-hint">{{viewerScale>1?"拖拽平移 · 滚轮或双指缩放":"双击 / 滚轮 / 双指缩放 · 左右滑动翻页"}}{{viewerStage==="thumb"?" · 正在加载高清版本…":""}}</span>
        </div>
        <video v-else controls playsinline :src="original(selected)" class="gallery-modal-video"/>
        <button v-if="selectedIndex+1<modalAssets.length" type="button" class="viewer-nav next" title="下一张" aria-label="下一张" @click="showAssetAt(selectedIndex+1)"><ChevronRight :size="26"/></button>
      </div>
      <div class="gallery-modal-footer">
        <template v-if="admin">
        <select v-model.number="addAlbum" aria-label="选择相册">
          <option :value="0">选择一个相册…</option>
          <option v-for="album in albums" :key="album.id" :value="album.id">{{album.name}}</option>
        </select>
        <button type="button" :disabled="!addAlbum||albumBusy" @click="addSelected">加入相册 <ChevronDown :size="14"/></button>
        <button v-if="activeAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="removeSelectedFromAlbum">移出此相册</button>
        </template>
        <div v-if="sharedAlbumsError&&selected" class="gallery-modal-feedback" role="alert">共享相册读取失败：{{sharedAlbumsError}} <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="refreshAlbums">{{sharedAlbumsLoading?"正在重试…":"重试"}}</button></div>
        <label v-if="privateAlbums.length" class="private-album-picker">
          <span>私人相册</span>
          <select v-model.number="addPrivateAlbum" aria-label="选择我的私人相册">
            <option :value="0">选择要加入的相册…</option>
            <option v-for="album in privateAlbums" :key="album.id" :value="album.id">{{album.name}}</option>
          </select>
          <button type="button" :disabled="!addPrivateAlbum||albumBusy" @click="addSelectedPrivate">加入 <ChevronDown :size="14"/></button>
        </label>
        <span v-else-if="privateAlbumsError&&selected" class="private-album-hint" role="alert">私人相册读取失败：{{privateAlbumsError}} <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="refreshPrivateAlbums()">{{privateAlbumsLoading?"正在重试…":"重试"}}</button></span>
        <span v-else-if="!privateAlbumsError" class="private-album-hint">还没有私人相册。关闭照片后，点「新建私人相册」即可创建。</span>
        <button v-if="activePrivateAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="removeSelectedPrivate">移出此相册</button>
      </div>
      <p v-if="message" class="gallery-modal-feedback" role="status">{{message}}</p>
    </div>
  </div>
  </Teleport>
</template>

<style scoped>
.gallery-stage{position:relative;display:grid}
.gallery-viewer{position:relative;display:grid;place-items:center;min-height:200px;overflow:hidden;border-radius:12px;background:#05070a;touch-action:none}
.gallery-viewer .gallery-modal-image{max-height:72vh;will-change:transform;transition:transform .18s ease;user-select:none}
.gallery-viewer.gesturing .gallery-modal-image{transition:none}
.gallery-viewer-hint{position:absolute;left:12px;bottom:10px;font-size:11px;color:#93a0b4;pointer-events:none}
.viewer-nav{position:absolute;top:50%;transform:translateY(-50%);z-index:2;display:grid;place-items:center;width:40px;height:40px;border:none;border-radius:99px;background:rgba(9,12,18,.55);color:#e8edf5;backdrop-filter:blur(6px)}
.viewer-nav:hover{background:rgba(9,12,18,.8)}
.viewer-nav.prev{left:10px}
.viewer-nav.next{right:10px}
.viewer-info{margin:0 20px;padding:12px 14px;border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);background:var(--fluid-card-fill)}
.viewer-info dl{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:6px 18px;margin:0}
.viewer-info dl>div{display:flex;gap:10px;align-items:baseline;min-width:0}
.viewer-info dt{flex:none;color:var(--text-secondary);font-size:12px}
.viewer-info dd{margin:0;color:var(--text-primary);font-size:13px;word-break:break-word}
.viewer-location{display:inline-flex;align-items:center;gap:4px;flex-wrap:wrap}
.viewer-map-link{border:none;background:none;color:#7c9bff;font-size:12px;padding:0;text-decoration:underline;cursor:pointer}
.timeline-tools{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;margin:0 0 12px}
.type-tabs{display:inline-flex;gap:4px}
.type-tabs button{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--fluid-card-border);border-radius:99px;background:var(--fluid-card-fill);color:var(--text-secondary);padding:7px 13px;font-size:12px;font-weight:650}
.type-tabs button.chosen{background:var(--accent-primary);border-color:var(--accent-primary);color:#fff}
.timeline-search{display:inline-flex;align-items:center;gap:7px;border:1px solid var(--fluid-card-border);border-radius:99px;background:var(--fluid-card-fill);color:var(--text-secondary);padding:7px 13px}
.timeline-search input{border:none;background:none;color:var(--text-primary);font-size:12px;outline:none;width:min(220px,42vw)}
.timeline-search button{border:none;background:none;color:var(--text-secondary);display:grid;place-items:center;padding:0;cursor:pointer}
.photo-mode-tabs{display:inline-flex;gap:4px;padding:4px;border:1px solid var(--fluid-card-border);border-radius:99px;background:var(--fluid-card-fill);margin:0 0 14px;width:fit-content}
.photo-mode-tabs button{display:inline-flex;align-items:center;gap:7px;border:none;border-radius:99px;background:none;color:var(--text-secondary);padding:8px 15px;font-size:13px;font-weight:650}
.photo-mode-tabs button.chosen{background:var(--accent);color:#fff}
.gallery-modal-feedback{margin:0;padding:0 20px 16px;color:var(--text-primary);font-size:13px;line-height:1.5}
.photo-grid{position:relative;display:block}
.timeline-jump{display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin:0 0 14px;color:var(--text-secondary);font-size:12px}
.timeline-jump label{display:inline-flex;align-items:center;gap:6px}
.timeline-jump label>span{font-weight:650}
.timeline-jump select{border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);background:var(--fluid-card-fill);color:var(--text-primary);padding:6px 8px;font-size:12px}
.timeline-jump-current{color:var(--text-secondary)}
.timeline-jump-top{display:inline-flex;align-items:center;gap:5px;border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);background:var(--fluid-card-fill);color:var(--text-secondary);padding:6px 10px;font-size:12px;font-weight:600}
.photo-month-heading{position:absolute;left:0;right:0;height:54px;display:flex;gap:12px;align-items:center;color:var(--text-primary);font-size:18px;font-weight:750;letter-spacing:-.02em;pointer-events:none}
.photo-month-heading small{font-size:12px;font-weight:500;color:var(--text-secondary)}
.photo-grid .photo-tile{position:absolute;margin:0;}
.photo-private-liked{position:absolute;top:8px;right:8px;display:grid;place-items:center;color:#ffd76c;background:rgba(0,0,0,.6);border-radius:99px;padding:5px}
.album-management{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:-6px 0 16px;color:var(--text-secondary);font-size:12px}
.album-management button,.album-new .album-cancel,.gallery-modal-footer .album-remove-photo{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);background:var(--fluid-card-fill);color:var(--text-secondary);padding:8px 11px;font-size:12px;font-weight:600}
.album-management .album-delete{color:var(--warning)}
.album-new button:disabled,.album-management button:disabled,.gallery-modal-footer button:disabled{opacity:.55;cursor:wait}
.gallery-modal-footer .album-remove-photo{background:var(--fluid-card-fill);color:var(--text-secondary);border-color:var(--fluid-card-border)}
.gallery-readonly-favorite{display:flex;align-items:center;color:var(--text-secondary);font-size:11px;white-space:nowrap}
.gallery-modal-footer{align-items:center;flex-wrap:wrap}
.gallery-modal-footer select{max-width:100%}
.private-album-picker{display:flex;align-items:center;gap:8px;flex-wrap:wrap;color:var(--text-secondary);font-size:12px}
.private-album-picker>span{font-weight:650}
.private-album-picker button:disabled,.gallery-modal-actions button:disabled{opacity:.55;cursor:wait}
.private-album-hint{color:var(--text-secondary);font-size:12px;line-height:1.5}
</style>

