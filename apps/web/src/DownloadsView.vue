<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import { ArrowDownToLine, ChevronLeft, ChevronRight, Folder, Link2, LoaderCircle, Pause, Play, RefreshCw, RotateCcw, Trash2 } from "lucide-vue-next";
import { requestConfirm } from "./useConfirmDialog.ts";
import { apiRequest } from "./apiClient.ts";
import IsleCard from "./IsleCard.vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleEmpty from "./IsleEmpty.vue";
import IsleModal from "./IsleModal.vue";
import {readDownloadCenter,type DownloadTask} from "./downloadCenterTransport.ts";
import {createMediaStatusPoller} from "./mediaStatusPoller.ts";
import {describeRootOperationFailure} from "./rootDiscovery.ts";
import {describeUserFacingError} from "./userFacingError.ts";
import {formatDateTime} from "./dateTimeFormat.ts";

type FolderItem = { name: string; path: string; type: "file" | "folder"; canWrite?: boolean };
type FolderListReply = { entries: FolderItem[]; nextCursor?: string; canWrite?: boolean };

const props=withDefaults(defineProps<{active?:boolean;api?:(path:string,init?:RequestInit)=>Promise<unknown>}>(),{active:true});
const requestApi=(path:string,init?:RequestInit)=>(props.api?props.api(path,init):apiRequest(path,init));
const tasks=ref<DownloadTask[]>([]);
const hasSnapshot=ref(false);
const status=ref<{available:boolean;networkAllowed?:boolean;version?:string;reason?:string}>({available:false});
const loading=ref(false),error=ref(""),busy=ref(""),newURL=ref(""),newDestination=ref("."),newMaxGB=ref("");
const creating=ref(false);

const folderPickerOpen=ref(false);
const pickerDir=ref(".");
const pickerFolders=ref<FolderItem[]>([]);
const pickerNextCursor=ref("");
const pickerCanWrite=ref(true);
const pickerLoading=ref(false);
const pickerError=ref("");
let pickerGen=0;

const pickerBreadcrumbs=computed(()=>{
 if(pickerDir.value===".")return[{label:"共享根目录",path:"."}];
 const parts=pickerDir.value.split("/");
 return[{label:"共享根目录",path:"."},...parts.map((part,i)=>({label:part,path:parts.slice(0,i+1).join("/")}))];
});

async function loadPickerFolders(more=false){
 const req=++pickerGen;
 const target=pickerDir.value;
 pickerLoading.value=true;
 pickerError.value="";
 try{
  const query=new URLSearchParams({path:target,limit:"100"});
  if(more&&pickerNextCursor.value)query.set("cursor",pickerNextCursor.value);
  const data=await requestApi("/api/v2/files?"+query.toString()) as FolderListReply;
  if(req!==pickerGen||target!==pickerDir.value)return;
  const dirs=(data.entries??[]).filter(item=>item.type==="folder");
  pickerFolders.value=more?[...pickerFolders.value,...dirs]:dirs;
  pickerNextCursor.value=data.nextCursor??"";
  pickerCanWrite.value=data.canWrite!==false;
 }catch(e){
  if(req===pickerGen)pickerError.value="读取文件夹失败："+describeUserFacingError(e);
 }finally{
  if(req===pickerGen)pickerLoading.value=false;
 }
}

function openFolderPicker(){
 const current=newDestination.value.trim().replace(/^\/+|\/+$/g,"")||".";
 pickerDir.value=current;
 pickerFolders.value=[];
 pickerNextCursor.value="";
 folderPickerOpen.value=true;
 void loadPickerFolders(false);
}

function navigatePicker(nextPath:string){
 pickerDir.value=nextPath;
 pickerFolders.value=[];
 pickerNextCursor.value="";
 void loadPickerFolders(false);
}

function confirmPickerFolder(){
 newDestination.value=pickerDir.value;
 folderPickerOpen.value=false;
}

