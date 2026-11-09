<script setup lang="ts">
// Map view for located photos: Leaflet grid clusters with an honest
// degradation path — when basemap tiles are unreachable the map drops to a
// dot-matrix view and says so, and the tile server stays user-configurable.
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from "vue";
import { MapPin, Settings2, X, RefreshCw, ChevronLeft, ChevronRight, ZoomIn } from "lucide-vue-next";
import { clusterGeoPoints, geoPointsBounds } from "./mapCluster.js";
import type { GeoCluster } from "./mapCluster.js";
import { clusterCellKey, expandBounds, planMarkerChanges, selectVisibleClusters } from "./mapViewport.js";
import { describePhotoMapFailure } from "./photoMapStatus.js";
import {describeUserFacingError} from "./userFacingError.js";
import type { GeoPointDTO, MapStripAsset, MapTransport } from "./photoMapTransport.js";
import AppleSelect from "./AppleSelect.vue";

const mapSourceOptions = [
  { value: "tianditu", label: "天地图（国内推荐）" },
  { value: "osm", label: "OpenStreetMap" },
  { value: "custom", label: "自定义瓦片" },
];

const props=defineProps<{transport:MapTransport}>();
const emit=defineEmits<{(e:"openAsset",asset:MapStripAsset,group:MapStripAsset[]):void}>();

const tileSettingKey="lightisle-tile-url";
const mapSourceKey="lightisle-map-source";
const basemapConsentKey="lightisle-map-basemap-consent";
const defaultTileURL="https://tile.openstreetmap.org/{z}/{x}/{y}.png";
const basemapConsent=ref(window.localStorage.getItem(basemapConsentKey)==="yes");
type TileSource="tianditu"|"osm"|"custom";
const previousSource=window.localStorage.getItem(mapSourceKey);
const initialSource:TileSource=previousSource==="tianditu"||previousSource==="osm"||previousSource==="custom"
  ?previousSource:(window.localStorage.getItem(tileSettingKey)&&window.localStorage.getItem(tileSettingKey)!==defaultTileURL?"custom":basemapConsent.value?"osm":"tianditu");
const mapSource=ref<TileSource>(initialSource);
const mapSourceInput=ref<TileSource>(initialSource);
const tiandituConfigured=ref(false);
const mapStatusError=ref(false);

const mapElement=ref<HTMLElement|null>(null);
const points=ref<GeoPointDTO[]>([]);
const total=ref(0);
const truncated=ref(false);
const geoLoaded=ref(false);
const geoLoading=ref(false);
const geoError=ref("");
const basemapFailed=ref(false);
const basemapRetrying=ref(false);
const settingsOpen=ref(false);
const tileURLInput=ref(window.localStorage.getItem(tileSettingKey)||defaultTileURL);
const strip=ref<MapStripAsset[]>([]);
const stripLabel=ref("");
const stripLoading=ref(false);
const activeCluster=ref<GeoCluster|null>(null);
const activeClusterKey=ref("");

let map:L.Map|undefined;
let tileLayer:L.LayerGroup|L.TileLayer|undefined;
let markerLayer:L.LayerGroup|undefined;
let tileErrors=0;
let tileSuccesses=0;
let zoomLevel=4;
let geoRequest=0;
let disposed=false;
let pendingFocus:{lat:number;lon:number}|null=null;
// Rendered bubbles indexed by the clusters' stable grid-cell key, so a pan
// can add/remove markers incrementally instead of rebuilding the layer.
const markersByKey=new Map<string,L.Marker>();
let renderedZoom=-1;
// Defensive ceiling: even inside one viewport a pathological point spread
// can produce more bubbles than a page should hold at once.
const maxVisibleMarkers=2000;
const viewportMargin=0.25;
const markerOverflow=ref(false);

const locatedLabel=computed(()=>{
  if(!geoLoaded.value)return"";
  if(total.value===0)return"还没有带位置的照片";
  const shown="共 "+total.value+" 张带位置的照片";
  return truncated.value?shown+"（地图仅显示最新的 "+points.value.length+" 张）":shown;
});
const geoStatusLabel=computed(()=>{
  if(geoLoading.value)return geoLoaded.value?locatedLabel.value+"（更新中…）":"正在读取位置信息…";
  if(geoError.value&&!geoLoaded.value)return"位置信息读取失败";
  return locatedLabel.value||"等待读取位置信息";
});

