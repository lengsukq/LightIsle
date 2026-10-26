<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { ArrowDownToLine, Link2, Pause, Play, RefreshCw, RotateCcw, Trash2 } from "lucide-vue-next";
import {readDownloadCenter,type DownloadTask} from "./downloadCenterTransport.js";
import {createMediaStatusPoller} from "./mediaStatusPoller.js";
import {describeRootOperationFailure} from "./rootDiscovery.js";
const props=defineProps<{api:(path:string,init?:RequestInit)=>Promise<unknown>}>();
const tasks=ref<DownloadTask[]>([]);
const hasSnapshot=ref(false);
const status=ref<{available:boolean;version?:string;reason?:string}>({available:false});
const loading=ref(false),error=ref(""),busy=ref(""),newURL=ref(""),newDestination=ref("."),newMaxGB=ref("");
const creating=ref(false);
let timer:number|undefined,disposed=false;
const activePollMs=3000,idlePollMs=15000;
let lastLoadAt=0;
let loadVersion=0;
const activeTasks=computed(()=>tasks.value.filter(t=>t.status==="queued"||t.status==="running"||t.status==="paused"));
const poller=createMediaStatusPoller(signal=>readDownloadCenter(props.api,signal),{
 onValue: value=>{tasks.value=value.tasks;status.value=value.status;hasSnapshot.value=true;error.value=""},
 onError: e=>{error.value="读取下载任务失败："+describeRootOperationFailure(e)},
});
async function load(){
 if(disposed)return;
 const version=++loadVersion;
 lastLoadAt=Date.now();
 loading.value=true;
 try{await poller.refresh()}
 finally{if(!disposed&&version===loadVersion)loading.value=false}
}
async function create(){
 if(creating.value||disposed)return;
 const url=newURL.value.trim();
 if(!url){error.value="请输入 http/https/ftp 或磁力链接。";return}
 const destination=newDestination.value.trim()||".";
 let maxBytes=0;
 if(newMaxGB.value.trim()){
  const gb=Number(newMaxGB.value);
  if(!Number.isFinite(gb)||gb<=0||gb>1024){error.value="大小上限必须大于 0 且不超过 1024 GiB，留空使用服务端上限。";return}
  maxBytes=Math.round(gb*1024**3);
 }
 creating.value=true;error.value="";
 poller.invalidate();
 try{
  await props.api("/api/v1/downloads",{method:"POST",headers:{"X-LightIsle-Request":"1"},body:JSON.stringify({url,destination,maxBytes})});
  if(disposed)return;
  newURL.value="";newMaxGB.value="";
  poller.invalidate();
  await load();
 }catch(e){
  if(!disposed)error.value=({download_unavailable:"下载中心不可用：本机未安装 aria2（brew install aria2）或服务未启动。",
    download_invalid_request:"链接或目标目录无效：仅支持 http/https/ftp 与磁力链接，目标须为共享目录内的文件夹。",
    download_limit_reached:"进行中的任务已达上限（100 个），请先完成或取消一些任务。",
    file_permission_denied:"你没有目标目录的写入权限。"} as Record<string,string>)[e instanceof Error?e.message:""]??("创建任务失败："+(e instanceof Error?e.message:"网络异常"));
 }finally{if(!disposed)creating.value=false}
}
async function action(task:DownloadTask,act:"pause"|"resume"|"retry"|"cancel"){
 if(busy.value||disposed)return;
 busy.value=task.id+":"+act;
 poller.invalidate();
 try{
  await props.api("/api/v1/downloads/"+encodeURIComponent(task.id)+"/actions",{method:"POST",headers:{"X-LightIsle-Request":"1"},body:JSON.stringify({action:act})});
  if(!disposed){poller.invalidate();await load()}
 }catch(e){if(!disposed)error.value="操作失败："+(e instanceof Error?e.message:"网络异常")}
 finally{if(!disposed)busy.value=""}
}
async function remove(task:DownloadTask){
 if(busy.value||disposed)return;
 if(!window.confirm("删除任务“"+(task.filename||task.url)+"”的记录？进行中的任务会先取消。"))return;
 busy.value=task.id+":delete";
 poller.invalidate();
 try{
  await props.api("/api/v1/downloads/"+encodeURIComponent(task.id),{method:"DELETE",headers:{"X-LightIsle-Request":"1"}});
  if(!disposed){poller.invalidate();await load()}
 }catch(e){if(!disposed)error.value="删除失败："+(e instanceof Error?e.message:"网络异常")}
 finally{if(!disposed)busy.value=""}
}
function bytes(value:number){return value>=1024**3?(value/1024**3).toFixed(1)+" GiB":value>=1024**2?(value/1024**2).toFixed(1)+" MiB":value>=1024?Math.round(value/1024)+" KiB":value+" B"}
function progress(task:DownloadTask){return task.totalBytes>0?Math.min(100,Math.round(task.completedBytes/task.totalBytes*100)):0}
const statusLabels:Record<DownloadTask["status"],string>={queued:"排队中",running:"下载中",paused:"已暂停",completed:"已完成",failed:"失败",cancelled:"已取消"};
const errorLabels:Record<string,string>={download_restarted:"服务重启，任务被安全中止，可重试。",download_permission_revoked:"目标目录的写入授权已被撤销。",download_exceeds_limit:"超出任务大小上限。",download_too_large:"文件超出下载发布上限。",download_publish_failed:"下载完成后写入共享目录失败，可重试。已保存的文件会保留。",download_staging_lost:"暂存数据丢失，请重试。",download_produced_no_files:"下载未产生文件。",download_gone:"下载会话消失，请重试。",download_root_changed:"共享磁盘已变更，请连接原磁盘后重试。",download_root_unavailable:"原共享磁盘离线，请连接后重试。",download_root_unbound:"旧版任务未绑定原磁盘，不能自动重试；请先核对已有文件。",download_publish_recovery_required:"已有目标文件发生变化，请先核对，不能自动覆盖或生成重复副本。"};
function describeError(task:DownloadTask){return errorLabels[task.error??""]??task.error??""}
// Polling keeps its 3s interval but backs off to 15s while nothing is
// active; hidden tabs skip work entirely and refresh on the first tick
// after becoming visible. Manual loads (refresh button, create, actions)
// run regardless and reset the clock via lastLoadAt.
function pollTick(){
 if(document.hidden||busy.value||creating.value)return;
 if(Date.now()-lastLoadAt<(activeTasks.value.length>0?activePollMs:idlePollMs))return;
 void load();
}
onMounted(()=>{disposed=false;void load();timer=window.setInterval(pollTick,activePollMs)});
onUnmounted(()=>{disposed=true;poller.dispose();if(timer)clearInterval(timer)});
</script>