let timer:number|undefined,disposed=false;
const activePollMs=3000,idlePollMs=15000;
let lastLoadAt=0;
let loadVersion=0;
const activeTasks=computed(()=>tasks.value.filter(t=>t.status==="queued"||t.status==="running"||t.status==="paused"));
const poller=createMediaStatusPoller(signal=>readDownloadCenter(requestApi,signal),{
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
 if(creating.value||disposed||status.value.networkAllowed===false)return;
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
  await requestApi("/api/v2/downloads",{method:"POST",headers:{"Content-Type":"application/json","X-LightIsle-Request":"1"},body:JSON.stringify({url,destination,maxBytes})});
  if(disposed)return;
  newURL.value="";newMaxGB.value="";
  poller.invalidate();
  await load();
 }catch(e){
  if(!disposed)error.value=({download_unavailable:"下载中心不可用：本机未安装 aria2（brew install aria2）或服务未启动。",
    download_invalid_request:"链接或目标目录无效：仅支持 http/https/ftp 与磁力链接，目标须为共享目录内的文件夹。",
    download_limit_reached:"进行中的任务已达上限（100 个），请先完成或取消一些任务。",
    file_permission_denied:"你没有目标目录的写入权限。"} as Record<string,string>)[e instanceof Error?e.message:""]??("创建任务失败："+describeUserFacingError(e));
 }finally{if(!disposed)creating.value=false}
}
async function action(task:DownloadTask,act:"pause"|"resume"|"retry"|"cancel"){
 if(busy.value||disposed)return;
 busy.value=task.id+":"+act;
 poller.invalidate();
 try{
  await requestApi("/api/v2/downloads/"+encodeURIComponent(task.id)+"/actions",{method:"POST",headers:{"Content-Type":"application/json","X-LightIsle-Request":"1"},body:JSON.stringify({action:act})});
  if(!disposed){poller.invalidate();await load()}
 }catch(e){if(!disposed)error.value="操作失败："+describeUserFacingError(e)}
 finally{if(!disposed)busy.value=""}
}
async function remove(task:DownloadTask){
 if(busy.value||disposed)return;
 if(!(await requestConfirm({title:"删除下载记录",message:"删除任务“"+(task.filename||task.url)+"”的记录？进行中的任务会先取消。",confirmText:"确认删除",variant:"danger"})))return;
 busy.value=task.id+":delete";
 poller.invalidate();
 try{
  await requestApi("/api/v2/downloads/"+encodeURIComponent(task.id),{method:"DELETE",headers:{"X-LightIsle-Request":"1"}});
  if(!disposed){poller.invalidate();await load()}
 }catch(e){if(!disposed)error.value="删除失败："+describeUserFacingError(e)}
 finally{if(!disposed)busy.value=""}
}
function bytes(value:number){return value>=1024**3?(value/1024**3).toFixed(1)+" GiB":value>=1024**2?(value/1024**2).toFixed(1)+" MiB":value>=1024?Math.round(value/1024)+" KiB":value+" B"}
function progress(task:DownloadTask){return task.totalBytes>0?Math.min(100,Math.round(task.completedBytes/task.totalBytes*100)):0}
const statusLabels:Record<DownloadTask["status"],string>={queued:"排队中",running:"下载中",paused:"已暂停",completed:"已完成",failed:"失败",cancelled:"已取消"};
const errorLabels:Record<string,string>={download_restarted:"服务重启，任务被安全中止，可重试。",download_permission_revoked:"目标目录的写入授权已被撤销。",download_exceeds_limit:"超出任务大小上限。",download_too_large:"文件超出下载发布上限。",download_publish_failed:"下载完成后写入共享目录失败，可重试。已保存的文件会保留。",download_staging_lost:"暂存数据丢失，请重试。",download_produced_no_files:"下载未产生文件。",download_gone:"下载会话消失，请重试。",download_root_changed:"共享磁盘已变更，请连接原磁盘后重试。",download_root_unavailable:"原共享磁盘离线，请连接后重试。",download_root_unbound:"旧版任务未绑定原磁盘，不能自动重试；请先核对已有文件。",download_publish_recovery_required:"已有目标文件发生变化，请先核对，不能自动覆盖或生成重复副本。"};
function describeError(task:DownloadTask){return !task.error?"":errorLabels[task.error]??describeUserFacingError(new Error(task.error))}
// Polling keeps its 3s interval but backs off to 15s while nothing is
// active; hidden/inactive tabs pause polling completely and refresh when active.
function pollTick(){
 if(props.active===false||document.hidden||busy.value||creating.value)return;
 if(Date.now()-lastLoadAt<(activeTasks.value.length>0?activePollMs:idlePollMs))return;
 void load();
}
function syncPollTimer(active:boolean){
 if(active&&!disposed){
  if(timer===undefined)timer=window.setInterval(pollTick,activePollMs);
 }else if(timer!==undefined){
  clearInterval(timer);timer=undefined;
 }
}
watch(()=>props.active,active=>{
 syncPollTimer(active!==false);
 if(active!==false&&!document.hidden)void load();
});
onMounted(()=>{disposed=false;if(props.active!==false)void load();syncPollTimer(props.active!==false)});
onUnmounted(()=>{disposed=true;poller.dispose();syncPollTimer(false)});
</script>