function currentTileURL(){return window.localStorage.getItem(tileSettingKey)||defaultTileURL}

async function refreshMapStatus(){
  try{
    const status=await props.transport.loadMapStatus();
    if(disposed)return false;
    tiandituConfigured.value=status.tiandituConfigured===true;
    mapStatusError.value=false;
    if(map&&mapSource.value==="tianditu"&&basemapConsent.value)attachTileLayer();
    return tiandituConfigured.value;
  }catch{
    if(!disposed){tiandituConfigured.value=false;mapStatusError.value=true}
    return false;
  }
}

function attachTileLayer(){
  if(!map)return;
  tileLayer?.remove();
  // Never contact an external map service until the user explicitly opts in.
  if(!basemapConsent.value)return;
  if(mapSource.value==="tianditu"&&!tiandituConfigured.value)return;
  tileErrors=0;tileSuccesses=0;
  basemapFailed.value=false;
  const attach=(layer:L.TileLayer)=>{
    layer.on("tileerror",()=>{tileErrors++;if(tileErrors>=4&&tileSuccesses===0)degradeBasemap()});
    layer.on("tileload",()=>{tileSuccesses++});
    return layer;
  };
  if(mapSource.value==="tianditu"){
    tileLayer=L.layerGroup([
      attach(L.tileLayer("/api/v2/map/tiles/tianditu/vec/{z}/{x}/{y}",{minZoom:2,maxZoom:18,maxNativeZoom:18,noWrap:true,attribution:"© 天地图"})),
      attach(L.tileLayer("/api/v2/map/tiles/tianditu/cva/{z}/{x}/{y}",{minZoom:2,maxZoom:18,maxNativeZoom:18,noWrap:true,attribution:"© 天地图"})),
    ]);
  }else{
    const custom=mapSource.value==="custom";
    tileLayer=attach(L.tileLayer(custom?currentTileURL():defaultTileURL,{
      minZoom:2,maxZoom:18,maxNativeZoom:18,noWrap:true,attribution:custom?"地图来源：自定义瓦片":"© OpenStreetMap contributors"
    }));
  }
  tileLayer.addTo(map);
}
function degradeBasemap(){
  if(basemapFailed.value)return;
  basemapFailed.value=true;
  tileLayer?.remove();
  tileLayer=undefined;
}
async function retryBasemap(){
  if(!map)return;
  basemapRetrying.value=true;
  if(mapSource.value==="tianditu")await refreshMapStatus();
  attachTileLayer();
  // A retry needs fresh tile fetches; success arrives asynchronously and
  // clears the flag via tileload or re-fails via degradeBasemap.
  window.setTimeout(()=>{basemapRetrying.value=false;basemapFailed.value=tileErrors>0&&tileSuccesses===0},2500);
}
function applyTileURL(){
  const value=tileURLInput.value.trim();
  if(mapSourceInput.value==="custom"&&(!/^https?:\/\//.test(value)||!value.includes("{z}")||!value.includes("{x}")||!value.includes("{y}"))){
    geoError.value="瓦片地址需为 http(s) 链接并包含 {z}/{x}/{y} 占位符。";
    return;
  }
  geoError.value="";
  window.localStorage.setItem(tileSettingKey,value);
  mapSource.value=mapSourceInput.value;
  window.localStorage.setItem(mapSourceKey,mapSource.value);
  settingsOpen.value=false;
  if(mapSource.value==="tianditu")void refreshMapStatus();
  if(map)attachTileLayer();
}
async function setBasemapConsent(enabled:boolean){
  if(enabled&&mapSource.value==="tianditu"&&!await refreshMapStatus())return;
  basemapConsent.value=enabled;
  if(enabled)window.localStorage.setItem(basemapConsentKey,"yes");
  else window.localStorage.removeItem(basemapConsentKey);
  if(map)attachTileLayer();
}

function destroyMarkerLayer(){
  markerLayer?.remove();
  markerLayer=undefined;
  markersByKey.clear();
}
function buildPinElement(cluster:GeoCluster,key:string){
  const root=document.createElement("div");
  root.className="photo-map-pin"+(activeClusterKey.value===key?" active":"");
  const frame=document.createElement("div");
  frame.className="photo-map-pin-frame";
  const coverId=cluster.items[0]?.id;
  if(coverId){
    const img=document.createElement("img");
    img.src=props.transport.thumbnail(coverId);
    img.alt="";
    img.loading="lazy";
    frame.appendChild(img);
  }
  root.appendChild(frame);
  if(cluster.count>1){
    const badge=document.createElement("span");
    badge.className="photo-map-pin-badge";
    badge.textContent=cluster.count>999?"999+":String(cluster.count);
    root.appendChild(badge);
  }
  const tail=document.createElement("span");
  tail.className="photo-map-pin-tail";
  root.appendChild(tail);
  return root;
}
function createClusterMarker(cluster:GeoCluster,key:string){
  const marker=L.marker([cluster.lat,cluster.lon],{
    icon:L.divIcon({
      className:"photo-map-pin-wrapper",
      html:buildPinElement(cluster,key),
      iconSize:[54,60],
      iconAnchor:[27,56],
    }),
    keyboard:true,
    title:cluster.count===1?"查看照片":"查看 "+cluster.count+" 张照片",
  });
  marker.on("click",()=>void openCluster(cluster,key));
  return marker;
}
// Clustering runs over all points every time (O(n), cheap); only the marker
// layer is view-bound. A zoom change alters cluster granularity, so the
// layer rebuilds from scratch; a pan keeps granularity, so markers inside
// the previous view are reused and only the ones crossing the edge move.
function renderClusters(rebuild=false){
  if(!map)return;
  const zoom=map.getZoom();
  const raw=map.getBounds();
  const bounds=expandBounds({south:raw.getSouth(),west:raw.getWest(),north:raw.getNorth(),east:raw.getEast()},viewportMargin);
  const clusters=clusterGeoPoints(points.value,zoom);
  const {visible,overflow}=selectVisibleClusters(clusters,zoom,bounds,maxVisibleMarkers);
  markerOverflow.value=overflow;
  if(rebuild||zoom!==renderedZoom||!markerLayer){
    destroyMarkerLayer();
    markerLayer=L.layerGroup().addTo(map);
  }
  const plan=planMarkerChanges(new Set(markersByKey.keys()),visible,zoom);
  for(const key of plan.remove){
    markersByKey.get(key)?.remove();
    markersByKey.delete(key);
  }
  for(const item of plan.add){
    const marker=createClusterMarker(item.cluster,item.key);
    markersByKey.set(item.key,marker);
    markerLayer.addLayer(marker);
  }
  renderedZoom=zoom;
}
async function openCluster(cluster:GeoCluster,key?:string){
  if(!stripLoading.value){
    stripLoading.value=true;
    activeCluster.value=cluster;
    activeClusterKey.value=key??(map?clusterCellKey(cluster,map.getZoom()):"");
    renderClusters(true);
    try{
      // The endpoint caps id lists at 120; geo points arrive newest-first so
      // the visible strip is the newest slice and says so when truncated.
      const ids=cluster.items.slice(0,120).map(item=>item.id);
      const assets=await props.transport.loadAssetsByIds(ids);
      strip.value=assets;
      stripLabel.value=cluster.count>120?"该位置最新 120 张（共 "+cluster.count+" 张）":"该位置 "+cluster.count+" 张照片";
    }catch(error){
      geoError.value="读取位置照片失败："+describeUserFacingError(error);
    }finally{stripLoading.value=false}
  }
}
function closeStrip(){
  strip.value=[];
  stripLabel.value="";
  activeCluster.value=null;
  activeClusterKey.value="";
  renderClusters(true);
}
function zoomIntoActiveCluster(){
  if(!map||!activeCluster.value)return;
  const target=activeCluster.value;
  const nextZoom=Math.min(18,map.getZoom()+2);
  map.setView([target.lat,target.lon],nextZoom,{animate:true});
}
function stepCluster(delta:number){
  if(!map||!points.value.length)return;
  const zoom=map.getZoom();
  const clusters=clusterGeoPoints(points.value,zoom);
  if(!clusters.length)return;
  const currentIdx=clusters.findIndex(c=>clusterCellKey(c,zoom)===activeClusterKey.value);
  const nextIdx=((currentIdx<0?0:currentIdx)+delta+clusters.length)%clusters.length;
  const next=clusters[nextIdx];
  const nextKey=clusterCellKey(next,zoom);
  map.panTo([next.lat,next.lon],{animate:true});
  void openCluster(next,nextKey);
}

// Jump target for "view on map" from the photo viewer.
function focusAsset(lat:number,lon:number){
  if(!map){pendingFocus={lat,lon};return}
  map.setView([lat,lon],Math.min(18,Math.max(map.getZoom(),13)),{animate:true});
}
defineExpose({focusAsset,refresh:loadGeo});

async function loadGeo(){
  if(geoLoading.value||disposed)return;
  const request=++geoRequest;
  geoLoading.value=true;
  geoError.value="";
  try{
    const result=await props.transport.loadGeo();
    if(disposed||request!==geoRequest)return;
    points.value=result.points;
    total.value=result.total;
    truncated.value=result.truncated;
    // An initial empty library may gain GPS photos on a later refresh.
    // Fit bounds whenever a new Leaflet instance is created, not just on
    // the first successful (possibly empty) API response.
    const needsFit=!map;
    geoLoaded.value=true;
    // The canvas is hidden until a successful response. Wait for Vue to
    // display it before creating Leaflet, including a retry after an error.
    await nextTick();
    if(disposed||request!==geoRequest)return;
    if(result.points.length>0&&!map&&mapElement.value){
      map=L.map(mapElement.value,{
        zoomControl:true,
        attributionControl:true,
        minZoom:2,
        maxZoom:18,
        maxBounds:[[-85,-180],[85,180]],
        maxBoundsViscosity:1.0,
      });
      map.setView([31,105],zoomLevel);
      attachTileLayer();
      map.on("moveend",()=>renderClusters());
      map.on("zoomend",()=>{
        zoomLevel=map?.getZoom()??zoomLevel;
        renderClusters();
      });
    }
    if(map&&result.points.length){
      if(needsFit){
        const bounds=geoPointsBounds(result.points);
        if(bounds)map.fitBounds(bounds,{padding:[36,36],maxZoom:10});
      }
      if(pendingFocus){
        const target=pendingFocus;pendingFocus=null;
        map.setView([target.lat,target.lon],Math.max(map.getZoom(),13));
      }
      map.invalidateSize();
    }else if(map&&!result.points.length){
      destroyMarkerLayer();tileLayer?.remove();tileLayer=undefined;
      map.remove();map=undefined;renderedZoom=-1;
    }
    // Point data changed, so reused markers could hold stale click targets.
    renderClusters(true);
  }catch(error){
    if(!disposed&&request===geoRequest)geoError.value=describePhotoMapFailure(error);
  }finally{
    if(!disposed&&request===geoRequest)geoLoading.value=false;
  }
}

onMounted(()=>{void loadGeo();void refreshMapStatus()});
onBeforeUnmount(()=>{
  disposed=true;++geoRequest;
  destroyMarkerLayer();tileLayer?.remove();map?.remove();map=undefined;
});
</script>

<template>
  <div class="photo-map">
    <div class="photo-map-toolbar">
      <span class="photo-map-status"><MapPin :size="14"/> {{geoStatusLabel}}</span>
      <button type="button" class="photo-map-tool" :disabled="geoLoading" @click="loadGeo">
        <RefreshCw :size="13"/> {{geoLoading?"读取中…":"刷新位置"}}
      </button>
      <button type="button" class="photo-map-tool" :class="{chosen:settingsOpen}" @click="settingsOpen=!settingsOpen"><Settings2 :size="14"/> 地图设置</button>
    </div>
    <div v-if="!basemapConsent" class="photo-map-degraded" role="status">
      当前只显示照片位置，不加载道路或地名。开启在线地图后，地图服务可能收到访问 IP 和浏览范围，但不会收到照片原件。
      <button type="button" class="photo-map-tool" @click="setBasemapConsent(true)">启用在线地图</button>
    </div>
    <div v-else class="photo-map-privacy">
      <button type="button" class="photo-map-tool" @click="setBasemapConsent(false)">关闭在线地图</button>
    </div>
    <form v-if="settingsOpen" class="photo-map-tile-form" @submit.prevent="applyTileURL">
      <AppleSelect v-model="mapSourceInput" :options="mapSourceOptions" aria-label="地图来源" />
      <span v-if="mapSourceInput==='tianditu'" class="photo-map-status">
        {{ tiandituConfigured?'已在 Mac 上设置天地图':(mapStatusError?'无法获取地图配置，请检查连接':'请管理员在 Mac 版 LightIsle 的「设置 → 媒体服务」填写天地图 Key') }}
      </span>
      <input v-if="mapSourceInput==='custom'" v-model="tileURLInput" placeholder="https://example.com/{z}/{x}/{y}.png" aria-label="瓦片服务地址">
      <button type="submit">保存并应用</button>
      <button v-if="mapSourceInput==='custom'" type="button" @click="tileURLInput=defaultTileURL">恢复默认</button>
    </form>
    <div v-if="mapSource==='tianditu'&&!tiandituConfigured" class="photo-map-degraded" role="status">
      {{mapStatusError?'无法获取地图设置，请检查 Mac 是否在线。':'尚未启用天地图。请管理员在 Mac 版 LightIsle 的「设置 → 媒体服务」填写天地图 Key。'}}
      <button type="button" class="photo-map-tool" @click="refreshMapStatus">重新检查</button>
    </div>
    <div v-if="basemapFailed" class="photo-map-degraded" role="status">
      地图暂时无法加载，仍可查看照片位置。请检查网络、重新加载，或更换地图来源。
      <button type="button" class="photo-map-tool" :disabled="basemapRetrying" @click="retryBasemap"><RefreshCw :size="13"/> {{basemapRetrying?"正在重试…":"重试底图"}}</button>
    </div>
    <div v-if="geoError&&geoLoaded" class="form-error photo-map-fetch-error" role="alert">
      <span>{{geoError}} 地图仍显示上次成功读取的位置数据。</span>
      <button type="button" class="photo-map-tool" :disabled="geoLoading" @click="loadGeo">重新读取</button>
    </div>
    <div v-if="geoError&&!geoLoaded" class="photo-map-empty photo-map-error-state" role="alert">
      <MapPin :size="34" :stroke-width="1.2"/>
      <h3>位置地图暂不可用</h3>
      <p>{{geoError}}</p>
      <button type="button" class="photo-map-tool" :disabled="geoLoading" @click="loadGeo">
        <RefreshCw :size="13"/> {{geoLoading?"正在重试…":"重新读取位置"}}
      </button>
    </div>
    <div v-if="markerOverflow" class="photo-map-notice" role="status">
      当前视野内位置点过多，已只显示数量最多的 {{maxVisibleMarkers}} 个标记；放大地图可查看更细的位置分组。
    </div>
    <div v-if="geoLoaded&&total===0" class="photo-map-empty">
      <MapPin :size="34" :stroke-width="1.2"/>
      <h3>还没有带位置信息的照片</h3>
      <p>带 GPS 的照片（手机拍摄、相机开启定位）和 iPhone 视频会出现在这里。已入库的旧照片会在后台自动补齐位置信息。</p>
    </div>
    <div v-show="geoLoaded&&total>0" ref="mapElement" class="photo-map-canvas" role="application" aria-label="按位置浏览照片"></div>
    <div v-if="strip.length" class="photo-map-strip">
      <div class="photo-map-strip-head">
        <span class="photo-map-strip-title">{{stripLabel}}</span>
        <div class="photo-map-strip-actions">
          <button type="button" class="photo-map-strip-btn" title="上一处足迹" @click="stepCluster(-1)"><ChevronLeft :size="15"/></button>
          <button type="button" class="photo-map-strip-btn" title="下一处足迹" @click="stepCluster(1)"><ChevronRight :size="15"/></button>
          <button v-if="activeCluster&&activeCluster.count>1" type="button" class="photo-map-strip-btn" title="放大此区域" @click="zoomIntoActiveCluster"><ZoomIn :size="14"/> 放大此区域</button>
          <button type="button" class="photo-map-strip-btn" title="收起" @click="closeStrip"><X :size="14"/></button>
        </div>
      </div>
      <div class="photo-map-strip-grid">
        <button v-for="asset in strip" :key="asset.id" type="button" class="photo-map-strip-tile" @click="emit('openAsset',asset,strip)">
          <img :src="transport.thumbnail(asset.id)" :alt="asset.name" loading="lazy"/>
          <small>{{new Date(asset.takenAt*1000).toLocaleDateString("zh-CN")}}</small>
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.photo-map{display:flex;flex-direction:column;gap:10px;margin-bottom:16px}
.photo-map-toolbar{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;color:var(--text-secondary);font-size:12px}
.photo-map-status{display:inline-flex;align-items:center;gap:6px}
.photo-map-tool{display:inline-flex;align-items:center;gap:5px;border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);background:var(--fluid-card-fill);color:var(--text-secondary);padding:6px 10px;font-size:12px;font-weight:600}
.photo-map-tile-form{display:flex;gap:8px;flex-wrap:wrap}
.photo-map-tile-form input,.photo-map-tile-form select{flex:1;min-width:220px;border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);background:var(--fluid-card-fill);color:var(--text-primary);padding:8px 10px;font-size:12px}
.photo-map-tile-form button{border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);background:var(--fluid-card-fill);color:var(--text-primary);padding:8px 12px;font-size:12px}
.photo-map-degraded{display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding:10px 12px;border:1px solid var(--warning);border-radius:var(--radius-sm);color:var(--text-primary);font-size:12px}
.photo-map-notice{padding:8px 12px;border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);color:var(--text-secondary);font-size:12px}
.photo-map-fetch-error{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.photo-map-error-state{background:var(--fluid-card-fill);border-style:solid}
.photo-map-error-state p{max-width:560px}
.photo-map-empty{display:grid;justify-items:center;gap:6px;padding:42px 20px;border:1px dashed var(--fluid-card-border);border-radius:var(--radius-md);color:var(--text-secondary);text-align:center}
.photo-map-empty h3{margin:0;color:var(--text-primary);font-size:16px}
.photo-map-empty p{margin:0;font-size:13px;max-width:460px}
.photo-map-canvas{height:min(64vh,620px);border-radius:var(--radius-md);border:1px solid var(--fluid-card-border);background:#0d1117;z-index:0}
.photo-map-strip{border:1px solid var(--fluid-card-border);border-radius:var(--radius-md);background:var(--fluid-card-fill);overflow:hidden;box-shadow:0 8px 28px rgba(0,0,0,.18)}
.photo-map-strip-head{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:10px 14px;color:var(--text-primary);font-size:13px;font-weight:600;border-bottom:1px solid var(--fluid-card-border)}
.photo-map-strip-actions{display:inline-flex;align-items:center;gap:6px}
.photo-map-strip-btn{display:inline-flex;align-items:center;gap:4px;border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);background:var(--fluid-card-fill);color:var(--text-secondary);padding:4px 8px;font-size:12px;cursor:pointer}
.photo-map-strip-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(104px,1fr));gap:10px;max-height:280px;overflow-y:auto;padding:12px}
.photo-map-strip-tile{display:grid;gap:4px;justify-items:center;border:none;background:none;color:var(--text-secondary);font-size:11px;padding:0;cursor:pointer}
.photo-map-strip-tile img{width:100%;aspect-ratio:1/1;object-fit:cover;border-radius:var(--radius-sm);display:block;background:rgba(255,255,255,.06)}
:global(.photo-map-pin-wrapper){background:transparent;border:none}
:global(.photo-map-pin){position:relative;width:54px;height:60px;display:flex;justify-content:center;align-items:flex-start;cursor:pointer}
:global(.photo-map-pin-frame){width:46px;height:46px;margin-top:4px;border-radius:11px;padding:2px;background:#fff;box-shadow:0 4px 12px rgba(0,0,0,.32);overflow:hidden;transition:transform .16s ease,box-shadow .16s ease,background .16s ease}
:global(.photo-map-pin.active .photo-map-pin-frame){transform:scale(1.1);background:#5865f2;box-shadow:0 6px 16px rgba(88,101,242,.5)}
:global(.photo-map-pin-frame img){width:100%;height:100%;object-fit:cover;border-radius:9px;display:block;background:#1e293b}
:global(.photo-map-pin-badge){position:absolute;top:0;right:1px;min-width:20px;padding:1px 5px;border-radius:999px;background:#1e293b;color:#fff;font-size:10.5px;font-weight:800;line-height:1.3;text-align:center;border:1.5px solid #fff;box-shadow:0 2px 5px rgba(0,0,0,.3)}
:global(.photo-map-pin.active .photo-map-pin-badge){background:#5865f2}
:global(.photo-map-pin-tail){position:absolute;bottom:6px;width:10px;height:10px;background:#fff;border-radius:2px;transform:rotate(45deg);box-shadow:2px 2px 4px rgba(0,0,0,.22);z-index:-1}
:global(.photo-map-pin.active .photo-map-pin-tail){background:#5865f2}
</style>
