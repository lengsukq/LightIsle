<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { ChevronLeft, ChevronRight, Folder, LoaderCircle } from "lucide-vue-next";

type FolderEntry = { name:string; path:string; type:"file"|"folder"; canWrite?:boolean };
type FolderPage = { entries:FolderEntry[]; nextCursor:string; canWrite:boolean };
type Conflict = ""|"skip"|"rename";
const props=defineProps<{
  item:{name:string;path:string;type:"file"|"folder"};
  action:"copy"|"move";
  listFolders:(path:string,cursor:string)=>Promise<FolderPage>;
  perform:(path:string,conflict:Conflict)=>Promise<{finalTo?:string;skipped?:boolean}>;
}>();
const emit=defineEmits<{
  (event:"close"):void;
  (event:"complete",message:string):void;
}>();
const dir=ref(".");
const name=ref(props.item.name);
const folders=ref<FolderEntry[]>([]);
const nextCursor=ref("");
const canWrite=ref(false);
const loading=ref(false);
const busy=ref(false);
const error=ref("");
const conflict=ref<Conflict>("rename");
let generation=0;
const breadcrumbs=computed(()=>{
  if(dir.value===".")return [{label:"共享根目录",path:"."}];
  const parts=dir.value.split("/");
  return [{label:"共享根目录",path:"."},...parts.map((part,i)=>({label:part,path:parts.slice(0,i+1).join("/")}))];
});
const destination=computed(()=>dir.value==="."?name.value:dir.value+"/"+name.value);
const validName=computed(()=>{
  const value=name.value.trim();
  return value.length>0&&value!== "."&&value!==".."&&
    !value.startsWith(".lightisle-")&&!value.includes("/")&&!value.includes("\\")&&
    !/[\u0000-\u001f]/.test(value);
});
const invalidDescendant=computed(()=>props.item.type==="folder" &&
  destination.value.startsWith(props.item.path+"/"));
const canSubmit=computed(()=>!busy.value&&!loading.value&&canWrite.value&&validName.value&&
  !invalidDescendant.value&&(props.action==="copy"||destination.value!==props.item.path));

async function loadFolders(more=false){
  const request=++generation;
  const path=dir.value;
  loading.value=true;
  error.value="";
  try{
    const data=await props.listFolders(path,more?nextCursor.value:"");
    if(request!==generation||path!==dir.value)return;
    const entries=data.entries.filter(item=>item.type==="folder");
    folders.value=more?[...folders.value,...entries]:entries;
    nextCursor.value=data.nextCursor;
    canWrite.value=data.canWrite===true;
  }catch(e){
    if(request===generation)error.value="读取目标文件夹失败："+(e instanceof Error?e.message:String(e));
  }finally{
    if(request===generation)loading.value=false;
  }
}
watch(dir,()=>{folders.value=[];nextCursor.value="";canWrite.value=false;void loadFolders();},{immediate:true});

async function submit(){
  if(!canSubmit.value)return;
  busy.value=true;
  error.value="";
  try{
    const result=await props.perform(destination.value,conflict.value);
    const outcome=result.skipped?"目标已存在，已跳过":props.action==="copy"?"复制完成":"移动完成";
    emit("complete",outcome+"："+(result.finalTo||destination.value));
  }catch(e){
    error.value="操作失败："+(e instanceof Error?e.message:String(e));
  }finally{
    busy.value=false;
  }
}
</script>

