<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { apiFetch } from "./apiClient.ts";
import { readApiFailure } from "./apiFailure.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { requestConfirm } from "./useConfirmDialog.ts";
import AppleSelect from "./AppleSelect.vue";

const props = defineProps<{admin:boolean}>();
type Entry = {name:string; path:string; type:"file"|"folder"; size:number};
type Member = {id:number; username:string; role:string};
type Grant = {mode:string; folders:{path:string}[]};
const enabled=ref(false), mode=ref("none"), path=ref(""), entries=ref<Entry[]>([]);
const busy=ref(false), error=ref(""), preview=ref<Entry|null>(null);
const nextCursor=ref("");
const history=ref<string[]>([]);
let browseGeneration=0;
const members=ref<Member[]>([]), selected=ref(""), grantMode=ref("none"), folders=ref<string[]>([]), saving=ref(false), grantLoading=ref(false), grantReady=ref(false);
const memberOptions=computed(()=>members.value.map(u=>({value:String(u.id),label:u.username})));
const modes=[{value:"none",label:"无权限"},{value:"folders",label:"指定文件夹"},{value:"all",label:"整台电脑"}];
const canOpen=computed(()=>enabled.value && mode.value!=="none");
const fileUrl=(action:string,p:string)=>`/api/v2/computer-files/${action}?path=${encodeURIComponent(p)}`;
async function request<T>(url:string, method="GET", json?:unknown):Promise<T> {
  const response=await apiFetch(url,{method,...(json===undefined?{}:{json})});
  if(!response.ok) throw await readApiFailure(response);
  return await response.json() as T;
}
async function loadStatus(){
  busy.value=true; error.value="";
  try {
    const result=await request<{enabled:boolean;mode:string}>("/api/v2/computer-files/status");
    enabled.value=result.enabled; mode.value=result.mode;
    if(canOpen.value) { history.value=[]; await browse(""); }
    if(props.admin && enabled.value) {
      const data=await request<{users:Member[]}>("/api/v2/users");
      members.value=data.users.filter(u=>u.role==="member");
    }
  } catch(e){error.value=describeUserFacingError(e);} finally {busy.value=false;}
}
async function browse(next:string, cursor="", push=false){
  const generation=++browseGeneration;
  error.value=""; preview.value=null;
  try {
    const result=await request<{path:string;entries:Entry[];nextCursor?:string}>(`/api/v2/computer-files?path=${encodeURIComponent(next)}&cursor=${encodeURIComponent(cursor)}`);
    if(generation!==browseGeneration)return;
    if(push) history.value.push(path.value);
    path.value=result.path; entries.value=cursor?[...entries.value,...result.entries]:result.entries; nextCursor.value=result.nextCursor??"";
  } catch(e){if(generation===browseGeneration)error.value=`无法读取此目录：${describeUserFacingError(e)}。请检查磁盘连接及 Mac 的文件和隐私权限。`;}
}
function goUp(){
  if(!history.value.length) return;
  void browse(history.value.pop() ?? "");
}
function canPreview(name:string){return /\.(jpe?g|png|gif|webp|txt|md|json|log|mp4|webm|m4v|pdf)$/i.test(name);}
async function downloadFolder(entry:Entry){
  error.value="";
  try {
    const target=fileUrl("archive",entry.path);
    const response=await apiFetch(target,{method:"HEAD"});
    if(!response.ok) throw await readApiFailure(response);
    const link=document.createElement("a"); link.href=target; link.download=`${entry.name}.zip`; link.click();
  } catch(e){error.value=`无法打包文件夹：${describeUserFacingError(e)}。超过 2 GiB、2,000 项或 16 层时请分批下载；含符号链接或特殊文件时请单独下载普通文件。`;}
}
async function loadGrant(){
  if(!selected.value)return;
  const member=selected.value; grantMode.value="none"; folders.value=[]; grantLoading.value=true; grantReady.value=false;
  try { const grant=await request<Grant>(`/api/v2/computer-files/grants/${member}`); if(selected.value!==member)return; grantMode.value=grant.mode; folders.value=grant.folders.map(f=>f.path); grantReady.value=true; }
  catch(e){error.value=describeUserFacingError(e);} finally {if(selected.value===member)grantLoading.value=false;}
}
async function saveGrant(){
  if(!selected.value || saving.value || grantLoading.value || !grantReady.value)return;
  if(grantMode.value==="folders" && folders.value.length===0){error.value="请先浏览并添加至少一个文件夹。";return;}
  if(grantMode.value==="all" && !await requestConfirm({title:"授权整台电脑", message:"该成员可以查看和下载 Mac 允许轻屿读取的所有文件，包括其他成员的私人文件。确认授权？"})) return;
  saving.value=true; error.value="";
  try { await request(`/api/v2/computer-files/grants/${selected.value}`,"PUT",{mode:grantMode.value,paths:folders.value}); }
  catch(e){error.value=`授权未保存：${describeUserFacingError(e)}`;} finally {saving.value=false;}
}
onMounted(loadStatus);
</script>

