<script setup lang="ts">
import { onMounted, ref } from "vue";
import { FolderSync, Plus, Copy, Trash2, KeyRound } from "lucide-vue-next";
import {describeUserFacingError} from "./userFacingError.js";
type Credential = { id:number; label:string; createdAt:number; lastUsedAt:number };
const credentials=ref<Credential[]>([]);
const loading=ref(false);
const busy=ref(false);
const error=ref("");
const label=ref("");
const freshPassword=ref("");
const freshCopied=ref(false);
const davUrl=location.origin+"/dav/";
const errors:Record<string,string>={
  invalid_dav_request:"请求无效，请检查标签长度（64 字符以内）。",
  dav_credential_limit_reached:"最多创建 8 个 WebDAV 密码，请先撤销不再使用的密码。",
  login_required:"请先登录。",
  dav_credential_failed:"操作未完成，请重试。",
  dav_credential_not_found:"该密码已被撤销或不存在，请刷新列表。",
};
function codeMessage(e:unknown):string{
  if(e instanceof Error)try{
    const parsed=JSON.parse(e.message) as {error?:string};
    if(parsed.error&&errors[parsed.error])return errors[parsed.error];
  }catch{/* plain message */}
  return describeUserFacingError(e);
}
async function refresh(){
  if(loading.value)return;
  loading.value=true;error.value="";
  try{
    const response=await fetch("/api/v2/dav/credentials",{credentials:"same-origin",cache:"no-store"});
    const value=await response.json().catch(()=>({})) as {credentials?:Credential[];error?:string};
    if(!response.ok)throw new Error(JSON.stringify(value));
    credentials.value=value.credentials??[];
  }catch(e){error.value=codeMessage(e);}
  finally{loading.value=false;}
}
async function create(){
  if(busy.value)return;
  busy.value=true;error.value="";freshPassword.value="";freshCopied.value=false;
  try{
    const response=await fetch("/api/v2/dav/credentials",{
      method:"POST",credentials:"same-origin",
      headers:{"Content-Type":"application/json","X-LightIsle-Request":"1"},
      body:JSON.stringify({label:label.value.trim()||"未命名"})
    });
    const value=await response.json().catch(()=>({})) as {credential?:Credential;password?:string;error?:string};
    if(!response.ok)throw new Error(JSON.stringify(value));
    label.value="";
    if(value.password)freshPassword.value=value.password;
    await refresh();
  }catch(e){error.value=codeMessage(e);}
  finally{busy.value=false;}
}
async function revoke(item:Credential){
  if(busy.value)return;
  if(!window.confirm(`确认撤销 WebDAV 密码「${item.label}」？正在使用该密码的客户端会立即失去连接。`))return;
  busy.value=true;error.value="";
  try{
    const response=await fetch("/api/v2/dav/credentials/"+item.id,{method:"DELETE",credentials:"same-origin"});
    const value=await response.json().catch(()=>({})) as {error?:string};
    if(!response.ok)throw new Error(JSON.stringify(value));
    await refresh();
  }catch(e){error.value=codeMessage(e);}
  finally{busy.value=false;}
}
function copy(text:string,what:string){
  navigator.clipboard?.writeText(text).then(()=>{freshCopied.value=true;}).catch(()=>{window.prompt("复制以下"+what+"：",text);});
}
const formatDate=(unix:number)=>unix>0?new Date(unix*1000).toLocaleDateString():"—";
onMounted(()=>{void refresh();});
</script>