<template>
  <div class="dialog-backdrop" @click.self="!busy&&emit('close')">
    <section class="file-operation-dialog" role="dialog" aria-modal="true" :aria-label="action==='copy'?'复制到文件夹':'移动到文件夹'">
      <div class="file-operation-top">
        <div><h3>{{action==="copy"?"复制文件":"移动或重命名"}}</h3><p>来源：{{item.path}}</p></div>
        <button type="button" :disabled="busy" @click="emit('close')">关闭</button>
      </div>
      <div class="file-operation-crumbs" aria-label="目标位置">
        <button v-for="crumb in breadcrumbs" :key="crumb.path" type="button" :disabled="loading||busy||crumb.path===dir" @click="dir=crumb.path">{{crumb.label}} <ChevronRight :size="13"/></button>
      </div>
      <div class="file-operation-folder-list">
        <p v-if="loading" class="file-operation-feedback"><LoaderCircle :size="15"/> 正在读取目录…</p>
        <template v-else>
          <button v-if="dir!=='.'" type="button" class="file-operation-folder" @click="dir=dir.split('/').slice(0,-1).join('/')||'.'"><ChevronLeft :size="17"/> 上一级</button>
          <button v-for="folder in folders" :key="folder.path" type="button" class="file-operation-folder" @click="dir=folder.path">
            <Folder :size="18"/> <span>{{folder.name}}</span> <ChevronRight :size="15"/>
          </button>
          <p v-if="!folders.length" class="file-operation-feedback">当前没有可浏览的子文件夹。</p>
          <button v-if="nextCursor" type="button" class="file-operation-more" @click="loadFolders(true)">加载更多文件夹</button>
        </template>
      </div>
      <label class="file-operation-label">目标文件名
        <input v-model="name" maxlength="240" type="text" autocomplete="off" :disabled="busy" />
      </label>
      <label class="file-operation-label">已有同名文件时
        <select v-model="conflict" :disabled="busy">
          <option value="rename">自动改名，保留原有文件</option>
          <option value="skip">跳过，不修改任何文件</option>
          <option value="">拒绝操作并提示冲突</option>
        </select>
      </label>
      <p class="file-operation-destination">目标：{{destination}}</p>
      <p v-if="!canWrite&&!loading" class="file-operation-warning">你没有当前文件夹的写入权限，可浏览其他授权文件夹。</p>
      <p v-if="!validName" class="file-operation-warning">请输入合法文件名，不能含路径分隔符或内部保留名称。</p>
      <p v-if="invalidDescendant" class="file-operation-warning">不能将文件夹复制或移动到它自己的子目录。</p>
      <p v-if="error" class="form-error" role="alert">{{error}}</p>
      <div class="file-operation-actions">
        <button type="button" :disabled="busy" @click="emit('close')">取消</button>
        <button type="button" class="upload-primary-action" :disabled="!canSubmit" @click="submit">{{busy?"正在处理…":action==="copy"?"确认复制":"确认移动"}}</button>
      </div>
    </section>
  </div>
</template>

<style scoped>
.file-operation-dialog{width:min(560px,calc(100vw - 24px));max-height:min(90vh,760px);overflow:auto;border-radius:24px;padding:24px;background:var(--surface-elevated,#fff);color:var(--text-primary,inherit);box-shadow:0 28px 80px #101d3840;display:flex;flex-direction:column;gap:14px}
.file-operation-top,.file-operation-actions{display:flex;justify-content:space-between;align-items:center;gap:12px}
.file-operation-top h3{margin:0 0 5px;font-size:20px}.file-operation-top p{margin:0;font-size:12px;overflow-wrap:anywhere;opacity:.68}
.file-operation-crumbs{display:flex;flex-wrap:wrap;gap:5px}.file-operation-crumbs button{display:flex;align-items:center;gap:3px;font-size:12px;padding:5px 8px}
.file-operation-folder-list{border:1px solid var(--stroke-subtle,#b9c2d063);border-radius:15px;padding:7px;min-height:95px;max-height:195px;overflow:auto}
.file-operation-folder{width:100%;padding:9px;display:flex;align-items:center;gap:9px;text-align:left;border-radius:10px}.file-operation-folder:hover{background:var(--accent-muted,#a9bad021)}.file-operation-folder span{flex:1;overflow:hidden;text-overflow:ellipsis}
.file-operation-feedback{padding:8px 12px;opacity:.65;font-size:13px}.file-operation-more{margin:6px auto;display:block}
.file-operation-label{font-size:13px;font-weight:600;display:grid;gap:6px}.file-operation-label input,.file-operation-label select{width:100%;min-width:0;padding:10px 12px;border-radius:11px;border:1px solid var(--stroke-subtle,#b9c2d090);background:var(--surface-base,#f5f7fa);color:inherit}
.file-operation-destination{font-size:12px;overflow-wrap:anywhere;opacity:.7;margin:0}.file-operation-warning{font-size:12px;color:var(--error,#bf4f49);margin:0}
.file-operation-actions{justify-content:flex-end}.file-operation-actions button{min-height:38px;padding:8px 15px}
</style>
