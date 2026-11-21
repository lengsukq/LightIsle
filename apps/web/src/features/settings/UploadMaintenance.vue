<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import { rootApiPath } from "../../api/rootApi.ts";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import { apiFetch } from "../../api/apiClient.ts";
import {readApiFailure} from "../../api/apiFailure.ts";
import {describeUserFacingError} from "../../api/userFacingError.ts";
import {formatMegabytes as bytes, formatUnixDateTime} from "../../utils/format.ts";

const dayOptions = [
  { value: 7, label: "7 天" },
  { value: 30, label: "30 天" },
  { value: 90, label: "90 天" },
];

type Upload = {
  id:string; ownerID:number; ownerName:string; ownerEnabled:boolean; ownerMissing:boolean; ownerCanWrite:boolean; orphan:boolean; corrupt:boolean;
  path:string; size:number; offset:number; created:number; activity:number; published:boolean;
};
const props=defineProps<{rootId?:string;rootGeneration?:number}>();
const uploads=ref<Upload[]>([]);
const nextCursor=ref("");
const loading=ref(false);
const busy=ref(false);
const error=ref("");
const notice=ref("");
const days=ref(30);
const confirming=ref<Upload|"expired"|null>(null);
const unknownOpen=ref(false);
const unknownItems=ref<Array<{name:string;nameBytes?:string}>>([]);
const unknownNext=ref("");
const unknownError=ref("");
const unknownLoading=ref(false);
const unknownLoaded=ref(false);
let generation=0;
let disposed=false;
const controller=new AbortController();
function apiPath(path:string){return rootApiPath(props.rootId,path)}
async function api<T>(path:string,method="GET",body?:object):Promise<T>{
  const rootID=props.rootId,rootGeneration=props.rootGeneration??0;
  const headers=new Headers();
  if(rootID)headers.set("X-LightIsle-Root-Generation",String(rootGeneration));
  const response=await apiFetch(path,{method,signal:controller.signal,headers,json:body});
  if(rootID&&(props.rootId!==rootID||props.rootGeneration!==rootGeneration||disposed))throw makeRootAbortError();
  if(!response.ok){
    const failure=await readApiFailure(response);
    if(rootID&&response.status===409&&failure.code==="root_generation_changed")window.dispatchEvent(new Event("lightisle-root-generation-changed"));
    throw failure;
  }
  return await response.json() as T;
}
function makeRootAbortError(){const error=new Error("root_context_changed");error.name="AbortError";return error;}
function failure(reason:unknown){
  const code=reason instanceof Error?reason.message:String(reason);
  const messages:Record<string,string>={
    volume_offline:"共享磁盘当前不可用，请重新连接后重试。",
    share_offline:"共享磁盘当前不可用，请重新连接后重试。",
    upload_busy:"上传正在写入或提交，请稍后重试。",
    upload_inventory_limit:"上传记录超过本次安全扫描上限，未执行清理。请在 Mac 上检查共享目录后重试。",
    authentication_required:"登录状态已失效，请重新登录。",
    not_found:"上传已结束或已被清理，请刷新列表。",
  };
  return messages[code]??describeUserFacingError(reason);
}
async function load(more=false){
  if(loading.value)return;
  const request=++generation;
  loading.value=true;error.value="";
  const query=new URLSearchParams({limit:"20"});
  if(more&&nextCursor.value)query.set("after",nextCursor.value);
  try{
    const page=await api<{uploads:Upload[];nextCursor:string}>(apiPath("/api/v2/admin/uploads")+"?"+query);
    if(disposed||request!==generation)return;
    uploads.value=more?[...uploads.value,...page.uploads]:page.uploads;
    nextCursor.value=page.nextCursor;
  }catch(reason){if(!disposed)error.value=failure(reason)}
  finally{if(request===generation)loading.value=false}
}
async function loadUnknown(more=false){
  if(unknownLoading.value)return;
  unknownLoading.value=true;unknownError.value="";
  const query=new URLSearchParams({limit:"20"});
  if(more&&unknownNext.value)query.set("after",unknownNext.value);
  try{
    const page=await api<{items:Array<{name:string;nameBytes?:string}>;nextCursor:string}>(apiPath("/api/v2/admin/uploads/unrecognized")+"?"+query);
    if(disposed)return;
    unknownItems.value=more?[...unknownItems.value,...page.items]:page.items;
    unknownNext.value=page.nextCursor;unknownLoaded.value=true;
  }catch(reason){if(!disposed)unknownError.value="读取失败，结果不完整："+failure(reason)}
  finally{unknownLoading.value=false}
}
function toggleUnknown(event:Event){
  unknownOpen.value=(event.target as HTMLDetailsElement).open;
  if(unknownOpen.value&&!unknownLoaded.value&&!unknownLoading.value)void loadUnknown();
}
async function confirm(){
  const target=confirming.value;
  if(!target||busy.value)return;
  busy.value=true;error.value="";notice.value="";
  try{
    if(target==="expired"){
      const result=await api<{removed:number;skipped:number;hasMore:boolean;pendingReservations?:number}>(apiPath("/api/v2/admin/uploads/cleanup-expired"),"POST",{inactiveForSeconds:days.value*86400});
      notice.value=`本次已清理 ${result.removed} 项${result.skipped?`，保留 ${result.skipped} 项需单独检查的记录`:''}。${result.pendingReservations?`${result.pendingReservations} 项容量预占仍需在任务中心检查。`:''}${result.hasMore?'仍有过期残留，可再次清理。':'已发布文件保持不变。'}`;
    }else{
      await api(apiPath("/api/v2/admin/uploads/"+encodeURIComponent(target.id)),"DELETE");
      notice.value="上传残留已取消；已完成的原文件保持不变。";
    }
    if(disposed)return;
    confirming.value=null;
    await load();
  }catch(reason){if(!disposed)error.value=failure(reason)}
  finally{busy.value=false}
}
function date(value:number){return formatUnixDateTime(value,"时间未知")}
onMounted(()=>void load());
onUnmounted(()=>{disposed=true;generation++;controller.abort()});
</script>

