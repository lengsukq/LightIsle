<script setup lang="ts">
import { onMounted, ref } from "vue";
import { FolderSync, Plus, Copy, Trash2, KeyRound } from "lucide-vue-next";
import SmbManagement from "./SmbManagement.vue";
import { requestConfirm } from "./useConfirmDialog.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { apiRequest } from "./apiClient.ts";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";
defineProps<{ admin?: boolean }>();
type Credential = { id:number; label:string; createdAt:number; lastUsedAt:number };
const credentials=ref<Credential[]>([]);
const loading=ref(false);
const busy=ref(false);
const error=ref("");
const label=ref("");
const freshPassword=ref("");
const freshCopied=ref(false);
const davUrl=location.origin+"/dav/";
async function refresh(){
  if(loading.value)return;
  loading.value=true;error.value="";
  try{
    const value=await apiRequest<{credentials?:Credential[]}>("/api/v2/dav/credentials");
    credentials.value=value.credentials??[];
  }catch(e){error.value=describeUserFacingError(e);}
  finally{loading.value=false;}
}
async function create(){
  if(busy.value)return;
  busy.value=true;error.value="";freshPassword.value="";freshCopied.value=false;
  try{
    const value=await apiRequest<{credential?:Credential;password?:string}>("/api/v2/dav/credentials",{
      method:"POST",
      json:{label:label.value.trim()||"未命名"}
    });
    label.value="";
    if(value.password)freshPassword.value=value.password;
    await refresh();
  }catch(e){error.value=describeUserFacingError(e);}
  finally{busy.value=false;}
}
async function revoke(item:Credential){
  if(busy.value)return;
  if(!(await requestConfirm({title:"撤销 WebDAV 密码",message:`确认撤销 WebDAV 密码「${item.label}」？后续请求将无法使用该密码，已开始的传输可能继续到结束。`,confirmText:"确认撤销",variant:"danger"})))return;
  busy.value=true;error.value="";
  try{
    await apiRequest("/api/v2/dav/credentials/"+encodeURIComponent(String(item.id)),{method:"DELETE"});
    await refresh();
  }catch(e){error.value=describeUserFacingError(e);}
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
        <p>使用独立密码挂载至访达、Windows 或 Infuse，不复用网页登录态。</p>
      </div>
      <IsleButton variant="glass" size="sm" :disabled="loading||busy" @click="refresh">
        {{loading?"加载中…":"刷新"}}
      </IsleButton>
    </div>
    <p class="dav-url-row">
      <span class="dav-url">{{davUrl}}</span>
      <IsleButton variant="glass" size="sm" @click="copy(davUrl,'DAV 地址')"><template #icon><Copy :size="13"/></template>复制地址</IsleButton>
    </p>
    <div class="dav-create">
      <input v-model="label" maxlength="64" placeholder="密码标签（如：MacBook Finder）" @keyup.enter="create"/>
      <IsleButton variant="primary" size="md" :disabled="busy" @click="create"><template #icon><Plus :size="14"/></template>生成新密码</IsleButton>
    </div>
    <div v-if="freshPassword" class="dav-fresh" role="status">
      <p><KeyRound :size="14"/> 新密码（仅显示这一次，请立即保存）：</p>
      <div class="dav-fresh-row">
        <code>{{freshPassword}}</code>
        <IsleButton variant="glass" size="sm" @click="copy(freshPassword,'密码')">{{freshCopied?"已复制":"复制"}}</IsleButton>
      </div>
      <IsleButton variant="primary" size="sm" class="dav-fresh-close" @click="freshPassword=''">我已保存，关闭</IsleButton>
    </div>
    <IsleBanner v-if="error" type="error" compact :message="error" />
    <IsleEmpty
      v-if="!credentials.length && !loading"
      compact
      :icon="KeyRound"
      title="暂无 WebDAV 独立密码"
      description="生成一个后即可用「用户名 + 该密码」在访达或第三方客户端安全连接。"
    />
    <div v-for="item in credentials" :key="item.id" class="dav-item">
      <div>
        <strong>{{item.label}}</strong>
        <small>创建于 {{formatDate(item.createdAt)}} · 最近使用 {{item.lastUsedAt>0?formatDate(item.lastUsedAt):"从未"}}</small>
      </div>
      <IsleButton variant="danger" size="sm" :disabled="busy" @click="revoke(item)"><template #icon><Trash2 :size="14"/></template>撤销</IsleButton>
    </div>
    <div class="dav-guide">
      <strong>连接说明</strong>
      <span>macOS 访达按 ⌘K，或 Windows / Infuse 选择 WebDAV，输入上方地址、用户名与生成的独立密码。</span>
      <span>仅访问当前默认存储盘；已授权的 Users 私人目录支持浏览与受控读写，暂不支持跨目录 COPY。</span>
    </div>
  </section>
  <SmbManagement v-if="admin" />
</template>

<style scoped>
.dav-panel{display:grid;gap:12px}
.dav-panel .account-heading h3{display:flex;align-items:center;gap:9px;margin:0}
.dav-panel .account-heading p{margin:6px 0 0;font-size:12px;color:var(--text-secondary)}
.dav-url-row{display:flex;align-items:center;gap:10px;margin:0!important;flex-wrap:wrap}
.dav-url{font-family:ui-monospace,monospace;font-size:12px;color:var(--text-primary);background:var(--fluid-card-fill);border:1px solid var(--fluid-card-border);border-radius:9px;padding:6px 10px;overflow-wrap:anywhere}
.dav-copy,.dav-fresh-row button,.dav-fresh-close{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--fluid-card-border);border-radius:9px;padding:6px 12px;background:var(--fluid-card-fill);font-size:12px;font-weight:600;color:var(--text-primary);cursor:pointer;transition:transform var(--motion-fast) var(--motion-spring),background var(--motion-fast) ease}
.dav-copy:hover,.dav-fresh-row button:hover,.dav-fresh-close:hover{background:var(--fluid-card-hover);transform:translateY(-1px)}
.dav-copy:active,.dav-fresh-row button:active,.dav-fresh-close:active{transform:scale(0.965)}
.dav-create{display:flex;gap:8px;flex-wrap:wrap}
.dav-create input{flex:1;min-width:180px;border:1px solid var(--fluid-card-border);border-radius:11px;padding:9px 12px;background:var(--fluid-card-fill);color:var(--text-primary);font-size:13px;transition:border-color 0.2s ease,box-shadow 0.2s ease}
.dav-create input:focus{border-color:var(--accent-primary);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent-primary) 20%,transparent);outline:none}
.dav-create button{display:inline-flex;align-items:center;gap:6px;border:none;border-radius:11px;padding:9px 14px;background:var(--accent-primary);color:#fff;font-size:12px;font-weight:650;cursor:pointer;box-shadow:0 4px 12px color-mix(in srgb,var(--accent-primary) 28%,transparent);transition:transform var(--motion-fast) var(--motion-spring),box-shadow 0.2s ease}
.dav-create button:hover{transform:translateY(-1.5px);box-shadow:0 6px 16px color-mix(in srgb,var(--accent-primary) 36%,transparent)}
.dav-create button:active{transform:scale(0.965)}
.dav-create button:disabled{opacity:.55;cursor:wait}
.dav-fresh{display:grid;gap:8px;padding:12px 14px;border-radius:14px;border:1px solid color-mix(in srgb,var(--accent-primary) 35%,transparent);background:color-mix(in srgb,var(--accent-primary) 7%,transparent)}
.dav-fresh p{margin:0;font-size:12px;font-weight:650;display:flex;align-items:center;gap:7px}
.dav-fresh-row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.dav-fresh-row code{font-size:13px;letter-spacing:.4px;background:var(--fluid-card-fill);border-radius:9px;padding:7px 11px;user-select:all;overflow-wrap:anywhere}
.dav-fresh-close{align-self:flex-start}
.dav-item{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;padding:12px 14px;border-radius:14px;border:1px solid var(--fluid-card-border);background:var(--fluid-card-item-fill);box-shadow:var(--fluid-item-card-shadow);transition:transform var(--motion-fast) var(--motion-spring),box-shadow 0.2s ease,background 0.2s ease}
.dav-item:hover{transform:translateY(-1.5px);box-shadow:var(--fluid-item-hover-shadow);background:var(--fluid-card-hover)}
.dav-item strong{display:block;font-size:13px;color:var(--text-primary)}
.dav-item small{font-size:11px;color:var(--text-secondary)}
.dav-item button{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--fluid-card-border);border-radius:10px;padding:7px 11px;background:var(--fluid-card-fill);font-size:12px;font-weight:600;color:var(--text-primary);cursor:pointer;transition:transform var(--motion-fast) var(--motion-spring)}
.dav-item button:hover{background:var(--fluid-card-hover);transform:translateY(-1px)}
.dav-item button:active{transform:scale(0.965)}
.dav-item button:disabled{opacity:.5;cursor:wait}
.dav-empty{padding:18px;text-align:center;font-size:12px;color:var(--text-secondary)}
.dav-guide{display:grid;gap:5px;font-size:11px;line-height:1.7;color:var(--text-secondary)}
.dav-guide strong{font-size:12px;color:var(--text-primary)}
</style>
