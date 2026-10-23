<script setup lang="ts">
import {ref,computed,onMounted,onUnmounted,watch,nextTick} from "vue";
import {Clapperboard,Film,Tv,Play,Download,Search,RefreshCcw,X,Subtitles,Pencil} from "lucide-vue-next";
import {createLatestRequestGate} from "./latestRequestGate.js";
import {rootApiPath,rootMediaPath} from "./rootApi.js";
import {tmdbCandidateScore} from "./cinemaCandidateScore.js";
import {isTMDBAuthenticationFailure,runSequentialTMDBBatch} from "./tmdbBatch.js";
type BrowserPlayback="verified-direct"|"unverified-direct"|"download-only";
type ProbeStatus="pending"|"ready"|"unsupported"|"unavailable"|"failed";
type Movie={id:number;title:string;path:string;kind:string;series:string;season:number;episode:number;year:number;size:number;playable?:boolean;browserPlayback?:BrowserPlayback;probeStatus?:ProbeStatus;mime?:string;container?:string;videoCodec?:string;audioCodec?:string;durationSeconds?:number;width?:number;height?:number;position:number;duration:number;completed:boolean;overview?:string;rating?:number;metadataSource?:string;titleSource?:string;yearSource?:string;posterURL?:string};
type TMDBCandidate={id:number;kind:string;title:string;year?:string;overview?:string;rating:number;posterURL?:string};
type DoubanCandidate={id:string;title:string;year?:string;kind?:string};
type Scan={running:boolean;visited:number;found:number;lastDone:number;lastError?:string};
const props=defineProps<{admin:boolean;rootId?:string;rootGeneration?:number}>();
const movies=ref<Movie[]>([]);
const mode=ref("all"),query=ref(""),next=ref(0),loading=ref(false),error=ref("");
const loadError=ref("");
const loadErrorReset=ref(true);
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
let scanTimer:number|undefined,searchTimer:number|undefined,lastDone=0,lastSave=0;
let loadGeneration=0;
let disposed=false;
watch([()=>props.rootId,()=>props.rootGeneration],()=>cancelBatch());
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
async function load(reset=false){
 if(loading.value&&!reset)return;
 const generation=++loadGeneration;
 loading.value=true;
 loadError.value="";
 if(reset){movies.value=[];next.value=0}
 try{
  const params=new URLSearchParams({limit:"48",cursor:String(next.value)});
  if(mode.value!=="all")params.set("kind",mode.value);
  if(query.value.trim())params.set("query",query.value.trim());
  const page=await api<{films:Movie[];nextCursor:number}>(apiPath("/api/v1/cinema")+"?"+params);
  if(generation!==loadGeneration)return;
  movies.value=[...movies.value,...page.films];next.value=page.nextCursor;error.value="";loadError.value="";
 }catch(e){if(generation===loadGeneration){loadError.value=e instanceof Error?e.message:"加载失败";loadErrorReset.value=reset;error.value="加载影视库失败："+loadError.value}}finally{if(generation===loadGeneration)loading.value=false}
}
function retryLoad(){void load(loadErrorReset.value)}
async function status(){
 try{
  const value=await api<{status:Scan}>(apiPath("/api/v1/cinema/status"));scan.value=value.status;
  if(!scan.value.running&&scan.value.lastDone&&scan.value.lastDone!==lastDone){lastDone=scan.value.lastDone;await load(true)}
 }catch{/* Mac App may have stopped */}
}
async function startScan(){
 try{await api(apiPath("/api/v1/cinema/scan"),"POST");await status()}
 catch(e){error.value=e instanceof Error?e.message:"无法开始扫描"}
}
function filter(value:string){mode.value=value;void load(true)}
watch(query,()=>{if(searchTimer)clearTimeout(searchTimer);searchTimer=window.setTimeout(()=>void load(true),350)});
const continueCount=computed(()=>movies.value.filter(v=>v.position>5&&!v.completed).length);
function duration(v:number){const min=Math.floor(v/60);return v?min>=60?Math.floor(min/60)+"h "+min%60+"m":min+" 分钟":"时长未知"}
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
function track(v:Movie){return mediaPath("/api/v1/cinema/"+v.id+"/subtitles"+(caption.value==="auto"?"":"?lang="+caption.value))}
function download(v:Movie){const a=document.createElement("a");a.href=mediaPath("/api/v1/files/content?path="+encodeURIComponent(v.path));a.download=v.path.split("/").pop()||v.title;a.click()}
async function open(v:Movie){
 selectedController?.abort();
 cancelMetadataRequests();
 tmdbQuery.value=v.title;tmdbToken.value="";tmdbMatches.value=[];candidatePosterFailed.value={};tmdbError.value="";scrapeMessage.value="";
 doubanQuery.value=v.title;doubanMatches.value=[];doubanError.value="";
 const controller=new AbortController();selectedController=controller;
 selected.value=v;caption.value="off";playError.value="";
 if(playback(v)==="download-only"){
  playError.value=v.probeStatus==="pending"
   ?"正在识别此视频格式，当前无法判断是否可直接播放。识别完成后可重新打开，也可以先下载原片。"
   :playbackLabel(v)+"。可下载原片后用 IINA、VLC 或系统播放器打开；LightIsle 不会转换或修改源视频。";
  return;
 }
 if(playback(v)==="unverified-direct")playError.value="该格式尚未经过本机解码验证，正在尝试浏览器播放；若无法解码，请下载原片使用本地播放器。";
 try{
  const detail=await api<Movie>(apiPath("/api/v1/cinema/"+v.id),"GET",undefined,controller.signal);
  if(controller.signal.aborted||selected.value?.id!==v.id)return;
  selected.value=detail;
  if(playback(detail)==="download-only")playError.value=playbackLabel(detail)+"。请下载原片后用 IINA、VLC 或系统播放器打开。";
  else if(playback(detail)==="unverified-direct")playError.value="该格式尚未经过本机解码验证，正在尝试浏览器播放；若无法解码，请下载原片使用本地播放器。";
  else playError.value="";
 }catch(e){if(!(e instanceof Error&&e.name==="AbortError")){/* Keep list metadata and the visible fallback guidance */}}
}
function loaded(){
 const v=selected.value,p=player.value;
 if(v&&p&&v.position>5&&!v.completed&&p.duration>v.position+5)p.currentTime=v.position;
}
async function save(done=false){
 const v=selected.value,p=player.value;
 if(!v||!p||!Number.isFinite(p.duration)||p.duration<=0)return;
 const current=p.currentTime,d=p.duration;
 try{
  await api(apiPath("/api/v1/cinema/"+v.id+"/progress"),"PUT",{position:current,duration:d,completed:done||d-current<8});
  v.position=current;v.duration=d;v.completed=done||d-current<8;
 }catch{/* connection may be interrupted */}
}
function tick(){const now=Date.now();if(now-lastSave>10000){lastSave=now;void save()}}
function close(){selectedController?.abort();selectedController=undefined;cancelMetadataRequests();void save();player.value?.pause();selected.value=null;playError.value="";tmdbToken.value="";tmdbMatches.value=[];tmdbError.value="";doubanMatches.value=[];doubanError.value="";scrapeMessage.value=""}
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
 if(!player.value)return;
 for(const t of Array.from(player.value.textTracks))t.mode=caption.value==="off"?"disabled":"showing";
}
async function rename(v:Movie){
 if(!props.admin)return;
 const title=window.prompt("修改影片展示名称",v.title)?.trim();
 if(!title||title===v.title)return;
 try{await api(apiPath("/api/v1/cinema/"+v.id),"PATCH",{title});v.title=title}
 catch(e){error.value=e instanceof Error?e.message:"修改失败"}
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
function keydown(e:KeyboardEvent){if(e.key==="Escape"&&selected.value)close()}
onMounted(()=>{disposed=false;void load(true);void status();scanTimer=window.setInterval(()=>void status(),5000);window.addEventListener("keydown",keydown)});
onUnmounted(()=>{disposed=true;if(scanTimer)clearInterval(scanTimer);if(searchTimer)clearTimeout(searchTimer);selectedController?.abort();cancelMetadataRequests();cancelBatch();tmdbToken.value="";window.removeEventListener("keydown",keydown);void save()});
</script>
<template>
 <div class="content cinema-view">
  <div class="section-heading">
   <div><h2>私人影院</h2><p>原片保存在 Mac 的授权共享目录，播放能力按实际格式检查结果显示。</p></div>
   <button v-if="admin" class="refresh" :disabled="scan.running" @click="startScan"><RefreshCcw :size="16" :class="{spinning: scan.running}"/>{{scan.running?"扫描中…":"扫描影视库"}}</button>
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
  <div v-if="scan.running" class="cinema-alert">正在扫描：{{scan.visited}} 项 · 已找到 {{scan.found}} 部作品</div>
  <div v-if="scan.lastError" class="cinema-alert">扫描未完成：{{scan.lastError}}</div>
  <div v-if="error&&movies.length" class="cinema-alert" role="alert">{{error}} <button v-if="loadError" type="button" class="account-action" :disabled="loading" @click="retryLoad">重试加载</button></div>
  <div class="cinema-tools">
   <div class="cinema-tabs">
    <button :class="{active:mode==='all'}" @click="filter('all')"><Clapperboard :size="15"/>全部</button>
    <button :class="{active:mode==='movie'}" @click="filter('movie')"><Film :size="15"/>电影</button>
    <button :class="{active:mode==='series'}" @click="filter('series')"><Tv :size="15"/>剧集</button>
    <button :class="{active:mode==='continue'}" @click="filter('continue')">继续观看</button>
   </div>
   <label class="cinema-search"><Search :size="16"/><input v-model="query" maxlength="120" type="search" placeholder="搜索影片或剧集"/></label>
  </div>
  <p v-if="continueCount" class="cinema-hint">当前列表有 {{continueCount}} 部作品可继续观看</p>
  <div v-if="!movies.length&&(loading||scan.running)" class="cinema-empty"><Clapperboard :size="48"/><h3>{{scan.running?"正在扫描影视库…":"正在读取影视库…"}}</h3><p>正在检查 Mac 授权的共享目录。</p></div>
  <div v-else-if="!movies.length&&(loadError||error||scan.lastError)" class="cinema-empty" role="alert">
   <Clapperboard :size="48"/><h3>暂时无法读取影视库</h3>
   <p>{{loadError?"加载影视库失败："+loadError:error||"上次扫描未完成："+scan.lastError}}</p>
   <button v-if="loadError" type="button" class="refresh" :disabled="loading" @click="retryLoad">重试读取影视库</button>
   <button v-else-if="admin" type="button" class="refresh" :disabled="scan.running" @click="startScan">重新扫描</button>
   <p v-else>请联系管理员检查共享目录或重新执行扫描。</p>
  </div>
  <div v-else-if="!movies.length" class="cinema-empty"><Clapperboard :size="48"/><h3>还没有影片</h3><p>将影视文件拷贝到 Mac 共享目录后，点击右上角「扫描影视库」。</p></div>
  <div class="cinema-grid">
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
  <div class="cinema-more"><button v-if="next" :disabled="loading" @click="load()">{{loading?"正在加载…":"加载更多作品"}}</button><span v-else-if="movies.length">已展示全部 {{movies.length}} 部作品</span></div>
  <p class="cinema-foot">已验证格式可直接播放；未验证格式会明确提示尝试播放或下载。原片保留于 Mac 本机，不进行有损重编码。</p>
 </div>
 <Teleport to="body">
 <div v-if="selected" class="cinema-backdrop" @click.self="close">
  <section class="cinema-dialog" role="dialog" aria-modal="true">
   <header><div><strong>{{selected.title}}</strong><small>{{selected.kind==='series'?'第 '+selected.season+' 季 · 第 '+selected.episode+' 集':'电影'}}</small></div><button title="关闭" @click="close"><X :size="19"/></button></header>
   <video v-if="canAttemptDirect(selected)" ref="player" :src="stream(selected)" controls playsinline preload="metadata"
    @loadedmetadata="loaded" @timeupdate="tick" @pause="save()" @ended="save(true)"
    @error="playError='浏览器无法解码该视频格式。可下载原片后使用 IINA 或 VLC 播放，原视频不会被修改。'">
    <track v-if="caption!=='off'" :key="caption" kind="subtitles" :src="track(selected)" :srclang="caption==='auto'?'zh':caption" label="字幕" default @load="changeCaption"/>
   </video>
   <div v-if="playError" class="cinema-alert">{{playError}}</div>
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
    <label v-if="canAttemptDirect(selected)"><Subtitles :size="16"/>字幕 <select v-model="caption" @change="changeCaption"><option value="off">关闭</option><option value="auto">同名字幕</option><option value="zh">中文字幕</option><option value="en">英文字幕</option></select></label>
    <span v-if="selected.position>5&&!selected.completed" class="resume-hint">上次播至 {{duration(selected.position)}}</span>
    <button class="dl-btn" @click="download(selected)">下载原片文件</button>
    <button v-if="admin" class="dl-btn" :disabled="scraping||tmdbBusy" @click="importLocalNFO(selected)">{{scraping?"读取中…":tmdbBusy?"正在处理资料…":"导入本地 NFO 资料"}}</button>
   </footer>
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
.resume-hint{color:var(--accent-primary);font-weight:600}
@media(max-width:700px){.cinema-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.cinema-search{flex:1}}
</style>