<template>
 <IsleCard aria-label="下载中心" title="任务与新建下载" subtitle="支持链接与磁力任务，完成后自动保存至所选目录，不覆盖同名文件。">
  <template #icon><ArrowDownToLine :size="18" aria-hidden="true"/></template>
  <template #actions>
    <IsleButton variant="glass" size="sm" :loading="loading" @click="load">{{loading?"加载中…":"刷新"}}</IsleButton>
  </template>
  <p v-if="loading&&!hasSnapshot" class="footnote" role="status">正在读取下载中心…</p>
  <IsleBanner v-if="hasSnapshot&&!status.available" type="warning" compact role="note" :message="'暂时无法新建下载：'+(status.reason==='aria2_not_installed'?'请先在 Mac 的「外部依赖」中安装下载组件':'下载服务未就绪，请稍后重试')+'。以前下载的文件不会删除。'" />
  <IsleBanner v-if="hasSnapshot&&status.networkAllowed===false" type="info" compact message="新建或继续网络下载需要管理员权限，已有任务和已下载的文件仍可管理。" />
  <form v-if="status.available&&status.networkAllowed!==false" class="account-form settings-form-subcard download-form" @submit.prevent="create">
   <label>下载链接
    <input v-model="newURL" type="text" placeholder="https://example.com/file.iso 或 magnet:?xt=urn:btih:…" required />
   </label>
   <div class="download-form-row">
    <div class="download-dest-field">
     <div class="download-dest-head">
      <span>保存位置</span>
      <div class="download-dest-chips">
       <button type="button" class="dest-quick-chip" :class="{active:(newDestination.trim()||'.')==='.'}" @click="newDestination='.'">根目录 (.)</button>
       <button type="button" class="dest-quick-chip" :class="{active:newDestination.trim()==='Downloads'}" @click="newDestination='Downloads'">Downloads</button>
       <button type="button" class="dest-browse-btn" @click="openFolderPicker"><Folder :size="13"/> 浏览目录…</button>
      </div>
     </div>
     <input v-model="newDestination" type="text" aria-label="保存位置" placeholder="例如 Downloads 或 .（根目录）" />
    </div>
    <label>大小上限（GiB，选填）
     <input v-model="newMaxGB" type="number" min="0.1" max="1024" step="0.1" placeholder="默认不限" />
    </label>
    <IsleButton type="submit" variant="primary" :loading="creating">{{creating?"正在创建…":"新建下载"}}</IsleButton>
   </div>
  </form>
  <IsleModal
   :open="folderPickerOpen"
   title="选择下载保存目录"
   :description="'当前位置：' + (pickerDir === '.' ? '共享根目录' : pickerDir)"
   size="md"
   @close="folderPickerOpen = false"
  >
   <div class="picker-crumbs" aria-label="目录层级">
    <button
     v-for="crumb in pickerBreadcrumbs"
     :key="crumb.path"
     type="button"
     :disabled="pickerLoading || crumb.path === pickerDir"
     @click="navigatePicker(crumb.path)"
    >
     {{ crumb.label }} <ChevronRight :size="13" />
    </button>
   </div>
   <div class="picker-folder-list">
    <p v-if="pickerLoading && !pickerFolders.length" class="picker-feedback"><LoaderCircle :size="15" class="spin-icon" /> 正在读取文件夹…</p>
    <template v-else>
     <button v-if="pickerDir !== '.'" type="button" class="picker-folder-row" :disabled="pickerLoading" @click="navigatePicker(pickerDir.split('/').slice(0, -1).join('/') || '.')">
      <ChevronLeft :size="16" /> <span>返回上一级</span>
     </button>
     <button v-for="folder in pickerFolders" :key="folder.path" type="button" class="picker-folder-row" :disabled="pickerLoading" @click="navigatePicker(folder.path)">
      <Folder :size="17" /> <span>{{ folder.name }}</span> <ChevronRight :size="14" />
     </button>
     <p v-if="!pickerFolders.length && !pickerError" class="picker-feedback">当前文件夹下没有子文件夹，可直接选择当前位置。</p>
     <IsleButton v-if="pickerNextCursor" variant="glass" size="sm" :loading="pickerLoading" style="margin:6px auto;display:flex" @click="loadPickerFolders(true)">加载更多文件夹</IsleButton>
    </template>
   </div>
   <IsleBanner v-if="!pickerCanWrite && !pickerLoading" type="warning" compact message="当前目录为只读，请选择有写入权限的文件夹。" />
   <IsleBanner v-if="pickerError" type="error" compact :message="pickerError" />
   <template #footer>
    <IsleButton variant="glass" @click="folderPickerOpen = false">取消</IsleButton>
    <IsleButton variant="primary" :disabled="!pickerCanWrite || pickerLoading" @click="confirmPickerFolder">保存到此目录</IsleButton>
   </template>
  </IsleModal>
  <IsleBanner v-if="error" type="error" compact :message="error" style="margin-top: 10px" />
  <IsleEmpty
    v-if="hasSnapshot&&!tasks.length&&!loading&&!error"
    compact
    :icon="ArrowDownToLine"
    title="还没有下载任务"
    description="从文件列表中选择文件创建下载任务，或在此处查看历史下载记录。"
  />
  <div v-for="task in tasks" :key="task.id" class="account-row download-row">
   <div>
    <strong>
      <Link2 :size="14" aria-hidden="true"/> {{task.filename||task.url}}
      <IsleBadge
        :variant="task.status==='completed'?'online':task.status==='failed'?'danger':task.status==='running'?'accent':'neutral'"
        size="sm"
      >
        {{task.phase==='publishing'&&task.status==='running'?'正在保存':statusLabels[task.status]}}
      </IsleBadge>
    </strong>
    <small>目标：{{task.destination==="."?"共享根目录":task.destination}}
     <template v-if="task.totalBytes>0"> · {{bytes(task.completedBytes)}} / {{bytes(task.totalBytes)}}（{{progress(task)}}%）</template>
     <template v-else-if="task.completedBytes>0"> · {{bytes(task.completedBytes)}}</template>
     <template v-if="task.maxBytes>0"> · 上限 {{bytes(task.maxBytes)}}</template>
     · {{formatDateTime(task.createdAt*1000)}}</small>
    <div v-if="task.status==='running'&&task.totalBytes>0" class="task-progress" role="progressbar" :aria-valuenow="progress(task)" aria-valuemin="0" aria-valuemax="100"><span :style="{width:progress(task)+'%'}"></span></div>
    <small v-if="task.status==='failed'&&describeError(task)" class="form-error">{{describeError(task)}}</small>
    <small v-if="task.partialPublish">部分文件已保存，任务尚未全部完成；重试会核对已有文件。</small>
    <small v-if="task.recoveryRequired" class="form-error">已有文件与记录不一致，请先在 Mac 核对；不会自动覆盖。</small>
    <details v-if="task.publishedFiles?.length" class="apple-disclosure-card">
     <summary><div class="disclosure-title"><span>文件处理记录（{{task.publishedFilesTotal??task.publishedFiles.length}} 项）</span></div></summary>
     <div class="disclosure-body">
      <ul><li v-for="file in task.publishedFiles" :key="file.target">{{file.target}} · {{file.status==='published'?'已保存':file.status==='recovery_required'?'需要核对':'等待核对'}} · {{bytes(file.size)}}</li></ul>
      <small v-if="task.publishedFilesTruncated">这里只显示前 {{task.publishedFiles.length}} 项；其余处理记录仍由服务端保留。</small>
     </div>
    </details>
   </div>
   <div class="task-empty-actions">
    <IsleButton v-if="task.phase!=='publishing'&&(task.status==='running'||task.status==='queued')" variant="glass" size="sm" :disabled="busy!==''||!status.available" @click="action(task,'pause')"><template #icon><Pause :size="14" aria-hidden="true"/></template>暂停</IsleButton>
    <IsleButton v-if="task.status==='paused'" variant="glass" size="sm" :disabled="busy!==''||!status.available||status.networkAllowed===false" @click="action(task,'resume')"><template #icon><Play :size="14" aria-hidden="true"/></template>继续</IsleButton>
    <IsleButton v-if="task.status==='failed'||task.status==='cancelled'" variant="glass" size="sm" :disabled="busy!==''||((!status.available||status.networkAllowed===false)&&task.phase!=='publishing')" @click="action(task,'retry')"><template #icon><RotateCcw :size="14" aria-hidden="true"/></template>重试</IsleButton>
    <IsleButton v-if="task.status!=='completed'&&task.status!=='cancelled'&&task.status!=='failed'" variant="glass" size="sm" :disabled="busy!==''" @click="action(task,'cancel')"><template #icon><RefreshCw :size="14" aria-hidden="true"/></template>取消</IsleButton>
    <IsleButton variant="danger" size="sm" :disabled="busy!==''" @click="remove(task)"><template #icon><Trash2 :size="14" aria-hidden="true"/></template>删除记录</IsleButton>
   </div>
  </div>
  <p v-if="activeTasks.length>0" class="footnote">{{activeTasks.length}} 个任务进行中。</p>
 </IsleCard>
