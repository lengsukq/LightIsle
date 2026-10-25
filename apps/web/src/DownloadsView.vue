<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { ArrowDownToLine, Link2, Pause, Play, RefreshCw, RotateCcw, Trash2 } from "lucide-vue-next";
type DownloadTask={id:string;url:string;destination:string;status:"queued"|"running"|"paused"|"completed"|"failed"|"cancelled";filename?:string;totalBytes:number;completedBytes:number;maxBytes:number;error?:string;createdAt:number;updatedAt:number;completedAt?:number};
const props=defineProps<{api:(path:string,init?:RequestInit)=>Promise<unknown>}>();
const tasks=ref<DownloadTask[]>([]);
const status=ref<{available:boolean;version?:string;reason?:string}>({available:false});
const loading=ref(false),error=ref(""),busy=ref(""),newURL=ref(""),newDestination=ref("."),newMaxGB=ref("");
const creating=ref(false);
let timer:number|undefined,disposed=false;
const activeTasks=computed(()=>tasks.value.filter(t=>t.status==="queued"||t.status==="running"||t.status==="paused"));
async function load(){
 if(disposed)return;
 loading.value=true;
 try{
  const [taskResult,statusResult]=await Promise.all([
    props.api("/api/v1/downloads") as Promise<{tasks:DownloadTask[]}>,
    props.api("/api/v1/downloads/status") as Promise<typeof status.value>,
  ]);
  if(disposed)return;
  tasks.value=taskResult.tasks;
  status.value=statusResult;
  error.value="";
 }catch(e){
  if(!disposed)error.value="读取下载任务失败："+(e instanceof Error?e.message:"网络异常");
 }finally{if(!disposed)loading.value=false}
}
async function create(){
 if(creating.value||disposed)return;
 const url=newURL.value.trim();
 if(!url){error.value="请输入 http/https/ftp 或磁力链接。";return}
 const destination=newDestination.value.trim()||".";
 let maxBytes=0;
 if(newMaxGB.value.trim()){
  const gb=Number(newMaxGB.value);
  if(!Number.isFinite(gb)||gb<=0){error.value="大小上限必须是正数 GB，留空表示不限制。";return}
  maxBytes=Math.round(gb*1024**3);
 }
 creating.value=true;error.value="";
 try{
  await props.api("/api/v1/downloads",{method:"POST",headers:{"X-LightIsle-Request":"1"},body:JSON.stringify({url,destination,maxBytes})});
  if(disposed)return;
  newURL.value="";newMaxGB.value="";
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
 try{
  await props.api("/api/v1/downloads/"+encodeURIComponent(task.id)+"/actions",{method:"POST",headers:{"X-LightIsle-Request":"1"},body:JSON.stringify({action:act})});
  if(!disposed)await load();
 }catch(e){if(!disposed)error.value="操作失败："+(e instanceof Error?e.message:"网络异常")}
 finally{if(!disposed)busy.value=""}
}
async function remove(task:DownloadTask){
 if(busy.value||disposed)return;
 if(!window.confirm("删除任务“"+(task.filename||task.url)+"”的记录？进行中的任务会先取消。"))return;
 busy.value=task.id+":delete";
 try{
  await props.api("/api/v1/downloads/"+encodeURIComponent(task.id),{method:"DELETE",headers:{"X-LightIsle-Request":"1"}});
  if(!disposed)await load();
 }catch(e){if(!disposed)error.value="删除失败："+(e instanceof Error?e.message:"网络异常")}
 finally{if(!disposed)busy.value=""}
}
function bytes(value:number){return value>=1024**3?(value/1024**3).toFixed(1)+" GiB":value>=1024**2?(value/1024**2).toFixed(1)+" MiB":value>=1024?Math.round(value/1024)+" KiB":value+" B"}
function progress(task:DownloadTask){return task.totalBytes>0?Math.min(100,Math.round(task.completedBytes/task.totalBytes*100)):0}
const statusLabels:Record<DownloadTask["status"],string>={queued:"排队中",running:"下载中",paused:"已暂停",completed:"已完成",failed:"失败",cancelled:"已取消"};
const errorLabels:Record<string,string>={download_restarted:"服务重启，任务被安全中止，可重试。",download_permission_revoked:"目标目录的写入授权已被撤销。",download_exceeds_limit:"超出任务大小上限。",download_publish_failed:"下载完成后写入共享目录失败。",download_staging_lost:"暂存数据丢失，请重试。",download_produced_no_files:"下载未产生文件。",download_gone:"下载会话消失，请重试。"};
function describeError(task:DownloadTask){return errorLabels[task.error??""]??task.error??""}
onMounted(()=>{disposed=false;void load();timer=window.setInterval(()=>void load(),3000)});
onUnmounted(()=>{disposed=true;if(timer)clearInterval(timer)});
</script>

<template>
 <section class="account-panel" aria-label="下载中心">
  <div class="account-heading"><h3><ArrowDownToLine :size="18" aria-hidden="true"/> 下载中心</h3>
   <button type="button" class="refresh" :disabled="loading" @click="load">{{loading?"加载中…":"刷新"}}</button></div>
  <p v-if="!status.available" class="footnote" role="note">下载中心不可用：{{status.reason==="aria2_not_installed"?"本机未安装 aria2（可在 Mac 上 brew install aria2，LightIsle 不捆绑、不自动下载）":"服务未启动"}}。文件上传、分享与 WebDAV 不受影响。</p>
  <p v-else class="footnote">HTTP/HTTPS/FTP 与磁力链接；任务先下载到服务端暂存区，完成后经安全发布进入共享目录（同名自动改名，绝不覆盖）。并发 3；Core 重启会安全中止进行中的任务并保留重试。</p>
  <form v-if="status.available" class="account-form" @submit.prevent="create">
   <label>下载链接（http/https/ftp/磁力）
    <input v-model="newURL" type="text" placeholder="https://example.com/file.iso 或 magnet:?xt=urn:btih:…" required />
   </label>
   <label>保存到共享目录
    <input v-model="newDestination" type="text" placeholder="例如 Downloads 或 .（根目录）" />
   </label>
   <label>大小上限 GB（留空不限制）
    <input v-model="newMaxGB" type="number" min="0.1" step="0.1" />
   </label>
   <button type="submit" class="auth-submit" :disabled="creating">{{creating?"正在创建…":"新建下载任务"}}</button>
  </form>
  <p v-if="error" class="form-error" role="alert">{{error}}</p>
  <p v-if="!tasks.length&&!loading" class="footnote">还没有下载任务。</p>
  <div v-for="task in tasks" :key="task.id" class="account-row">
   <div>
    <strong><Link2 :size="14" aria-hidden="true"/> {{task.filename||task.url}}<span class="share-flag">{{statusLabels[task.status]}}</span></strong>
    <small>目标：{{task.destination==="."?"共享根目录":task.destination}}
     <template v-if="task.totalBytes>0"> · {{bytes(task.completedBytes)}} / {{bytes(task.totalBytes)}}（{{progress(task)}}%）</template>
     <template v-else-if="task.completedBytes>0"> · {{bytes(task.completedBytes)}}</template>
     <template v-if="task.maxBytes>0"> · 上限 {{bytes(task.maxBytes)}}</template>
     · {{new Date(task.createdAt*1000).toLocaleString()}}</small>
    <div v-if="task.status==='running'&&task.totalBytes>0" class="task-progress" role="progressbar" :aria-valuenow="progress(task)" aria-valuemin="0" aria-valuemax="100"><span :style="{width:progress(task)+'%'}"></span></div>
    <small v-if="task.status==='failed'&&describeError(task)" class="form-error">{{describeError(task)}}</small>
   </div>
   <div class="task-empty-actions">
    <button v-if="task.status==='running'||task.status==='queued'" type="button" class="account-action" :disabled="busy!==''" @click="action(task,'pause')"><Pause :size="14" aria-hidden="true"/> 暂停</button>
    <button v-if="task.status==='paused'" type="button" class="account-action" :disabled="busy!==''" @click="action(task,'resume')"><Play :size="14" aria-hidden="true"/> 继续</button>
    <button v-if="task.status==='failed'||task.status==='cancelled'" type="button" class="account-action" :disabled="busy!==''" @click="action(task,'retry')"><RotateCcw :size="14" aria-hidden="true"/> 重试</button>
    <button v-if="task.status!=='completed'&&task.status!=='cancelled'&&task.status!=='failed'" type="button" class="account-action" :disabled="busy!==''" @click="action(task,'cancel')"><RefreshCw :size="14" aria-hidden="true"/> 取消</button>
    <button type="button" class="account-action" :disabled="busy!==''" @click="remove(task)"><Trash2 :size="14" aria-hidden="true"/> 删除记录</button>
   </div>
  </div>
  <p v-if="activeTasks.length>0" class="footnote">{{activeTasks.length}} 个任务进行中。</p>
 </section>
</template>