<template>
  <div class="content computer-files">
    <div class="section-heading"><div><h2>电脑文件</h2><p>浏览、查看和下载 Mac 上的文件；此处只读。</p></div><button class="refresh" type="button" :disabled="busy" @click="loadStatus">刷新</button></div>
    <p v-if="error" class="form-error" role="alert">{{ error }}</p>
    <section v-if="!enabled && !busy" class="content-empty"><h2>电脑文件访问未开启</h2><p>请在 Mac 的轻屿设置 → 安全中开启。</p></section>
    <section v-else-if="enabled && !canOpen" class="content-empty"><h2>暂无访问权限</h2><p>请联系管理员授权电脑文件或指定文件夹。</p></section>
    <template v-if="canOpen">
      <section class="files-panel computer-browser">
        <div class="computer-toolbar"><button type="button" :disabled="!history.length" @click="goUp">返回上级</button><code>{{path || '已授权的文件夹'}}</code><button type="button" @click="browse(path)">刷新目录</button></div>
        <p v-if="entries.length===0">此文件夹为空，或没有可显示的普通文件。</p>
        <ul class="computer-list">
          <li v-for="entry in entries" :key="entry.path">
            <button class="computer-name" type="button" @click="entry.type==='folder'?browse(entry.path,'',true):canPreview(entry.name)?preview=entry:null">{{entry.type==='folder'?'📁':'📄'}} {{entry.name}}</button>
            <template v-if="entry.type==='file'"><button v-if="canPreview(entry.name)" type="button" @click="preview=entry">查看</button><a :href="fileUrl('content',entry.path)" download>下载</a></template>
            <button v-else type="button" @click="downloadFolder(entry)">下载文件夹</button>
          </li>
        </ul>
        <button v-if="nextCursor" type="button" @click="browse(path,nextCursor)">加载更多</button>
      </section>
      <section v-if="admin" class="files-panel computer-grants">
        <h3>成员访问权限</h3><p>整机权限可能包含其他成员的私人文件及敏感资料。</p>
        <div class="computer-toolbar"><AppleSelect v-model="selected" :options="memberOptions" placeholder="选择成员" :disabled="saving" @change="loadGrant" /><AppleSelect v-model="grantMode" :options="modes" :disabled="!selected || !grantReady || grantLoading || saving" /><button v-if="selected && !grantReady && !grantLoading" type="button" @click="loadGrant">重新读取权限</button></div>
        <div v-if="grantMode==='folders' && selected"><p>在上方打开文件夹后，将当前文件夹加入授权。</p><button type="button" :disabled="!path || folders.includes(path)" @click="folders.push(path)">添加当前文件夹</button><ul><li v-for="folder in folders" :key="folder"><code>{{folder}}</code> <button type="button" @click="folders=folders.filter(p=>p!==folder)">移除</button></li></ul></div>
        <button type="button" :disabled="!selected || !grantReady || saving || grantLoading" @click="saveGrant">{{saving?'正在保存…':grantLoading?'正在读取权限…':'保存权限'}}</button>
      </section>
    </template>
    <div v-if="preview" class="computer-preview" role="dialog" aria-modal="true" aria-label="文件预览"><div class="computer-preview-inner"><div class="computer-toolbar"><strong>{{preview.name}}</strong><a :href="fileUrl('content',preview.path)" download>下载</a><button type="button" @click="preview=null">关闭</button></div><iframe :src="fileUrl('preview',preview.path)" title="文件只读预览" sandbox="allow-same-origin" /></div></div>
  </div>
</template>

<style scoped>
.computer-files{padding:24px}.computer-browser,.computer-grants{padding:18px;margin-top:16px}.computer-toolbar{display:flex;align-items:center;gap:12px;flex-wrap:wrap}.computer-toolbar code{flex:1;overflow-wrap:anywhere}.computer-list{list-style:none;padding:0}.computer-list li{display:flex;align-items:center;gap:14px;padding:10px 0;border-bottom:1px solid var(--border, #8883)}.computer-name{flex:1;text-align:left;overflow-wrap:anywhere}.computer-preview{position:fixed;inset:0;background:#0009;z-index:1000;display:grid;place-items:center;padding:20px}.computer-preview-inner{background:var(--surface,white);width:min(100%,1000px);height:min(90vh,850px);padding:16px;border-radius:18px;display:flex;flex-direction:column;gap:12px}.computer-preview iframe{width:100%;flex:1;border:0;background:white}
</style>
