<script setup lang="ts">
import {ref,computed,onMounted,onBeforeUnmount,onUnmounted,watch,nextTick} from "vue";
import type Hls from "hls.js";
import {describeRootOperationFailure} from "./rootDiscovery.js";
import {Clapperboard,Film,Tv,Play,Download,Search,RefreshCcw,X,Subtitles,Pencil,AudioLines,Wand2,Gauge,RotateCcw} from "lucide-vue-next";
import {createLatestRequestGate} from "./latestRequestGate.js";
import {createMediaStatusPoller} from "./mediaStatusPoller.js";
import {createPlaybackProgressWriter,type ProgressSnapshot} from "./playbackProgressWriter.js";
import {mediaQueryKey,transitionMediaQuery} from "./mediaQueryContext.js";
import {rootApiPath,rootMediaPath} from "./rootApi.js";
import {tmdbCandidateScore} from "./cinemaCandidateScore.js";
import {isTMDBAuthenticationFailure,runSequentialTMDBBatch} from "./tmdbBatch.js";
type BrowserPlayback="verified-direct"|"unverified-direct"|"download-only";
type ProbeStatus="pending"|"ready"|"unsupported"|"unavailable"|"failed";
type Movie={id:number;title:string;path:string;kind:string;series:string;season:number;episode:number;year:number;size:number;playable?:boolean;browserPlayback?:BrowserPlayback;probeStatus?:ProbeStatus;mime?:string;container?:string;videoCodec?:string;audioCodec?:string;durationSeconds?:number;width?:number;height?:number;position:number;duration:number;completed:boolean;updatedAt?:number;overview?:string;rating?:number;metadataSource?:string;titleSource?:string;yearSource?:string;posterURL?:string};
type TMDBCandidate={id:number;kind:string;title:string;year?:string;overview?:string;rating:number;posterURL?:string};
type DoubanCandidate={id:string;title:string;year?:string;kind?:string};
type Scan={running:boolean;visited:number;found:number;lastDone:number;lastError?:string};
type TranscodeSession={sessionId:string;start:number;profile:"remux"|"transcode";audioTrack:number;quality:string;ready:boolean};
type AudioTrackInfo={streamIndex:number;audioIndex:number;codec?:string;language?:string;title?:string;channels?:number};
type SubtitleTrackInfo={streamIndex:number;codec?:string;language?:string;title?:string;extractable:boolean};
type TrackInfo={videoCodec?:string;height?:number;durationSeconds?:number;audio:AudioTrackInfo[];subtitles:SubtitleTrackInfo[]};
type SeriesInfo={id:number;name:string;tmdbId?:number;overview?:string;posterURL?:string;episodeCount:number;watchedCount:number;year?:number;nextFilmId?:number;nextTitle?:string;inProgress?:boolean;position?:number;duration?:number};
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
const selected=ref<Movie|null>(null),player=ref<HTMLVideoElement|null>(null);
const posterFailed=ref<Record<number,boolean>>({});
const candidatePosterFailed=ref<Record<number,boolean>>({});
const scraping=ref(false),scrapeMessage=ref("");
const tmdbQuery=ref(""),tmdbToken=ref(""),tmdbMatches=ref<TMDBCandidate[]>([]);
const tmdbBusy=ref(false),tmdbError=ref("");
type BatchCandidate={filmId:number;filmTitle:string;match:TMDBCandidate;score:number};
const batchToken=ref(""),batchBusy=ref(false),batchError=ref(""),batchProgress=ref("");
const batchCandidates=ref<BatchCandidate[]>([]);
let batchController:AbortController|undefined;
function cancelBatch(){
 batchController?.abort();batchController=undefined;
 batchBusy.value=false;batchToken.value="";batchCandidates.value=[];batchProgress.value="";
}
function tmdbErrorMessage(error:unknown){
 if(isTMDBAuthenticationFailure(error))return "TMDB 拒绝了该访问令牌或其权限（401/403）。请检查 Read Access Token 是否有效且有访问权限。";
 return error instanceof Error?error.message:"请求失败";
}
async function suggestBatch(){
 if(!props.admin||batchBusy.value)return;
 if(batchToken.value.trim().length<20){batchError.value="输入自己的 TMDB Read Access Token（仅保留在本页内存）。";return}
 const target=movies.value.filter(f=>!f.metadataSource&&!f.titleSource).slice(0,8);
 if(!target.length){batchError.value="当前已加载的列表中没有需要匹配的影片。";return}
 const rootID=props.rootId,generation=props.rootGeneration??0;
 batchController?.abort();
 const request=new AbortController();batchController=request;
 const fresh=()=>!disposed&&!request.signal.aborted&&batchController===request&&
   rootID===props.rootId&&generation===(props.rootGeneration??0);
 batchBusy.value=true;batchError.value="";batchCandidates.value=[];
 try{
  const result=await runSequentialTMDBBatch(target,async film=>{
   const response=await api<{results:TMDBCandidate[]}>(apiPath("/api/v1/cinema/"+film.id+"/metadata/tmdb/search"),
    "POST",{accessToken:batchToken.value,query:film.title},request.signal);
   return response.results.map(c=>({filmId:film.id,filmTitle:film.title,match:c,score:tmdbCandidateScore(film,c)}))
    .sort((a,b)=>b.score-a.score);
  },{
   isCurrent:fresh,
   onProgress:(film,index,total)=>{batchProgress.value=`正在分析 ${index+1}/${total}：${film.title}`},
   onResult:(_film,ranked)=>{if(ranked.length&&ranked[0].score>=60)batchCandidates.value.push(ranked[0])}
  });
  if(!fresh())return;
  if(result.status==="auth-rejected"){
   batchToken.value="";batchCandidates.value=[];
   batchError.value="TMDB 拒绝了该访问令牌或其权限（401/403）。已停止后续查询并清除令牌；请检查 Read Access Token 后重试。";
   batchProgress.value="认证失败，未查询剩余影片。";
  }else if(result.status==="completed"){
   batchError.value=result.hadFailures?"部分匹配查询失败；可稍后重试。不会自动修改现有影片。":"";
   batchProgress.value=result.hadFailures
    ?"候选建议已生成；部分影片未能查询。"
    :"匹配建议生成完成；必须逐条确认才会保存。";
  }
 }catch(e){if(fresh())batchError.value="批量查询失败："+tmdbErrorMessage(e)}
 finally{if(fresh())batchBusy.value=false}
}
async function acceptBatchCandidate(item:BatchCandidate){
 if(!props.admin||batchBusy.value||!batchToken.value)return;
 const film=movies.value.find(v=>v.id===item.filmId);
 if(!film||!window.confirm("确认将「"+item.match.title+"」的 TMDB 信息写入「"+item.filmTitle+"」？每部影片需独立确认。"))return;
 batchBusy.value=true;batchError.value="";
 try{
  const updated=await api<Movie>(apiPath("/api/v1/cinema/"+item.filmId+"/metadata/tmdb/match"),
    "POST",{accessToken:batchToken.value,tmdbId:item.match.id});
  movies.value=movies.value.map(v=>v.id===item.filmId?{...v,...updated}:v);
  batchCandidates.value=batchCandidates.value.filter(v=>v.filmId!==item.filmId);
 }catch(e){
  if(isTMDBAuthenticationFailure(e)){
   batchToken.value="";batchCandidates.value=[];
   batchError.value="TMDB 拒绝了该访问令牌或其权限（401/403）。已停止后续确认并清除令牌；请检查 Read Access Token 后重试。";
  }else batchError.value="无法保存「"+item.filmTitle+"」："+tmdbErrorMessage(e);
 }
 finally{batchBusy.value=false}
}
const doubanQuery=ref(""),doubanMatches=ref<DoubanCandidate[]>([]);
const doubanBusy=ref(false),doubanError=ref("");
const caption=ref("off"),playError=ref("");
// Transcode (HLS) playback for download-only sources. The muxer writes
// segments from the requested start; the player timeline begins at zero, so
// every progress value is offset by session.start before being saved.
const hlsSession=ref<TranscodeSession|null>(null);
const hlsTracks=ref<TrackInfo|null>(null);
const hlsStarting=ref(false);
let hls:Hls|null=null;
const hlsPlayer=ref<HTMLVideoElement|null>(null);
const hlsQuality=ref("source");
const playbackRate=ref(1);
// Watch-history view state.
const historyFilms=ref<Movie[]>([]);
const historyNext=ref(0);
const historyLoading=ref(false),historyError=ref(""),historyLoaded=ref(false);
const transcodeStatus=ref<{available:boolean;reason?:string}|null>(null);
// Series aggregation view.
const view=ref<"films"|"series">("films");
const seriesList=ref<SeriesInfo[]>([]);
const seriesLoading=ref(false),seriesError=ref("");
const seriesDetail=ref<{series:SeriesInfo;films:Movie[]}|null>(null);
const seriesDetailLoading=ref(false),seriesDetailError=ref("");
const seriesTmdbId=ref(""),seriesTmdbBusy=ref(false),seriesTmdbMessage=ref("");
// Administrator automatic scrape (server-side TMDB backfill).
const scrapeState=ref<{running:boolean;operation:string;processed:number;matched:number;tmdbConfigured:boolean}|null>(null);
const scrapeBusy=ref(false),scrapeNotice=ref(""),scrapeError=ref("");
let scrapeTimer:number|undefined;
function transcodeErrorMessage(e:unknown){
 const code=e instanceof Error?e.message:"request_failed";
 switch(code){
  case "transcode_unavailable":return "未安装 FFmpeg，仅支持直接播放或下载原片；管理员可在本机执行 brew install ffmpeg 启用在线转码。";
  case "transcode_busy":return "转码通道被占用，请稍后重试。";
  case "transcode_failed":return "转码失败：该影片可能包含不兼容的编码，请下载后用 IINA 或 VLC 播放。";
  case "transcode_insufficient_space":return "存储空间不足，无法创建转码缓存，请清理空间后重试。";
  case "direct_playback_available":return "该影片可直接播放，无需转码。";
  case "transcode_start_timeout":return "转码启动超时，请稍后重试；若反复出现请下载原片播放。";
  default:return describeRootOperationFailure(e);
 }
}
const progressSaveError=ref("");
const progressWriter=createPlaybackProgressWriter(async snapshot=>{
 const headers=new Headers({"Content-Type":"application/json","X-LightIsle-Request":"1"});
 if(snapshot.rootId)headers.set("X-LightIsle-Root-Generation",String(snapshot.rootGeneration));
 const response=await fetch(snapshot.url,{method:"PUT",credentials:"same-origin",cache:"no-store",keepalive:true,
  headers,body:JSON.stringify({position:snapshot.position,duration:snapshot.duration,completed:snapshot.completed})});
 if(!response.ok)throw new Error("HTTP "+response.status);
},{
 onSaved:(snapshot:ProgressSnapshot)=>{
  if(snapshot.rootId!==(props.rootId??"")||snapshot.rootGeneration!==(props.rootGeneration??0))return;
  progressSaveError.value="";
  movies.value=movies.value.map(item=>item.id===snapshot.id?{...item,position:snapshot.position,duration:snapshot.duration,completed:snapshot.completed}:item);
  if(selected.value?.id===snapshot.id){selected.value.position=snapshot.position;selected.value.duration=snapshot.duration;selected.value.completed=snapshot.completed;}
 },
 onError:(_error:unknown,snapshot:ProgressSnapshot)=>{
  if(snapshot.rootId===(props.rootId??"")&&snapshot.rootGeneration===(props.rootGeneration??0))
   progressSaveError.value="播放进度尚未保存，网络恢复后请点击重试。离开当前影院页面后将无法再次重试。";
 }
});
function retryProgress(){void progressWriter.retry()}
let scanTimer:number|undefined,searchTimer:number|undefined,lastDone=0,lastSave=0;
let loadGeneration=0;
let disposed=false;
let rootEpoch=0;
watch([()=>props.rootId,()=>props.rootGeneration],()=>{
 rootEpoch+=1;loadGeneration+=1;cancelBatch();selectedController?.abort();cancelMetadataRequests();if(searchTimer)clearTimeout(searchTimer);
 scanStatusPoller.invalidate();movies.value=[];next.value=0;loading.value=false;pageLoaded.value=false;
 pageQueryKey=cinemaQueryKey();
 loadError.value="";actionError.value="";scanActionError.value="";scanStatusLoaded.value=false;scanStatusLoading.value=false;scanStatusError.value="";
 scan.value={running:false,visited:0,found:0,lastDone:0};lastDone=0;
 progressSaveError.value="";
 destroyHls();
 seriesList.value=[];seriesDetail.value=null;seriesError.value="";seriesDetailError.value="";
 historyFilms.value=[];historyNext.value=0;historyLoaded.value=false;historyError.value="";
 selected.value=null;playError.value="";player.value?.pause();
 void load(true);void status();void refreshScrape();
 if(view.value==="series")void loadSeries();
},{flush:"sync"});
let selectedController:AbortController|undefined;
const nfoRequests=createLatestRequestGate();
const tmdbSearchRequests=createLatestRequestGate();
const tmdbMatchRequests=createLatestRequestGate();
const doubanSearchRequests=createLatestRequestGate();
const doubanMatchRequests=createLatestRequestGate();
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
  throw new Error(data.error||"request_failed")}
 const result=await response.json() as T;
 if(rootID&&(props.rootId!==rootID||props.rootGeneration!==rootGeneration||disposed))throw makeRootAbortError();
 return result;
}
function makeRootAbortError(){const error=new Error("root_context_changed");error.name="AbortError";return error;}
const scanStatusPoller=createMediaStatusPoller(
 signal=>api<{status:Scan}>(apiPath("/api/v1/cinema/status"),"GET",undefined,signal),
 {
  onValue:value=>{
   const previous=scan.value.lastDone;
   scan.value=value.status;scanStatusLoaded.value=true;scanStatusError.value="";scanStatusLoading.value=false;
   if(!scan.value.running&&scan.value.lastDone&&scan.value.lastDone!==previous&&scan.value.lastDone!==lastDone){lastDone=scan.value.lastDone;void load(true)}
  },
  onError:value=>{scanStatusError.value=describeRootOperationFailure(value);scanStatusLoading.value=false;},
 },
);
function status(){scanStatusLoading.value=true;return scanStatusPoller.refresh()}
async function load(reset=false){
 if(loading.value&&!reset)return;
 const transition=transitionMediaQuery(pageQueryKey,cinemaQueryKey());
 if(transition.clearContent){
  pageQueryKey=transition.queryKey;movies.value=[];next.value=0;pageLoaded.value=false;posterFailed.value={};
 }
 const generation=++loadGeneration;
 loading.value=true;
 loadError.value="";
 try{
  const params=new URLSearchParams({limit:"48",cursor:String(reset?0:next.value)});
  if(mode.value!=="all")params.set("kind",mode.value);
  if(query.value.trim())params.set("query",query.value.trim());
  const page=await api<{films:Movie[];nextCursor:number}>(apiPath("/api/v1/cinema")+"?"+params);
  if(generation!==loadGeneration)return;
  movies.value=reset?page.films:[...movies.value,...page.films];next.value=page.nextCursor;if(reset){pageLoaded.value=true;actionError.value=""}loadError.value="";
 }catch(e){if(generation===loadGeneration&&!(e instanceof Error&&e.name==="AbortError")){loadError.value=describeRootOperationFailure(e);loadErrorReset.value=reset}}finally{if(generation===loadGeneration)loading.value=false}
}
function retryLoad(){void load(loadErrorReset.value)}
async function startScan(){
 const context=rootEpoch;scanActionError.value="";
 try{await api(apiPath("/api/v1/cinema/scan"),"POST");if(context!==rootEpoch)return;scanStatusPoller.invalidate();await status()}
 catch(e){if(context===rootEpoch)scanActionError.value=e instanceof Error?e.message:"无法开始扫描"}
}
function filter(value:string){if(searchTimer)clearTimeout(searchTimer);mode.value=value;if(value==="history"){void loadHistory(true);return}void load(true)}
watch(query,()=>{
 const transition=transitionMediaQuery(pageQueryKey,cinemaQueryKey());
 if(transition.clearContent){
  pageQueryKey=transition.queryKey;loadGeneration+=1;movies.value=[];next.value=0;loading.value=false;pageLoaded.value=false;
  loadError.value="";loadErrorReset.value=true;actionError.value="";posterFailed.value={};
 }
 if(searchTimer)clearTimeout(searchTimer);
 searchTimer=window.setTimeout(()=>void load(true),350);
},{flush:"sync"});
const filteredView=computed(()=>mode.value!=="all"||!!query.value.trim());
const emptyTitle=computed(()=>query.value.trim()?"没有找到匹配的影片":mode.value==="continue"?"还没有可继续观看的影片":mode.value==="movie"?"电影分类还没有内容":mode.value==="series"?"剧集分类还没有内容":"还没有影片");
const emptyMessage=computed(()=>query.value.trim()?"换个名称试试，或查看全部影片。":mode.value==="continue"?"播放影片后，可从这里继续上次的观看进度。":mode.value!=="all"?"可以查看全部影片，或将此类影视文件加入共享目录后重新扫描。":"将影视文件拷贝到 Mac 共享目录后，点击右上角「扫描影视库」。");
function resetFilters(){mode.value="all";query.value="";if(searchTimer){clearTimeout(searchTimer);searchTimer=undefined}void load(true)}
const continueCount=computed(()=>movies.value.filter(v=>v.position>5&&!v.completed).length);
function duration(v:number){if(!Number.isFinite(v)||v<=0)return "时长未知";if(v<60)return Math.ceil(v)+" 秒";const min=Math.floor(v/60);return min>=60?Math.floor(min/60)+"h "+min%60+"m":min+" 分钟"}
function playback(v:Movie):BrowserPlayback{return v.browserPlayback??(v.playable?"unverified-direct":"download-only")}
function metadataSourceName(value?:string){
 if(!value)return "文件名自动识别";
 if(value==="manual")return "手动命名";
 if(value==="legacy-confirmed")return "旧版已确认（具体来源未记录）";
 if(value.startsWith("tmdb:"))return "TMDB";
 if(value.startsWith("nfo:"))return "本地 NFO";
 if(value.startsWith("douban-suggest:"))return "豆瓣网页搜索建议";
 return "已确认的其他来源";
}
function canAttemptDirect(v:Movie){return playback(v)!=="download-only"}
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
function formatLabel(v:Movie){
 const values=[v.container?.toUpperCase(),v.videoCodec?.toUpperCase(),v.audioCodec?.toUpperCase()].filter(Boolean);
 return values.join(" · ");
}
function posterReady(v:Movie){return v.probeStatus==="ready"&&!posterFailed.value[v.id]}
function poster(v:Movie){return v.posterURL||mediaPath("/api/v1/cinema/"+v.id+"/poster")}
function percent(v:Movie){return v.duration?Math.min(100,Math.round(v.position/v.duration*100)):0}
function stream(v:Movie){return mediaPath("/api/v1/cinema/"+v.id+"/stream")}
function track(v:Movie){
 if(caption.value.startsWith("emb:"))return mediaPath("/api/v1/cinema/"+v.id+"/embedded-subtitles?track="+caption.value.slice(4));
 return mediaPath("/api/v1/cinema/"+v.id+"/subtitles"+(caption.value==="auto"?"":"?lang="+caption.value));
}
function captionLabel(v:SubtitleTrackInfo){
 const language=v.language==="chi"||v.language==="zh"?"中文":v.language==="eng"||v.language==="en"?"英文":(v.language||"内嵌");
 return "内嵌 "+language+"（"+(v.codec||"?")+"，样式简化）";
}
function download(v:Movie){const a=document.createElement("a");a.href=mediaPath("/api/v1/files/content?path="+encodeURIComponent(v.path));a.download=v.path.split("/").pop()||v.title;a.click()}
function destroyHls(){
 if(hls){hls.destroy();hls=null}
 hlsSession.value=null;hlsTracks.value=null;hlsStarting.value=false;
}
async function waitForPlaylist(v:Movie,session:TranscodeSession){
 const url=mediaPath("/api/v1/cinema/"+v.id+"/hls/"+session.sessionId+"/index.m3u8");
 for(let attempt=0;attempt<60;attempt++){
  if(selected.value?.id!==v.id)throw new Error("aborted");
  const response=await fetch(url,{method:"GET",credentials:"same-origin",cache:"no-store"});
  if(response.ok)return url;
  if(response.status===502)throw new Error("transcode_failed");
  await new Promise(resolve=>setTimeout(resolve,500));
 }
 throw new Error("transcode_start_timeout");
}
async function startTranscode(v:Movie,startSeconds=0,audio=0,quality="source"){
 if(hlsStarting.value)return;
 hlsStarting.value=true;playError.value="";
 destroyHls();hlsStarting.value=true;
 hlsQuality.value=quality;
 try{
  const session=await api<TranscodeSession>(apiPath("/api/v1/cinema/"+v.id+"/hls/session?start="+encodeURIComponent(startSeconds.toFixed(3))+"&audio="+audio+(quality&&quality!=="source"?"&quality="+quality:"")));
  if(selected.value?.id!==v.id)return;
  hlsSession.value=session;
  await nextTick();
  const video=hlsPlayer.value;
  if(!video)throw new Error("transcode_failed");
  const url=await waitForPlaylist(v,session);
  if(selected.value?.id!==v.id)return;
  if(video.canPlayType("application/vnd.apple.mpegurl")){
   video.src=url;
  }else{
   // Load the large HLS library only if the user actually needs transcoded
   // playback on a browser without native HLS support.
   const {default:Hls}=await import("hls.js");
   if(selected.value?.id!==v.id)return;
   if(!Hls.isSupported()){
    playError.value="当前浏览器不支持所需的媒体能力，请下载原片后使用本地播放器。";
    return;
   }
   // enableWorker:false keeps the page CSP clean (script-src 'self') and is
   // cheap here: fMP4 segments are appended, not transmuxed.
   hls=new Hls({enableWorker:false});
   hls.loadSource(url);
   hls.attachMedia(video);
   hls.on(Hls.Events.ERROR,(_event,data)=>{
    if(data.fatal&&selected.value?.id===v.id){
     playError.value="转码播放中断（"+(data.details||"media_error")+"）。可重新点击转码播放，或下载原片用 IINA/VLC 播放。";
    }
   });
  }
  try{hlsTracks.value=(await api<{tracks:TrackInfo}>(apiPath("/api/v1/cinema/"+v.id+"/tracks"))).tracks}catch{/* tracks are optional; playback continues without selectors */}
  applyPlaybackRate();
 }catch(e){
  if(selected.value?.id===v.id){destroyHls();playError.value=transcodeErrorMessage(e)}
 }
 finally{hlsStarting.value=false}
}
async function switchAudioTrack(audioIndex:number){
 const v=selected.value,session=hlsSession.value,p=hlsPlayer.value;
 if(!v||!session||hlsStarting.value)return;
 const realPosition=p&&Number.isFinite(p.currentTime)?p.currentTime+session.start:0;
 caption.value=caption.value.startsWith("emb:")?caption.value:"off";
 await startTranscode(v,Math.max(0,realPosition),audioIndex,hlsQuality.value);
}
// Picking a lower tier on any film (including directly playable ones)
// rebuilds the session at the current position; "原画" on a playable film
// returns to the plain stream by tearing the session down.
async function switchQuality(quality:string){
 const v=selected.value,session=hlsSession.value,p=hlsPlayer.value;
 if(!v||hlsStarting.value)return;
 const realPosition=session&&p&&Number.isFinite(p.currentTime)?p.currentTime+session.start:v.position;
 if(quality==="source"&&canAttemptDirect(v)){
  destroyHls();playError.value="";
  await nextTick();
  loaded();
  return;
 }
 await startTranscode(v,Math.max(0,realPosition),session?session.audioTrack:0,quality);
}
function qualityOptions(v:Movie){
 const options=[{value:"source",label:"原画"}];
 const sourceHeight=v.height||0;
 for(const tier of [{value:"1080",label:"1080P",height:1080},{value:"720",label:"720P",height:720},{value:"480",label:"480P",height:480}]){
  if(sourceHeight>0&&sourceHeight<=tier.height)break;
  options.push({value:tier.value,label:tier.label});
 }
 return options;
}
function applyPlaybackRate(){
 const p=activeVideo();
 if(p)p.playbackRate=playbackRate.value;
}
function setPlaybackRate(rate:number){
 playbackRate.value=rate;
 applyPlaybackRate();
}
// MARK: watch history
async function loadHistory(reset=false){
 if(historyLoading.value)return;
 historyLoading.value=true;historyError.value="";
 try{
  const query=new URLSearchParams({limit:"48",cursor:String(reset?0:historyNext.value)});
  const page=await api<{films:Movie[];nextCursor:number}>(apiPath("/api/v1/cinema/history")+"?"+query.toString());
  historyFilms.value=reset?page.films:[...historyFilms.value,...page.films];
  historyNext.value=page.nextCursor;
  historyLoaded.value=true;
 }catch(e){historyError.value=describeRootOperationFailure(e)}
 finally{historyLoading.value=false}
}
async function clearHistory(){
 if(!window.confirm("清空全部观看历史与各影片的续播进度？该操作只影响当前账号，且不可撤销。"))return;
 try{
  await api(apiPath("/api/v1/cinema/history"),"DELETE");
  historyFilms.value=[];historyNext.value=0;
  movies.value=movies.value.map(item=>({...item,position:0,completed:false}));
  await load(true);
 }catch(e){historyError.value=describeRootOperationFailure(e)}
}
async function markWatched(v:Movie,completed:boolean){
 try{
  const updated=await api<Movie>(apiPath("/api/v1/cinema/"+v.id+"/watched"),"POST",{completed});
  if(selected.value?.id===v.id)selected.value=updated;
  movies.value=movies.value.map(item=>item.id===v.id?{...item,...updated}:item);
  historyFilms.value=historyFilms.value.map(item=>item.id===v.id?{...item,...updated}:item)
   .filter(item=>item.id!==v.id||item.position>5||item.completed);
  scrapeMessage.value=completed?"已标记为看完。":"已标记为未看，续播进度已重置。";
 }catch(e){scrapeMessage.value="标记失败："+describeRootOperationFailure(e)}
}
async function open(v:Movie,autoStart=false){
 selectedController?.abort();
 cancelMetadataRequests();
 destroyHls();
 tmdbQuery.value=v.title;tmdbToken.value="";tmdbMatches.value=[];candidatePosterFailed.value={};tmdbError.value="";scrapeMessage.value="";
 doubanQuery.value=v.title;doubanMatches.value=[];doubanError.value="";
 seriesTmdbMessage.value="";
 const controller=new AbortController();selectedController=controller;
 selected.value=v;caption.value="off";playError.value="";lastSave=0;
 if(playback(v)==="download-only"){
  if(v.probeStatus==="pending"){
   playError.value="正在识别此视频格式，当前无法判断是否可直接播放。识别完成后可重新打开，也可以先下载原片。";
   return;
  }
  if(autoStart){await startTranscode(v,v.position>5?v.position:0,0)}
  else playError.value=playbackLabel(v)+"。可尝试在线转码播放（服务器实时转封装/转码，原片不变），或下载原片后用 IINA、VLC 打开。";
  return;
 }
 if(playback(v)==="unverified-direct")playError.value="该格式尚未经过本机解码验证，正在尝试浏览器播放；若无法解码，请下载原片使用本地播放器。";
 try{
  const detail=await api<Movie>(apiPath("/api/v1/cinema/"+v.id),"GET",undefined,controller.signal);
  if(controller.signal.aborted||selected.value?.id!==v.id)return;
  selected.value=detail;
  if(playback(detail)==="download-only"){
   if(autoStart)await startTranscode(v,detail.position>5?detail.position:0,0);
   else playError.value=playbackLabel(detail)+"。可尝试在线转码播放，或下载原片后用 IINA、VLC 打开。";
  }
  else if(playback(detail)==="unverified-direct")playError.value="该格式尚未经过本机解码验证，正在尝试浏览器播放；若无法解码，请下载原片使用本地播放器。";
  else playError.value="";
 }catch(e){if(!(e instanceof Error&&e.name==="AbortError")){/* Keep list metadata and the visible fallback guidance */}}
}
function activeVideo(){return hlsSession.value?hlsPlayer.value:player.value}
function loaded(){
 const v=selected.value,p=activeVideo(),session=hlsSession.value;
 if(!v||!p)return;
 applyPlaybackRate();
 const resume=v.position>5&&!v.completed;
 if(!session){
  if(resume&&p.duration>v.position+5)p.currentTime=v.position;
  return;
 }
 const target=v.position-session.start;
 if(resume&&target>1&&p.duration>target+5)p.currentTime=target;
 else if(session.start>0)p.currentTime=0;
}
async function save(done=false){
 const v=selected.value,p=activeVideo(),session=hlsSession.value;
 if(!v||!p||!Number.isFinite(p.duration)||p.duration<=0)return;
 const current=p.currentTime+(session?.start??0),d=p.duration+(session?.start??0);
 if(!Number.isFinite(current)||current<0)return;
 const rootId=props.rootId??"",rootGeneration=props.rootGeneration??0;
 const snapshot:ProgressSnapshot={key:`${rootId}:${rootGeneration}:${v.id}`,id:v.id,rootId,rootGeneration,
  url:apiPath("/api/v1/cinema/"+v.id+"/progress"),position:current,duration:d,completed:done||p.duration-current<8};
 await progressWriter.save(snapshot);
}
function tick(){const now=Date.now();if(now-lastSave>10000){lastSave=now;void save()}}
function close(){selectedController?.abort();selectedController=undefined;cancelMetadataRequests();destroyHls();void save();player.value?.pause();hlsPlayer.value?.pause();selected.value=null;playError.value="";tmdbToken.value="";tmdbMatches.value=[];tmdbError.value="";doubanMatches.value=[];doubanError.value="";scrapeMessage.value="";seriesTmdbMessage.value=""}
function cancelMetadataRequests(){
 nfoRequests.cancel();tmdbSearchRequests.cancel();tmdbMatchRequests.cancel();doubanSearchRequests.cancel();doubanMatchRequests.cancel();
 scraping.value=false;tmdbBusy.value=false;doubanBusy.value=false;
}
async function searchDouban(){
 const film=selected.value;
 if(!film||!props.admin||doubanBusy.value||tmdbBusy.value||scraping.value)return;
 const search=doubanQuery.value.trim();
 if(search.length<2||search.length>60){doubanError.value="请输入 2–60 个字符的片名。";return}
 const filmID=film.id,request=doubanSearchRequests.begin();
 const isCurrent=()=>request.isCurrent()&&selected.value?.id===filmID;
 doubanBusy.value=true;doubanMatches.value=[];doubanError.value="";
 try{
  const result=await api<{results:DoubanCandidate[]}>(apiPath("/api/v1/cinema/"+filmID+"/metadata/douban/search"),"POST",{query:search},request.signal);
  if(isCurrent()){
   doubanMatches.value=result.results.filter(c=>c.kind!== "tv"||film.kind==="series").filter(c=>c.kind!=="movie"||film.kind==="movie");
   if(!doubanMatches.value.length)doubanError.value="未找到候选资料，或搜索结果不属于当前影片类型。";
  }
 }catch(e){
  if(isCurrent()&&!(e instanceof Error&&e.name==="AbortError"))doubanError.value=
    "豆瓣网页搜索暂不可用（可能限流、拒绝访问或页面调整）。可继续使用 TMDB 或本地 NFO。";
 }finally{if(isCurrent())doubanBusy.value=false}
}
async function matchDouban(candidate:DoubanCandidate){
 const film=selected.value;
 if(!film||!props.admin||doubanBusy.value||tmdbBusy.value||scraping.value)return;
 if(!window.confirm("将豆瓣网页搜索建议「"+candidate.title+"」"+(candidate.year?"（"+candidate.year+"）":"")+"匹配到「"+film.title+"」？只更新非手动片名和年份，不复制简介、评分或海报，原始文件及观看进度不变。"))return;
 const filmID=film.id,request=doubanMatchRequests.begin();
 const isCurrent=()=>request.isCurrent()&&selected.value?.id===filmID;
 doubanBusy.value=true;doubanError.value="";
 try{
  await api(apiPath("/api/v1/cinema/"+filmID+"/metadata/douban/match"),"POST",{query:doubanQuery.value.trim(),doubanId:candidate.id},request.signal);
  if(!isCurrent())return;
  const updated=await api<Movie>(apiPath("/api/v1/cinema/"+filmID),"GET",undefined,request.signal);
  if(isCurrent()){
   selected.value=updated;
   movies.value=movies.value.map(m=>m.id===filmID?{...m,...updated}:m);
   doubanMatches.value=[];
   scrapeMessage.value="已根据网页搜索结果更新片名/年份；简介、评分、海报保持原有来源，不会保存网页副本。";
  }
 }catch(e){
  if(isCurrent()&&!(e instanceof Error&&e.name==="AbortError"))doubanError.value="匹配失败：网页结果可能已变化或不再可访问，请稍后重试。";
 }finally{if(isCurrent())doubanBusy.value=false}
}
async function changeCaption(){
 await nextTick();
 for(const video of [player.value,hlsPlayer.value]){
  if(!video)continue;
  for(const t of Array.from(video.textTracks))t.mode=caption.value==="off"?"disabled":"showing";
 }
}
function captionSrclang(){
 if(caption.value.startsWith("emb:")){
  const index=Number.parseInt(caption.value.slice(4),10);
  const found=hlsTracks.value?.subtitles.find(t=>t.streamIndex===index);
  if(found?.language)return found.language;
  return "zh";
 }
 return caption.value==="auto"?"zh":caption.value;
}
async function rename(v:Movie){
 if(!props.admin)return;
 const title=window.prompt("修改影片展示名称",v.title)?.trim();
 if(!title||title===v.title)return;
 try{await api(apiPath("/api/v1/cinema/"+v.id),"PATCH",{title});v.title=title}
 catch(e){actionError.value=e instanceof Error?e.message:"修改失败"}
}
async function importLocalNFO(v:Movie){
 if(!props.admin||scraping.value||tmdbBusy.value)return;
 const filmID=v.id,request=nfoRequests.begin();
 const isCurrent=()=>request.isCurrent()&&selected.value?.id===filmID;
 scraping.value=true;scrapeMessage.value="";
 try{
  await api<Movie>(apiPath("/api/v1/cinema/"+filmID+"/metadata/nfo"),"POST",undefined,request.signal);
  if(!isCurrent())return;
  const updated=await api<Movie>(apiPath("/api/v1/cinema/"+filmID),"GET",undefined,request.signal);
  if(!isCurrent())return;
  selected.value=updated;
  movies.value=movies.value.map(movie=>movie.id===filmID?{...movie,...updated}:movie);
  scrapeMessage.value="本地 NFO 资料已导入，原视频与观看进度未修改。";
 }catch(e){
  if(!isCurrent()||e instanceof Error&&e.name==="AbortError")return;
  const code=e instanceof Error?e.message:"request_failed";
  scrapeMessage.value=code==="nfo_not_found"?"未找到同名 .nfo 或电影目录下的 movie.nfo。":code==="invalid_nfo"?"NFO 文件内容无效或超出大小限制。":"读取 NFO 失败："+code;
 }finally{if(isCurrent())scraping.value=false}
}
async function searchTMDB(){
 const film=selected.value;
 if(!film||!props.admin||tmdbBusy.value||scraping.value)return;
 if(!tmdbToken.value||!tmdbQuery.value.trim()){tmdbError.value="请输入自己的 TMDB API Read Access Token 和搜索关键词。";return}
 const filmID=film.id,request=tmdbSearchRequests.begin();
 const isCurrent=()=>request.isCurrent()&&selected.value?.id===filmID;
 tmdbBusy.value=true;tmdbMatches.value=[];candidatePosterFailed.value={};tmdbError.value="";
 try{
  const result=await api<{results:TMDBCandidate[]}>(apiPath("/api/v1/cinema/"+filmID+"/metadata/tmdb/search"),"POST",{accessToken:tmdbToken.value,query:tmdbQuery.value.trim()},request.signal);
  if(isCurrent()){tmdbMatches.value=result.results;tmdbError.value=result.results.length?"":"没有找到相关影片，可调整关键词再试。"}
 }catch(e){if(isCurrent()&&!(e instanceof Error&&e.name==="AbortError"))tmdbError.value="搜索失败："+tmdbErrorMessage(e)}
 finally{if(isCurrent())tmdbBusy.value=false}
}
async function matchTMDB(candidate:TMDBCandidate){
 const film=selected.value;
 if(!film||!props.admin||tmdbBusy.value||scraping.value)return;
 if(!window.confirm("确认将「"+candidate.title+"」的 TMDB 资料匹配到「"+film.title+"」？将更新简介、评分及海报；手动设置的影片名保持不变。"))return;
 const filmID=film.id,request=tmdbMatchRequests.begin();
 const isCurrent=()=>request.isCurrent()&&selected.value?.id===filmID;
 tmdbBusy.value=true;tmdbError.value="";
 try{
  await api<Movie>(apiPath("/api/v1/cinema/"+filmID+"/metadata/tmdb/match"),"POST",{accessToken:tmdbToken.value,tmdbId:candidate.id},request.signal);
  if(!isCurrent())return;
  const updated=await api<Movie>(apiPath("/api/v1/cinema/"+filmID),"GET",undefined,request.signal);
  if(isCurrent()){
   selected.value=updated;movies.value=movies.value.map(item=>item.id===film.id?{...item,...updated}:item);
   delete posterFailed.value[filmID];
   tmdbMatches.value=[];tmdbToken.value="";scrapeMessage.value="已匹配 TMDB 资料；API 凭据已从页面内存清除。";
  }
 }catch(e){if(isCurrent()&&!(e instanceof Error&&e.name==="AbortError"))tmdbError.value="保存匹配失败："+tmdbErrorMessage(e)}
 finally{if(isCurrent())tmdbBusy.value=false}
}
function keydown(e:KeyboardEvent){
 if(e.key!=="Escape")return;
 if(seriesDetail.value){closeSeries();return}
 if(selected.value)close();
}
// MARK: series aggregation
async function loadSeries(){
 if(seriesLoading.value)return;
 const generation=++loadGeneration;
 seriesLoading.value=true;seriesError.value="";
 try{
  const page=await api<{series:SeriesInfo[]}>(apiPath("/api/v1/series")+"?limit=60");
  if(generation!==loadGeneration)return;
  seriesList.value=page.series;
 }catch(e){if(generation===loadGeneration)seriesError.value=describeRootOperationFailure(e)}
 finally{if(generation===loadGeneration)seriesLoading.value=false}
}
function switchView(target:"films"|"series"){
 view.value=target;
 if(target==="series")void loadSeries();
 else void load(true);
}
async function openSeries(item:SeriesInfo){
 seriesDetailLoading.value=true;seriesDetailError.value="";seriesTmdbMessage.value="";seriesTmdbId.value="";
 try{
  const detail=await api<{series:SeriesInfo;films:Movie[]}>(apiPath("/api/v1/series/"+item.id));
  seriesDetail.value=detail;
 }catch(e){seriesDetailError.value=describeRootOperationFailure(e)}
 finally{seriesDetailLoading.value=false}
}
function closeSeries(){seriesDetail.value=null;seriesDetailError.value="";seriesTmdbMessage.value="";seriesTmdbId.value=""}
function seasonNumbers(films:Movie[]){return Array.from(new Set(films.map(f=>f.season))).sort((a,b)=>a-b)}
async function continueSeries(item:SeriesInfo){
 if(!item.nextFilmId)return;
 const film=seriesDetail.value?.films.find(f=>f.id===item.nextFilmId);
 closeSeries();
 if(film){await open(film,true);return}
 // Not in the loaded detail — open by id via a minimal movie stub so the
 // player still starts; the dialog refreshes metadata on its own.
 await open({id:item.nextFilmId,title:item.nextTitle||item.name,path:"",kind:"series",series:item.name,season:0,episode:0,year:item.year||0,size:0,position:item.position||0,duration:item.duration||0,completed:false},true);
}
async function matchSeriesTMDB(item:SeriesInfo){
 if(!props.admin||seriesTmdbBusy.value)return;
 const parsed=Number.parseInt(seriesTmdbId.value,10);
 if(!Number.isFinite(parsed)||parsed<1){seriesTmdbMessage.value="请输入有效的 TMDB 剧集 ID（数字）。";return}
 seriesTmdbBusy.value=true;seriesTmdbMessage.value="";
 try{
  const updated=await api<{series:SeriesInfo}>(apiPath("/api/v1/series/"+item.id+"/metadata/tmdb/match"),"POST",{tmdbId:parsed});
  if(seriesDetail.value&&seriesDetail.value.series.id===item.id)seriesDetail.value={...seriesDetail.value,series:{...seriesDetail.value.series,...updated.series}};
  seriesList.value=seriesList.value.map(s=>s.id===item.id?{...s,...updated.series}:s);
  seriesTmdbId.value="";seriesTmdbMessage.value="已更新剧集资料（海报/简介）。";
 }catch(e){
  const code=e instanceof Error?e.message:"request_failed";
  seriesTmdbMessage.value=code==="tmdb_token_not_configured"
   ?"未配置 TMDB Token：请管理员在 Mac App「偏好与安全」中配置后重试。"
   :code==="series_not_found"?"剧集不存在或已变化，请刷新列表。":"匹配失败："+code;
 }
 finally{seriesTmdbBusy.value=false}
}
// MARK: server-side automatic scrape (administrator)
async function refreshScrape(){
 if(props.admin!==true)return;
 try{
  const status=await api<{running:boolean;operation:string;processed:number;matched:number;tmdbConfigured:boolean}>(apiPath("/api/v1/cinema/scrape/status"));
  const wasRunning=scrapeState.value?.running;
  scrapeState.value=status;
  if(wasRunning&&!status.running){scrapeNotice.value="自动刮削已结束：处理 "+status.processed+" 项，成功匹配 "+status.matched+" 项。";void load(true)}
  if(status.running&&!scrapeTimer)scrapeTimer=window.setInterval(async()=>{await refreshScrape()},3000);
  if(!status.running&&scrapeTimer){clearInterval(scrapeTimer);scrapeTimer=undefined}
 }catch{/* status polling is best-effort */}
}
async function startScrape(){
 if(scrapeBusy.value)return;
 scrapeBusy.value=true;scrapeError.value="";
 try{
  await api(apiPath("/api/v1/cinema/scrape/start"),"POST",{retryMisses:scrapeRetryTried.value});
  scrapeNotice.value="自动刮削已启动；处理速度受 TMDB 限速约束，可随时在任务中心取消。";
  await refreshScrape();
 }catch(e){
  const code=e instanceof Error?e.message:"request_failed";
  scrapeError.value=code==="tmdb_token_not_configured"
   ?"自动刮削需要在 Mac App「偏好与安全」中配置 TMDB Token。"
   :code==="scan_running"?"媒体库扫描正在进行，请稍后再试。":transcodeErrorMessage(e);
 }
 finally{scrapeBusy.value=false}
}
const scrapeRetryTried=ref(false);
onMounted(()=>{disposed=false;void load(true);void status();void refreshScrape();scanTimer=window.setInterval(()=>void status(),5000);window.addEventListener("keydown",keydown)});
onBeforeUnmount(()=>{void save()});
onUnmounted(()=>{disposed=true;loadGeneration+=1;if(scanTimer)clearInterval(scanTimer);if(searchTimer)clearTimeout(searchTimer);if(scrapeTimer)clearInterval(scrapeTimer);selectedController?.abort();cancelMetadataRequests();cancelBatch();destroyHls();scanStatusPoller.dispose();tmdbToken.value="";window.removeEventListener("keydown",keydown)});
</script>
<template>
 <div class="content cinema-view">
  <div class="section-heading">
   <div><h2>私人影院</h2><p>原片保存在 Mac 的授权共享目录，播放能力按实际格式检查结果显示。</p></div>
   <button v-if="admin" class="refresh" :disabled="scan.running&&!scanStatusError" @click="startScan"><RefreshCcw :size="16" :class="{spinning: scan.running&&!scanStatusError}"/>{{scan.running&&!scanStatusError?"扫描中…":"扫描影视库"}}</button>
  </div>
  <details v-if="admin" class="cinema-tmdb-panel">
   <summary>批量整理影片 · TMDB 候选建议（逐条确认）</summary>
   <p>只对当前已加载、尚未手动匹配的最多 8 部影片生成候选。根据片名与年份初步评分，不保证同名电影匹配准确；每部作品必须人工确认才写入。不会移动原片、自动改名或后台保存 TMDB 密钥。</p>
   <form class="cinema-tmdb-form" @submit.prevent="suggestBatch">
    <input v-model="batchToken" type="password" autocomplete="off" placeholder="你的 TMDB Read Access Token（不保存）" :disabled="batchBusy"/>
    <button type="submit" :disabled="batchBusy">{{batchBusy?"正在查找…":"生成候选"}}</button>
    <button type="button" :disabled="batchBusy" @click="cancelBatch">清除令牌与候选</button>
   </form>
   <p v-if="batchProgress" class="cinema-hint" role="status">{{batchProgress}}</p>
   <p v-if="batchError" class="cinema-alert" role="alert">{{batchError}}</p>
   <div v-for="item in batchCandidates" :key="item.filmId" class="cinema-tmdb-match">
    <div class="cinema-tmdb-match-text">
     <strong>{{item.filmTitle}} → {{item.match.title}} {{item.match.year?"("+item.match.year+")":""}}</strong>
     <small>自动候选评分 {{item.score}} / 100 · 请核对是否同一部影片</small>
    </div>
    <button type="button" :disabled="batchBusy" @click="acceptBatchCandidate(item)">确认此条</button>
   </div>
  </details>
  <details v-if="admin" class="cinema-tmdb-panel">
   <summary>自动刮削 · 服务器端 TMDB 批量补全（需在 Mac App 配置 Token）</summary>
   <p>由服务器后台任务为尚未确认资料的影片与剧集自动匹配 TMDB 信息（海报/简介/评分），严格限速、可随时在任务中心取消；只有高置信匹配（同名且年份一致）才会自动写入，其余记录为未匹配。Token 由管理员在 Mac App「偏好与安全」中配置，本页不收集。</p>
   <p v-if="scrapeState&&!scrapeState.tmdbConfigured" class="cinema-alert" role="status">尚未配置 TMDB Token：请在 Mac App「偏好与安全 → TMDB 自动刮削」中配置后使用。</p>
   <p v-if="scrapeState&&scrapeState.running" class="cinema-hint" role="status">自动刮削进行中：已处理 {{scrapeState.processed}} 项，成功匹配 {{scrapeState.matched}} 项…</p>
   <p v-if="scrapeNotice" class="cinema-hint" role="status">{{scrapeNotice}}</p>
   <p v-if="scrapeError" class="cinema-alert" role="alert">{{scrapeError}}</p>
   <form class="cinema-tmdb-form" @submit.prevent="startScrape">
    <label style="display:flex;align-items:center;gap:6px"><input v-model="scrapeRetryTried" type="checkbox"/>重试此前未匹配的条目</label>
    <button type="submit" :disabled="scrapeBusy||(scrapeState?.running??false)||scrapeState?.tmdbConfigured===false">{{scrapeState?.running?"刮削进行中…":scrapeBusy?"正在启动…":"开始自动刮削"}}</button>
   </form>
  </details>
  <div v-if="scan.running&&!scanStatusError" class="cinema-alert">正在扫描：{{scan.visited}} 项 · 已找到 {{scan.found}} 部作品</div>
  <div v-if="scanStatusError&&movies.length" class="cinema-alert" role="alert">扫描状态读取失败：{{scanStatusError}} <span v-if="scanStatusLoaded">显示的是最近一次成功读取的状态。</span> <button type="button" class="account-action" :disabled="scanStatusLoading" @click="status">{{scanStatusLoading?"正在重试…":"重试状态"}}</button></div>
  <div v-if="scanStatusLoaded&&scan.lastError&&movies.length" class="cinema-alert" role="alert">扫描未完成：{{scan.lastError}}</div>
  <div v-if="scanActionError&&movies.length" class="cinema-alert" role="alert">无法启动扫描：{{scanActionError}}</div>
  <div v-if="actionError&&movies.length" class="cinema-alert" role="alert">{{actionError}}</div>
  <div v-if="loadError&&movies.length" class="cinema-alert" role="alert">加载影视库失败：{{loadError}} 当前仍显示上次成功读取的内容。 <button type="button" class="account-action" :disabled="loading" @click="retryLoad">重试加载</button></div>
  <div v-if="progressSaveError" class="cinema-alert" role="alert">{{progressSaveError}} <button type="button" class="account-action" @click="retryProgress">重试保存进度</button></div>
  <div class="cinema-tools">
   <div class="cinema-tabs">
    <button :class="{active:view==='films'}" @click="switchView('films')"><Clapperboard :size="15"/>影片</button>
    <button :class="{active:view==='series'}" @click="switchView('series')"><Tv :size="15"/>剧集库</button>
   </div>
  </div>
  <div class="cinema-tools">
   <div class="cinema-tabs">
    <button :class="{active:mode==='all'}" @click="filter('all')"><Film :size="15"/>全部</button>
    <button :class="{active:mode==='movie'}" @click="filter('movie')"><Film :size="15"/>电影</button>
    <button :class="{active:mode==='series'}" @click="filter('series')"><Tv :size="15"/>剧集</button>
    <button :class="{active:mode==='continue'}" @click="filter('continue')">继续观看</button>
    <button :class="{active:mode==='history'}" @click="filter('history')">历史记录</button>
   </div>
   <label class="cinema-search"><Search :size="16"/><input v-model="query" maxlength="120" type="search" placeholder="搜索影片或剧集"/></label>
  </div>
  <p v-if="view==='films'&&continueCount" class="cinema-hint">当前列表有 {{continueCount}} 部作品可继续观看</p>
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
     <template v-else><Tv :size="44"/></template>
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
   <p>{{loadError?"加载影视库失败："+loadError:actionError||scanActionError||(scanStatusError?"扫描状态暂不可用："+scanStatusError:"上次扫描未完成："+scan.lastError)}}</p>
   <button v-if="loadError" type="button" class="refresh" :disabled="loading" @click="retryLoad">重试读取影视库</button>
   <button v-if="scanStatusError" type="button" class="refresh" :disabled="scanStatusLoading" @click="status">重试读取扫描状态</button>
   <button v-if="admin&&(!loadError||scanActionError||scan.lastError)" type="button" class="refresh" :disabled="scan.running&&!scanStatusError" @click="startScan">重新扫描</button>
   <p v-if="!admin">请联系管理员检查共享目录或重新执行扫描。</p>
  </div>
  <div v-else-if="view==='films'&&!movies.length&&(loading||!pageLoaded||!scanStatusLoaded&&!scanStatusError||scan.running&&!scanStatusError)" class="cinema-empty"><Clapperboard :size="48"/><h3>{{scan.running&&!scanStatusError?"正在扫描影视库…":!scanStatusLoaded&&!scanStatusError?"正在确认扫描状态…":"正在读取影视库…"}}</h3><p>正在检查 Mac 授权的共享目录。</p></div>
  <div v-else-if="view==='films'&&!movies.length" class="cinema-empty"><Clapperboard :size="48"/><h3>{{emptyTitle}}</h3><p>{{emptyMessage}}</p><button v-if="filteredView" type="button" class="refresh" @click="resetFilters">查看全部影片</button></div>
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
    <button class="cinema-poster" :aria-label="(playback(movie)==='verified-direct'?'播放 ':playback(movie)==='unverified-direct'?'尝试播放 ':'查看播放状态 ')+movie.title" @click="open(movie)">
     <img v-if="(movie.posterURL||posterReady(movie))&&!posterFailed[movie.id]" :src="poster(movie)" :alt="movie.title+'海报'" class="cinema-poster-image" @error="posterFailed[movie.id]=true"/>
     <template v-else><Tv v-if="movie.kind==='series'" :size="44"/><Film v-else :size="44"/></template>
     <span class="cinema-play"><Download v-if="playback(movie)==='download-only'" :size="18"/><Play v-else :size="18" fill="currentColor"/></span>
     <span class="cinema-label">{{movie.kind==='series'?'S'+movie.season+'E'+movie.episode:(movie.year||'电影')}}</span>
     <span class="cinema-watchbar" :style="{width:percent(movie)+'%'}"></span>
    </button>
    <div class="cinema-details">
     <strong :title="movie.title">{{movie.title}}</strong>
     <small>{{movie.kind==='series'?'电视剧':'电影'}} · {{duration(movie.durationSeconds||movie.duration)}}</small>
     <small v-if="formatLabel(movie)" class="cinema-format">{{formatLabel(movie)}}</small>
     <small v-if="movie.completed" class="badge-done">已看完</small>
     <small v-else-if="movie.position>5" class="badge-prog">已看 {{percent(movie)}}%</small>
     <small v-if="playback(movie)!=='verified-direct'" class="badge-warn">{{playbackLabel(movie)}}</small>
     <button v-if="admin" @click="rename(movie)" title="修改展示名称"><Pencil :size="14"/></button>
    </div>
   </article>
  </div>
  <div v-if="view==='films'&&mode!=='history'" class="cinema-more"><button v-if="next" :disabled="loading" @click="load()">{{loading?"正在加载…":"加载更多作品"}}</button><span v-else-if="movies.length">已展示全部 {{movies.length}} 部作品</span></div>
  <p class="cinema-foot">已验证格式直接播放原文件；不兼容格式可在线转码播放（服务器实时转封装/转码为临时缓存，原片永不修改），也可下载后用 IINA/VLC 打开。未安装 FFmpeg 时仅提供直接播放与下载。</p>
 </div>
 <Teleport to="body">
 <div v-if="selected" class="cinema-backdrop" @click.self="close">
  <section class="cinema-dialog" role="dialog" aria-modal="true">
   <header><div><strong>{{selected.title}}</strong><small>{{selected.kind==='series'?'第 '+selected.season+' 季 · 第 '+selected.episode+' 集':'电影'}}</small></div><button title="关闭" @click="close"><X :size="19"/></button></header>
   <video v-if="canAttemptDirect(selected)" ref="player" :src="stream(selected)" controls playsinline preload="metadata"
    @loadedmetadata="loaded" @timeupdate="tick" @pause="save()" @ended="save(true)"
    @error="playError='浏览器无法解码该视频格式。可下载原片后使用 IINA 或 VLC 播放，原视频不会被修改。'">
    <track v-if="caption!=='off'" :key="caption" kind="subtitles" :src="track(selected)" :srclang="captionSrclang()" label="字幕" default @load="changeCaption"/>
   </video>
   <div v-else-if="hlsStarting" class="cinema-alert" role="status">转码启动中，正在准备播放…（转封装通常数秒；转码档与影片时长和机器性能有关）</div>
   <video v-else-if="hlsSession" ref="hlsPlayer" controls playsinline preload="auto"
    @loadedmetadata="loaded" @timeupdate="tick" @pause="save()" @ended="save(true)"
    @error="playError=playError||'转码播放出错，可重新尝试或下载原片。'">
    <track v-if="caption!=='off'" :key="caption" kind="subtitles" :src="track(selected)" :srclang="captionSrclang()" label="字幕" default @load="changeCaption"/>
   </video>
   <div v-if="playError" class="cinema-alert">{{playError}}</div>
   <div v-if="!canAttemptDirect(selected)&&!hlsSession&&!hlsStarting&&selected.probeStatus!=='pending'" class="cinema-actions">
    <button class="dl-btn" @click="startTranscode(selected,selected.position>5?selected.position:0,0)"><Play :size="15"/> 在线转码播放（原片不变）</button>
   </div>
   <p v-if="selected.overview" class="cinema-synopsis">{{selected.overview}}</p>
   <p v-if="selected.titleSource||selected.yearSource||selected.metadataSource" class="cinema-metadata-source">
    片名：{{metadataSourceName(selected.titleSource)}} · 年份：{{metadataSourceName(selected.yearSource)}} · 简介/评分：{{selected.metadataSource?metadataSourceName(selected.metadataSource):"无已确认来源"}}
    <span v-if="selected.rating"> · 评分 {{selected.rating.toFixed(1)}} / 10</span>
   </p>
   <p v-if="scrapeMessage" class="cinema-alert" role="status">{{scrapeMessage}}</p>
   <details v-if="admin" class="cinema-tmdb-panel">
    <summary>豆瓣网页搜索建议 · 备用匹配（实验性，无跳转）</summary>
    <p>仅在点击搜索时请求豆瓣网页使用的影视搜索建议，直接显示片名和年份；这是非官方、可能失效且受网站使用条款约束的入口。不会自动抓取海报、评论或评分，不绕过网站的访问限制。</p>
    <form class="cinema-tmdb-form" @submit.prevent="searchDouban">
     <input v-model="doubanQuery" type="search" maxlength="60" aria-label="豆瓣影片搜索关键词" placeholder="输入电影或剧集名称" :disabled="doubanBusy||scraping||tmdbBusy"/>
     <button type="submit" :disabled="doubanBusy||scraping||tmdbBusy">{{doubanBusy?"正在查询…":"在此搜索豆瓣候选"}}</button>
    </form>
    <p v-if="doubanError" class="cinema-alert" role="alert">{{doubanError}}</p>
    <div v-for="candidate in doubanMatches" :key="candidate.id" class="cinema-tmdb-match">
     <div class="cinema-tmdb-match-text">
      <strong>{{candidate.title}} {{candidate.year?"("+candidate.year+")":""}}</strong>
      <small>网页搜索建议 · {{candidate.kind==="tv"?"剧集":"影片"}} · 不含评分和海报</small>
     </div>
     <button type="button" :disabled="doubanBusy||tmdbBusy||scraping" @click="matchDouban(candidate)">确认匹配</button>
    </div>
   </details>
   <details v-if="admin" class="cinema-tmdb-panel">
    <summary>从 TMDB 在线匹配电影 / 剧集资料（自愿联网）</summary>
    <p>只有点击搜索时才会向 TMDB 发送搜索词。请输入你自己的 API Read Access Token；令牌只用于当前请求，不存储在 LightIsle 数据库。选中候选结果后才会保存对应资料。</p>
    <form class="cinema-tmdb-form" @submit.prevent="searchTMDB">
     <input v-model="tmdbToken" type="password" autocomplete="off" spellcheck="false" placeholder="TMDB API Read Access Token" aria-label="TMDB API Read Access Token" :disabled="tmdbBusy||scraping"/>
     <input v-model="tmdbQuery" type="search" maxlength="120" placeholder="影视名称" aria-label="TMDB 搜索关键词" :disabled="tmdbBusy||scraping"/>
     <button type="submit" :disabled="tmdbBusy||scraping">{{tmdbBusy?"查询中…":scraping?"正在导入…":"搜索 TMDB"}}</button>
    </form>
    <p v-if="tmdbError" class="cinema-alert" role="alert">{{tmdbError}}</p>
    <div v-for="candidate in tmdbMatches" :key="candidate.id" class="cinema-tmdb-match">
     <img v-if="candidate.posterURL&&!candidatePosterFailed[candidate.id]" :src="candidate.posterURL" :alt="candidate.title+'海报'" loading="lazy" @error="candidatePosterFailed[candidate.id]=true"/>
     <div v-else class="cinema-tmdb-poster-placeholder" aria-hidden="true"><Film :size="22"/></div>
     <div class="cinema-tmdb-match-text">
      <strong>{{candidate.title}} {{candidate.year?"("+candidate.year+")":""}}</strong>
      <small>评分 {{candidate.rating.toFixed(1)}} / 10</small>
      <p v-if="candidate.overview">{{candidate.overview}}</p>
     </div>
     <button type="button" :disabled="tmdbBusy||scraping" @click="matchTMDB(candidate)">选择匹配</button>
    </div>
    <p class="cinema-metadata-source">This product uses the TMDB API but is not endorsed or certified by TMDB. <a href="https://www.themoviedb.org/" rel="noopener noreferrer" target="_blank">TMDB</a></p>
   </details>
   <footer>
    <label v-if="canAttemptDirect(selected)||hlsSession"><Subtitles :size="16"/>字幕 <select v-model="caption" @change="changeCaption"><option value="off">关闭</option><option value="auto">同名字幕</option><option value="zh">中文字幕</option><option value="en">英文字幕</option><option v-for="t in (hlsTracks?.subtitles??[]).filter(s=>s.extractable)" :key="'emb'+t.streamIndex" :value="'emb:'+t.streamIndex">{{captionLabel(t)}}</option></select></label>
    <label v-if="hlsSession&&(hlsTracks?.audio?.length??0)>1"><AudioLines :size="16"/>音轨 <select :value="hlsSession.audioTrack" @change="switchAudioTrack(Number(($event.target as HTMLSelectElement).value))"><option v-for="t in hlsTracks?.audio" :key="t.streamIndex" :value="t.audioIndex">{{t.title||t.language||("音轨 "+(t.audioIndex+1))}}{{t.codec?" · "+t.codec:""}}{{t.channels?" · "+t.channels+"ch":""}}</option></select></label>
    <label><Gauge :size="16"/>清晰度 <select :value="hlsSession?hlsSession.quality:qualityOptions(selected)[0]?.value" :disabled="hlsStarting" @change="switchQuality(($event.target as HTMLSelectElement).value)"><option v-for="option in qualityOptions(selected)" :key="option.value" :value="option.value">{{option.label}}{{option.value==="source"&&!canAttemptDirect(selected)?"（转封装）":""}}</option></select></label>
    <label><Gauge :size="16"/>倍速 <select :value="playbackRate" @change="setPlaybackRate(Number(($event.target as HTMLSelectElement).value))"><option :value="0.75">0.75x</option><option :value="1">1x</option><option :value="1.25">1.25x</option><option :value="1.5">1.5x</option><option :value="2">2x</option></select></label>
    <span v-if="hlsSession" class="resume-hint">{{hlsSession.profile==="remux"?"转封装播放（无画质损失）":"转码播放中"}} · 进度按原片时间轴保存</span>
    <span v-else-if="selected.position>5&&!selected.completed" class="resume-hint">上次播至 {{duration(selected.position)}}</span>
    <button class="dl-btn" @click="download(selected)">下载原片文件</button>
    <button class="dl-btn" @click="markWatched(selected,!selected.completed)">{{selected.completed?"标记未看":"标记已看"}}</button>
    <button v-if="selected.position>5&&!selected.completed" class="dl-btn" @click="markWatched(selected,false);open(selected,true)">从头播放</button>
    <button v-if="admin" class="dl-btn" :disabled="scraping||tmdbBusy" @click="importLocalNFO(selected)">{{scraping?"读取中…":tmdbBusy?"正在处理资料…":"导入本地 NFO 资料"}}</button>
   </footer>
  </section>
 </div>
 </Teleport>
 <Teleport to="body">
 <div v-if="seriesDetail" class="cinema-backdrop" @click.self="closeSeries">
  <section class="cinema-dialog" role="dialog" aria-modal="true">
   <header><div><strong>{{seriesDetail.series.name}}</strong><small>{{seriesDetail.series.year||"剧集"}} · 已看 {{seriesDetail.series.watchedCount}}/{{seriesDetail.series.episodeCount}} 集<template v-if="seriesDetail.series.tmdbId"> · TMDB</template></small></div><button title="关闭" @click="closeSeries"><X :size="19"/></button></header>
   <p v-if="seriesDetail.series.overview" class="cinema-synopsis">{{seriesDetail.series.overview}}</p>
   <div v-if="seriesDetailLoading" class="cinema-alert" role="status">正在读取剧集分集…</div>
   <div v-if="seriesDetailError" class="cinema-alert" role="alert">{{seriesDetailError}}</div>
   <div v-for="season in seasonNumbers(seriesDetail.films)" :key="season" class="cinema-season">
    <h4>第 {{season}} 季</h4>
    <button v-for="episode in seriesDetail.films.filter(f=>f.season===season)" :key="episode.id" class="cinema-episode" @click="open(episode,true);closeSeries()">
     <span class="cinema-episode-no">E{{episode.episode}}</span>
     <span class="cinema-episode-title">{{episode.title}}</span>
     <span class="cinema-episode-meta">{{duration(episode.durationSeconds||episode.duration)}}</span>
     <span v-if="episode.completed" class="badge-done">已看完</span>
     <span v-else-if="episode.position>5" class="badge-prog">已看 {{percent(episode)}}%</span>
    </button>
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
<style scoped>
.cinema-tmdb-panel{margin:10px 0;padding:12px;border:1px solid var(--fluid-card-border);border-radius:12px;font-size:12px}
.cinema-tmdb-panel summary{cursor:pointer;font-weight:700}
.cinema-tmdb-panel>p{color:var(--text-secondary);line-height:1.5}
.cinema-tmdb-form{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0}
.cinema-tmdb-form input{min-width:170px;flex:1;border:1px solid var(--fluid-card-border);border-radius:8px;background:var(--fluid-card-fill);color:var(--text-primary);padding:8px}
.cinema-tmdb-match{display:flex;align-items:center;gap:10px;padding:10px 0;border-top:1px solid var(--fluid-card-border)}
.cinema-tmdb-match img,.cinema-tmdb-poster-placeholder{height:78px;width:52px;object-fit:cover;border-radius:5px;flex:none}
.cinema-tmdb-poster-placeholder{display:grid;place-items:center;background:linear-gradient(135deg,#23314d,#415c82 65%,#352f52);color:#f4f7ff}
.cinema-tmdb-match-text{flex:1;min-width:0;display:flex;flex-direction:column;gap:3px}
.cinema-tmdb-match-text p{margin:0;font-size:11px;max-height:52px;overflow:auto}
.cinema-tmdb-match button,.cinema-tmdb-form button{border:1px solid var(--fluid-card-border);padding:8px 11px;border-radius:8px}
.cinema-synopsis{white-space:pre-wrap;overflow-wrap:anywhere;max-height:160px;overflow:auto;font-size:13px;color:var(--text-secondary);line-height:1.6}
.cinema-metadata-source{font-size:12px;color:var(--text-secondary)}
.cinema-tools{display:flex;align-items:center;justify-content:space-between;gap:14px;margin:24px 0;flex-wrap:wrap}
.cinema-tabs{display:flex;gap:8px}.cinema-tabs button,.cinema-search{display:flex;align-items:center;gap:7px;border-radius:var(--radius-pill);border:1px solid var(--fluid-card-border);background:var(--fluid-card-fill);color:var(--text-secondary);padding:9px 16px;font-size:13px;font-weight:550;box-shadow:var(--fluid-item-card-shadow);transition:transform var(--motion-fast) var(--motion-spring),box-shadow var(--motion-fast) ease,background var(--motion-fast) ease}
.cinema-tabs button:hover{background:var(--fluid-card-hover);transform:translateY(-1.5px);box-shadow:var(--fluid-item-hover-shadow)}
.cinema-tabs button.active{background:var(--fluid-card-fill);color:var(--accent-primary);border-color:var(--fluid-card-border);box-shadow:var(--fluid-card-shadow);font-weight:700}
.cinema-search input{border:0;outline:0;background:transparent;color:var(--text-primary);font-size:13px;min-width:140px}
.cinema-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:18px}
.cinema-tile{overflow:hidden;border-radius:var(--radius-lg);background:var(--fluid-card-fill);border:1px solid var(--fluid-card-border);min-width:0;box-shadow:var(--fluid-card-shadow);transition:transform var(--motion-fast) var(--motion-spring),box-shadow var(--motion-fast) ease}
.cinema-tile:hover{transform:translateY(-4px);box-shadow:var(--fluid-hover-shadow)}
.cinema-poster{width:100%;aspect-ratio:3/4;border:0;position:relative;display:grid;place-items:center;background:linear-gradient(135deg,#23314d,#415c82 65%,#352f52);color:#f4f7ff;overflow:hidden;cursor:pointer}
.cinema-poster-image{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.cinema-tile:nth-child(3n+2) .cinema-poster{background:linear-gradient(135deg,#4e3352,#875f78,#3a2d54)}
.cinema-tile:nth-child(3n+3) .cinema-poster{background:linear-gradient(135deg,#24494c,#44767e,#253d50)}
.cinema-play{position:absolute;width:48px;height:48px;display:grid;place-items:center;border-radius:50%;background:rgba(255,255,255,0.25);border:1px solid rgba(255,255,255,0.5);color:#fff;backdrop-filter:blur(8px);box-shadow:0 8px 24px rgba(0,0,0,0.3);transition:transform var(--motion-fast) var(--motion-spring)}
.cinema-poster:hover .cinema-play{transform:scale(1.12)}
.cinema-label{position:absolute;right:10px;top:10px;background:rgba(14,15,18,0.65);border-radius:var(--radius-sm);padding:4px 8px;font-size:11px;font-weight:600;backdrop-filter:blur(6px)}
.cinema-watchbar{position:absolute;bottom:0;left:0;height:4px;background:linear-gradient(90deg,#60A5FA,#0071E3)}
.cinema-details{padding:14px;position:relative}.cinema-details strong{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:13.5px;font-weight:650;padding-right:24px}.cinema-details small{display:block;color:var(--text-secondary);font-size:11.5px;margin-top:5px}
.cinema-details .cinema-format{color:var(--text-tertiary);font-size:10.5px}
.cinema-details button{position:absolute;right:8px;top:10px;background:none;border:0;color:var(--text-secondary);padding:4px}
.cinema-details button:hover{color:var(--accent-primary)}
.badge-done{color:var(--success)!important;font-weight:600}
.badge-prog{color:var(--accent-primary)!important;font-weight:600}
.badge-warn{color:var(--warning)!important}
.cinema-empty{padding:60px 24px;display:flex;flex-direction:column;align-items:center;gap:12px;background:var(--fluid-card-fill);border-radius:var(--radius-xl);color:var(--text-secondary);border:1px solid var(--fluid-card-border);box-shadow:var(--fluid-card-shadow)}
.cinema-empty h3{color:var(--text-primary);margin:0;font-size:18px}.cinema-alert,.cinema-hint{background:var(--fluid-card-fill);color:var(--accent-primary);border:1px solid var(--fluid-card-border);box-shadow:var(--fluid-item-card-shadow);border-radius:var(--radius-md);padding:12px 18px;font-size:13px;font-weight:550;margin:14px 0}
.cinema-more{display:flex;justify-content:center;padding:26px;color:var(--text-secondary);font-size:13px}.cinema-more button{background:var(--fluid-card-fill);color:var(--accent-primary);padding:10px 20px;border-radius:var(--radius-pill);border:1px solid var(--fluid-card-border);box-shadow:var(--fluid-item-card-shadow);font-weight:600}
.cinema-foot{color:var(--text-tertiary);font-size:11.5px;line-height:1.7;margin-top:14px}
.cinema-backdrop{position:fixed;inset:0;z-index:99;display:grid;place-items:center;background:rgba(10,12,18,0.72);-webkit-backdrop-filter:blur(24px) saturate(160%);backdrop-filter:blur(24px) saturate(160%);padding:16px}
.cinema-dialog{width:min(100%,1020px);max-height:96vh;overflow:auto;border:1px solid var(--fluid-card-border);border-radius:var(--radius-xl);background:var(--fluid-card-fill);padding:22px;display:flex;flex-direction:column;gap:16px;box-shadow:var(--fluid-card-shadow);animation:modalZoomIn 0.3s var(--motion-spring)}
.cinema-dialog header,.cinema-dialog footer{display:flex;justify-content:space-between;align-items:center;gap:14px;flex-wrap:wrap;color:var(--text-secondary);font-size:12.5px}
.cinema-dialog header strong{display:block;color:var(--text-primary);font-size:16px;font-weight:700}.cinema-dialog header small{display:block;margin-top:4px}
.cinema-dialog header button{border:1px solid var(--fluid-card-border);background:var(--fluid-card-fill);color:var(--text-primary);border-radius:var(--radius-sm);width:36px;height:36px;display:grid;place-items:center;box-shadow:var(--fluid-item-card-shadow)}
.cinema-dialog video{width:100%;max-height:74vh;background:#05070A;border-radius:var(--radius-md);box-shadow:0 12px 32px rgba(0,0,0,0.5)}
.cinema-dialog footer label{display:flex;align-items:center;gap:7px;font-weight:600}
.cinema-dialog footer select{padding:8px 12px;border:1px solid var(--stroke-subtle);border-radius:var(--radius-sm);background:var(--surface-base);color:var(--text-primary);font-size:12px}
.dl-btn{background:var(--accent-primary)!important;color:#fff!important;border:0!important;border-radius:var(--radius-sm)!important;padding:10px 18px!important;font-weight:600}
.cinema-actions{display:flex;gap:10px;flex-wrap:wrap}
.cinema-season h4{margin:6px 0 10px;font-size:14px;color:var(--text-primary)}
.cinema-episode{display:flex;align-items:center;gap:12px;width:100%;text-align:left;padding:11px 14px;border:1px solid var(--fluid-card-border);border-radius:var(--radius-md);background:var(--fluid-card-fill);color:var(--text-primary);margin-bottom:8px;cursor:pointer;transition:transform var(--motion-fast) var(--motion-spring),background var(--motion-fast) ease}
.cinema-episode:hover{background:var(--fluid-card-hover);transform:translateY(-1px)}
.cinema-episode-no{font-weight:700;font-size:12.5px;color:var(--accent-primary);min-width:34px}
.cinema-episode-title{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:13px}
.cinema-episode-meta{color:var(--text-tertiary);font-size:11.5px}
.cinema-episode .badge-done,.cinema-episode .badge-prog{font-size:11px}
.resume-hint{color:var(--accent-primary);font-weight:600}
@media(max-width:700px){.cinema-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.cinema-search{flex:1}}
</style>