</template>

<style scoped>
.account-row>div{min-width:0}
.account-row strong,.account-row small,details li{overflow-wrap:anywhere}
.download-form-row{display:grid;grid-template-columns:minmax(220px,1.7fr) minmax(140px,1fr) auto;gap:12px;align-items:end}
.download-dest-field{display:grid;gap:6px;min-width:0}
.download-dest-head{display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;font-size:13px;font-weight:600}
.download-dest-chips{display:inline-flex;align-items:center;gap:6px;flex-wrap:wrap}
.dest-quick-chip,.dest-browse-btn{
  display:inline-flex;align-items:center;gap:4px;padding:3px 9px;border-radius:999px;
  font-size:11.5px;font-weight:600;cursor:pointer;
  border:1px solid var(--fluid-card-border);background:var(--fluid-card-item-fill);color:var(--text-secondary);
  transition:background 0.15s ease,color 0.15s ease,border-color 0.15s ease;
}
.dest-quick-chip:hover,.dest-browse-btn:hover{color:var(--text-primary);background:var(--fluid-card-hover)}
.dest-quick-chip.active{
  color:var(--accent-primary);
  border-color:color-mix(in srgb,var(--accent-primary) 45%,var(--fluid-card-border));
  background:color-mix(in srgb,var(--accent-primary) 12%,transparent);
}
.dest-browse-btn{color:var(--accent-primary)}
.picker-crumbs{display:flex;flex-wrap:wrap;gap:6px}
.picker-crumbs button{
  display:inline-flex;align-items:center;gap:4px;font-size:12px;padding:5px 10px;
  border-radius:var(--radius-xs,8px);border:1px solid var(--fluid-card-border);
  background:var(--fluid-card-item-fill);color:var(--text-primary);cursor:pointer;
}
.picker-crumbs button:disabled{opacity:0.65;cursor:default}
.picker-folder-list{
  border:1px solid var(--fluid-card-border);border-radius:var(--radius-md,16px);
  padding:8px;min-height:110px;max-height:220px;overflow:auto;background:var(--fluid-card-item-fill);
}
.picker-folder-row{
  width:100%;padding:8px 12px;display:flex;align-items:center;gap:10px;text-align:left;
  border-radius:var(--radius-sm,10px);border:0;background:transparent;color:var(--text-primary);
  cursor:pointer;font-size:13.5px;transition:background 0.15s ease;
}
.picker-folder-row:hover{background:var(--fluid-card-hover)}
.picker-folder-row span{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.picker-feedback{margin:0;padding:12px;font-size:13px;color:var(--text-secondary);display:flex;align-items:center;gap:8px}
.spin-icon{animation:spin 1s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
@media(max-width:720px){.download-form-row{grid-template-columns:1fr}}
.download-row {
  content-visibility: auto;
  contain-intrinsic-size: auto 84px;
  transition: transform var(--motion-fast) var(--motion-spring), opacity var(--motion-fast) ease;
}
.download-row:hover {
  transform: translateY(-1.5px);
}
.download-row:active {
  transform: scale(0.995);
}
details{margin-top:8px;font-size:var(--font-size-sm,13px)}
summary{cursor:pointer;padding:8px 0}
details ul{padding-inline-start:20px;margin:4px 0;line-height:1.7}
@media(max-width:600px){.account-row{align-items:stretch;flex-direction:column;gap:12px}.task-empty-actions{flex-wrap:wrap}}
@media(prefers-reduced-motion:reduce){
 .dest-quick-chip,.dest-browse-btn,.picker-folder-row,.download-row{transition:none}
 .spin-icon{animation:none}
}
</style>