<template>
  <section class="account-panel dav-panel">
    <div class="account-heading">
      <div>
        <h3><FolderSync :size="18"/> WebDAV 访问</h3>
        <p>用独立密码挂载到 Finder、Windows 或 Infuse 等客户端 · 不复用网页登录态</p>
      </div>
      <button type="button" class="refresh" :disabled="loading||busy" @click="refresh">
        {{loading?"加载中…":"刷新"}}
      </button>
    </div>
    <p class="dav-url-row">
      <span class="dav-url">{{davUrl}}</span>
      <button type="button" class="dav-copy" @click="copy(davUrl,'DAV 地址')"><Copy :size="13"/> 复制地址</button>
    </p>
    <div class="dav-create">
      <input v-model="label" maxlength="64" placeholder="密码标签（如：MacBook Finder）" @keyup.enter="create"/>
      <button type="button" :disabled="busy" @click="create"><Plus :size="14"/> 生成新密码</button>
    </div>
    <div v-if="freshPassword" class="dav-fresh" role="status">
      <p><KeyRound :size="14"/> 新密码（仅显示这一次，请立即保存）：</p>
      <div class="dav-fresh-row">
        <code>{{freshPassword}}</code>
        <button type="button" @click="copy(freshPassword,'密码')">{{freshCopied?"已复制":"复制"}}</button>
      </div>
      <button type="button" class="dav-fresh-close" @click="freshPassword=''">我已保存，关闭</button>
    </div>
    <p v-if="error" role="alert" class="form-error">{{error}}</p>
    <div v-if="!credentials.length&&!loading" class="dav-empty">还没有 WebDAV 密码。生成一个后即可用「用户名 + 该密码」连接。</div>
    <div v-for="item in credentials" :key="item.id" class="dav-item">
      <div>
        <strong>{{item.label}}</strong>
        <small>创建于 {{formatDate(item.createdAt)}} · 最近使用 {{item.lastUsedAt>0?formatDate(item.lastUsedAt):"从未"}}</small>
      </div>
      <button type="button" :disabled="busy" @click="revoke(item)"><Trash2 :size="14"/> 撤销</button>
    </div>
    <div class="dav-guide">
      <strong>连接方法</strong>
      <span>macOS：访达 ⌘K → 输入上方地址 → 用户名 + 生成的 WebDAV 密码。</span>
      <span>Windows：文件资源管理器 → 映射网络驱动器 → 同一地址。</span>
      <span>Infuse / rclone 等：WebDAV 类型，地址、账号与密码同上；目录权限与管理端一致。</span>
    </div>
  </section>
</template>

<style scoped>
.dav-panel{display:grid;gap:12px}
.dav-panel .account-heading h3{display:flex;align-items:center;gap:9px;margin:0}
.dav-panel .account-heading p{margin:6px 0 0;font-size:12px;color:var(--text-secondary)}
.dav-url-row{display:flex;align-items:center;gap:10px;margin:0!important;flex-wrap:wrap}
.dav-url{font-family:ui-monospace,monospace;font-size:12px;color:var(--text-primary);background:var(--fluid-card-fill);border:1px solid var(--fluid-card-border);border-radius:9px;padding:6px 10px}
.dav-copy,.dav-fresh-row button,.dav-fresh-close{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--fluid-card-border);border-radius:9px;padding:6px 10px;background:var(--fluid-card-fill);font-size:12px;font-weight:600;color:var(--text-primary);cursor:pointer}
.dav-copy:hover,.dav-fresh-row button:hover,.dav-fresh-close:hover{background:var(--fluid-card-hover)}
.dav-create{display:flex;gap:8px;flex-wrap:wrap}
.dav-create input{flex:1;min-width:200px;border:1px solid var(--fluid-card-border);border-radius:11px;padding:9px 12px;background:var(--fluid-card-fill);color:var(--text-primary);font-size:13px}
.dav-create button{display:inline-flex;align-items:center;gap:6px;border:none;border-radius:11px;padding:9px 14px;background:var(--accent-primary);color:#fff;font-size:12px;font-weight:650;cursor:pointer}
.dav-create button:disabled{opacity:.55;cursor:wait}
.dav-fresh{display:grid;gap:8px;padding:12px 14px;border-radius:14px;border:1px solid color-mix(in srgb,var(--accent-primary) 35%,transparent);background:color-mix(in srgb,var(--accent-primary) 7%,transparent)}
.dav-fresh p{margin:0;font-size:12px;font-weight:650;display:flex;align-items:center;gap:7px}
.dav-fresh-row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.dav-fresh-row code{font-size:13px;letter-spacing:.4px;background:var(--fluid-card-fill);border-radius:9px;padding:7px 11px;user-select:all;overflow-wrap:anywhere}
.dav-fresh-close{align-self:flex-start}
.dav-item{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:12px 14px;border-radius:14px;border:1px solid var(--fluid-card-border);background:var(--fluid-card-item-fill)}
.dav-item strong{display:block;font-size:13px;color:var(--text-primary)}
.dav-item small{font-size:11px;color:var(--text-secondary)}
.dav-item button{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--fluid-card-border);border-radius:10px;padding:7px 11px;background:var(--fluid-card-fill);font-size:12px;font-weight:600;color:var(--text-primary);cursor:pointer}
.dav-item button:hover{background:var(--fluid-card-hover)}
.dav-item button:disabled{opacity:.5;cursor:wait}
.dav-empty{padding:18px;text-align:center;font-size:12px;color:var(--text-secondary)}
.dav-guide{display:grid;gap:5px;font-size:11px;line-height:1.7;color:var(--text-secondary)}
.dav-guide strong{font-size:12px;color:var(--text-primary)}
</style>
