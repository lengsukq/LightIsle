<script setup lang="ts">
import {ref,computed,onMounted,onBeforeUnmount,onUnmounted,watch,nextTick} from "vue";
import {describeRootOperationFailure} from "./rootDiscovery.js";
import {describeUserFacingError} from "./userFacingError.js";
import {apiErrorFromResponse} from "./apiFailure.js";
import {Clapperboard,Film,Tv,Play,Download,Search,RefreshCcw,X,Subtitles,Pencil,AudioLines,Wand2,Gauge,RotateCcw,Trash2} from "lucide-vue-next";
import {trashMediaOriginals} from "./mediaTrash.js";
import {createMediaStatusPoller} from "./mediaStatusPoller.js";
import {mediaQueryKey,transitionMediaQuery} from "./mediaQueryContext.js";
import {rootApiPath,rootMediaPath} from "./rootApi.js";
import AppleSelect from "./AppleSelect.vue";
import {useCinemaPlayback} from "./useCinemaPlayback.js";
import {duration,formatLabel,metadataSourceName,percent,useCinemaMetadata} from "./useCinemaMetadata.js";
import {useCinemaSeriesAndHistory} from "./useCinemaSeriesAndHistory.js";
import {readCinemaHomeShelves} from "./cinemaHomeShelves.js";
import {useCinemaDirectoryPlaylist} from "./useCinemaDirectoryPlaylist.js";
import {continueAfterPlaybackEnd} from "./cinemaAutoAdvance.js";
import {confirmCinemaExit} from "./cinemaSafeExit.js";
import {createBrowserMediaBackstack} from "./browserMediaBackstack.js";
import {getMetadata,putMetadata} from "./useIsleCache";
import type {Movie,Scan} from "./cinemaTypes.js";
const props=defineProps<{admin:boolean;rootId?:string;rootGeneration?:number}>();
const movies=ref<Movie[]>([]);
const mode=ref("all"),query=ref(""),next=ref(0),loading=ref(false),actionError=ref("");
function cinemaQueryKey(){return mediaQueryKey({root:props.rootId??"",generation:props.rootGeneration??0,mode:mode.value,query:query.value.trim()})}
let pageQueryKey=cinemaQueryKey();
const pageLoaded=ref(false);
const loadError=ref("");
const loadErrorReset=ref(true);
const scanActionError=ref("");
const scanStatusLoading=ref(false),scanStatusLoaded=ref(false),scanStatusError=ref("");
const scan=ref<Scan>({running:false,visited:0,found:0,lastDone:0});
const selected=ref<Movie|null>(null);
// Poster -> information -> explicit play. Resume/episode actions skip the overview and go directly to playback, matching Flutter.
const viewerPlaying=ref(false);
const showPlayerPlaylist=ref(false);
const leavingPlayer=ref(false),exitSaveBlocked=ref(false);
let mediaBackstack:ReturnType<typeof createBrowserMediaBackstack>|null=null;
const cinemaDialog=ref<HTMLElement|null>(null);
let returnFocus:HTMLElement|null=null;
const seriesDialog=ref<HTMLElement|null>(null);
const continueShelf=ref<Movie[]>([]),recentShelf=ref<Movie[]>([]),shelvesError=ref("");
const featuredFilm=computed(()=>continueShelf.value[0]??recentShelf.value[0]??movies.value[0]??null);
let shelfGeneration=0;
const deleting=ref(false),choosingTrash=ref(false),trashIDs=ref<Set<number>>(new Set());
function toggleTrashFilm(id:number){
 if(!movies.value.some(movie=>movie.id===id&&(props.admin||movie.canWrite===true)))return;
 const next=new Set(trashIDs.value);
 if(next.has(id))next.delete(id);
 else if(next.size<50)next.add(id);
 trashIDs.value=next;
}
function playSelected(){
 const film=selected.value;
 if(!film||viewerPlaying.value)return;
 mediaBackstack?.push();
 viewerPlaying.value=true;
 if(!canAttemptDirect(film)){
  if(film.probeStatus==="pending"){
   playError.value="正在检查此视频格式，识别完成后可重试；原片可下载。";
   return;
  }
  void startTranscode(film,film.position>5?film.position:0,0);
 }
}
function returnToOverview(){
 if(mediaBackstack?.depth&&mediaBackstack.depth>1){mediaBackstack.back();return}
 void leavePlayer("overview");
}
function finishReturnToOverview(){
 player.value?.pause();hlsPlayer.value?.pause();destroyHls();viewerPlaying.value=false;showPlayerPlaylist.value=false;exitSaveBlocked.value=false;
 playError.value="";
 void nextTick(()=>cinemaDialog.value?.focus());
}
async function trashFilms(items:Movie[]){
 if(deleting.value||!items.length)return;
 if(items.length>50||items.some(item=>!item.path||!(props.admin||item.canWrite===true))){
  actionError.value="每次最多删除50部，且只能删除你有写入权限的原文件。";
  return;
 }
 const root=rootEpoch,generation=loadGeneration;
 const frozen=items.map(item=>({id:item.id,path:item.path}));
 if(!window.confirm(`将 ${items.length} 部影片的原文件移入回收站？影视记录将在后续扫描时更新。`))return;
 const current=()=>!disposed&&root===rootEpoch&&generation===loadGeneration &&
   frozen.every(item=>movies.value.some(film=>film.id===item.id&&film.path===item.path));
 if(!current()){actionError.value="影片列表或硬盘已变化，请重新选择。";return}
 deleting.value=true;
 try{
  const result=await trashMediaOriginals(frozen.map(item=>item.path),
    paths=>api<{results:Array<{path?:string;success:boolean;error?:string}>}>(
      apiPath("/api/v2/files/batch"),"POST",{action:"trash",paths}),
    current);
  if(result.cancelled){actionError.value="存储根已变化，请回原目录确认删除结果。";return}
  if(selected.value&&frozen.some(item=>item.id===selected.value?.id))close();
  trashIDs.value=new Set();choosingTrash.value=false;
  const outcome=`已确认移入回收站 ${result.completed}/${items.length} 项。`+
    (result.needsRootCheck?"硬盘连接发生变化，部分操作的结果不确定。请重新连接原硬盘，检查原目录和回收站后再重试。":result.failed.length?"其余项目请检查权限或文件状态。":"");
  await load(true);
  if(!disposed&&root===rootEpoch)actionError.value=outcome;
 }catch(error){if(root===rootEpoch)actionError.value="未能确认移入回收站的结果："+describeRootOperationFailure(error)}
 finally{deleting.value=false}
}
function trashSelectedFilms(){
 const items=movies.value.filter(item=>trashIDs.value.has(item.id));
 if(items.length!==trashIDs.value.size){actionError.value="影片列表已变化，请重新选择。";return}
 void trashFilms(items);
}
const posterFailed=ref<Record<number,boolean>>({});
const view=ref<"films"|"series">("films");
let scanTimer:number|undefined,searchTimer:number|undefined,lastDone=0;
let loadGeneration=0;
let disposed=false;
let rootEpoch=0;
let playbackGeneration=0;
let selectedController:AbortController|undefined;
function apiPath(path:string){return rootApiPath(props.rootId,path)}
function mediaPath(path:string){return rootMediaPath(props.rootId,props.rootGeneration??0,path)}
async function api<T>(url:string,method="GET",body?:object,signal?:AbortSignal):Promise<T>{
 const rootID=props.rootId,rootGeneration=props.rootGeneration??0;
 const headers=new Headers(method==="GET"?{}:{"Content-Type":"application/json","X-LightIsle-Request":"1"});
 if(rootID)headers.set("X-LightIsle-Root-Generation",String(rootGeneration));
 const response=await fetch(url,{method,credentials:"same-origin",cache:"no-store",
 headers,
 body:body===undefined?undefined:JSON.stringify(body),signal});
 if(!response.ok){const data=await response.json().catch(()=>({error:"HTTP "+response.status})) as {error?:string};
  if(rootID&&(props.rootId!==rootID||props.rootGeneration!==rootGeneration||disposed))throw makeRootAbortError();
  if(rootID&&response.status===409&&data.error==="root_generation_changed"){window.dispatchEvent(new Event("lightisle-root-generation-changed"));throw new Error("共享目录已变化，请刷新根列表后重新选择。");}
  throw apiErrorFromResponse(response,data)}
 const result=await response.json() as T;
 if(rootID&&(props.rootId!==rootID||props.rootGeneration!==rootGeneration||disposed))throw makeRootAbortError();
 return result;
}
function makeRootAbortError(){const error=new Error("root_context_changed");error.name="AbortError";return error;}
const {
 player,hlsPlayer,caption,playError,hlsSession,hlsTracks,hlsStarting,hlsQuality,
 playbackRate,autoplayNext,preferLocalDecode,directLocalOverride,playbackPosition,playbackDuration,canPictureInPicture,seekPreview,
 progressSaveError,retryProgress,currentFilmProgressUnsaved,refreshProgressSaveError,stream,track,download,playback,canAttemptDirect,destroyHls,
 resetPendingSeek,startTranscode,switchAudioTrack,switchQuality,playbackRateOptions,
 captionOptions,audioTrackOptions,currentQuality,cinemaQualityOptions,setPlaybackRate,
 setAutoplayNext,setPreferLocalDecode,activeVideo,loaded,save,tick,resetProgressClock,changeCaption,captionSrclang,
 jumpPlayback,seekAbsolute,toggleCinemaFullscreen,toggleCinemaPictureInPicture,transcodeErrorMessage,
}=useCinemaPlayback({selected,movies,props,api,apiPath,mediaPath});
const {
 candidatePosterFailed,scraping,scrapeMessage,tmdbQuery,tmdbToken,tmdbMatches,tmdbBusy,tmdbError,batchToken,batchBusy,batchError,batchProgress,batchCandidates,
 doubanQuery,doubanMatches,doubanBusy,doubanError,scrapeState,scrapeBusy,scrapeNotice,scrapeError,cancelBatch,suggestBatch,acceptBatchCandidate,cancelMetadataRequests,
 searchDouban,matchDouban,rename,importLocalNFO,searchTMDB,matchTMDB,refreshScrape,startScrape,resetMetadataForOpen,resetMetadataForClose,resetMetadataForRootChange,disposeMetadata,
}=useCinemaMetadata({
 isAdmin:()=>props.admin,getRootId:()=>props.rootId,getRootGeneration:()=>props.rootGeneration??0,getRootEpoch:()=>rootEpoch,isDisposed:()=>disposed,
 movies,selected,posterFailed,actionError,api,apiPath,load:(reset)=>load(reset),transcodeErrorMessage,
});
const {
 matchingSeries,seriesSearchLoading,seriesSearchError,historyFilms,historyLoading,historyError,seriesList,seriesLoading,seriesError,seriesDetail,seriesDetailLoading,seriesDetailError,
 seriesTmdbId,seriesTmdbBusy,seriesTmdbMessage,resetSeriesSearch,searchForSeries,loadHistory,clearHistory,markWatched,findNextEpisode,loadSeries,switchView,openSeries,
 finishCloseSeries,closeSeries,seasonNumbers,continueSeries,matchSeriesTMDB,resetSeriesAndHistoryForRootChange,disposeSeriesAndHistory,
}=useCinemaSeriesAndHistory({
 isAdmin:()=>props.admin,getRootEpoch:()=>rootEpoch,isDisposed:()=>disposed,query,view,movies,selected,scrapeMessage,seriesDialog,api,apiPath,
 load:(reset)=>load(reset),open:(v,autoStart)=>open(v,autoStart),getMediaBackstack:()=>mediaBackstack,
});
const {
 directoryOf:playlistDirectory,reset:resetDirectoryPlaylist,load:loadDirectoryPlaylist,findNext:findNextDirectoryFilm,sameDirectoryFilms,currentIndex:currentPlaylistIndex,
 previousFilm:prevPlaylistFilm,nextFilm:nextPlaylistFilm,loading:directoryLoading,error:directoryError,nextCursor:directoryNextCursor,
}=useCinemaDirectoryPlaylist({
 selected,sources:()=>[movies.value,continueShelf.value,recentShelf.value,historyFilms.value,seriesDetail.value?.films??[]],
 rootEpoch:()=>rootEpoch,disposed:()=>disposed,api,apiPath,describeError:describeRootOperationFailure,
});
function togglePlayerPlaylist(){
 showPlayerPlaylist.value=!showPlayerPlaylist.value;
 if(showPlayerPlaylist.value&&selected.value)void loadDirectoryPlaylist(selected.value);
}
async function switchPlaylistFilm(target:Movie,autoStart=true){
 if(!selected.value||leavingPlayer.value)return;
 if(target.id===selected.value.id){
  showPlayerPlaylist.value=false;
  if(autoStart&&!viewerPlaying.value)playSelected();
  return;
 }
 if(viewerPlaying.value){
  leavingPlayer.value=true;exitSaveBlocked.value=false;
  try{
   activeVideo()?.pause();
   const saved=await confirmCinemaExit({
    save,hasUnsaved:currentFilmProgressUnsaved,
    onLeave:()=>{},onFailure:()=>{exitSaveBlocked.value=true},
   });
   if(!saved)return;
  }finally{leavingPlayer.value=false}
 }
 showPlayerPlaylist.value=false;
 await open(target,autoStart);
}
async function findNextPlayable(film:Movie):Promise<Movie|null>{
 if(film.kind==="series"){
  const episode=await findNextEpisode(film);
  if(episode)return episode;
 }
 return findNextDirectoryFilm(film);
}
watch([()=>props.rootId,()=>props.rootGeneration],()=>{
 mediaBackstack?.reset();
 resetDirectoryPlaylist();showPlayerPlaylist.value=false;
 rootEpoch+=1;loadGeneration+=1;playbackGeneration+=1;shelfGeneration+=1;selectedController?.abort();if(searchTimer)clearTimeout(searchTimer);
 resetMetadataForRootChange();
 resetSeriesAndHistoryForRootChange();
 scanStatusPoller.invalidate();movies.value=[];next.value=0;loading.value=false;pageLoaded.value=false;
 pageQueryKey=cinemaQueryKey();
 loadError.value="";actionError.value="";scanActionError.value="";scanStatusLoaded.value=false;scanStatusLoading.value=false;scanStatusError.value="";
 scan.value={running:false,visited:0,found:0,lastDone:0};lastDone=0;
 refreshProgressSaveError();
 destroyHls();
 selected.value=null;viewerPlaying.value=false;continueShelf.value=[];recentShelf.value=[];shelvesError.value="";playError.value="";player.value?.pause();
 trashIDs.value=new Set();choosingTrash.value=false;deleting.value=false;
 void load(true);void loadHomeShelves();void status();void refreshScrape();
 if(view.value==="series")void loadSeries();
 if(mode.value==="history"&&view.value==="films")void loadHistory(true);
},{flush:"sync"});
const scanStatusPoller=createMediaStatusPoller(
 signal=>api<{status:Scan}>(apiPath("/api/v2/cinema/status"),"GET",undefined,signal),
 {
  onValue:value=>{
   const wasRunning=scan.value.running;
   scan.value=value.status;scanStatusLoaded.value=true;scanStatusError.value="";scanStatusLoading.value=false;
   if((wasRunning&&!scan.value.running)||(scan.value.lastDone&&scan.value.lastDone!==lastDone)){lastDone=scan.value.lastDone;void load(true);void loadHomeShelves();void refreshScrape();if(view.value==="series")void loadSeries()}
  },
  onError:value=>{scanStatusError.value=describeRootOperationFailure(value);scanStatusLoading.value=false;},
 },
);
function status(){scanStatusLoading.value=true;return scanStatusPoller.refresh()}
async function loadHomeShelves(){
 const epoch=rootEpoch,generation=++shelfGeneration;
 const current=()=>!disposed&&epoch===rootEpoch&&generation===shelfGeneration;
 try{
  const shelves=await readCinemaHomeShelves(
   kind=>api<{films:Movie[]}>(apiPath("/api/v2/cinema")+"?"+new URLSearchParams({kind,limit:"8",cursor:"0"})),
   current,
  );
  if(!shelves||!current())return;
  continueShelf.value=shelves.resume;
  recentShelf.value=shelves.recent;
  shelvesError.value="";
 }catch(e){if(current())shelvesError.value=describeRootOperationFailure(e)}
}
async function load(reset=false){
 if(loading.value&&!reset)return;
 const transition=transitionMediaQuery(pageQueryKey,cinemaQueryKey());
 if(transition.clearContent){
  pageQueryKey=transition.queryKey;movies.value=[];next.value=0;pageLoaded.value=false;posterFailed.value={};
 }
 const generation=++loadGeneration;
 loading.value=true;
 loadError.value="";
 if(reset&&!movies.value.length){const cached=getMetadata<{films:Movie[];nextCursor:number}>("cinema:list:"+cinemaQueryKey());if(cached?.films?.length){movies.value=cached.films;next.value=cached.nextCursor||0;pageLoaded.value=true;}}
 try{
  const params=new URLSearchParams({limit:"48",cursor:String(reset?0:next.value)});
  if(mode.value!=="all")params.set("kind",mode.value);
  if(query.value.trim())params.set("query",query.value.trim());
  const page=await api<{films:Movie[];nextCursor:number}>(apiPath("/api/v2/cinema")+"?"+params);
  if(generation!==loadGeneration)return;
  movies.value=reset?page.films:[...movies.value,...page.films];next.value=page.nextCursor;if(reset){pageLoaded.value=true;actionError.value="";putMetadata("cinema:list:"+cinemaQueryKey(),{films:page.films,nextCursor:page.nextCursor});}loadError.value="";
 }catch(e){if(generation===loadGeneration&&!(e instanceof Error&&e.name==="AbortError")){loadError.value=describeRootOperationFailure(e);loadErrorReset.value=reset}}finally{if(generation===loadGeneration)loading.value=false}
}
function retryLoad(){void load(loadErrorReset.value)}
async function startScan(){
 const context=rootEpoch;scanActionError.value="";
 try{await api(apiPath("/api/v2/cinema/scan"),"POST");if(context!==rootEpoch)return;scanStatusPoller.invalidate();await status()}
 catch(e){if(context===rootEpoch)scanActionError.value=describeUserFacingError(e)}
}
function filter(value:string){
 if(searchTimer)clearTimeout(searchTimer);
 if(query.value)query.value="";
 view.value="films";
 mode.value=value;
 if(value==="history"){void loadHistory(true);return}
 void load(true);
 if(value==="all")void loadHomeShelves();
}
watch(query,()=>{
 if(query.value.trim()){
  view.value="films";mode.value="all";
 }
 const transition=transitionMediaQuery(pageQueryKey,cinemaQueryKey());
 if(transition.clearContent){
  pageQueryKey=transition.queryKey;loadGeneration+=1;movies.value=[];next.value=0;loading.value=false;pageLoaded.value=false;
  loadError.value="";loadErrorReset.value=true;actionError.value="";posterFailed.value={};
 }
 if(searchTimer)clearTimeout(searchTimer);
 const term=query.value.trim();
 resetSeriesSearch();
 searchTimer=window.setTimeout(()=>{
  void load(true);
  if(term)void searchForSeries(term);
 },350);
},{flush:"sync"});
const filteredView=computed(()=>mode.value!=="all"||!!query.value.trim());
const emptyTitle=computed(()=>query.value.trim()?"没有找到匹配的影片":mode.value==="continue"?"还没有可继续观看的影片":mode.value==="unmatched"?"所有影片均已匹配资料":mode.value==="movie"?"电影分类还没有内容":mode.value==="series"?"剧集分类还没有内容":"还没有影片");
const emptyMessage=computed(()=>query.value.trim()?"换个名称试试，或查看全部影片。":mode.value==="continue"?"播放影片后，可从这里继续上次的观看进度。":mode.value==="unmatched"?"没有尚未确认海报或简介的影片。":mode.value!=="all"?"可以查看全部影片，或将此类影视文件加入共享目录后重新扫描。":"将影视文件拷贝到 Mac 共享目录后，点击右上角「扫描影视库」。");
function resetFilters(){mode.value="all";query.value="";if(searchTimer){clearTimeout(searchTimer);searchTimer=undefined}void load(true)}
const continueCount=computed(()=>movies.value.filter(v=>v.position>5&&!v.completed).length);
function playbackLabel(v:Movie){
 const mode=playback(v);
 if(mode==="verified-direct")return "已验证可播放";
 if(mode==="unverified-direct")return "可尝试播放 · 尚未验证";
 const status=v.probeStatus;
 if(status==="pending")return "正在识别格式";
 if(status==="unavailable")return "格式检查器不可用";
 if(status==="failed")return "格式识别失败";
 if(status==="unsupported")return "浏览器暂不支持";
 return "建议下载后播放";
}
function posterReady(v:Movie){return v.probeStatus==="ready"&&!posterFailed.value[v.id]}
function poster(v:Movie){return v.posterURL||mediaPath("/api/v2/cinema/"+v.id+"/poster")}
async function open(v:Movie,autoStart=false){
 if(!selected.value)mediaBackstack?.push();
 playbackGeneration+=1;
 selectedController?.abort();
 resetMetadataForOpen(v);
 destroyHls();
 seriesTmdbMessage.value="";
 const controller=new AbortController();selectedController=controller;
 if(!selected.value) returnFocus=document.activeElement instanceof HTMLElement?document.activeElement:null;
 selected.value=v;viewerPlaying.value=autoStart;caption.value="off";playError.value="";directLocalOverride.value=preferLocalDecode.value;resetProgressClock();
 void loadDirectoryPlaylist(v);
 void nextTick(()=>cinemaDialog.value?.focus());
 if(!canAttemptDirect(v)){
  if(v.probeStatus==="pending"){
   playError.value="正在识别此视频格式，当前无法判断是否可直接播放。识别完成后可重新打开，也可以先下载原片。";
   return;
  }
  if(autoStart){await startTranscode(v,v.position>5?v.position:0,0)}
  else playError.value=playbackLabel(v)+"。可尝试在线转码播放（服务器实时转封装/转码，原片不变），或下载原片后用 IINA、VLC 打开。";
  return;
 }
 if(autoStart&&playback(v)==="unverified-direct")playError.value="该格式尚未经过本机解码验证，正在尝试浏览器播放；若无法解码，请下载原片使用本地播放器。";
 try{
  const detail=await api<Movie>(apiPath("/api/v2/cinema/"+v.id),"GET",undefined,controller.signal);
  if(controller.signal.aborted||selected.value?.id!==v.id)return;
  selected.value=detail;
  if(!canAttemptDirect(detail)){
   if(autoStart)await startTranscode(v,detail.position>5?detail.position:0,0);
   else playError.value=playbackLabel(detail)+"。可尝试在线转码播放，或下载原片后用 IINA、VLC 打开。";
  }
  else if(autoStart&&playback(detail)==="unverified-direct")playError.value="该格式尚未经过本机解码验证，正在尝试浏览器播放；若无法解码，请下载原片使用本地播放器。";
  else playError.value="";
 }catch(e){if(!(e instanceof Error&&e.name==="AbortError")){/* Keep list metadata and the visible fallback guidance */}}
}
async function playbackEnded(){
 const finished=selected.value;
 const generation=playbackGeneration;
 await continueAfterPlaybackEnd({
  film:finished,
  saveFinished:()=>save(true),
  shouldAdvance:film=>autoplayNext.value&&(film.kind==="series"||!!film.path),
  isCurrent:()=>!disposed&&generation===playbackGeneration&&selected.value?.id===finished?.id,
  findNext:findNextPlayable,
  openNext:film=>open(film,true),
  onNoNext:()=>{playError.value=directoryError.value?"同目录播放列表读取失败："+directoryError.value:finished?.kind==="series"?"本季已播完，或还没有扫描到下一集。可从剧集库选择继续观看。":"当前目录没有下一部影片。"},
 });
}
function finishClose(){
 playbackGeneration+=1;selectedController?.abort();selectedController=undefined;resetMetadataForClose();
 player.value?.pause();hlsPlayer.value?.pause();destroyHls();resetDirectoryPlaylist();selected.value=null;viewerPlaying.value=false;showPlayerPlaylist.value=false;exitSaveBlocked.value=false;
 playError.value="";seriesTmdbMessage.value="";resetPendingSeek();
 const target=returnFocus;returnFocus=null;void nextTick(()=>{if(target?.isConnected)target.focus()});void loadHomeShelves();
}
async function leavePlayer(destination:"overview"|"close",allowUnsaved=false):Promise<boolean>{
 if(leavingPlayer.value||!selected.value)return false;
 if(!viewerPlaying.value){finishClose();return true}
 if(allowUnsaved){
  if(destination==="overview")finishReturnToOverview();else finishClose();
  return true;
 }
 leavingPlayer.value=true;exitSaveBlocked.value=false;
 try{
  // Snapshot and pause before hiding the video element. Pause can enqueue an
  // additional progress write; the serialized writer flushes both.
  activeVideo()?.pause();
  return await confirmCinemaExit({
   save,hasUnsaved:currentFilmProgressUnsaved,
   onLeave:()=>{if(destination==="overview")finishReturnToOverview();else finishClose()},
   onFailure:()=>{exitSaveBlocked.value=true},
  });
 }finally{leavingPlayer.value=false}
}
function close(){
 if(mediaBackstack?.back(seriesDetail.value?1:mediaBackstack.depth))return;
 void leavePlayer("close");
}
function keydown(e:KeyboardEvent){
 const dialog=selected.value?cinemaDialog.value:seriesDetail.value?seriesDialog.value:null;
 if(dialog&&e.key==="Tab"){
  const focusable=Array.from(dialog.querySelectorAll<HTMLElement>(
   'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),video[controls],[tabindex]:not([tabindex="-1"])',
  )).filter(element=>element.offsetWidth>0||element.offsetHeight>0||element===document.activeElement);
  if(!focusable.length){e.preventDefault();dialog.focus();return}
  const first=focusable[0],last=focusable[focusable.length-1],active=document.activeElement;
  if(!focusable.includes(active as HTMLElement)){e.preventDefault();(e.shiftKey?last:first).focus();return}
  if(e.shiftKey&&active===first){e.preventDefault();last.focus()}
  else if(!e.shiftKey&&active===last){e.preventDefault();first.focus()}
  return;
 }
 const target=e.target;
 const isInteractive=target instanceof HTMLElement&&Boolean(target.closest(
  'button,a,input,textarea,select,[contenteditable="true"],[role="slider"]',
 ));
 if(selected.value&&viewerPlaying.value&&!e.altKey&&!e.ctrlKey&&!e.metaKey&&!isInteractive){
  if(e.key==="ArrowLeft"||e.key==="ArrowRight"){
   e.preventDefault();void jumpPlayback(e.key==="ArrowLeft"?-10:10);return;
  }
  if(e.key===" "){
   e.preventDefault();const video=activeVideo();if(video){if(video.paused)void video.play();else video.pause()}return;
  }
 }
 if(e.key!=="Escape")return;
 if(selected.value&&viewerPlaying.value&&showPlayerPlaylist.value){e.preventDefault();showPlayerPlaylist.value=false;return}
 if(selected.value){e.preventDefault();if(viewerPlaying.value)returnToOverview();else close();return}
 if(seriesDetail.value){e.preventDefault();closeSeries()}
}
onMounted(()=>{
 disposed=false;
 mediaBackstack=createBrowserMediaBackstack(window,"lightisle-cinema",async(_old,target)=>{
  if(selected.value){
   const toOverview=viewerPlaying.value&&target>0&&!seriesDetail.value;
   const saved=await leavePlayer(toOverview?"overview":"close");
   if(saved&&target===0&&seriesDetail.value)finishCloseSeries();
   return saved;
  }
  if(seriesDetail.value)finishCloseSeries();
  return true;
 });
 void load(true);void loadHomeShelves();void status();void refreshScrape();
 scanTimer=window.setInterval(()=>{if(document.hidden)return;void status()},5000);
 window.addEventListener("keydown",keydown);
});
onBeforeUnmount(()=>{void save()});
onUnmounted(()=>{disposed=true;resetDirectoryPlaylist();mediaBackstack?.dispose();mediaBackstack=null;loadGeneration+=1;playbackGeneration+=1;shelfGeneration+=1;disposeSeriesAndHistory();if(scanTimer)clearInterval(scanTimer);if(searchTimer)clearTimeout(searchTimer);selectedController?.abort();disposeMetadata();destroyHls();scanStatusPoller.dispose();window.removeEventListener("keydown",keydown)});
</script>
<template>
  <div class="content cinema-view">
  <div class="section-heading">
   <div><h2>影视</h2><p>选择想看的作品，或者从上次的位置继续观看。</p></div>
   <button v-if="admin" class="refresh" :disabled="scan.running&&!scanStatusError" @click="startScan"><RefreshCcw :size="16" :class="{spinning: scan.running&&!scanStatusError}"/>{{scan.running&&!scanStatusError?"扫描中…":"扫描影视库"}}</button>
  </div>
  <details v-if="admin" class="cinema-tmdb-panel">
   <summary>批量整理影片 · TMDB 候选建议（逐条确认）</summary>
   <p>只对当前已加载、尚未手动匹配的最多 8 部影片生成候选。根据片名与年份初步评分，不保证同名电影匹配准确；每部作品必须人工确认才写入。若已在 Mac 端配置 TMDB Token 可直接留空。</p>
   <form class="cinema-tmdb-form" @submit.prevent="suggestBatch">
    <input v-model="batchToken" type="password" autocomplete="off" placeholder="你的 TMDB Read Access Token（可选，留空默认使用 Mac 已配置 Token）" :disabled="batchBusy"/>
    <button type="submit" :disabled="batchBusy">{{batchBusy?"正在查找…":"生成候选"}}</button>
    <button type="button" :disabled="batchBusy" @click="cancelBatch">清除令牌与候选</button>
   </form>
   <p v-if="batchProgress" class="cinema-hint" role="status">{{batchProgress}}</p>
   <p v-if="batchError" class="cinema-alert" role="alert">{{batchError}}</p>
   <div v-for="item in batchCandidates" :key="item.filmId" class="cinema-tmdb-match">
    <div class="cinema-tmdb-match-text"><strong>{{item.filmTitle}} → {{item.match.title}} {{item.match.year?"("+item.match.year+")":""}}</strong><small>自动候选评分 {{item.score}} / 100 · 请核对是否同一部影片</small></div>
    <button type="button" :disabled="batchBusy" @click="acceptBatchCandidate(item)">确认此条</button>
   </div>
  </details>
  <details v-if="admin" class="cinema-tmdb-panel">
   <summary>自动刮削 · 服务器端 TMDB 批量补全（填好 Token 后默认开启，仅 Mac 端可关闭）</summary>
   <p>在 Mac App「设置 → 媒体服务」填好 TMDB Token 后，服务器后台默认自动为待匹配影片与剧集补全 TMDB 信息（海报/简介/评分），仅 Mac 端清除 Token 可关闭。此处仅用于重试此前未命中的条目。</p>
   <p v-if="scrapeState&&!scrapeState.tmdbConfigured" class="cinema-alert" role="status">尚未配置 TMDB Token：请在 Mac App「设置 → 媒体服务」中填写后自动启用。</p>
   <p v-else-if="scrapeState&&scrapeState.running" class="cinema-hint" role="status">自动刮削进行中：已处理 {{scrapeState.processed}} 项，成功匹配 {{scrapeState.matched}} 项…</p>
   <p v-else-if="scrapeState?.tmdbConfigured" class="cinema-hint" role="status">已在 Mac 端配置 TMDB Token，自动刮削已默认开启（仅 Mac 端可关闭）。</p>
   <p v-if="scrapeNotice" class="cinema-hint" role="status">{{scrapeNotice}}</p>
   <p v-if="scrapeError" class="cinema-alert" role="alert">{{scrapeError}}</p>
   <form class="cinema-tmdb-form" @submit.prevent="startScrape">
    <button type="submit" :disabled="scrapeBusy||(scrapeState?.running??false)||scrapeState?.tmdbConfigured===false">{{scrapeState?.running?"刮削进行中…":scrapeBusy?"正在重试…":"重试此前未匹配的条目"}}</button>
   </form>
  </details>
  <div v-if="scan.running&&!scanStatusError" class="cinema-alert">正在扫描：{{scan.visited}} 项 · 已找到 {{scan.found}} 部作品</div>
  <div v-if="scanStatusError&&movies.length" class="cinema-alert" role="alert">扫描状态读取失败：{{scanStatusError}} <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span> <button type="button" class="account-action" :disabled="scanStatusLoading" @click="status">{{scanStatusLoading?"正在重试…":"重试状态"}}</button></div>
  <div v-if="scanStatusLoaded&&scan.lastError&&movies.length" class="cinema-alert" role="alert">扫描未完成：{{describeUserFacingError(scan.lastError)}}</div>
  <div v-if="scanActionError&&movies.length" class="cinema-alert" role="alert">无法启动扫描：{{scanActionError}}</div>
  <div v-if="actionError&&movies.length" class="cinema-alert" role="alert">{{actionError}}</div>
  <div v-if="loadError&&movies.length" class="cinema-alert" role="alert">加载影视库失败：{{loadError}} 当前仍显示上次成功读取的内容。 <button type="button" class="account-action" :disabled="loading" @click="retryLoad">重试加载</button></div>
  <div v-if="progressSaveError" class="cinema-alert" role="alert">{{progressSaveError}} <button type="button" class="account-action" @click="retryProgress">重试保存进度</button></div>
  <div class="cinema-tools cinema-navigation">
   <div class="cinema-tabs" role="group" aria-label="影视分类">
    <button type="button" :class="{active:view==='films'&&mode==='all'}" :aria-pressed="view==='films'&&mode==='all'" @click="filter('all')"><Clapperboard :size="15"/>首页</button>
    <button type="button" :class="{active:view==='films'&&mode==='movie'}" :aria-pressed="view==='films'&&mode==='movie'" @click="filter('movie')"><Film :size="15"/>电影</button>
    <button type="button" :class="{active:view==='series'}" :aria-pressed="view==='series'" @click="switchView('series')"><Tv :size="15"/>剧集</button>
    <button type="button" :class="{active:view==='films'&&mode==='unmatched'}" :aria-pressed="view==='films'&&mode==='unmatched'" @click="filter('unmatched')"><Wand2 :size="15"/>待匹配</button>
   </div>
   <div class="cinema-activities" role="group" aria-label="观看记录">
    <button type="button" :class="{active:mode==='continue'&&view==='films'}" :aria-pressed="mode==='continue'&&view==='films'" @click="filter('continue')"><Play :size="15"/>继续观看</button>
    <button type="button" :class="{active:mode==='history'&&view==='films'}" :aria-pressed="mode==='history'&&view==='films'" @click="filter('history')">观看历史</button>
   </div>
   <label class="cinema-search"><Search :size="16"/><input v-model="query" maxlength="120" type="search" placeholder="搜索电影、剧集或单集" aria-label="搜索电影、剧集或单集"/><button v-if="query" type="button" title="清除搜索" @click="query=''"><X :size="15"/></button></label>
   <button v-if="(admin||movies.some(movie=>movie.canWrite===true))&&view==='films'&&mode!=='history'" type="button" class="dl-btn" :disabled="deleting" @click="choosingTrash=!choosingTrash;trashIDs=new Set()">{{choosingTrash?"完成多选":"多选删除"}}</button>
  </div>
  <div v-if="choosingTrash&&view==='films'&&mode!=='history'" class="cinema-tools media-selection-actions" role="group" aria-label="已选择影片的操作">
   <span>已选 {{trashIDs.size}} 部（最多50部）</span>
   <button type="button" class="dl-btn" :disabled="deleting" @click="trashIDs=new Set(movies.filter(movie=>admin||movie.canWrite===true).slice(0,50).map(movie=>movie.id))">全选可删除影片</button>
   <button type="button" class="dl-btn" :disabled="deleting||!trashIDs.size" @click="trashSelectedFilms"><Trash2 :size="15"/> 移入回收站</button>
  </div>
  <p v-if="view==='films'&&mode==='continue'&&continueCount" class="cinema-hint">当前列表有 {{continueCount}} 部作品可继续观看</p>
  <section v-if="view==='films'&&mode==='all'&&!query.trim()&&!choosingTrash" class="cinema-home">
   <div v-if="shelvesError" class="cinema-alert" role="status">内容推荐暂不可用，仍可浏览下方影片。 <button type="button" class="account-action" @click="loadHomeShelves">重试</button></div>
   <div v-if="featuredFilm" class="cinema-featured" aria-label="影视库精选">
    <div class="cinema-featured-poster">
     <img v-if="(featuredFilm.posterURL||posterReady(featuredFilm))&&!posterFailed[featuredFilm.id]"
       :src="poster(featuredFilm)" :alt="featuredFilm.title+'海报'" loading="lazy" @error="posterFailed[featuredFilm.id]=true"/>
     <Film v-else :size="48"/>
    </div>
    <div class="cinema-featured-info">
     <span class="cinema-featured-kicker">{{featuredFilm.position>5&&!featuredFilm.completed?'继续观看':'来自你的影视库'}}</span>
     <h3>{{featuredFilm.title}}</h3>
     <p class="cinema-featured-meta">{{[featuredFilm.year||'',featuredFilm.kind==='series'?'剧集':'电影',duration(featuredFilm.durationSeconds||featuredFilm.duration)].filter(Boolean).join(' · ')}}</p>
     <p v-if="featuredFilm.overview" class="cinema-featured-description">{{featuredFilm.overview}}</p>
     <div class="cinema-featured-actions">
      <button type="button" class="cinema-featured-play" @click="open(featuredFilm,true)"><Play :size="18"/> {{featuredFilm.position>5&&!featuredFilm.completed?'继续播放':'开始播放'}}</button>
      <button type="button" class="cinema-featured-detail" @click="open(featuredFilm)">影片详情</button>
     </div>
    </div>
   </div>
   <div v-if="continueShelf.length" class="cinema-home-section">
    <div class="cinema-home-heading"><h3>继续观看</h3><button type="button" @click="filter('continue')">查看全部</button></div>
    <div class="cinema-home-rail" role="group" aria-label="继续观看的影片">
     <button v-for="movie in continueShelf" :key="movie.id" type="button" class="cinema-home-card" :aria-label="'继续观看 '+movie.title" @click="open(movie,true)">
      <span class="cinema-home-cover"><img v-if="(movie.posterURL||posterReady(movie))&&!posterFailed[movie.id]" :src="poster(movie)" :alt="movie.title+'海报'" loading="lazy" @error="posterFailed[movie.id]=true"/><Film v-else :size="32"/></span>
      <strong :title="movie.title">{{movie.title}}</strong><small>已看 {{percent(movie)}}%</small><span class="cinema-home-progress"><span :style="{width:percent(movie)+'%'}"></span></span>
     </button>
    </div>
   </div>
   <div v-if="recentShelf.length" class="cinema-home-section">
    <div class="cinema-home-heading"><h3>最近添加</h3><button type="button" @click="filter('all')">浏览全部</button></div>
    <div class="cinema-home-rail" role="group" aria-label="最近添加的影片">
     <button v-for="movie in recentShelf" :key="movie.id" type="button" class="cinema-home-card" :aria-label="'查看影片 '+movie.title" @click="open(movie)">
      <span class="cinema-home-cover"><img v-if="(movie.posterURL||posterReady(movie))&&!posterFailed[movie.id]" :src="poster(movie)" :alt="movie.title+'海报'" loading="lazy" @error="posterFailed[movie.id]=true"/><Film v-else :size="32"/></span>
      <strong :title="movie.title">{{movie.title}}</strong><small>{{movie.year||'影片'}} · {{duration(movie.durationSeconds||movie.duration)}}</small>
     </button>
    </div>
   </div>
  </section>
  <section v-if="query.trim()" class="cinema-home-section" aria-label="影视搜索结果">
   <div class="cinema-home-heading"><h3>剧集匹配</h3><small v-if="seriesSearchLoading" role="status">正在搜索剧集…</small></div>
   <p v-if="seriesSearchError" class="cinema-alert" role="alert">搜索剧集失败：{{seriesSearchError}} <button type="button" class="account-action" @click="searchForSeries(query.trim())">重试</button></p>
   <div v-if="matchingSeries.length" class="cinema-home-rail" role="group" aria-label="匹配的完整剧集">
    <button v-for="item in matchingSeries" :key="item.id" type="button" class="cinema-home-card" :aria-label="'查看剧集 '+item.name" @click="openSeries(item)">
     <span class="cinema-home-cover"><img v-if="item.posterURL" :src="item.posterURL" :alt="item.name+'海报'" loading="lazy"/><Tv v-else :size="32"/></span>
     <strong :title="item.name">{{item.name}}</strong><small>{{item.episodeCount}} 集 · {{item.year||'年份未知'}}</small>
    </button>
   </div>
   <p v-else-if="!seriesSearchLoading&&!seriesSearchError" class="cinema-hint">没有匹配的完整剧集，可继续查看下方影片和单集。</p>
   <div class="cinema-home-heading"><h3>影片与单集匹配</h3></div>
  </section>
  <div v-if="view==='series'" class="cinema-tools">
   <span v-if="seriesLoading" class="cinema-hint" role="status">正在读取剧集库…</span>
   <span v-else-if="seriesError" class="cinema-alert" role="alert">剧集库读取失败：{{seriesError}} <button type="button" class="account-action" @click="loadSeries">重试</button></span>
   <span v-else-if="!seriesList.length" class="cinema-hint">还没有可聚合的剧集；将剧集文件（如 Show.S01E01.mkv）加入共享目录并扫描后，这里会按剧名聚合。</span>
   <span v-else class="cinema-hint">共 {{seriesList.length}} 部剧集</span>
  </div>
  <div v-if="view==='series'&&seriesList.length" class="cinema-grid">
   <article v-for="item in seriesList" :key="item.id" class="cinema-tile">
    <button class="cinema-poster" :aria-label="'查看剧集 '+item.name" @click="openSeries(item)">
     <img v-if="item.posterURL" :src="item.posterURL" :alt="item.name+'海报'" class="cinema-poster-image"/>
     <template v-else><Tv :size="44"/>
