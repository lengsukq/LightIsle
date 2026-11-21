<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import { ArrowDownToLine, ChevronLeft, ChevronRight, Folder, Link2, ListTodo, LoaderCircle, Pause, Play, PlusCircle, RefreshCw, RotateCcw, Trash2 } from "lucide-vue-next";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import { apiRequest } from "../../api/apiClient.ts";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleChip from "../../components/ui/IsleChip.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import {readDownloadCenter,type DownloadTask} from "./downloadCenterTransport.ts";
import {createMediaStatusPoller} from "../../api/mediaStatusPoller.ts";
import {describeRootOperationFailure} from "../../api/rootDiscovery.ts";
import {describeUserFacingError} from "../../api/userFacingError.ts";
import {formatDateTime} from "../../utils/dateTimeFormat.ts";
import {formatBinaryBytes as bytes} from "../../utils/format.ts";

type FolderItem = { name: string; path: string; type: "file" | "folder"; canWrite?: boolean };
type FolderListReply = { entries: FolderItem[]; nextCursor?: string; canWrite?: boolean };
type TaskFilter = "all" | "active" | "completed" | "issues";

const props=withDefaults(defineProps<{active?:boolean;api?:(path:string,init?:RequestInit)=>Promise<unknown>}>(),{active:true});
const requestApi=(path:string,init?:RequestInit)=>(props.api?props.api(path,init):apiRequest(path,init));
const tasks=ref<DownloadTask[]>([]);
const hasSnapshot=ref(false);
const status=ref<{available:boolean;networkAllowed?:boolean;version?:string;reason?:string}>({available:false});
const loading=ref(false),error=ref(""),busy=ref(""),newURL=ref(""),newDestination=ref("."),newMaxGB=ref("");
const creating=ref(false);
const taskFilter=ref<TaskFilter>("all");

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
const completedTasksCount=computed(()=>tasks.value.filter(t=>t.status==="completed").length);
const issueTasksCount=computed(()=>tasks.value.filter(t=>t.status==="failed"||t.status==="cancelled").length);
const filteredTasks=computed(()=>{
 if(taskFilter.value==="active")return activeTasks.value;
 if(taskFilter.value==="completed")return tasks.value.filter(t=>t.status==="completed");
 if(taskFilter.value==="issues")return tasks.value.filter(t=>t.status==="failed"||t.status==="cancelled");
 return tasks.value;
});

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
  taskFilter.value="all";
  poller.invalidate();
  await load();
 }catch(e){
  if(!disposed)error.value="创建任务失败："+describeUserFacingError(e);
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
function progress(task:DownloadTask){return task.totalBytes>0?Math.min(100,Math.round(task.completedBytes/task.totalBytes*100)):0}
const statusLabels:Record<DownloadTask["status"],string>={queued:"排队中",running:"下载中",paused:"已暂停",completed:"已完成",failed:"失败",cancelled:"已取消"};
function describeError(task:DownloadTask){return !task.error?"":describeUserFacingError(new Error(task.error))}
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
 <div class="downloads-page-wrap">
  <IslePageHeader title="下载中心" subtitle="支持 HTTP / HTTPS / FTP 与磁力离线任务，下载完成安全发布且同名文件零覆盖">
   <template #title-extra>
    <IsleHelpButton
      title="离线下载与文件保护规则"
      :items="[
        { title: '同名文件零覆盖', body: '任务下载完成后自动发布至所选共享目录；若遇到同名文件存在变动，将进入安全核对状态而绝不自动覆盖已有文件。' },
        { title: '组件依赖', body: '离线下载依赖宿主 Mac 上的 aria2 服务，可在轻屿 Mac 端「设置 → 工具 → 外部依赖」中一键检查。' },
      ]"
    />
   </template>
   <template #actions>
    <IsleBadge v-if="activeTasks.length > 0" variant="accent" size="sm" dot>{{ activeTasks.length }} 项进行中</IsleBadge>
    <IsleButton variant="glass" size="sm" :loading="loading" @click="load">
     <template #icon><RefreshCw :size="14" :class="{ 'spin-icon': loading }" /></template>
     {{loading?"加载中…":"刷新队列"}}
    </IsleButton>
   </template>
  </IslePageHeader>

  <IsleBanner v-if="hasSnapshot&&!status.available" type="warning" compact role="note" :message="'暂时无法新建下载：'+(status.reason==='aria2_not_installed'?'请先在 Mac 端「设置 → 工具 → 外部依赖」中安装下载组件':'下载服务未就绪，请稍后重试')+'。以前下载的文件不会删除。'" />
  <IsleBanner v-if="hasSnapshot&&status.networkAllowed===false" type="info" compact message="新建或继续网络下载需要管理员权限，已有任务和已下载的文件仍可管理。" />
  <IsleBanner v-if="error" type="error" compact :message="error" />

  <IsleCard v-if="status.available&&status.networkAllowed!==false" aria-label="新建离线下载" title="新建离线下载" subtitle="粘贴直链或磁力链接，选择共享目录内的保存位置后即可后台下载。">
   <template #icon><PlusCircle :size="18" aria-hidden="true"/></template>
   <form class="account-form download-form" @submit.prevent="create">
    <label class="download-url-label">下载链接
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
     <IsleButton type="submit" variant="primary" size="md" :loading="creating">{{creating?"正在创建…":"新建下载"}}</IsleButton>
    </div>
   </form>
  </IsleCard>

  <IsleCard aria-label="下载队列与历史记录" title="下载队列与历史记录" :subtitle="tasks.length ? `共 ${tasks.length} 条记录 · ${activeTasks.length} 项进行中` : '查看当前排队进度与历史已完成任务'">
   <template #icon><ListTodo :size="18" aria-hidden="true"/></template>
   <template v-if="tasks.length > 0" #actions>
    <div class="download-filter-pills" role="group" aria-label="按任务状态筛选">
     <IsleChip small :selected="taskFilter === 'all'" @select="taskFilter = 'all'">全部 ({{ tasks.length }})</IsleChip>
     <IsleChip small :selected="taskFilter === 'active'" @select="taskFilter = 'active'">进行中 ({{ activeTasks.length }})</IsleChip>
     <IsleChip small :selected="taskFilter === 'completed'" @select="taskFilter = 'completed'">已完成 ({{ completedTasksCount }})</IsleChip>
     <IsleChip v-if="issueTasksCount > 0 || taskFilter === 'issues'" small :selected="taskFilter === 'issues'" @select="taskFilter = 'issues'">异常/已取消 ({{ issueTasksCount }})</IsleChip>
    </div>
   </template>

   <p v-if="loading&&!hasSnapshot" class="footnote" role="status">正在读取下载中心…</p>
   <IsleEmpty
     v-else-if="hasSnapshot&&!tasks.length&&!loading&&!error"
     compact
     :icon="ArrowDownToLine"
     title="还没有下载任务"
     description="在上方输入链接创建离线下载任务，或在此查看历史下载记录。"
   />
   <IsleEmpty
     v-else-if="tasks.length > 0 && filteredTasks.length === 0"
     compact
     :icon="ListTodo"
     title="当前筛选下没有任务"
     description="可切换回「全部」查看其他状态的下载记录。"
   >
     <template #action>
       <IsleButton variant="tonal" size="sm" @click="taskFilter = 'all'">查看全部任务</IsleButton>
     </template>
   </IsleEmpty>

   <div v-if="filteredTasks.length" class="download-task-list">
    <div v-for="task in filteredTasks" :key="task.id" class="account-row download-row">
     <div class="download-row-main">
      <strong class="download-row-title">
        <Link2 :size="14" aria-hidden="true"/> <span>{{task.filename||task.url}}</span>
        <IsleBadge
          :variant="task.status==='completed'?'online':task.status==='failed'?'danger':task.status==='running'?'accent':'neutral'"
          size="sm"
        >
          {{task.phase==='publishing'&&task.status==='running'?'正在保存':statusLabels[task.status]}}
        </IsleBadge>
      </strong>
      <small class="download-row-meta">目标：{{task.destination==="."?"共享根目录":task.destination}}
       <template v-if="task.totalBytes>0"> · <span class="download-tabular">{{bytes(task.completedBytes)}} / {{bytes(task.totalBytes)}}（{{progress(task)}}%）</span></template>
       <template v-else-if="task.completedBytes>0"> · <span class="download-tabular">{{bytes(task.completedBytes)}}</span></template>
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
      <IsleButton v-if="task.phase!=='publishing'&&(task.status==='running'||task.status==='queued')" variant="glass" size="sm" :disabled="busy!==''||!status.available" @click="action(task,'pause')"><template #icon><Pause :size="13" aria-hidden="true"/></template>暂停</IsleButton>
      <IsleButton v-if="task.status==='paused'" variant="tonal" size="sm" :disabled="busy!==''||!status.available||status.networkAllowed===false" @click="action(task,'resume')"><template #icon><Play :size="13" aria-hidden="true"/></template>继续</IsleButton>
      <IsleButton v-if="task.status==='failed'||task.status==='cancelled'" variant="tonal" size="sm" :disabled="busy!==''||((!status.available||status.networkAllowed===false)&&task.phase!=='publishing')" @click="action(task,'retry')"><template #icon><RotateCcw :size="13" aria-hidden="true"/></template>重试</IsleButton>
      <IsleButton v-if="task.status!=='completed'&&task.status!=='cancelled'&&task.status!=='failed'" variant="glass" size="sm" :disabled="busy!==''" @click="action(task,'cancel')"><template #icon><RefreshCw :size="13" aria-hidden="true"/></template>取消</IsleButton>
      <IsleButton variant="danger" size="sm" :disabled="busy!==''" @click="remove(task)"><template #icon><Trash2 :size="13" aria-hidden="true"/></template>删除记录</IsleButton>
     </div>
    </div>
   </div>
  </IsleCard>

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
     {{ crumb.label }} <ChevronRight :size="12" />
    </button>
   </div>
   <div class="picker-folder-list">
    <p v-if="pickerLoading && !pickerFolders.length" class="picker-feedback"><LoaderCircle :size="15" class="spin-icon" /> 正在读取文件夹…</p>
    <template v-else>
     <button v-if="pickerDir !== '.'" type="button" class="picker-folder-row" :disabled="pickerLoading" @click="navigatePicker(pickerDir.split('/').slice(0, -1).join('/') || '.')">
      <ChevronLeft :size="15" /> <span>返回上一级</span>
     </button>
     <button v-for="folder in pickerFolders" :key="folder.path" type="button" class="picker-folder-row" :disabled="pickerLoading" @click="navigatePicker(folder.path)">
      <Folder :size="16" /> <span>{{ folder.name }}</span> <ChevronRight :size="14" />
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
 </div>