<template>
 <section class="account-panel" aria-label="下载中心">
  <div class="account-heading"><h3><ArrowDownToLine :size="18" aria-hidden="true"/> 下载中心</h3>
   <button type="button" class="refresh" :disabled="loading" @click="load">{{loading?"加载中…":"刷新"}}</button></div>
  <p v-if="loading&&!hasSnapshot" class="footnote" role="status">正在读取下载中心…</p>
  <p v-if="hasSnapshot&&!status.available" class="footnote" role="note">暂时不能新建下载：{{status.reason==="aria2_not_installed"?"Mac 尚未安装下载组件 aria2，请在 Mac 安装后刷新":"下载服务尚未启动"}}。已有记录可查看，已下载的任务仍可重试保存；已保存的文件会保留。</p>
  <p v-if="hasSnapshot&&status.available" class="footnote">HTTP/HTTPS/FTP 与磁力链接；任务先下载到服务端暂存区，完成后经安全发布进入共享目录（同名自动改名，绝不覆盖）。并发 3；Core 重启会安全中止进行中的任务并保留重试。</p>
  <form v-if="status.available" class="account-form" @submit.prevent="create">
   <label>下载链接（http/https/ftp/磁力）
    <input v-model="newURL" type="text" placeholder="https://example.com/file.iso 或 magnet:?xt=urn:btih:…" required />
   </label>
   <label>保存到共享目录
    <input v-model="newDestination" type="text" placeholder="例如 Downloads 或 .（根目录）" />
   </label>
   <label>大小上限 GiB（留空使用服务端上限）
    <input v-model="newMaxGB" type="number" min="0.1" max="1024" step="0.1" />
   </label>
   <button type="submit" class="auth-submit" :disabled="creating">{{creating?"正在创建…":"新建下载任务"}}</button>
  </form>
  <p v-if="error" class="form-error" role="alert">{{error}}</p>
  <p v-if="hasSnapshot&&!tasks.length&&!loading&&!error" class="footnote">还没有下载任务。</p>
  <div v-for="task in tasks" :key="task.id" class="account-row">
   <div>
    <strong><Link2 :size="14" aria-hidden="true"/> {{task.filename||task.url}}<span class="share-flag">{{task.phase==='publishing'&&task.status==='running'?'正在保存':statusLabels[task.status]}}</span></strong>
    <small>目标：{{task.destination==="."?"共享根目录":task.destination}}
     <template v-if="task.totalBytes>0"> · {{bytes(task.completedBytes)}} / {{bytes(task.totalBytes)}}（{{progress(task)}}%）</template>
     <template v-else-if="task.completedBytes>0"> · {{bytes(task.completedBytes)}}</template>
     <template v-if="task.maxBytes>0"> · 上限 {{bytes(task.maxBytes)}}</template>
     · {{new Date(task.createdAt*1000).toLocaleString()}}</small>
    <div v-if="task.status==='running'&&task.totalBytes>0" class="task-progress" role="progressbar" :aria-valuenow="progress(task)" aria-valuemin="0" aria-valuemax="100"><span :style="{width:progress(task)+'%'}"></span></div>
    <small v-if="task.status==='failed'&&describeError(task)" class="form-error">{{describeError(task)}}</small>
    <small v-if="task.partialPublish">部分文件已保存，任务尚未全部完成；重试会核对已有文件。</small>
    <small v-if="task.recoveryRequired" class="form-error">已有文件与记录不一致，请先在 Mac 核对；不会自动覆盖。</small>
    <details v-if="task.publishedFiles?.length">
     <summary>文件处理记录（{{task.publishedFilesTotal??task.publishedFiles.length}} 项）</summary>
     <ul><li v-for="file in task.publishedFiles" :key="file.target">{{file.target}} · {{file.status==='published'?'已保存':file.status==='recovery_required'?'需要核对':'等待核对'}} · {{bytes(file.size)}}</li></ul>
     <small v-if="task.publishedFilesTruncated">这里只显示前 {{task.publishedFiles.length}} 项；其余处理记录仍由服务端保留。</small>
    </details>
   </div>
   <div class="task-empty-actions">
    <button v-if="task.phase!=='publishing'&&(task.status==='running'||task.status==='queued')" type="button" class="account-action" :disabled="busy!==''||!status.available" @click="action(task,'pause')"><Pause :size="14" aria-hidden="true"/> 暂停</button>
    <button v-if="task.status==='paused'" type="button" class="account-action" :disabled="busy!==''||!status.available" @click="action(task,'resume')"><Play :size="14" aria-hidden="true"/> 继续</button>
    <button v-if="task.status==='failed'||task.status==='cancelled'" type="button" class="account-action" :disabled="busy!==''||(!status.available&&task.phase!=='publishing')" @click="action(task,'retry')"><RotateCcw :size="14" aria-hidden="true"/> 重试</button>
    <button v-if="task.status!=='completed'&&task.status!=='cancelled'&&task.status!=='failed'" type="button" class="account-action" :disabled="busy!==''" @click="action(task,'cancel')"><RefreshCw :size="14" aria-hidden="true"/> 取消</button>
    <button type="button" class="account-action" :disabled="busy!==''" @click="remove(task)"><Trash2 :size="14" aria-hidden="true"/> 删除记录</button>
   </div>
  </div>
  <p v-if="activeTasks.length>0" class="footnote">{{activeTasks.length}} 个任务进行中。</p>
 </section>
</template>

<style scoped>
.account-row>div{min-width:0}
.account-row strong,.account-row small,details li{overflow-wrap:anywhere}
details{margin-top:8px;font-size:var(--font-size-sm,13px)}
summary{cursor:pointer;padding:8px 0}
details ul{padding-inline-start:20px;margin:4px 0;line-height:1.7}
@media(max-width:600px){.account-row{align-items:stretch;flex-direction:column;gap:12px}.task-empty-actions{flex-wrap:wrap}}
</style>
