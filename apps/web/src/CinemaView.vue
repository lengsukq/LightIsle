<script setup lang="ts">
import {ref,computed,onMounted,onUnmounted,watch,nextTick} from "vue";
import {Clapperboard,Film,Tv,Play,Search,RefreshCcw,X,Subtitles,Pencil} from "lucide-vue-next";
type Movie={id:number;title:string;path:string;kind:string;series:string;season:number;episode:number;year:number;size:number;playable:boolean;position:number;duration:number;completed:boolean};
type Scan={running:boolean;visited:number;found:number;lastDone:number;lastError?:string};
const props=defineProps<{admin:boolean}>();
const movies=ref<Movie[]>([]);
const mode=ref("all"),query=ref(""),next=ref(0),loading=ref(false),error=ref("");
const scan=ref<Scan>({running:false,visited:0,found:0,lastDone:0});
const selected=ref<Movie|null>(null),player=ref<HTMLVideoElement|null>(null);
const caption=ref("off"),playError=ref("");
let scanTimer:number|undefined,searchTimer:number|undefined,lastDone=0,lastSave=0;
async function api<T>(url:string,method="GET",body?:object):Promise<T>{
 const response=await fetch(url,{method,credentials:"same-origin",cache:"no-store",
 headers:method==="GET"?{}:{"Content-Type":"application/json","X-LightIsle-Request":"1"},
 body:body===undefined?undefined:JSON.stringify(body)});
 if(!response.ok){const data=await response.json().catch(()=>({error:"HTTP "+response.status})) as {error?:string};throw new Error(data.error||"request_failed")}
 return response.json() as Promise<T>;
}
async function load(reset=false){
 if(loading.value)return;loading.value=true;
 if(reset){movies.value=[];next.value=0}
 try{
  const params=new URLSearchParams({limit:"48",cursor:String(next.value)});
  if(mode.value!=="all")params.set("kind",mode.value);
  if(query.value.trim())params.set("query",query.value.trim());
  const page=await api<{films:Movie[];nextCursor:number}>("/api/v1/cinema?"+params);
  movies.value=[...movies.value,...page.films];next.value=page.nextCursor;error.value="";
 }catch(e){error.value=e instanceof Error?e.message:"加载失败"}finally{loading.value=false}
}
async function status(){
 try{
  const value=await api<{status:Scan}>("/api/v1/cinema/status");scan.value=value.status;
  if(!scan.value.running&&scan.value.lastDone&&scan.value.lastDone!==lastDone){lastDone=scan.value.lastDone;await load(true)}
 }catch{/* Mac App may have stopped */}
}
async function startScan(){
 try{await api("/api/v1/cinema/scan","POST");await status()}
 catch(e){error.value=e instanceof Error?e.message:"无法开始扫描"}
}
function filter(value:string){mode.value=value;void load(true)}
watch(query,()=>{if(searchTimer)clearTimeout(searchTimer);searchTimer=window.setTimeout(()=>void load(true),350)});
const continueCount=computed(()=>movies.value.filter(v=>v.position>5&&!v.completed).length);
function duration(v:number){const min=Math.floor(v/60);return v?min>=60?Math.floor(min/60)+"h "+min%60+"m":min+" 分钟":"时长未知"}
function percent(v:Movie){return v.duration?Math.min(100,Math.round(v.position/v.duration*100)):0}
function stream(v:Movie){return "/api/v1/cinema/"+v.id+"/stream"}
function track(v:Movie){return "/api/v1/cinema/"+v.id+"/subtitles"+(caption.value==="auto"?"":"?lang="+caption.value)}
function download(v:Movie){const a=document.createElement("a");a.href="/api/v1/files/content?path="+encodeURIComponent(v.path);a.download=v.path.split("/").pop()||v.title;a.click()}
async function open(v:Movie){
 selected.value=v;caption.value="off";playError.value="";
 if(!v.playable){playError.value="当前视频封装格式不能在浏览器直接播放，请下载使用本地播放器。";return}
 try{selected.value=await api<Movie>("/api/v1/cinema/"+v.id)}catch{/* Use list entry */}
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
  await api("/api/v1/cinema/"+v.id+"/progress","PUT",{position:current,duration:d,completed:done||d-current<8});
  v.position=current;v.duration=d;v.completed=done||d-current<8;
 }catch{/* connection may be interrupted */}
}
function tick(){const now=Date.now();if(now-lastSave>10000){lastSave=now;void save()}}
function close(){void save();player.value?.pause();selected.value=null;playError.value=""}
async function changeCaption(){
 await nextTick();
 if(!player.value)return;
 for(const t of Array.from(player.value.textTracks))t.mode=caption.value==="off"?"disabled":"showing";
}
async function rename(v:Movie){
 if(!props.admin)return;
 const title=window.prompt("修改影片展示名称",v.title)?.trim();
 if(!title||title===v.title)return;
 try{await api("/api/v1/cinema/"+v.id,"PATCH",{title});v.title=title}
 catch(e){error.value=e instanceof Error?e.message:"修改失败"}
}
function keydown(e:KeyboardEvent){if(e.key==="Escape"&&selected.value)close()}
onMounted(()=>{void load(true);void status();scanTimer=window.setInterval(()=>void status(),5000);window.addEventListener("keydown",keydown)});
onUnmounted(()=>{if(scanTimer)clearInterval(scanTimer);if(searchTimer)clearTimeout(searchTimer);window.removeEventListener("keydown",keydown);void save()});
</script>
<template>
 <div class="content cinema-view">
  <div class="section-heading">
   <div><h2>私人影院</h2><p>原片保存在 Mac 的授权共享目录，支持直接播放和断点续播。</p></div>
   <button v-if="admin" class="refresh" :disabled="scan.running" @click="startScan"><RefreshCcw :size="16" :class="{spinning: scan.running}"/>{{scan.running?"扫描中…":"扫描影视库"}}</button>
  </div>
  <div v-if="scan.running" class="cinema-alert">正在扫描：{{scan.visited}} 项 · 已找到 {{scan.found}} 部作品</div>
  <div v-if="scan.lastError" class="cinema-alert">扫描未完成：{{scan.lastError}}</div>
  <div v-if="error" class="cinema-alert" role="alert">{{error}}</div>
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
  <div v-if="!movies.length" class="cinema-empty"><Clapperboard :size="48"/><h3>{{loading?"正在索引媒体库…":"还没有影片"}}</h3><p>将影视文件拷贝到 Mac 共享目录后，点击右上角「扫描影视库」。</p></div>
  <div class="cinema-grid">
   <article v-for="movie in movies" :key="movie.id" class="cinema-tile">
    <button class="cinema-poster" :aria-label="'播放 '+movie.title" @click="open(movie)">
     <Tv v-if="movie.kind==='series'" :size="44"/><Film v-else :size="44"/>
     <span class="cinema-play"><Play :size="18" fill="currentColor"/></span>
     <span class="cinema-label">{{movie.kind==='series'?'S'+movie.season+'E'+movie.episode:(movie.year||'电影')}}</span>
     <span class="cinema-watchbar" :style="{width:percent(movie)+'%'}"></span>
    </button>
    <div class="cinema-details">
     <strong :title="movie.title">{{movie.title}}</strong>
     <small>{{movie.kind==='series'?'电视剧':'电影'}} · {{duration(movie.duration)}}</small>
     <small v-if="movie.completed" class="badge-done">已看完</small>
     <small v-else-if="movie.position>5" class="badge-prog">已看 {{percent(movie)}}%</small>
     <small v-if="!movie.playable" class="badge-warn">需下载播放</small>
     <button v-if="admin" @click="rename(movie)" title="修改展示名称"><Pencil :size="14"/></button>
    </div>
   </article>
  </div>
  <div class="cinema-more"><button v-if="next" :disabled="loading" @click="load()">{{loading?"正在加载…":"加载更多作品"}}</button><span v-else-if="movies.length">已展示全部 {{movies.length}} 部作品</span></div>
  <p class="cinema-foot">原生支持 MP4 与 WebM 在线串流；原片保留于 Mac 本机，不进行有损重编码。</p>
 </div>
 <div v-if="selected" class="cinema-backdrop" @click.self="close">
  <section class="cinema-dialog" role="dialog" aria-modal="true">
   <header><div><strong>{{selected.title}}</strong><small>{{selected.kind==='series'?'第 '+selected.season+' 季 · 第 '+selected.episode+' 集':'电影'}}</small></div><button title="关闭" @click="close"><X :size="19"/></button></header>
   <video v-if="selected.playable" ref="player" :src="stream(selected)" controls playsinline preload="metadata"
    @loadedmetadata="loaded" @timeupdate="tick" @pause="save()" @ended="save(true)"
    @error="playError='浏览器暂不能解码此视频容器，请下载后使用本机播放器播放。'">
    <track v-if="caption!=='off'" :key="caption" kind="subtitles" :src="track(selected)" :srclang="caption==='auto'?'zh':caption" label="字幕" default @load="changeCaption"/>
   </video>
   <div v-if="playError" class="cinema-alert">{{playError}}</div>
   <footer>
    <label v-if="selected.playable"><Subtitles :size="16"/>字幕 <select v-model="caption" @change="changeCaption"><option value="off">关闭</option><option value="auto">同名字幕</option><option value="zh">中文字幕</option><option value="en">英文字幕</option></select></label>
    <span v-if="selected.position>5&&!selected.completed" class="resume-hint">上次播至 {{duration(selected.position)}}</span>
    <button class="dl-btn" @click="download(selected)">下载原片文件</button>
   </footer>
  </section>
 </div>