</template>

<style scoped>
.downloads-page-wrap{max-width:1120px;margin:0 auto;width:100%;display:grid;gap:14px}
.download-form{padding:2px 0 0;gap:12px;background:transparent;border:0;box-shadow:none}
.download-form input{height:36px;padding:0 12px;border-radius:10px;font-size:13px}
.download-url-label{display:grid;gap:6px;font-size:12.5px;font-weight:600;color:var(--text-secondary)}
.download-form-row{display:grid;grid-template-columns:minmax(220px,1.7fr) minmax(144px,1fr) auto;gap:12px;align-items:end}
.download-dest-field{display:grid;gap:6px;min-width:0}
.download-dest-head{display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;font-size:12.5px;font-weight:600;color:var(--text-secondary)}
.download-dest-chips{display:inline-flex;align-items:center;gap:5px;flex-wrap:wrap}
.dest-quick-chip,.dest-browse-btn{
  display:inline-flex;align-items:center;gap:4px;padding:3px 9px;border-radius:999px;
  font-size:11.5px;font-weight:600;cursor:pointer;
  border:1px solid var(--fluid-card-border);background:var(--fluid-card-item-fill);color:var(--text-secondary);
  transition:background 0.15s ease,color 0.15s ease,border-color 0.15s ease;
}
.dest-quick-chip:hover,.dest-browse-btn:hover{color:var(--text-primary);background:var(--fluid-card-hover)}
.dest-quick-chip.active{
  color:var(--accent-primary);
  border-color:color-mix(in srgb,var(--accent-primary) 42%,var(--fluid-card-border));
  background:color-mix(in srgb,var(--accent-primary) 12%,transparent);
}
.dest-browse-btn{color:var(--accent-primary)}
.download-filter-pills{display:inline-flex;align-items:center;gap:4px;flex-wrap:wrap}
.picker-crumbs{display:flex;flex-wrap:wrap;gap:5px}
.picker-crumbs button{
  display:inline-flex;align-items:center;gap:4px;font-size:12px;padding:4px 9px;
  border-radius:7px;border:1px solid var(--fluid-card-border);
  background:var(--fluid-card-item-fill);color:var(--text-primary);cursor:pointer;
}
.picker-crumbs button:disabled{opacity:0.65;cursor:default}
.picker-folder-list{
  border:1px solid var(--fluid-card-border);border-radius:12px;
  padding:4px;min-height:96px;max-height:210px;overflow:auto;background:var(--fluid-card-item-fill);
}
.picker-folder-row{
  width:100%;min-height:36px;padding:6px 10px;display:flex;align-items:center;gap:8px;text-align:left;
  border-radius:8px;border:0;background:transparent;color:var(--text-primary);
  cursor:pointer;font-size:13px;transition:background 0.15s ease;
}
.picker-folder-row:hover{background:var(--fluid-card-hover)}
.picker-folder-row span{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.picker-feedback{margin:0;padding:10px;font-size:12.5px;color:var(--text-secondary);display:flex;align-items:center;gap:8px}
.spin-icon{animation:spin 1s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.download-task-list{
  margin-top:4px;
  border:1px solid var(--fluid-card-border);
  border-radius:12px;
  background:var(--fluid-card-item-fill);
  overflow:hidden;
}
.download-row{
  margin:0;
  border:0;
  border-bottom:1px solid var(--fluid-divider,var(--fluid-card-border));
  border-radius:0;
  background:transparent;
  box-shadow:none;
  padding:12px 15px;
  content-visibility:auto;
  contain-intrinsic-size:auto 72px;
  transition:background-color 0.15s ease;
}
.download-row:last-child{border-bottom:0}
.download-row:hover{background:var(--fluid-card-hover)}
.download-row>div{min-width:0}
.download-row-main{display:grid;gap:3px;flex:1;min-width:0}
.download-row-title{display:inline-flex;align-items:center;gap:7px;flex-wrap:wrap;font-size:13.5px;font-weight:650}
.download-row-meta{color:var(--text-secondary);font-size:12px;line-height:1.45}
.download-tabular{font-variant-numeric:tabular-nums}
.account-row strong,.account-row small,details li{overflow-wrap:anywhere}
details{margin-top:6px;font-size:12.5px}
summary{cursor:pointer;padding:6px 0}
details ul{padding-inline-start:18px;margin:4px 0;line-height:1.6}
@media(max-width:720px){.download-form-row{grid-template-columns:1fr}}
@media(max-width:600px){.account-row{align-items:stretch;flex-direction:column;gap:10px}.task-empty-actions{flex-wrap:wrap}}
@media(prefers-reduced-motion:reduce){
 .dest-quick-chip,.dest-browse-btn,.picker-folder-row,.download-row{transition:none}
 .spin-icon{animation:none}
}
</style>
