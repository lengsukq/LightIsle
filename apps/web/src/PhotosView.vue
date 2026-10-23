<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import { Heart, Star, RefreshCw, Images, Film, Plus, X, FolderPlus, ChevronDown, Pencil, Trash2 } from "lucide-vue-next";
import { validateAlbumName } from "./albumNameValidation.js";
import { createLatestRequestGate } from "./latestRequestGate.js";
import { createPhotoTimelineLayout, getPhotoTimelineWindow } from "./photoTimelineLayout.js";
import { rootApiPath, rootMediaPath } from "./rootApi.js";

type Asset={id:number;path:string;name:string;type:"photo"|"video";size:number;takenAt:number;favorite:boolean;personalFavorite?:boolean;canWrite?:boolean};
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
const nextCursor=ref(0);
const loading=ref(false);
const loadError=ref("");
const loadErrorReset=ref(true);
const scanActionError=ref("");
const message=ref("");
const scan=ref<Status>({running:false,scanned:0,found:0});
const selected=ref<Asset|null>(null);
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
async function status(){
 try{
  const result=await api<{status:Status;count:number}>(apiPath("/api/v1/photos/status"));
  if(disposed)return;
  scan.value=result.status;
  if(!scan.value.running && scan.value.lastDone && scan.value.lastDone>lastCompletedScan){
   lastCompletedScan=scan.value.lastDone;
   await load(true);
   await refreshAlbums();
  }
 }catch {/* App may have been stopped */}
}
async function load(reset=false){
 if(loading.value&&!reset)return;
 const request=listRequests.begin();
 loading.value=true;
 loadError.value="";
 if(reset){nextCursor.value=0;assets.value=[];focusedIndex.value=0;}
 try {
  const query=new URLSearchParams({limit:"48",cursor:String(nextCursor.value)});
  if(activeAlbum.value)query.set("album",String(activeAlbum.value));
  if(activePrivateAlbum.value)query.set("privateAlbum",String(activePrivateAlbum.value));
  if(favoritesOnly.value)query.set("favorites","1");
  if(personalOnly.value)query.set("personal","1");
  const result=await api<{assets:Asset[];nextCursor:number}>(apiPath("/api/v1/photos")+"?"+query.toString(),"GET",undefined,request.signal);
  if(!request.isCurrent())return;
  assets.value=[...assets.value,...result.assets];
  nextCursor.value=result.nextCursor;
  message.value="";
  await nextTick();if(request.isCurrent())updateViewport();
 }catch(e){if(request.isCurrent() && !(e instanceof DOMException && e.name==="AbortError")){loadError.value="加载照片失败："+(e instanceof Error?e.message:"未知错误");loadErrorReset.value=reset}}
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
 try{const result=await api<{albums:Album[]}>(apiPath("/api/v1/photos/albums"),"GET",undefined,request.signal);if(!disposed&&request.isCurrent())albums.value=result.albums}catch{}
}
async function refreshPrivateAlbums(isCurrent:()=>boolean=()=>true){
 const request=privateAlbumRequests.begin();
 try{
  const result=await api<{albums:Album[]}>(apiPath("/api/v1/photos/private-albums"),"GET",undefined,request.signal);
  if(!disposed&&request.isCurrent())privateAlbums.value=result.albums;
 }catch(e){if(request.isCurrent()&&!disposed&&isCurrent())message.value="私人相册加载失败："+albumError(e)}
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
 scanActionError.value="";
 try{await api(apiPath("/api/v1/photos/scan"),"POST");message.value="正在后台扫描授权的共享目录";await status()}
 catch(e){scanActionError.value="无法启动扫描："+(e instanceof Error?e.message:"未知错误")}
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
 return messages[code]??code;
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
 if(activeAlbum.value===album&&favoritesOnly.value===favorites&&personalOnly.value===mine&&activePrivateAlbum.value===privateID)return;
 viewGeneration+=1;
 activeAlbum.value=album;favoritesOnly.value=favorites;personalOnly.value=mine;activePrivateAlbum.value=privateID;selected.value=null;selectedIndex.value=-1;focusedIndex.value=0;
 selectionGeneration+=1;
 void load(true);
 requestAnimationFrame(()=>{
  const root=photosPage.value;
  if(root)window.scrollTo({top:Math.max(0,root.getBoundingClientRect().top+window.scrollY-100),behavior:"auto"});
 });
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
function openAsset(asset:Asset,index:number){
 selectModalAsset(asset,index);
 void nextTick(()=>modalCloseButton.value?.focus());
}
function closeModal(restoreFocus=true){
 const previousIndex=selectedIndex.value;
 selectionGeneration+=1;
 selected.value=null;selectedIndex.value=-1;
 if(restoreFocus&&previousIndex>=0)void focusTile(previousIndex);
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
 if(event.key==="ArrowLeft"&&selectedIndex.value>0){event.preventDefault();const next=selectedIndex.value-1;selectModalAsset(assets.value[next],next)}
 if(event.key==="ArrowRight"&&selectedIndex.value+1<assets.value.length){event.preventDefault();const next=selectedIndex.value+1;selectModalAsset(assets.value[next],next)}
}
function dateLabel(timestamp:number){
 return new Date(timestamp*1000).toLocaleDateString("zh-CN",{year:"numeric",month:"long",day:"numeric"});
}
function canWriteAsset(asset:Asset){return props.admin||asset.canWrite===true}
function thumb(asset:Asset){return mediaPath("/api/v1/photos/"+asset.id+"/thumbnail")}
function original(asset:Asset){return mediaPath("/api/v1/files/preview?path="+encodeURIComponent(asset.path))}
onMounted(()=>{
 disposed=false;
 void load(true);void refreshAlbums();void refreshPrivateAlbums();void status();timer=window.setInterval(()=>void status(),4500);
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
 if(timer)clearInterval(timer);if(viewportFrame)cancelAnimationFrame(viewportFrame);resizeObserver?.disconnect();loadObserver?.disconnect();listRequests.cancel();albumRequests.cancel();privateAlbumRequests.cancel();
 window.removeEventListener("scroll",updateViewport);window.removeEventListener("resize",updateViewport);window.removeEventListener("keydown",modalKeydown);
});
</script>

<template>
  <div ref="photosPage" class="content photos-page">
    <div class="section-heading">
      <div><h2>照片图库</h2><p>你的每个瞬间，保存在自己的 Mac 上。</p></div>
      <button v-if="admin" type="button" class="refresh" @click="startScan" :disabled="scan.running">
        <RefreshCw :size="16" :class="{spinning:scan.running}" /> {{scan.running?"扫描中…":"扫描媒体"}}
      </button>
    </div>
    <div v-if="scan.running" class="scan-banner">正在后台整理媒体 · 已检查 {{scan.scanned}} 项 · 发现 {{scan.found}} 项</div>
    <p v-if="scan.lastError" class="form-error">上次扫描：{{scan.lastError}}</p>
    <p v-if="message" class="gallery-message">{{message}}</p>
    <p v-if="scanActionError&&assets.length" class="gallery-message" role="alert">{{scanActionError}}</p>
    <div class="album-toolbar">
      <div class="album-tabs">
        <button type="button" :class="{chosen:activeAlbum===0&&!activePrivateAlbum&&!favoritesOnly&&!personalOnly}" @click="changeView(0,false)"><Images :size="15"/> 全部照片</button>
        <button type="button" :class="{chosen:favoritesOnly}" @click="changeView(0,true)"><Heart :size="15"/> 共享收藏</button>
        <button type="button" :class="{chosen:personalOnly}" @click="changeView(0,false,true)"><Star :size="15"/> 我的收藏</button>
        <button v-for="album in albums" :key="album.id" type="button" :class="{chosen:activeAlbum===album.id}" @click="changeView(album.id,false)">{{album.name}} <small>{{album.count}}</small></button>
        <button v-for="album in privateAlbums" :key="'private-'+album.id" :data-private-album-filter="album.id" type="button" :class="{chosen:activePrivateAlbum===album.id}" @click="changeView(0,false,false,album.id)"><FolderPlus :size="14"/> {{album.name}} <small>{{album.count}}</small></button>
      </div>
      <button v-if="admin" type="button" class="album-create" @click="toggleAlbumCreate"><Plus :size="17"/> 新建相册</button>
      <button type="button" class="album-create" @click="creatingPrivate=!creatingPrivate;editingPrivate=null;privateAlbumName=''"><Plus :size="17"/> 新建私人相册</button>
    </div>
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
    <div v-if="loading && !assets.length" class="gallery-empty">正在读取媒体索引…</div>
    <div v-else-if="!assets.length && (loadError || scanActionError || scan.lastError)" class="gallery-empty" role="alert">
      <Images :size="40" :stroke-width="1.2" />
      <h3>暂时无法读取图库</h3>
      <p>{{loadError || scanActionError || "上次扫描未完成："+scan.lastError}}</p>
      <button v-if="loadError" type="button" class="refresh" :disabled="loading" @click="retryLoad">重试读取图库</button>
      <button v-else-if="admin" type="button" class="refresh" :disabled="scan.running" @click="startScan">重新扫描</button>
      <p v-else>请联系管理员检查共享目录或重新执行扫描。</p>
    </div>
    <div v-else-if="!assets.length" class="gallery-empty">
      <Images :size="40" :stroke-width="1.2" />
      <h3>{{currentPrivateAlbum?'私人相册还没有照片':currentAlbum?'此相册还没有照片':personalOnly?'还没有个人收藏':favoritesOnly?'还没有共享收藏':'这里还没有照片或视频'}}</h3>
      <p v-if="currentPrivateAlbum">打开全部照片，预览照片后选择自己的私人相册并点击「加入我的相册」。其他账号不会看到这里的相册名称和照片清单。</p>
      <p v-else-if="currentAlbum">打开全部照片，预览照片后选择此相册并点击「加入相册」。</p>
      <p v-else-if="favoritesOnly">在照片预览中点击收藏，已授权查看该照片的成员都可以看到。</p>
      <p v-else-if="personalOnly">预览自己有权限查看的照片，点击星形按钮保存到仅自己可见的收藏夹。</p>
      <p v-else>在文件管理中上传照片或视频，然后点击「扫描媒体」。<span v-if="!admin">请让管理员执行扫描。</span></p>
      <button v-if="currentAlbum||currentPrivateAlbum||favoritesOnly||personalOnly" type="button" class="refresh" @click="changeView(0,false)">浏览全部照片</button>
    </div>
    <p v-if="loadError&&assets.length" class="form-error" role="alert">{{loadError}} <button type="button" class="refresh" :disabled="loading" @click="retryLoad">重试加载</button></p>
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
          <button ref="modalCloseButton" type="button" @click="closeModal()" title="关闭"><X :size="19"/></button>
        </div>
      </div>
      <img v-if="selected.type==='photo'" :src="thumb(selected)" :alt="selected.name" class="gallery-modal-image"/>
      <video v-else controls playsinline :src="original(selected)" class="gallery-modal-video"/>
      <div class="gallery-modal-footer">
        <template v-if="admin">
        <select v-model.number="addAlbum" aria-label="选择相册">
          <option :value="0">选择一个相册…</option>
          <option v-for="album in albums" :key="album.id" :value="album.id">{{album.name}}</option>
        </select>
        <button type="button" :disabled="!addAlbum||albumBusy" @click="addSelected">加入相册 <ChevronDown :size="14"/></button>
        <button v-if="activeAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="removeSelectedFromAlbum">移出此相册</button>
        </template>
        <label v-if="privateAlbums.length" class="private-album-picker">
          <span>私人相册</span>
          <select v-model.number="addPrivateAlbum" aria-label="选择我的私人相册">
            <option :value="0">选择要加入的相册…</option>
            <option v-for="album in privateAlbums" :key="album.id" :value="album.id">{{album.name}}</option>
          </select>
          <button type="button" :disabled="!addPrivateAlbum||albumBusy" @click="addSelectedPrivate">加入 <ChevronDown :size="14"/></button>
        </label>
        <span v-else class="private-album-hint">还没有私人相册。关闭照片后，点「新建私人相册」即可创建。</span>
        <button v-if="activePrivateAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="removeSelectedPrivate">移出此相册</button>
      </div>
      <p v-if="message" class="gallery-modal-feedback" role="status">{{message}}</p>
    </div>
  </div>
  </Teleport>
</template>

<style scoped>
.gallery-modal-feedback{margin:0;padding:0 20px 16px;color:var(--text-primary);font-size:13px;line-height:1.5}
.photo-grid{position:relative;display:block}
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

