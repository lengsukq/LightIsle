<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import { AlertTriangle, CheckCircle2, RefreshCw } from "lucide-vue-next";
import { createLatestRequestGate } from "./latestRequestGate.js";
import { rootApiPath } from "./rootApi.js";
type Alert={code:string;severity:"warning"|"critical";message:string;active:boolean;acknowledged:boolean;firstSeen:number;lastSeen:number};
const props=defineProps<{rootId?:string;rootGeneration?:number}>();
const alerts=ref<Alert[]>([]);
const loading=ref(false),error=ref(""),history=ref(false),busy=ref("");
let timer:number|undefined,disposed=false;
const alertRequests=createLatestRequestGate();
function apiPath(path:string){return rootApiPath(props.rootId,path)}
async function load(force=false){
 if(disposed||loading.value&&!force)return;
 const request=alertRequests.begin();
 const rootID=props.rootId,rootGeneration=props.rootGeneration??0;
 loading.value=true;error.value="";
 try{
  const headers=new Headers();if(rootID)headers.set("X-LightIsle-Root-Generation",String(rootGeneration));
  const response=await fetch(apiPath("/api/v1/alerts")+(history.value?"?history=1":""),{credentials:"same-origin",cache:"no-store",signal:request.signal,headers});
  if(!response.ok){
   const failure=await response.json().catch(()=>({})) as {error?:string};
   if(rootID&&response.status===409&&failure.error==="root_generation_changed")window.dispatchEvent(new Event("lightisle-root-generation-changed"));
   throw new Error(failure.error==="root_generation_changed"?"共享目录已变化，请刷新根列表后重新选择。":"HTTP "+response.status);
  }
  const result=await response.json() as {alerts:Alert[]};
  if(!disposed&&request.isCurrent()&&rootID===props.rootId&&rootGeneration===(props.rootGeneration??0))alerts.value=result.alerts;
 }catch(e){if(!disposed&&request.isCurrent()&&!(e instanceof Error&&e.name==="AbortError"))error.value="无法获取异常通知："+(e instanceof Error?e.message:"网络异常")}
 finally{if(request.isCurrent())loading.value=false}
}
async function acknowledge(alert:Alert){
 if(busy.value||disposed)return;
 const rootID=props.rootId,rootGeneration=props.rootGeneration??0;
 busy.value=alert.code;
 try{
  const headers=new Headers({"X-LightIsle-Request":"1"});if(rootID)headers.set("X-LightIsle-Root-Generation",String(rootGeneration));
  const response=await fetch(apiPath("/api/v1/alerts/"+encodeURIComponent(alert.code)+"/acknowledge"),{
   method:"POST",credentials:"same-origin",headers,
  });
  if(!response.ok){
   const failure=await response.json().catch(()=>({})) as {error?:string};
   if(rootID&&response.status===409&&failure.error==="root_generation_changed")window.dispatchEvent(new Event("lightisle-root-generation-changed"));
   throw new Error(failure.error==="root_generation_changed"?"共享目录已变化，请刷新根列表后重新选择。":"HTTP "+response.status);
  }
  if(rootID!==props.rootId||rootGeneration!==(props.rootGeneration??0)||disposed)return;
  await load(true);
 }catch(e){if(!disposed)error.value="确认通知失败："+(e instanceof Error?e.message:"网络异常")}
 finally{if(!disposed)busy.value=""}
}
function toggleHistory(){history.value=!history.value;void load(true)}
onMounted(()=>{disposed=false;void load();timer=window.setInterval(()=>void load(),60000)});
onUnmounted(()=>{disposed=true;if(timer)clearInterval(timer);alertRequests.cancel()});
</script>

<template>
 <section class="account-panel alert-center" aria-label="存储和任务异常通知">
  <div class="account-heading">
   <h3><AlertTriangle :size="18" aria-hidden="true"/> 存储与任务通知</h3>
   <div class="alert-actions">
    <button type="button" class="account-action" @click="toggleHistory">{{history?"仅看未恢复":"查看历史"}}</button>
    <button type="button" class="refresh" :disabled="loading" @click="load()"><RefreshCw :size="14"/> 刷新</button>
   </div>
  </div>
  <p>监测共享盘离线、剩余空间过低、备份失败及图库/影视扫描失败。相同异常不会反复提醒；确认操作不会隐藏磁盘的实际故障状态。</p>
  <p v-if="error" class="form-error" role="alert">{{error}}</p>
  <p v-if="!alerts.length&&!loading&&!error" class="footnote">目前没有{{history?"历史":"未恢复的"}}异常记录。</p>
  <div v-for="alert in alerts" :key="alert.code" class="account-row alert-item">
   <div>
    <strong><AlertTriangle v-if="alert.active&&!alert.acknowledged" :size="15" aria-hidden="true"/><CheckCircle2 v-else :size="15" aria-hidden="true"/> {{alert.message}}</strong>
    <small>{{alert.severity==="critical"?"严重":"警告"}} · {{alert.active?alert.acknowledged?"已确认，异常仍存在":"待确认":"已恢复"}} · 发现于 {{new Date(alert.firstSeen*1000).toLocaleString("zh-CN")}}</small>
   </div>
   <button v-if="alert.active&&!alert.acknowledged" type="button" class="account-action" :disabled="!!busy" @click="acknowledge(alert)">确认已知晓</button>
  </div>
 </section>
</template>

<style scoped>
.alert-center{margin-bottom:20px}
.alert-center .account-heading h3{display:flex;align-items:center;gap:8px}
.alert-center p{color:var(--text-secondary);font-size:12px;line-height:1.5}
.alert-item strong{display:flex;align-items:center;gap:6px;font-size:13px}
.alert-item small{display:block;margin-top:6px;color:var(--text-secondary);font-size:11px}
.alert-actions{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
</style>