</template>
     <span class="cinema-play"><Play v-if="item.nextFilmId" :size="18" fill="currentColor"/><Tv v-else :size="18"/></span>
     <span class="cinema-label">{{item.year||"剧集"}}</span>
    </button>
    <div class="cinema-details">
     <strong :title="item.name">{{item.name}}</strong>
     <small>已看 {{item.watchedCount}}/{{item.episodeCount}} 集</small>
     <small v-if="item.inProgress&&item.nextTitle" class="badge-prog">继续：{{item.nextTitle}}</small>
     <small v-else-if="item.watchedCount>=item.episodeCount&&item.episodeCount" class="badge-done">已看完</small>
     <button v-if="item.nextFilmId" @click="continueSeries(item)" title="继续观看"><Play :size="14"/></button>
    </div>
   </article>
  </div>
  <div v-if="view==='films'&&mode!=='history'&&!movies.length&&(loadError||actionError||scanActionError||scanStatusError||scanStatusLoaded&&scan.lastError)" class="cinema-empty" role="alert">
   <Clapperboard :size="48"/><h3>{{loadError?"暂时无法读取影视库":actionError?"操作未完成":scanActionError?"扫描无法启动":scanStatusError?"无法确认扫描状态":"上次扫描未完成"}}</h3>
   <p>{{loadError?"加载影视库失败："+loadError:actionError||scanActionError||(scanStatusError?"扫描状态暂不可用："+scanStatusError:"上次扫描未完成："+describeUserFacingError(scan.lastError))}}</p>
   <button v-if="loadError" type="button" class="refresh" :disabled="loading" @click="retryLoad">重试读取影视库</button>
   <button v-if="scanStatusError" type="button" class="refresh" :disabled="scanStatusLoading" @click="status">重试读取扫描状态</button>
   <button v-if="admin&&(!loadError||scanActionError||scan.lastError)" type="button" class="refresh" :disabled="scan.running&&!scanStatusError" @click="startScan">重新扫描</button>
   <p v-if="!admin">可在设置的「缺失媒体」中重新检查自己的目录；其他目录请联系管理员。</p>
  </div>
  <div v-else-if="view==='films'&&mode!=='history'&&!movies.length&&(loading||!pageLoaded||!scanStatusLoaded&&!scanStatusError||scan.running&&!scanStatusError)" class="cinema-empty"><Clapperboard :size="48"/><h3>{{scan.running&&!scanStatusError?"正在扫描影视库…":!scanStatusLoaded&&!scanStatusError?"正在确认扫描状态…":"正在读取影视库…"}}</h3><p>正在检查 Mac 授权的共享目录。</p></div>
  <div v-else-if="view==='films'&&mode!=='history'&&!movies.length&&!(query.trim()&&matchingSeries.length)" class="cinema-empty"><Clapperboard :size="48"/><h3>{{emptyTitle}}</h3><p>{{emptyMessage}}</p><button v-if="filteredView" type="button" class="refresh" @click="resetFilters">查看全部影片</button></div>
  <div v-if="view==='films'&&mode==='history'" class="cinema-tools">
   <span v-if="historyLoading" class="cinema-hint" role="status">正在读取历史记录…</span>
   <span v-else-if="historyError" class="cinema-alert" role="alert">历史读取失败：{{historyError}} <button type="button" class="account-action" @click="loadHistory(true)">重试</button></span>
   <span v-else-if="!historyFilms.length" class="cinema-hint">还没有观看记录；播放过的影片和剧集会按时间出现在这里。</span>
   <span v-else class="cinema-hint">共 {{historyFilms.length}} 条记录（仅当前账号可见）
    <button type="button" class="account-action" @click="clearHistory">清空历史</button></span>
  </div>
  <div v-if="view==='films'&&mode==='history'" class="cinema-grid">
   <article v-for="movie in historyFilms" :key="movie.id" class="cinema-tile">
    <button class="cinema-poster" @click="open(movie,true)">
     <img v-if="(movie.posterURL||posterReady(movie))&&!posterFailed[movie.id]" :src="poster(movie)" :alt="movie.title+'海报'" class="cinema-poster-image" @error="posterFailed[movie.id]=true"/>
     <template v-else><Tv v-if="movie.kind==='series'" :size="44"/><Film v-else :size="44"/></template>
     <span class="cinema-play"><Play :size="18" fill="currentColor"/></span>
     <span class="cinema-label">{{movie.updatedAt?new Date(movie.updatedAt*1000).toLocaleDateString():""}}</span>
     <span class="cinema-watchbar" :style="{width:percent(movie)+'%'}"></span>
    </button>
    <div class="cinema-details">
     <strong :title="movie.title">{{movie.title}}</strong>
     <small>{{movie.completed?"已看完":"看到 "+percent(movie)+"%"}} · {{duration(movie.durationSeconds||movie.duration)}}</small>
     <button v-if="movie.position>5&&!movie.completed" @click="markWatched(movie,false);open(movie,true)" title="从头播放"><RotateCcw :size="14"/></button>
    </div>
   </article>
  </div>
  <div v-if="view==='films'&&mode!=='history'" class="cinema-grid">
   <article v-for="movie in movies" :key="movie.id" class="cinema-tile">
    <button class="cinema-poster" :aria-label="choosingTrash?'选择 '+movie.title:'查看影片 '+movie.title"
      :aria-pressed="choosingTrash?trashIDs.has(movie.id):undefined"
      :style="choosingTrash&&trashIDs.has(movie.id)?{outline:'3px solid var(--accent-primary)'}:undefined"
      @click="choosingTrash?toggleTrashFilm(movie.id):open(movie)">
     <img v-if="(movie.posterURL||posterReady(movie))&&!posterFailed[movie.id]" :src="poster(movie)" :alt="movie.title+'海报'" class="cinema-poster-image" @error="posterFailed[movie.id]=true"/>
     <template v-else><Tv v-if="movie.kind==='series'" :size="44"/><Film v-else :size="44"/></template>
     <span class="cinema-play"><Download v-if="playback(movie)==='download-only'" :size="18"/><Play v-else :size="18" fill="currentColor"/></span>
     <span class="cinema-label">{{movie.kind==='series'?'S'+movie.season+'E'+movie.episode:(movie.year||'电影')}}</span>
     <span v-if="choosingTrash" class="cinema-label" style="left:auto;right:8px">{{trashIDs.has(movie.id)?"✓":"○"}}</span>
     <span class="cinema-watchbar" :style="{width:percent(movie)+'%'}"></span>
    </button>
    <div class="cinema-details">
     <strong :title="movie.title">{{movie.title}}</strong>
     <small>{{movie.kind==='series'?'电视剧':'电影'}} · {{duration(movie.durationSeconds||movie.duration)}}</small>
     <small v-if="formatLabel(movie)" class="cinema-format">{{formatLabel(movie)}}</small>
     <small v-if="movie.completed" class="badge-done">已看完</small>
     <small v-else-if="movie.position>5" class="badge-prog">已看 {{percent(movie)}}%</small>
     <small v-if="!movie.metadataSource" class="badge-warn">{{movie.scrapeState==='miss'?'自动未命中 · 待手动匹配':'待匹配资料'}}</small>
     <small v-if="playback(movie)!=='verified-direct'" class="badge-warn">{{playbackLabel(movie)}}</small>
     <button v-if="admin" @click="rename(movie)" title="修改展示名称"><Pencil :size="14"/></button>
     <button v-if="(admin||movie.canWrite===true)&&!choosingTrash" :disabled="deleting" @click="trashFilms([movie])" title="移入回收站"><Trash2 :size="14"/></button>
    </div>
   </article>
  </div>
  <div v-if="view==='films'&&mode!=='history'" class="cinema-more"><button v-if="next" :disabled="loading" @click="load()">{{loading?"正在加载…":"加载更多作品"}}</button><span v-else-if="movies.length">已展示全部 {{movies.length}} 部作品</span></div>
  <details class="cinema-foot"><summary>播放格式与兼容性说明</summary><p>已验证格式优先直接播放原文件；不兼容时可尝试在线转码（需要 FFmpeg，且不会修改原片）或保存后用 IINA/VLC 打开。</p></details>
 </div>
 <Teleport to="body">
 <div v-if="selected" class="cinema-backdrop" :class="{'cinema-backdrop--media':!!seriesDetail,'cinema-backdrop--playing':viewerPlaying}" @click.self="close">
  <section ref="cinemaDialog" class="cinema-dialog" :class="{'cinema-dialog-playing':viewerPlaying}" role="dialog" aria-modal="true" :aria-label="selected.title+(viewerPlaying?' · 播放':' · 影片详情')" tabindex="-1">
   <header :class="{'cinema-player-topbar':viewerPlaying}">
    <div><strong>{{selected.title}}</strong><small>{{selected.kind==='series'?'第 '+selected.season+' 季 · 第 '+selected.episode+' 集':'电影'}} · {{selected.year||'年份未知'}} · {{duration(selected.durationSeconds||selected.duration)}}</small></div>
    <div class="cinema-actions">
     <button v-if="viewerPlaying" type="button" class="cinema-top-pill" title="同目录播放列表" :aria-expanded="showPlayerPlaylist" :disabled="leavingPlayer" @click="togglePlayerPlaylist">播放列表 ({{sameDirectoryFilms.length}})</button>
     <button v-if="viewerPlaying" type="button" class="cinema-top-pill" title="返回影片详情" aria-label="返回影片详情" :disabled="leavingPlayer" @click="returnToOverview">{{leavingPlayer?"正在保存…":"返回详情"}}</button>
     <button type="button" title="关闭" aria-label="关闭影片详情" :disabled="leavingPlayer" @click="close"><X :size="19"/></button>
    </div>
   </header>
   <div v-if="exitSaveBlocked" class="cinema-alert" role="alert">
    当前影片的观看进度未保存，已暂停播放。请重试保存，或明确选择放弃本次未保存的进度。
    <button type="button" class="account-action" :disabled="leavingPlayer" @click="leavePlayer('close')">重试保存并关闭</button>
    <button type="button" class="account-action" :disabled="leavingPlayer" @click="leavePlayer('close',true)">仍然关闭（不保存）</button>
   </div>
   <div v-if="!viewerPlaying" class="cinema-overview">
    <div class="cinema-overview-poster"><img v-if="(selected.posterURL||posterReady(selected))&&!posterFailed[selected.id]" :src="poster(selected)" :alt="selected.title+'海报'" @error="posterFailed[selected.id]=true"/><Film v-else :size="56"/></div>
    <div class="cinema-overview-text">
     <h3>{{selected.title}}</h3>
     <p v-if="selected.overview" class="cinema-synopsis">{{selected.overview}}</p>
     <p v-else class="cinema-metadata-source">暂无影片简介，仍可播放或保存原文件。</p>
     <p v-if="selected.position>5&&!selected.completed" class="resume-hint">上次播放到 {{duration(selected.position)}}</p>
     <button type="button" class="dl-btn" :disabled="selected.probeStatus==='pending'&&playback(selected)==='download-only'" @click="playSelected"><Play :size="16"/> {{selected.position>5&&!selected.completed?'继续观看':'开始播放'}}</button>
     <p v-if="playback(selected)==='download-only'" class="cinema-metadata-source">{{playbackLabel(selected)}}，可尝试在线转码或保存原文件。</p>
    </div>
   </div>
   <div v-if="!viewerPlaying&&sameDirectoryFilms.length>1" class="cinema-overview-playlist" role="region" aria-label="同目录播放列表">
    <div class="cinema-overview-playlist-head"><strong>同目录播放列表（{{sameDirectoryFilms.length}}）</strong><small>{{playlistDirectory(selected.path)}}</small></div>
    <div class="cinema-overview-playlist-items">
     <button v-for="item in sameDirectoryFilms" :key="item.id" type="button" class="cinema-episode" :class="{active:item.id===selected.id}" :disabled="leavingPlayer" @click="switchPlaylistFilm(item,true)">{{item.title}} <span v-if="item.id===selected.id" class="badge-prog">当前选中</span></button>
    </div>
   </div>
   <div v-if="viewerPlaying" class="cinema-player-stage">
   <video v-if="canAttemptDirect(selected)&&!hlsSession&&!hlsStarting" ref="player" :src="stream(selected)" controls playsinline preload="metadata"
    @loadedmetadata="loaded" @timeupdate="tick" @pause="save()" @ended="playbackEnded"
    @error="playError='浏览器无法解码该视频格式。可下载原片后使用 IINA 或 VLC 播放，原视频不会被修改。'">
    <track v-if="caption!=='off'" :key="caption" kind="subtitles" :src="track(selected)" :srclang="captionSrclang()" label="字幕" default @load="changeCaption"/>
   </video>
   <video v-if="hlsSession" ref="hlsPlayer" controls playsinline preload="auto"
    @loadedmetadata="loaded" @timeupdate="tick" @pause="save()" @ended="playbackEnded"
    @error="playError=playError||'转码播放出错，可重新尝试或下载原片。'">
    <track v-if="caption!=='off'" :key="caption" kind="subtitles" :src="track(selected)" :srclang="captionSrclang()" label="字幕" default @load="changeCaption"/>
   </video>
   <div v-if="hlsStarting&&!hlsSession" class="cinema-stage-notice" role="status">转码启动中，正在准备播放…</div>
   </div>
   <div v-if="viewerPlaying&&(canAttemptDirect(selected)||hlsSession)" class="cinema-seek-controls">
    <button type="button" class="dl-btn" title="快退10秒（键盘左箭头）" :disabled="hlsStarting" @click="jumpPlayback(-10)">−10 秒</button>
    <label v-if="hlsSession&&playbackDuration>0" class="cinema-absolute-progress">
     <span>{{duration(seekPreview??playbackPosition)}}</span>
     <input type="range" min="0" :max="playbackDuration" step="1" :value="seekPreview??playbackPosition" :disabled="hlsStarting"
      aria-label="原片播放进度" @input="seekPreview=Number(($event.target as HTMLInputElement).value)" @change="seekAbsolute(Number(($event.target as HTMLInputElement).value))"/>
     <span>{{duration(playbackDuration)}}</span>
    </label>
    <button type="button" class="dl-btn" title="快进10秒（键盘右箭头）" :disabled="hlsStarting" @click="jumpPlayback(10)">+10 秒</button>
    <button type="button" class="dl-btn" title="切换全屏" @click="toggleCinemaFullscreen">全屏</button>
    <button v-if="canPictureInPicture" type="button" class="dl-btn" title="画中画" @click="toggleCinemaPictureInPicture">画中画</button>
   </div>
   <div v-if="viewerPlaying&&showPlayerPlaylist" class="cinema-player-inspector-backdrop" @click.self="showPlayerPlaylist=false">
    <section class="cinema-player-playlist" role="region" aria-label="同目录播放列表">
     <div class="cinema-inspector-header">
      <div><strong>同目录播放列表</strong><small class="cinema-playlist-sub">{{playlistDirectory(selected.path)}} · {{sameDirectoryFilms.length}} 个视频</small></div>
      <button type="button" title="关闭播放列表" @click="showPlayerPlaylist=false"><X :size="18"/></button>
     </div>
     <div v-if="directoryError" class="cinema-alert" role="alert">读取失败：{{directoryError}} <button type="button" @click="loadDirectoryPlaylist(selected)">重试加载</button></div>
     <p v-if="directoryLoading" class="cinema-hint" role="status">正在读取当前目录…</p>
     <div class="cinema-playlist-list">
      <button v-for="(item,index) in sameDirectoryFilms" :key="item.id" type="button" class="cinema-playlist-item" :class="{active:item.id===selected.id}" :disabled="leavingPlayer" @click="switchPlaylistFilm(item,true)">
       <span class="cinema-playlist-index">{{index+1}}</span>
       <span class="cinema-playlist-main"><strong>{{item.title}}</strong><small>{{item.path.split('/').pop()}} · {{duration(item.durationSeconds||item.duration)}}</small></span>
       <span v-if="item.id===selected.id" class="cinema-playlist-badge">正在播放</span>
      </button>
     </div>
     <button v-if="directoryNextCursor>0" type="button" class="btn-secondary" :disabled="directoryLoading" @click="loadDirectoryPlaylist(selected,true)">加载更多</button>
     <label><input type="checkbox" :checked="autoplayNext" @change="setAutoplayNext(($event.target as HTMLInputElement).checked)"/>自动连播</label>
    </section>
   </div>
   <div v-if="viewerPlaying&&playError" class="cinema-alert" role="alert">{{playError}}</div>
   <div v-if="viewerPlaying&&!canAttemptDirect(selected)&&!hlsSession&&!hlsStarting&&selected.probeStatus!=='pending'" class="cinema-actions">
    <button class="dl-btn" @click="startTranscode(selected,selected.position>5?selected.position:0,0)"><Play :size="15"/> 在线转码播放（原片不变）</button>
   </div>
   <p v-if="!viewerPlaying&&(selected.titleSource||selected.yearSource||selected.metadataSource)" class="cinema-metadata-source">
    片名：{{metadataSourceName(selected.titleSource)}} · 年份：{{metadataSourceName(selected.yearSource)}} · 简介/评分：{{selected.metadataSource?metadataSourceName(selected.metadataSource):"无已确认来源"}}
    <span v-if="selected.rating"> · 评分 {{selected.rating.toFixed(1)}} / 10</span>
   </p>
   <p v-if="!viewerPlaying&&scrapeMessage" class="cinema-alert" role="status">{{scrapeMessage}}</p>
   <details v-if="!viewerPlaying&&admin" class="cinema-tmdb-panel">
    <summary>豆瓣网页搜索建议 · 备用匹配（实验性，无跳转）</summary>
    <p>仅在点击搜索时请求豆瓣网页使用的影视搜索建议，直接显示片名和年份；这是非官方、可能失效且受网站使用条款约束的入口。不会自动抓取海报、评论或评分，不绕过网站的访问限制。</p>
    <form class="cinema-tmdb-form" @submit.prevent="searchDouban">
     <input v-model="doubanQuery" type="search" maxlength="60" aria-label="豆瓣影片搜索关键词" placeholder="输入电影或剧集名称" :disabled="doubanBusy||scraping||tmdbBusy"/>
     <button type="submit" :disabled="doubanBusy||scraping||tmdbBusy">{{doubanBusy?"正在查询…":"在此搜索豆瓣候选"}}</button>
    </form>
    <p v-if="doubanError" class="cinema-alert" role="alert">{{doubanError}}</p>
    <div v-for="candidate in doubanMatches" :key="candidate.id" class="cinema-tmdb-match">
     <div class="cinema-tmdb-match-text"><strong>{{candidate.title}} {{candidate.year?"("+candidate.year+")":""}}</strong><small>网页搜索建议 · {{candidate.kind==="tv"?"剧集":"影片"}} · 不含评分和海报</small></div>
     <button type="button" :disabled="doubanBusy||tmdbBusy||scraping" @click="matchDouban(candidate)">确认匹配</button>
    </div>
   </details>
   <details v-if="!viewerPlaying&&admin" class="cinema-tmdb-panel">
    <summary>从 TMDB 在线匹配电影 / 剧集资料</summary>
    <p>若已在 Mac 端配置 TMDB Token，直接输入影视名称搜索即可；也可临时输入自定义 Read Access Token（仅用于当前请求，不存储在数据库）。选中候选结果后才会保存对应资料。</p>
    <form class="cinema-tmdb-form" @submit.prevent="searchTMDB">
     <input v-model="tmdbToken" type="password" autocomplete="off" spellcheck="false" placeholder="TMDB API Read Access Token（可选，留空使用 Mac 已配置 Token）" aria-label="TMDB API Read Access Token" :disabled="tmdbBusy||scraping"/>
     <input v-model="tmdbQuery" type="search" maxlength="120" placeholder="影视名称" aria-label="TMDB 搜索关键词" :disabled="tmdbBusy||scraping"/>
     <button type="submit" :disabled="tmdbBusy||scraping">{{tmdbBusy?"查询中…":scraping?"正在导入…":"搜索 TMDB"}}</button>
    </form>
    <p v-if="tmdbError" class="cinema-alert" role="alert">{{tmdbError}}</p>
    <div v-for="candidate in tmdbMatches" :key="candidate.id" class="cinema-tmdb-match">
     <img v-if="candidate.posterURL&&!candidatePosterFailed[candidate.id]" :src="candidate.posterURL" :alt="candidate.title+'海报'" loading="lazy" @error="candidatePosterFailed[candidate.id]=true"/>
     <div v-else class="cinema-tmdb-poster-placeholder" aria-hidden="true"><Film :size="22"/></div>
     <div class="cinema-tmdb-match-text"><strong>{{candidate.title}} {{candidate.year?"("+candidate.year+")":""}}</strong><small>评分 {{candidate.rating.toFixed(1)}} / 10</small><p v-if="candidate.overview">{{candidate.overview}}</p></div>
     <button type="button" :disabled="tmdbBusy||scraping" @click="matchTMDB(candidate)">选择匹配</button>
    </div>
    <p class="cinema-metadata-source">This product uses the TMDB API but is not endorsed or certified by TMDB. <a href="https://www.themoviedb.org/" rel="noopener noreferrer" target="_blank">TMDB</a></p>
   </details>
   <footer :class="{'cinema-player-dock':viewerPlaying}">
    <button v-if="!viewerPlaying&&(admin||selected.canWrite===true)&&selected.path&&movies.some(movie=>movie.id===selected!.id)" type="button" class="dl-btn" :disabled="deleting" @click="trashFilms([selected])"><Trash2 :size="14"/> 移入回收站</button>
    <div v-if="canAttemptDirect(selected)||hlsSession" class="cinema-ctrl-field"><Subtitles :size="16"/><span>字幕</span><AppleSelect v-model="caption" :options="captionOptions" size="sm" aria-label="字幕" @change="changeCaption" /></div>
    <div v-if="hlsSession&&(hlsTracks?.audio?.length??0)>1" class="cinema-ctrl-field"><AudioLines :size="16"/><span>音轨</span><AppleSelect :model-value="hlsSession.audioTrack" :options="audioTrackOptions" size="sm" aria-label="音轨" @change="switchAudioTrack(Number($event))" /></div>
    <div class="cinema-ctrl-field"><Gauge :size="16"/><span>清晰度</span><AppleSelect :model-value="currentQuality" :options="cinemaQualityOptions" :disabled="hlsStarting" size="sm" aria-label="清晰度" @change="switchQuality(String($event))" /></div>
    <div class="cinema-ctrl-field"><Gauge :size="16"/><span>倍速</span><AppleSelect :model-value="playbackRate" :options="playbackRateOptions" size="sm" aria-label="倍速" @change="setPlaybackRate(Number($event))" /></div>
    <label title="开启后即使安装了 FFmpeg 也优先直传原始视频由本地硬件解码"><input type="checkbox" :checked="preferLocalDecode" @change="setPreferLocalDecode(($event.target as HTMLInputElement).checked)"/>本地解码</label>
    <label v-if="selected.path"><input type="checkbox" :checked="autoplayNext" @change="setAutoplayNext(($event.target as HTMLInputElement).checked)"/>{{selected.kind==='series'?'播完自动下一集':'播完自动连播'}}</label>
    <span v-if="hlsSession" class="resume-hint">{{hlsSession.profile==="remux"?"转封装播放（无画质损失）":"转码播放中"}} · 进度按原片时间轴保存</span>
    <span v-else-if="selected.position>5&&!selected.completed" class="resume-hint">上次播至 {{duration(selected.position)}}</span>
    <button v-if="!viewerPlaying" class="dl-btn" @click="download(selected)">下载原片文件</button>
    <button v-if="!viewerPlaying" class="dl-btn" @click="markWatched(selected,!selected.completed)">{{selected.completed?"标记未看":"标记已看"}}</button>
    <button v-if="!viewerPlaying&&selected.position>5&&!selected.completed" class="dl-btn" @click="markWatched(selected,false);open(selected,true)">从头播放</button>
    <button v-if="!viewerPlaying&&admin" class="dl-btn" :disabled="scraping||tmdbBusy" @click="importLocalNFO(selected)">{{scraping?"读取中…":tmdbBusy?"正在处理资料…":"导入本地 NFO 资料"}}</button>
   </footer>
  </section>
 </div>
 </Teleport>
 <Teleport to="body">
 <div v-if="seriesDetail" class="cinema-backdrop" @click.self="closeSeries">
  <section ref="seriesDialog" class="cinema-dialog" role="dialog" aria-modal="true" :aria-label="seriesDetail.series.name+' · 剧集列表'" tabindex="-1">
   <header><div><strong>{{seriesDetail.series.name}}</strong><small>{{seriesDetail.series.year||"剧集"}} · 已看 {{seriesDetail.series.watchedCount}}/{{seriesDetail.series.episodeCount}} 集<template v-if="seriesDetail.series.tmdbId"> · TMDB</template></small></div><button title="关闭" @click="closeSeries"><X :size="19"/></button></header>
   <p v-if="seriesDetail.series.overview" class="cinema-synopsis">{{seriesDetail.series.overview}}</p>
   <div v-if="seriesDetailLoading" class="cinema-alert" role="status">正在读取剧集分集…</div>
   <div v-if="seriesDetailError" class="cinema-alert" role="alert">{{seriesDetailError}}</div>
   <div v-for="season in seasonNumbers(seriesDetail.films)" :key="season" class="cinema-season">
    <h4>第 {{season}} 季</h4>
    <button v-for="episode in seriesDetail.films.filter(f=>f.season===season)" :key="episode.id" class="cinema-episode" @click="open(episode,true)"><span class="cinema-episode-no">E{{episode.episode}}</span><span class="cinema-episode-title">{{episode.title}}</span><span class="cinema-episode-meta">{{duration(episode.durationSeconds||episode.duration)}}</span><span v-if="episode.completed" class="badge-done">已看完</span><span v-else-if="episode.position>5" class="badge-prog">已看 {{percent(episode)}}%</span></button>
   </div>
   <p v-if="seriesTmdbMessage" class="cinema-alert" role="status">{{seriesTmdbMessage}}</p>
   <details v-if="admin" class="cinema-tmdb-panel">
    <summary>匹配 TMDB 剧集资料（使用 Mac App 配置的 Token）</summary>
    <form class="cinema-tmdb-form" @submit.prevent="matchSeriesTMDB(seriesDetail.series)">
     <input v-model="seriesTmdbId" type="text" inputmode="numeric" placeholder="TMDB 剧集 ID（数字，可在 themoviedb.org 剧集页地址中找到）" :disabled="seriesTmdbBusy"/>
     <button type="submit" :disabled="seriesTmdbBusy">{{seriesTmdbBusy?"匹配中…":"匹配"}}</button>
    </form>
   </details>
  </section>
 </div>
 </Teleport>
</template>
<style scoped src="./CinemaView.css"></style>
