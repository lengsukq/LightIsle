<script setup lang="ts">
// Map view for located photos: Leaflet grid clusters with an honest
// degradation path — when basemap tiles are unreachable the map drops to a
// dot-matrix view and says so, and the tile server stays user-configurable.
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import { MapPin, Settings2, X, RefreshCw } from "lucide-vue-next";
import { clusterGeoPoints, geoPointsBounds } from "./mapCluster.js";
import type { GeoCluster } from "./mapCluster.js";
import { expandBounds, planMarkerChanges, selectVisibleClusters } from "./mapViewport.js";
import type { GeoPointDTO, MapStripAsset, MapTransport } from "./photoMapTransport.js";

const props=defineProps<{transport:MapTransport}>();
const emit=defineEmits<{(e:"openAsset",asset:MapStripAsset,group:MapStripAsset[]):void}>();

const tileSettingKey="lightisle-tile-url";
const basemapConsentKey="lightisle-map-basemap-consent";
const defaultTileURL="https://tile.openstreetmap.org/{z}/{x}/{y}.png";
const basemapConsent=ref(window.localStorage.getItem(basemapConsentKey)==="yes");

const mapElement=ref<HTMLElement|null>(null);
const points=ref<GeoPointDTO[]>([]);
const total=ref(0);
const truncated=ref(false);
const geoLoaded=ref(false);
const geoError=ref("");
const basemapFailed=ref(false);
const basemapRetrying=ref(false);
const settingsOpen=ref(false);
const tileURLInput=ref(window.localStorage.getItem(tileSettingKey)||defaultTileURL);
const strip=ref<MapStripAsset[]>([]);
const stripLabel=ref("");
const stripLoading=ref(false);

let map:L.Map|undefined;
let tileLayer:L.TileLayer|undefined;
let markerLayer:L.LayerGroup|undefined;
let tileErrors=0;
let tileSuccesses=0;
let zoomLevel=4;
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

function currentTileURL(){return window.localStorage.getItem(tileSettingKey)||defaultTileURL}

function attachTileLayer(){
  if(!map)return;
  tileLayer?.remove();
  // Never contact an external map service until the user explicitly opts in.
  if(!basemapConsent.value)return;
  tileErrors=0;tileSuccesses=0;
  basemapFailed.value=false;
  tileLayer=L.tileLayer(currentTileURL(),{maxZoom:19,attribution:"&copy; OpenStreetMap contributors"});
  tileLayer.on("tileerror",()=>{
    tileErrors++;
    if(tileErrors>=4&&tileSuccesses===0)degradeBasemap();
  });
  tileLayer.on("tileload",()=>{tileSuccesses++});
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
  attachTileLayer();
  // A retry needs fresh tile fetches; success arrives asynchronously and
  // clears the flag via tileload or re-fails via degradeBasemap.
  window.setTimeout(()=>{basemapRetrying.value=false;basemapFailed.value=tileErrors>0&&tileSuccesses===0},2500);
}
function applyTileURL(){
  const value=tileURLInput.value.trim();
  if(!/^https?:\/\//.test(value)||!value.includes("{z}")||!value.includes("{x}")||!value.includes("{y}")){
    geoError.value="瓦片地址需为 http(s) 链接并包含 {z}/{x}/{y} 占位符。";
    return;
  }
  geoError.value="";
  window.localStorage.setItem(tileSettingKey,value);
  settingsOpen.value=false;
  if(map)attachTileLayer();
}
function setBasemapConsent(enabled:boolean){
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
function createClusterMarker(cluster:GeoCluster){
  const marker=L.marker([cluster.lat,cluster.lon],{
    icon:L.divIcon({
      className:"photo-map-bubble"+(cluster.count===1?" single":""),
      html:cluster.count===1?"":String(cluster.count),
      iconSize:cluster.count===1?[14,14]:[34,34],
    }),
    keyboard:true,
    title:cluster.count===1?"查看照片":cluster.count+" 张照片",
  });
  marker.on("click",()=>void openCluster(cluster));
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
    const marker=createClusterMarker(item.cluster);
    markersByKey.set(item.key,marker);
    markerLayer.addLayer(marker);
  }
  renderedZoom=zoom;
}
async function openCluster(cluster:GeoCluster){
  if(!stripLoading.value){
    stripLoading.value=true;
    try{
      // The endpoint caps id lists at 120; geo points arrive newest-first so
      // the visible strip is the newest slice and says so when truncated.
      const ids=cluster.items.slice(0,120).map(item=>item.id);
      const assets=await props.transport.loadAssetsByIds(ids);
      strip.value=assets;
      stripLabel.value=cluster.count>120?"该位置最新 120 张（共 "+cluster.count+" 张）":"该位置 "+cluster.count+" 张";
      if(assets.length===1){
        strip.value=[];
        emit("openAsset",assets[0],assets);
      }
    }catch(error){
      geoError.value="读取位置照片失败："+(error instanceof Error?error.message:"未知错误");
    }finally{stripLoading.value=false}
  }
}
function closeStrip(){strip.value=[];stripLabel.value=""}

// Jump target for "view on map" from the photo viewer.
function focusAsset(lat:number,lon:number){
  if(!map)return;
  map.setView([lat,lon],Math.max(map.getZoom(),13),{animate:true});
}
defineExpose({focusAsset,refresh:loadGeo});