</template>
<style scoped>
.cinema-tools{display:flex;align-items:center;justify-content:space-between;gap:14px;margin:24px 0;flex-wrap:wrap}
.cinema-tabs{display:flex;gap:8px}.cinema-tabs button,.cinema-search{display:flex;align-items:center;gap:7px;border-radius:var(--radius-pill);border:1px solid var(--stroke-subtle);background:var(--surface-raised);color:var(--text-secondary);padding:9px 16px;font-size:13px;font-weight:550}
.cinema-tabs button.active{background:var(--accent-muted);color:var(--accent-primary);border-color:var(--stroke-glass);font-weight:700}
.cinema-search input{border:0;outline:0;background:transparent;color:var(--text-primary);font-size:13px;min-width:140px}
.cinema-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:18px}
.cinema-tile{overflow:hidden;border-radius:var(--radius-lg);background:var(--surface-raised);border:1px solid var(--stroke-subtle);min-width:0;box-shadow:var(--shadow-elevated);transition:transform var(--motion-fast) var(--motion-spring),box-shadow var(--motion-fast) ease}
.cinema-tile:hover{transform:translateY(-4px);box-shadow:var(--shadow-float)}
.cinema-poster{width:100%;aspect-ratio:3/4;border:0;position:relative;display:grid;place-items:center;background:linear-gradient(135deg,#23314d,#415c82 65%,#352f52);color:#f4f7ff;overflow:hidden;cursor:pointer}
.cinema-tile:nth-child(3n+2) .cinema-poster{background:linear-gradient(135deg,#4e3352,#875f78,#3a2d54)}
.cinema-tile:nth-child(3n+3) .cinema-poster{background:linear-gradient(135deg,#24494c,#44767e,#253d50)}
.cinema-play{position:absolute;width:48px;height:48px;display:grid;place-items:center;border-radius:50%;background:rgba(255,255,255,0.25);border:1px solid rgba(255,255,255,0.5);color:#fff;backdrop-filter:blur(8px);box-shadow:0 8px 24px rgba(0,0,0,0.3);transition:transform var(--motion-fast) var(--motion-spring)}
.cinema-poster:hover .cinema-play{transform:scale(1.12)}
.cinema-label{position:absolute;right:10px;top:10px;background:rgba(14,15,18,0.65);border-radius:var(--radius-sm);padding:4px 8px;font-size:11px;font-weight:600;backdrop-filter:blur(6px)}
.cinema-watchbar{position:absolute;bottom:0;left:0;height:4px;background:linear-gradient(90deg,#60A5FA,#0071E3)}
.cinema-details{padding:14px;position:relative}.cinema-details strong{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:13.5px;font-weight:650;padding-right:24px}.cinema-details small{display:block;color:var(--text-secondary);font-size:11.5px;margin-top:5px}
.cinema-details button{position:absolute;right:8px;top:10px;background:none;border:0;color:var(--text-secondary);padding:4px}
.cinema-details button:hover{color:var(--accent-primary)}
.badge-done{color:var(--success)!important;font-weight:600}
.badge-prog{color:var(--accent-primary)!important;font-weight:600}
.badge-warn{color:var(--warning)!important}
.cinema-empty{padding:60px 24px;display:flex;flex-direction:column;align-items:center;gap:12px;background:var(--surface-raised);border-radius:var(--radius-xl);color:var(--text-secondary);border:1px solid var(--stroke-subtle)}
.cinema-empty h3{color:var(--text-primary);margin:0;font-size:18px}.cinema-alert,.cinema-hint{background:var(--accent-muted);color:var(--accent-primary);border-radius:var(--radius-md);padding:12px 18px;font-size:13px;font-weight:550;margin:14px 0}
.cinema-more{display:flex;justify-content:center;padding:26px;color:var(--text-secondary);font-size:13px}.cinema-more button{background:var(--surface-raised);color:var(--accent-primary);padding:10px 20px;border-radius:var(--radius-pill);border:1px solid var(--stroke-subtle);font-weight:600}
.cinema-foot{color:var(--text-tertiary);font-size:11.5px;line-height:1.7;margin-top:14px}
.cinema-backdrop{position:fixed;inset:0;z-index:99;display:grid;place-items:center;background:rgba(10,12,18,0.7);-webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px);padding:16px}
.cinema-dialog{width:min(100%,1020px);max-height:96vh;overflow:auto;border:1px solid var(--stroke-glass);border-radius:var(--radius-xl);background:var(--surface-raised);padding:20px;display:flex;flex-direction:column;gap:14px;box-shadow:var(--shadow-float);animation:modalZoomIn 0.3s var(--motion-spring)}
.cinema-dialog header,.cinema-dialog footer{display:flex;justify-content:space-between;align-items:center;gap:14px;flex-wrap:wrap;color:var(--text-secondary);font-size:12.5px}
.cinema-dialog header strong{display:block;color:var(--text-primary);font-size:16px;font-weight:700}.cinema-dialog header small{display:block;margin-top:4px}
.cinema-dialog header button{border:1px solid var(--stroke-subtle);background:var(--surface-base);color:var(--text-primary);border-radius:var(--radius-sm);width:36px;height:36px;display:grid;place-items:center}
.cinema-dialog video{width:100%;max-height:74vh;background:#05070A;border-radius:var(--radius-md);box-shadow:0 12px 32px rgba(0,0,0,0.5)}
.cinema-dialog footer label{display:flex;align-items:center;gap:7px;font-weight:600}
.cinema-dialog footer select{padding:8px 12px;border:1px solid var(--stroke-subtle);border-radius:var(--radius-sm);background:var(--surface-base);color:var(--text-primary);font-size:12px}
.dl-btn{background:var(--accent-primary)!important;color:#fff!important;border:0!important;border-radius:var(--radius-sm)!important;padding:10px 18px!important;font-weight:600}
.resume-hint{color:var(--accent-primary);font-weight:600}
@media(max-width:700px){.cinema-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.cinema-search{flex:1}}
</style>
