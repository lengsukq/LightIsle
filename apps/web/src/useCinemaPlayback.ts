import {computed,nextTick,ref,type Ref} from "vue";
import type Hls from "hls.js";
import {describeRootOperationFailure} from "./rootDiscovery.ts";
import {readApiFailure} from "./apiFailure.ts";
import {createPlaybackProgressWriter,type ProgressSnapshot} from "./playbackProgressWriter.ts";
import {cinemaTimeline,cinemaSeekTarget} from "./cinemaTimeline.ts";
import type {AudioTrackInfo,BrowserPlayback,Movie,SubtitleTrackInfo,TrackInfo,TranscodeSession} from "./cinemaTypes.ts";

type CinemaApi=<T>(url:string,method?:string,body?:object,signal?:AbortSignal)=>Promise<T>;
type CinemaRootProps={rootId?:string;rootGeneration?:number};

export function useCinemaPlayback({
 selected,movies,props,api,apiPath,mediaPath,
}:{
 selected:Ref<Movie|null>;
 movies:Ref<Movie[]>;
 props:CinemaRootProps;
 api:CinemaApi;
 apiPath:(path:string)=>string;
 mediaPath:(path:string)=>string;
}){
 const player=ref<HTMLVideoElement|null>(null);
 function playbackClock(){
 const film=selected.value,video=activeVideo(),session=hlsSession.value;
 if(!film||!video)return null;
 return cinemaTimeline(video.currentTime,video.duration,session?.start??0,film.durationSeconds??0);
}
function refreshPlaybackClock(){
 const clock=playbackClock();
 if(!clock)return;
 playbackPosition.value=clock.position;
 playbackDuration.value=clock.duration;
}
async function jumpPlayback(seconds:number){
 const film=selected.value,video=activeVideo(),session=hlsSession.value;
 if(!film||!video||hlsStarting.value)return;
 const clock=playbackClock();
 if(!clock)return;
 const target=cinemaSeekTarget(clock.position,seconds,clock.duration);
 if(session){
  // HLS is generated starting at the requested offset. A native seek cannot
  // jump earlier than session.start and may exceed the playlist's live edge.
  void save();
  await startTranscode(film,target,session.audioTrack,session.quality);
 }else{
  video.currentTime=target;
  refreshPlaybackClock();
  void save();
 }
 seekPreview.value=null;
}
function seekAbsolute(position:number){
 if(!Number.isFinite(position)||hlsStarting.value)return;
 const clock=playbackClock();
 if(clock)void jumpPlayback(position-clock.position);
}
async function toggleCinemaFullscreen(container?:HTMLElement|null){
 const video=activeVideo() as (HTMLVideoElement & {webkitEnterFullscreen?:()=>void})|null;
 const target=container??video;
 if(!target)return;
 try{
  if(document.fullscreenElement)await document.exitFullscreen();
  else if(typeof target.requestFullscreen==="function")await target.requestFullscreen();
  else if(video&&typeof video.webkitEnterFullscreen==="function")video.webkitEnterFullscreen();
  isFullscreen.value=Boolean(document.fullscreenElement);
 }catch{
  if(video&&typeof video.webkitEnterFullscreen==="function"){try{video.webkitEnterFullscreen();return}catch{}}
  playError.value="当前浏览器不支持此播放模式，请尝试系统全屏快捷键。";
 }
}
async function toggleCinemaPictureInPicture(){
 const video=activeVideo();
 if(!video||!document.pictureInPictureEnabled)return;
 try{
  if(document.pictureInPictureElement)await document.exitPictureInPicture();
  else await video.requestPictureInPicture();
 }catch{playError.value="当前设备无法开启画中画。"}
}
const isPlaying=ref(false),volume=ref(1),isMuted=ref(false),fillScreen=ref(false),isFullscreen=ref(false);
let lastNonZeroVolume=1;
function syncVideoMediaState(){
 const p=activeVideo();
 if(!p)return;
 isPlaying.value=!p.paused&&!p.ended;
 isMuted.value=p.muted||p.volume===0;
 volume.value=p.muted?0:p.volume;
 if(p.volume>0&&!p.muted)lastNonZeroVolume=p.volume;
}
async function togglePlayPause(){
 const p=activeVideo();
 if(!p||hlsStarting.value)return;
 if(p.paused||p.ended){
  try{await p.play()}catch{}
 }else{
  p.pause();
  void save();
 }
 syncVideoMediaState();
}
function setVolume(next:number){
 const clamped=Math.max(0,Math.min(1,Number.isFinite(next)?next:1));
 if(clamped>0)lastNonZeroVolume=clamped;
 volume.value=clamped;
 isMuted.value=clamped===0;
 for(const v of [player.value,hlsPlayer.value]){
  if(!v)continue;
  v.muted=clamped===0;
  if(clamped>0)v.volume=clamped;
 }
}
function toggleMute(){
 if(isMuted.value||volume.value===0){
  setVolume(lastNonZeroVolume>0?lastNonZeroVolume:1);
 }else{
  setVolume(0);
 }
}
function toggleFillScreen(){fillScreen.value=!fillScreen.value}
function syncFullscreenState(){isFullscreen.value=Boolean(document.fullscreenElement)}
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
let transcodeRequestGeneration=0;
function readPlaybackPreference(){
 try{const rate=Number(window.localStorage.getItem("lightisle-cinema-playback-rate"));return [0.75,1,1.25,1.5,2].includes(rate)?rate:1}
 catch{return 1}
}
const playbackRate=ref(readPlaybackPreference());
const autoplayNext=ref((()=>{try{return window.localStorage.getItem("lightisle-cinema-autoplay-next")==="yes"}catch{return false}})());
const preferLocalDecode=ref((()=>{try{return window.localStorage.getItem("lightisle-cinema-prefer-local-decode")==="yes"}catch{return false}})());
const directLocalOverride=ref(preferLocalDecode.value);
function setAutoplayNext(checked:boolean){
 autoplayNext.value=checked;
 try{
  if(checked)window.localStorage.setItem("lightisle-cinema-autoplay-next","yes");
  else window.localStorage.removeItem("lightisle-cinema-autoplay-next");
 }catch{/* Private browsing must not prevent playing videos. */}
}
function setPreferLocalDecode(checked:boolean){
 preferLocalDecode.value=checked;
 directLocalOverride.value=checked;
 try{
  if(checked)window.localStorage.setItem("lightisle-cinema-prefer-local-decode","yes");
  else window.localStorage.removeItem("lightisle-cinema-prefer-local-decode");
 }catch{}
 if(selected.value){
  if(checked)void switchQuality("local");
  else if(playback(selected.value)==="download-only")void switchQuality("source");
 }
}
const playbackPosition=ref(0),playbackDuration=ref(0);
const canPictureInPicture=typeof document!=="undefined"&&document.pictureInPictureEnabled;
const seekPreview=ref<number|null>(null);
let pendingDirectSeek:number|null=null;
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
const failedProgressSnapshots=new Map<string,ProgressSnapshot>();
function refreshProgressSaveError(){
 const rootId=props.rootId??"",rootGeneration=props.rootGeneration??0;
 let currentRootFailures=0,otherRootFailures=0;
 for(const snapshot of failedProgressSnapshots.values()){
  if(snapshot.rootId===rootId&&snapshot.rootGeneration===rootGeneration)currentRootFailures+=1;
  else otherRootFailures+=1;
 }
 if(currentRootFailures&&otherRootFailures){
  progressSaveError.value=`当前播放进度尚未保存，另有 ${otherRootFailures} 项其他目录进度未保存；请点击重试。离开影院页面或刷新后仍未保存的进度将无法恢复。`;
 }else if(currentRootFailures){
  progressSaveError.value="播放进度尚未保存，网络恢复后请点击重试。离开影院页面或刷新后仍未保存的进度将无法恢复。";
 }else if(otherRootFailures){
  progressSaveError.value=`另有 ${otherRootFailures} 项其他存储目录的播放进度尚未保存；可在当前影院页面点击重试。离开影院页面或刷新后仍未保存的进度将无法恢复。`;
 }else{
  progressSaveError.value="";
 }
}
const progressWriter=createPlaybackProgressWriter(async snapshot=>{
 const headers=new Headers({"Content-Type":"application/json","X-LightIsle-Request":"1"});
 if(snapshot.rootId)headers.set("X-LightIsle-Root-Generation",String(snapshot.rootGeneration));
 const response=await fetch(snapshot.url,{method:"PUT",credentials:"same-origin",cache:"no-store",keepalive:true,
  headers,body:JSON.stringify({position:snapshot.position,duration:snapshot.duration,completed:snapshot.completed})});
 if(!response.ok)throw await readApiFailure(response);
},{
 onSaved:(snapshot:ProgressSnapshot)=>{
  failedProgressSnapshots.delete(snapshot.key);
  refreshProgressSaveError();
  if(snapshot.rootId!==(props.rootId??"")||snapshot.rootGeneration!==(props.rootGeneration??0))return;
  movies.value=movies.value.map(item=>item.id===snapshot.id?{...item,position:snapshot.position,duration:snapshot.duration,completed:snapshot.completed}:item);
  if(selected.value?.id===snapshot.id){selected.value.position=snapshot.position;selected.value.duration=snapshot.duration;selected.value.completed=snapshot.completed;}
 },
 onError:(_error:unknown,snapshot:ProgressSnapshot)=>{
  failedProgressSnapshots.set(snapshot.key,snapshot);
  refreshProgressSaveError();
 }
});
function retryProgress(){return progressWriter.retry()}
function currentFilmProgressUnsaved(){
 const film=selected.value;
 if(!film)return false;
 return failedProgressSnapshots.has(
  `${props.rootId??""}:${props.rootGeneration??0}:${film.id}`,
 );
}
function stream(v:Movie){
 const base=mediaPath("/api/v2/cinema/"+v.id+"/stream");
 const needDirect=playback(v)==="download-only"||preferLocalDecode.value||directLocalOverride.value;
 return needDirect?base+(base.includes("?")?"&":"?")+"direct=1":base;
}
function track(v:Movie){
 if(caption.value.startsWith("emb:"))return mediaPath("/api/v2/cinema/"+v.id+"/embedded-subtitles?track="+caption.value.slice(4));
 return mediaPath("/api/v2/cinema/"+v.id+"/subtitles"+(caption.value==="auto"?"":"?lang="+caption.value));
}
function captionLabel(v:SubtitleTrackInfo){
 const language=v.language==="chi"||v.language==="zh"?"中文":v.language==="eng"||v.language==="en"?"英文":(v.language||"内嵌");
 return "内嵌 "+language+"（"+(v.codec||"?")+"，样式简化）";
}
function download(v:Movie){const a=document.createElement("a");a.href=mediaPath("/api/v2/files/content?path="+encodeURIComponent(v.path));a.download=v.path.split("/").pop()||v.title;a.click()}
function playback(v:Movie):BrowserPlayback{return v.browserPlayback??(v.playable?"unverified-direct":"download-only")}
function canAttemptDirect(v:Movie){return playback(v)!=="download-only"||preferLocalDecode.value||directLocalOverride.value}
function destroyHls(){
 transcodeRequestGeneration+=1;
 if(hls){hls.destroy();hls=null}
 hlsSession.value=null;hlsTracks.value=null;hlsStarting.value=false;isPlaying.value=false;
}
async function waitForPlaylist(v:Movie,session:TranscodeSession,isCurrent:()=>boolean){
 const url=mediaPath("/api/v2/cinema/"+v.id+"/hls/"+session.sessionId+"/index.m3u8");
 for(let attempt=0;attempt<60;attempt++){
  if(!isCurrent())throw new Error("aborted");
  const response=await fetch(url,{method:"GET",credentials:"same-origin",cache:"no-store"});
  if(!isCurrent())throw new Error("aborted");
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
 const requestGeneration=transcodeRequestGeneration;
 const requestRoot=props.rootId;
 const requestRootGeneration=props.rootGeneration??0;
 const isCurrent=()=>requestGeneration===transcodeRequestGeneration&&
  selected.value?.id===v.id&&props.rootId===requestRoot&&
  (props.rootGeneration??0)===requestRootGeneration;
 hlsQuality.value=quality;
 try{
  const session=await api<TranscodeSession>(apiPath("/api/v2/cinema/"+v.id+"/hls/session?start="+encodeURIComponent(startSeconds.toFixed(3))+"&audio="+audio+(quality&&quality!=="source"?"&quality="+quality:"")));
  if(!isCurrent())return;
  hlsSession.value=session;
  await nextTick();
  if(!isCurrent())return;
  const video=hlsPlayer.value;
  if(!video)throw new Error("transcode_failed");
  const url=await waitForPlaylist(v,session,isCurrent);
  if(!isCurrent())return;
  if(video.canPlayType("application/vnd.apple.mpegurl")){
   video.src=url;
  }else{
   // Load the large HLS library only if the user actually needs transcoded
   // playback on a browser without native HLS support.
   const {default:Hls}=await import("hls.js");
   if(!isCurrent())return;
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
    if(data.fatal&&isCurrent()){
     playError.value="转码播放中断（"+(data.details||"media_error")+"）。可重新点击转码播放，或下载原片用 IINA/VLC 播放。";
    }
   });
  }
  try{
   const result=await api<{tracks:TrackInfo}>(apiPath("/api/v2/cinema/"+v.id+"/tracks"));
   if(isCurrent())hlsTracks.value=result.tracks;
  }catch{/* tracks are optional; playback continues without selectors */}
  if(!isCurrent())return;
  applyPlaybackRate();
 }catch(e){
  if(isCurrent()){
   destroyHls();
   if(e instanceof Error&&e.message==="transcode_unavailable"){
    directLocalOverride.value=true;
    pendingDirectSeek=startSeconds>0?startSeconds:null;
    playError.value="服务器未安装 FFmpeg，已自动启用原片直传（本地解码）。";
   }else{
    playError.value=transcodeErrorMessage(e);
   }
  }
 }
 finally{if(isCurrent())hlsStarting.value=false}
}
async function switchAudioTrack(audioIndex:number){
 const v=selected.value,session=hlsSession.value,p=hlsPlayer.value;
 if(!v||!session||hlsStarting.value)return;
 const realPosition=p&&Number.isFinite(p.currentTime)?p.currentTime+session.start:0;
 void save();
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
 void save();
 if(quality==="local"){
  directLocalOverride.value=true;
  pendingDirectSeek=Math.max(0,realPosition);
  destroyHls();playError.value=playback(v)==="download-only"?"原片直传（本地解码）播放中。":"";
  await nextTick();
  return;
 }
 directLocalOverride.value=false;
 if(quality==="source"&&playback(v)!=="download-only"&&!preferLocalDecode.value){
  pendingDirectSeek=Math.max(0,realPosition);
  destroyHls();playError.value="";
  await nextTick();
  return;
 }
 await startTranscode(v,Math.max(0,realPosition),session?session.audioTrack:0,quality);
}
function qualityOptions(v:Movie){
 const options=[{value:"source",label:"原画"},{value:"local",label:"本地硬解"}];
 const sourceHeight=v.height||0;
 for(const tier of [{value:"1080",label:"1080P",height:1080},{value:"720",label:"720P",height:720},{value:"480",label:"480P",height:480}]){
  if(sourceHeight>0&&sourceHeight<=tier.height)break;
  options.push({value:tier.value,label:tier.label});
 }
 return options;
}
const captionOptions=computed(()=>{
 const opts=[
  {value:"off",label:"关闭"},
  {value:"auto",label:"同名字幕"},
  {value:"zh",label:"中文字幕"},
  {value:"en",label:"英文字幕"},
 ];
 const extractable=(hlsTracks.value?.subtitles??[]).filter((s)=>s.extractable);
 for(const t of extractable){
  opts.push({value:`emb:${t.streamIndex}`,label:captionLabel(t)});
 }
 return opts;
});
const audioTrackOptions=computed(()=>{
 return (hlsTracks.value?.audio??[]).map((t)=>({
  value:t.audioIndex,
  label:`${t.title||t.language||`音轨 ${t.audioIndex+1}`}${t.codec?` · ${t.codec}`:""}${t.channels?` · ${t.channels}ch`:""}`,
 }));
});
const currentQuality=computed(()=>{
 if(hlsSession.value)return hlsSession.value.quality;
 const film=selected.value;
 if(film&&(directLocalOverride.value||preferLocalDecode.value)&&playback(film)==="download-only")return "local";
 return film?qualityOptions(film)[0]?.value??"source":"source";
});
const cinemaQualityOptions=computed(()=>{
 const film=selected.value;
 if(!film)return [];
 return qualityOptions(film).map((opt)=>({
  value:opt.value,
  label:`${opt.label}${opt.value==="source"&&playback(film)==="download-only"?"（转封装）":""}`,
 }));
});
const playbackRateOptions=[
 {value:0.75,label:"0.75x"},
 {value:1,label:"1x"},
 {value:1.25,label:"1.25x"},
 {value:1.5,label:"1.5x"},
 {value:2,label:"2x"},
];
function applyPlaybackRate(){
 const p=activeVideo();
 if(p)p.playbackRate=playbackRate.value;
}
function setPlaybackRate(rate:number){
 if(![0.75,1,1.25,1.5,2].includes(rate))return;
 playbackRate.value=rate;
 applyPlaybackRate();
 try{window.localStorage.setItem("lightisle-cinema-playback-rate",String(rate))}catch{}
}
function activeVideo(){return hlsSession.value?hlsPlayer.value:player.value}
function loaded(){
 const v=selected.value,p=activeVideo(),session=hlsSession.value;
 if(!v||!p)return;
 applyPlaybackRate();
 p.muted=isMuted.value;
 if(volume.value>0)p.volume=volume.value;
 if(!session&&pendingDirectSeek!==null){
  const target=pendingDirectSeek;pendingDirectSeek=null;
  if(Number.isFinite(p.duration)&&p.duration>target)p.currentTime=target;
  refreshPlaybackClock();
  void p.play().catch(()=>{});
  syncVideoMediaState();
  return;
 }
 const resume=v.position>5&&!v.completed;
 if(!session){
  if(resume&&p.duration>v.position+5)p.currentTime=v.position;
  refreshPlaybackClock();
  void p.play().catch(()=>{});
  syncVideoMediaState();
  return;
 }
 const target=v.position-session.start;
 if(resume&&target>1&&p.duration>target+5)p.currentTime=target;
 else if(session.start>0)p.currentTime=0;
 refreshPlaybackClock();
 void p.play().catch(()=>{});
 syncVideoMediaState();
}
async function save(done=false){
 const v=selected.value,p=activeVideo(),session=hlsSession.value;
 if(!v||!p||!Number.isFinite(p.duration)||p.duration<=0)return;
 if(!Number.isFinite(p.currentTime)||p.currentTime<0)return;
 const clock=cinemaTimeline(p.currentTime,p.duration,session?.start??0,v.durationSeconds??0);
 const current=clock.position,d=clock.duration;
 const rootId=props.rootId??"",rootGeneration=props.rootGeneration??0;
 const snapshot:ProgressSnapshot={key:`${rootId}:${rootGeneration}:${v.id}`,id:v.id,rootId,rootGeneration,
  url:apiPath("/api/v2/cinema/"+v.id+"/progress"),position:current,duration:d,completed:done||clock.nearEnd};
 await progressWriter.save(snapshot);
}
let lastSave=0;
function resetProgressClock(){lastSave=0}
function tick(){refreshPlaybackClock();const now=Date.now();if(now-lastSave>10000){lastSave=now;void save()}}
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
 function resetPendingSeek(){pendingDirectSeek=null}

 return {
  player,hlsPlayer,caption,playError,hlsSession,hlsTracks,hlsStarting,hlsQuality,
  playbackRate,autoplayNext,preferLocalDecode,directLocalOverride,playbackPosition,playbackDuration,canPictureInPicture,seekPreview,
  progressSaveError,retryProgress,currentFilmProgressUnsaved,stream,track,download,playback,canAttemptDirect,destroyHls,
  refreshProgressSaveError,
  resetPendingSeek,startTranscode,switchAudioTrack,switchQuality,playbackRateOptions,
  captionOptions,audioTrackOptions,currentQuality,cinemaQualityOptions,setPlaybackRate,
  setAutoplayNext,setPreferLocalDecode,activeVideo,loaded,save,tick,resetProgressClock,changeCaption,captionSrclang,
  jumpPlayback,seekAbsolute,toggleCinemaFullscreen,toggleCinemaPictureInPicture,transcodeErrorMessage,
  isPlaying,volume,isMuted,fillScreen,isFullscreen,syncVideoMediaState,togglePlayPause,setVolume,toggleMute,toggleFillScreen,syncFullscreenState,
 };
}