async function loadGeo(){
  geoError.value="";
  try{
    const result=await props.transport.loadGeo();
    points.value=result.points;
    total.value=result.total;
    truncated.value=result.truncated;
    if(!geoLoaded.value&&map&&result.points.length){
      const bounds=geoPointsBounds(result.points);
      if(bounds)map.fitBounds(bounds,{padding:[36,36],maxZoom:10});
    }
    geoLoaded.value=true;
    // Point data changed, so reused markers could hold stale click targets.
    renderClusters(true);
  }catch(error){
    geoError.value="读取位置信息失败："+(error instanceof Error?error.message:"未知错误");
  }
}

onMounted(()=>{
  void loadGeo().then(()=>{
    if(!mapElement.value||total.value===0)return;
    map=L.map(mapElement.value,{zoomControl:true,attributionControl:true,worldCopyJump:true});
    map.setView([31,105],zoomLevel);
    attachTileLayer();
    // moveend covers pans and fires after every zoom as well; renderClusters
    // rebuilds only when the zoom (granularity) actually changed.
    map.on("moveend",()=>{renderClusters()});
    map.on("zoomend",()=>{
      zoomLevel=map?.getZoom()??zoomLevel;
      renderClusters();
    });
    const bounds=geoPointsBounds(points.value);
    if(bounds)map.fitBounds(bounds,{padding:[36,36],maxZoom:10});
    zoomLevel=map.getZoom();
    renderClusters();
  });
});
onBeforeUnmount(()=>{destroyMarkerLayer();tileLayer?.remove();map?.remove();map=undefined});
</script>

<template>
  <div class="photo-map">
    <div class="photo-map-toolbar">
      <span class="photo-map-status"><MapPin :size="14"/> {{locatedLabel||"正在读取位置信息…"}}</span>
      <button type="button" class="photo-map-tool" :class="{chosen:settingsOpen}" @click="settingsOpen=!settingsOpen"><Settings2 :size="14"/> 底图设置</button>
    </div>
    <div v-if="!basemapConsent" class="photo-map-degraded" role="status">
      隐私模式：只显示本机照片坐标，不连接任何外部地图服务。启用在线底图后，地图供应商会收到你的访问 IP 与浏览的地图范围。
      <button type="button" class="photo-map-tool" @click="setBasemapConsent(true)">同意并启用在线底图</button>
    </div>
    <div v-else class="photo-map-privacy">
      <button type="button" class="photo-map-tool" @click="setBasemapConsent(false)">关闭外部底图（隐私模式）</button>
    </div>
    <form v-if="settingsOpen" class="photo-map-tile-form" @submit.prevent="applyTileURL">
      <input v-model="tileURLInput" placeholder="https://example.com/{z}/{x}/{y}.png" aria-label="瓦片服务地址">
      <button type="submit">保存并应用</button>
      <button type="button" @click="tileURLInput=defaultTileURL">恢复默认</button>
    </form>
    <div v-if="basemapFailed" class="photo-map-degraded" role="status">
      地图底图不可达，已切换为位置点阵视图；照片与坐标仍全部来自本机。可配置可用的瓦片服务或重试。
      <button type="button" class="photo-map-tool" :disabled="basemapRetrying" @click="retryBasemap"><RefreshCw :size="13"/> {{basemapRetrying?"正在重试…":"重试底图"}}</button>
    </div>
    <div v-if="geoError" class="form-error" role="alert">{{geoError}}</div>
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
        <span>{{stripLabel}}</span>
        <button type="button" @click="closeStrip" title="收起"><X :size="14"/></button>
      </div>
      <div class="photo-map-strip-row">
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
.photo-map-tile-form input{flex:1;min-width:240px;border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);background:var(--fluid-card-fill);color:var(--text-primary);padding:8px 10px;font-size:12px}
.photo-map-tile-form button{border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);background:var(--fluid-card-fill);color:var(--text-primary);padding:8px 12px;font-size:12px}
.photo-map-degraded{display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding:10px 12px;border:1px solid var(--warning);border-radius:var(--radius-sm);color:var(--text-primary);font-size:12px}
.photo-map-notice{padding:8px 12px;border:1px solid var(--fluid-card-border);border-radius:var(--radius-sm);color:var(--text-secondary);font-size:12px}
.photo-map-empty{display:grid;justify-items:center;gap:6px;padding:42px 20px;border:1px dashed var(--fluid-card-border);border-radius:var(--radius-md);color:var(--text-secondary);text-align:center}
.photo-map-empty h3{margin:0;color:var(--text-primary);font-size:16px}
.photo-map-empty p{margin:0;font-size:13px;max-width:460px}
.photo-map-canvas{height:min(64vh,620px);border-radius:var(--radius-md);border:1px solid var(--fluid-card-border);background:#0d1117;z-index:0}
.photo-map-strip{border:1px solid var(--fluid-card-border);border-radius:var(--radius-md);background:var(--fluid-card-fill);overflow:hidden}
.photo-map-strip-head{display:flex;align-items:center;justify-content:space-between;padding:8px 12px;color:var(--text-secondary);font-size:12px}
.photo-map-strip-row{display:flex;gap:10px;overflow-x:auto;padding:0 12px 12px}
.photo-map-strip-tile{flex:none;display:grid;gap:4px;justify-items:center;border:none;background:none;color:var(--text-secondary);font-size:11px;padding:0}
.photo-map-strip-tile img{width:96px;height:96px;object-fit:cover;border-radius:var(--radius-sm);display:block}
:global(.photo-map-bubble){display:grid;place-items:center;border-radius:99px;background:rgba(88,101,242,.85);color:#fff;font-size:13px;font-weight:700;border:2px solid rgba(255,255,255,.65);box-shadow:0 3px 10px rgba(0,0,0,.35)}
:global(.photo-map-bubble.single){background:rgba(88,101,242,.9)}
</style>
