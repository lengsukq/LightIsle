<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import { Heart, RefreshCw, Images, Film, Plus, X, FolderPlus, ChevronDown } from "lucide-vue-next";

type Asset={id:number;path:string;name:string;type:"photo"|"video";size:number;takenAt:number;favorite:boolean};
type Album={id:number;name:string;count:number};
type Status={running:boolean;scanned:number;found:number;lastError?:string;lastDone?:number};
const props=defineProps<{admin:boolean}>();
const assets=ref<Asset[]>([]);
const albums=ref<Album[]>([]);
const activeAlbum=ref(0);
const favoritesOnly=ref(false);
const nextCursor=ref(0);
const loading=ref(false);
const message=ref("");
const scan=ref<Status>({running:false,scanned:0,found:0});
const selected=ref<Asset|null>(null);
const creating=ref(false);
const albumName=ref("");
const addAlbum=ref(0);
let timer:number|undefined;
let lastCompletedScan=0;
async function api<T>(url:string,method="GET",body?:object):Promise<T>{
 const response=await fetch(url,{
  method,credentials:"same-origin",
  headers:method==="GET"?{}:{"Content-Type":"application/json","X-LightIsle-Request":"1"},
  body:body?JSON.stringify(body):undefined,cache:"no-store"
 });
 if(!response.ok){
  const data=await response.json().catch(()=>({error:"request_failed"})) as {error?:string};
  throw new Error(data.error??String(response.status));
 }
 return await response.json() as T;
}
async function status(){
 try{
  const result=await api<{status:Status;count:number}>("/api/v1/photos/status");
  scan.value=result.status;
  if(!scan.value.running && scan.value.lastDone && scan.value.lastDone>lastCompletedScan){
   lastCompletedScan=scan.value.lastDone;
   await load(true);
   await refreshAlbums();
  }
 }catch {/* App may have been stopped */}
}
async function load(reset=false){
 if(loading.value)return;
 loading.value=true;
 if(reset){nextCursor.value=0;assets.value=[];}
 try {
  const query=new URLSearchParams({limit:"48",cursor:String(nextCursor.value)});
  if(activeAlbum.value)query.set("album",String(activeAlbum.value));
  if(favoritesOnly.value)query.set("favorites","1");
  const result=await api<{assets:Asset[];nextCursor:number}>("/api/v1/photos?"+query.toString());
  assets.value=[...assets.value,...result.assets];
  nextCursor.value=result.nextCursor;
  message.value="";
 }catch(e){message.value="加载照片失败："+(e instanceof Error?e.message:"未知错误")}
 finally{loading.value=false}
}
async function refreshAlbums(){
 try{const result=await api<{albums:Album[]}>("/api/v1/photos/albums");albums.value=result.albums}catch{}
}
async function startScan(){
 try{await api("/api/v1/photos/scan","POST");message.value="正在后台扫描授权的共享目录";await status()}
 catch(e){message.value="无法启动扫描："+(e instanceof Error?e.message:"未知错误")}
}
async function toggleFavorite(asset:Asset){
 try{
  await api("/api/v1/photos/"+asset.id+"/favorite","POST",{favorite:!asset.favorite});
  asset.favorite=!asset.favorite;
 }catch(e){message.value="收藏失败："+(e instanceof Error?e.message:"未知错误")}
}
async function createAlbum(){
 const name=albumName.value.trim();if(!name)return;
 try{
  await api("/api/v1/photos/albums","POST",{name});
  albumName.value="";creating.value=false;await refreshAlbums()
 }catch(e){message.value="创建相册失败："+(e instanceof Error?e.message:"未知错误")}
}
async function addSelected(){
 if(!selected.value || !addAlbum.value)return;
 try{
  await api("/api/v1/photos/albums/"+addAlbum.value+"/items","POST",{assetId:selected.value.id});
  message.value="已加入相册";
  await refreshAlbums();
 }catch(e){message.value="加入相册失败："+(e instanceof Error?e.message:"未知错误")}
}
function changeView(album:number,favorites:boolean){
 activeAlbum.value=album;favoritesOnly.value=favorites;void load(true)
}
function dateLabel(timestamp:number){
 return new Date(timestamp*1000).toLocaleDateString("zh-CN",{year:"numeric",month:"long",day:"numeric"});
}
function thumb(asset:Asset){return "/api/v1/photos/"+asset.id+"/thumbnail"}
function original(asset:Asset){return "/api/v1/files/preview?path="+encodeURIComponent(asset.path)}
onMounted(()=>{void load(true);void refreshAlbums();void status();timer=window.setInterval(()=>void status(),4500)});
onUnmounted(()=>{if(timer)clearInterval(timer)});
</script>

