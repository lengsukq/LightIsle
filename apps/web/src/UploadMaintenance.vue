<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import { rootApiPath } from "./rootApi.js";

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
let generation=0;
let disposed=false;
const controller=new AbortController();
function apiPath(path:string){return rootApiPath(props.rootId,path)}
async function api<T>(path:string,method="GET",body?:object):Promise<T>{
  const rootID=props.rootId,rootGeneration=props.rootGeneration??0;
  const headers=new Headers(method==="GET"?{}:{"Content-Type":"application/json","X-LightIsle-Request":"1"});
  if(rootID)headers.set("X-LightIsle-Root-Generation",String(rootGeneration));
  const response=await fetch(path,{method,credentials:"same-origin",cache:"no-store",signal:controller.signal,
    headers,
    body:body?JSON.stringify(body):undefined});
  const result=await response.json().catch(()=>({error:"invalid_response"}));
  if(rootID&&(props.rootId!==rootID||props.rootGeneration!==rootGeneration||disposed))throw makeRootAbortError();
  if(!response.ok){
    if(rootID&&response.status===409&&result.error==="root_generation_changed")window.dispatchEvent(new Event("lightisle-root-generation-changed"));
    throw new Error(result.error==="root_generation_changed"?"共享目录已变化，请刷新根列表后重新选择。":result.error??String(response.status));
  }
  return result as T;
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
  return messages[code]??`操作未完成：${code}`;
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
async function confirm(){
  const target=confirming.value;
  if(!target||busy.value)return;
  busy.value=true;error.value="";notice.value="";
  try{
    if(target==="expired"){
      const result=await api<{removed:number;skipped:number;hasMore:boolean}>(apiPath("/api/v2/admin/uploads/cleanup-expired"),"POST",{inactiveForSeconds:days.value*86400});
      notice.value=`本次已清理 ${result.removed} 项${result.skipped?`，保留 ${result.skipped} 项需单独检查的记录`:''}。${result.hasMore?'仍有过期残留，可再次清理。':'已发布文件保持不变。'}`;
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
function bytes(value:number){return new Intl.NumberFormat("zh-CN",{maximumFractionDigits:1}).format(value/(1024*1024))+" MB"}
function date(value:number){return value?new Date(value*1000).toLocaleString():"时间未知"}
onMounted(()=>void load());
onUnmounted(()=>{disposed=true;generation++;controller.abort()});
</script>

<template>
  <section class="account-panel upload-maintenance">
    <div class="account-heading"><h3>未完成上传</h3><button type="button" class="refresh" :disabled="loading||busy" @click="load()">刷新</button></div>
    <p>管理当前共享目录的断点续传残留。取消后需重新上传；不会删除已经发布的文件。</p>
    <p v-if="error" class="form-error" role="alert">{{error}}</p>
    <p v-if="notice" role="status">{{notice}}</p>
    <div v-if="loading&&!uploads.length" class="files-empty">正在读取上传记录…</div>
    <div v-else-if="!uploads.length&&!error" class="files-empty">没有未完成上传</div>
    <div v-for="upload in uploads" :key="upload.id" class="account-row">
      <div class="upload-detail">
        <strong>{{upload.path}}</strong>
        <small>{{upload.ownerName||`账号 #${upload.ownerID}`}} · {{upload.ownerMissing?'账号已移除':!upload.ownerEnabled?'账号已停用':!upload.ownerCanWrite?'写入授权已撤销':'账号正常'}} · {{bytes(upload.offset)}} / {{bytes(upload.size)}}</small>
        <small v-if="upload.orphan||upload.corrupt">临时部分或记录异常，请单独检查后取消。</small>
        <small>上次活动 {{date(upload.activity||upload.created)}}{{upload.published?' · 已发布，待收尾':''}}</small>
      </div>
      <button type="button" class="account-action" :disabled="busy" @click="confirming=upload">取消残留</button>
    </div>
    <div v-if="nextCursor" class="gallery-load"><button type="button" :disabled="loading||busy" @click="load(true)">{{loading?'正在加载…':'加载更多上传'}}</button></div>
    <div class="upload-cleanup-controls">
      <label>清理多久未活动的上传 <select v-model.number="days" :disabled="busy"><option :value="7">7 天</option><option :value="30">30 天</option><option :value="90">90 天</option></select></label>
      <button type="button" class="account-action" :disabled="busy||loading" @click="confirming='expired'">清理过期残留…</button>
    </div>
    <div v-if="confirming" class="upload-confirm" role="group" aria-label="确认清理上传">
      <p>{{confirming==='expired'?`清理 ${days} 天没有活动、尚未发布的上传残留？正在写入和提交的上传会受到保护。`:`取消“${confirming.path}”的断点续传残留？已上传的临时部分将被清理。`}}</p>
      <button type="button" class="account-action" :disabled="busy" @click="confirm">{{busy?'正在处理…':'确认清理'}}</button>
      <button type="button" class="account-action" :disabled="busy" @click="confirming=null">保留</button>
    </div>
  </section>
</template>

<style scoped>
.upload-maintenance{margin-bottom:20px}
.upload-detail{min-width:0;overflow-wrap:anywhere}
.upload-cleanup-controls{display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin-top:18px}
.upload-cleanup-controls label{display:flex;align-items:center;gap:8px;font-size:13px}
.upload-cleanup-controls select{font:inherit;padding:5px 8px;border:1px solid var(--fluid-card-border);border-radius:6px;background:var(--fluid-card-fill);color:var(--text-primary)}
.upload-confirm{margin-top:12px;padding:12px;border:1px solid var(--fluid-card-border);border-radius:8px}
.upload-confirm button+button{margin-left:12px}
</style>