<template>
  <section class="account-panel upload-maintenance">
    <div class="account-heading">
      <h3>未完成上传</h3>
      <IsleButton variant="glass" size="sm" :loading="loading" :disabled="busy" @click="load()">
        刷新
      </IsleButton>
    </div>
    <p class="upload-sub">管理当前共享目录的断点续传残留。取消后需重新上传；不会删除已发布的文件。</p>
    <IsleBanner v-if="error" type="error" compact role="alert">{{ error }}</IsleBanner>
    <IsleBanner v-if="notice" type="info" compact role="status">{{ notice }}</IsleBanner>
    <p v-if="loading && !uploads.length" class="footnote">正在读取上传记录…</p>
    <IsleEmpty v-else-if="!uploads.length && !error" compact description="当前没有已识别的未完成上传；无法识别的条目可在下方检查。" />
    <div v-for="upload in uploads" :key="upload.id" class="account-row">
      <div class="upload-detail">
        <strong>{{upload.path}}</strong>
        <small>{{upload.ownerName||`账号 #${upload.ownerID}`}} · {{upload.ownerMissing?'账号已移除':!upload.ownerEnabled?'账号已停用':!upload.ownerCanWrite?'写入授权已撤销':'账号正常'}} · {{bytes(upload.offset)}} / {{bytes(upload.size)}}</small>
        <small v-if="upload.orphan||upload.corrupt">临时部分或记录异常，请单独检查后取消。</small>
        <small>上次活动 {{date(upload.activity||upload.created)}}{{upload.published?' · 已发布，待收尾':''}}</small>
      </div>
      <IsleButton variant="danger" size="sm" :disabled="busy" @click="confirming=upload">取消残留</IsleButton>
    </div>
    <div v-if="nextCursor" class="gallery-load">
      <IsleButton variant="glass" size="sm" :loading="loading" :disabled="busy" @click="load(true)">
        {{ loading ? '正在加载…' : '加载更多上传' }}
      </IsleButton>
    </div>
    <details class="upload-unknown-details apple-disclosure-card" @toggle="toggleUnknown">
      <summary>
        <div class="disclosure-title"><span>检查无法识别的上传暂存文件</span></div>
      </summary>
      <div class="disclosure-body">
        <p style="margin-top:0;font-size:12px">位于 <code>.lightisle-parts</code> 的未识别文件不会自动清理，请在 Mac 访达（⌘⇧. 显示隐藏文件）核对处理。</p>
        <IsleBanner v-if="unknownError" type="error" compact role="alert">{{ unknownError }}</IsleBanner>
        <p v-else-if="unknownLoading && !unknownLoaded" class="footnote">正在检查…</p>
        <IsleEmpty v-else-if="unknownLoaded && !unknownItems.length" compact description="当前未发现无法识别的条目。" />
        <div v-for="item in unknownItems" :key="item.nameBytes||item.name" class="account-row upload-detail">
          <span>.lightisle-parts/{{item.name}}</span><small v-if="item.nameBytes">文件名字节（Base64URL）：{{item.nameBytes}}</small>
        </div>
        <div style="display: flex; gap: 8px; margin-top: 8px;">
          <IsleButton v-if="unknownNext" variant="glass" size="sm" :loading="unknownLoading" @click="loadUnknown(true)">加载更多</IsleButton>
          <IsleButton variant="glass" size="sm" :loading="unknownLoading" @click="loadUnknown()">重新检查</IsleButton>
        </div>
      </div>
    </details>
    <div class="upload-cleanup-controls">
      <span class="upload-cleanup-label">清理多久未活动的上传</span>
      <AppleSelect v-model="days" :options="dayOptions" :disabled="busy" size="sm" aria-label="清理多久未活动的上传" />
      <IsleButton variant="glass" size="sm" :disabled="busy || loading" @click="confirming='expired'">清理过期残留…</IsleButton>
    </div>
    <div v-if="confirming" class="upload-confirm" role="group" aria-label="确认清理上传">
      <p>{{confirming==='expired'?`清理 ${days} 天没有活动、尚未发布的上传残留？正在写入和提交的上传会受到保护。`:`取消“${confirming.path}”的断点续传残留？已上传的临时部分将被清理。`}}</p>
      <div style="display: flex; gap: 8px;">
        <IsleButton variant="danger" size="sm" :loading="busy" :disabled="busy" @click="confirm">
          {{ busy ? '正在处理…' : '确认清理' }}
        </IsleButton>
        <IsleButton variant="glass" size="sm" :disabled="busy" @click="confirming=null">保留</IsleButton>
      </div>
    </div>
  </section>
</template>

<style scoped>
.upload-maintenance{margin-bottom:14px}
.upload-sub{margin:4px 0 8px;font-size:12.5px;color:var(--text-secondary)}
.upload-detail{min-width:0;overflow-wrap:anywhere}
.upload-cleanup-controls{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:12px;padding-top:12px;border-top:1px solid var(--fluid-divider, var(--stroke-subtle))}
.upload-cleanup-label{font-size:12.5px;color:var(--text-primary)}
.upload-confirm{margin-top:10px;padding:11px 13px;border:1px solid var(--fluid-card-border);background:var(--fluid-card-item-fill);border-radius:11px}
.upload-confirm p{margin:0 0 8px;font-size:12.5px}
</style>