<template>
  <div class="content photos-page">
    <div class="section-heading">
      <div><h2>照片图库</h2><p>你的每个瞬间，保存在自己的 Mac 上。</p></div>
      <button v-if="admin" type="button" class="refresh" @click="startScan" :disabled="scan.running">
        <RefreshCw :size="16" :class="{spinning:scan.running}" /> {{scan.running?"扫描中…":"扫描媒体"}}
      </button>
    </div>
    <div v-if="scan.running" class="scan-banner">正在后台整理媒体 · 已检查 {{scan.scanned}} 项 · 发现 {{scan.found}} 项</div>
    <p v-if="scan.lastError" class="form-error">上次扫描：{{scan.lastError}}</p>
    <p v-if="message" class="gallery-message">{{message}}</p>
    <div class="album-toolbar">
      <div class="album-tabs">
        <button type="button" :class="{chosen:activeAlbum===0&&!favoritesOnly}" @click="changeView(0,false)"><Images :size="15"/> 全部照片</button>
        <button type="button" :class="{chosen:favoritesOnly}" @click="changeView(0,true)"><Heart :size="15"/> 我的收藏</button>
        <button v-for="album in albums" :key="album.id" type="button" :class="{chosen:activeAlbum===album.id}" @click="changeView(album.id,false)">{{album.name}} <small>{{album.count}}</small></button>
      </div>
      <button type="button" class="album-create" @click="creating=!creating"><Plus :size="17"/> 新建相册</button>
    </div>
    <form v-if="creating" class="album-new" @submit.prevent="createAlbum">
      <FolderPlus :size="18"/><input v-model="albumName" maxlength="60" placeholder="相册名称" required/>
      <button type="submit">创建</button>
    </form>
    <div v-if="loading && !assets.length" class="gallery-empty">正在读取媒体索引…</div>
    <div v-else-if="!assets.length" class="gallery-empty">
      <Images :size="40" :stroke-width="1.2" />
      <h3>这里还没有照片</h3>
      <p>在文件管理中上传照片或视频，然后点击「扫描媒体」。<span v-if="!admin">请让管理员执行扫描。</span></p>
    </div>
    <div class="photo-grid">
      <button v-for="asset in assets" :key="asset.id" type="button" class="photo-tile" @click="selected=asset">
        <img v-if="asset.type==='photo'" :src="thumb(asset)" loading="lazy" :alt="asset.name"/>
        <div v-else class="video-placeholder"><Film :size="26"/><small>视频</small></div>
        <span v-if="asset.favorite" class="photo-liked"><Heart :size="16" fill="currentColor"/></span>
        <small class="photo-date">{{dateLabel(asset.takenAt)}}</small>
      </button>
    </div>
    <div class="gallery-load">
      <button v-if="nextCursor" type="button" @click="load()" :disabled="loading">{{loading?"加载中…":"加载更多"}}</button>
      <span v-else-if="assets.length">已显示 {{assets.length}} 项</span>
    </div>
    <p class="footnote">图片缩略图使用 macOS 按需生成的 JPEG 缓存；视频暂显示占位图。图库不修改或复制你的原始媒体。</p>
  </div>
  <div v-if="selected" class="dialog-backdrop" @click.self="selected=null">
    <div class="gallery-modal" role="dialog" aria-modal="true" aria-label="照片详细信息">
      <div class="gallery-modal-toolbar">
        <div><strong>{{selected.name}}</strong><small>{{dateLabel(selected.takenAt)}} · {{selected.type==="video"?"视频":"照片"}}</small></div>
        <div class="gallery-modal-actions">
          <button type="button" @click="toggleFavorite(selected)" :title="selected.favorite?'取消收藏':'收藏'"><Heart :size="19" :fill="selected.favorite?'currentColor':'none'"/></button>
          <button type="button" @click="selected=null" title="关闭"><X :size="19"/></button>
        </div>
      </div>
      <img v-if="selected.type==='photo'" :src="thumb(selected)" :alt="selected.name" class="gallery-modal-image"/>
      <video v-else controls playsinline :src="original(selected)" class="gallery-modal-video"/>
      <div class="gallery-modal-footer">
        <select v-model.number="addAlbum" aria-label="选择相册">
          <option :value="0">选择一个相册…</option>
          <option v-for="album in albums" :key="album.id" :value="album.id">{{album.name}}</option>
        </select>
        <button type="button" :disabled="!addAlbum" @click="addSelected">加入相册 <ChevronDown :size="14"/></button>
      </div>
    </div>
  </div>
</template>

