<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import AppleSelect from "./AppleSelect.vue";

type StorageLocation = { category:string; rootID:string; rootGeneration:number; relativePath:string };
type RootQuota = {rootID:string;rootGeneration:number;quotaBytes:number|null;accountedBytes:number;reservedBytes:number};
type StoragePolicy = {
  userId:number; quotaBytes:number|null; rootQuotas:RootQuota[]; locations:StorageLocation[]; enforcement:string;
  accountedBytes?:number; reservedBytes?:number; usageComplete?:boolean;
};
type User = {id:number;username:string;role:"admin"|"member";enabled:boolean};
type Root = {rootID:string;generation:number;name:string;online:boolean};
const props = defineProps<{ admin:boolean }>();
const users = ref<User[]>([]);
const roots = ref<Root[]>([]);
const registeredRoots = ref<Root[]>([]);
const rootsKnown = ref(false);
const policies = ref<Record<number,StoragePolicy>>({});
const pending = ref(false);
const error = ref("");
const message = ref("");
const quotas = ref<Record<string,string>>({});
const selection = ref<Record<string,string>>({});
const usageChecks=ref<Record<number,string>>({});
const categories = [
  {id:"files",label:"普通文件与下载"},
  {id:"photos",label:"照片"},
  {id:"videos",label:"视频"},
];
const rootOptions = computed(() => [
  { value: "", label: "选择存储硬盘" },
  ...roots.value.map(root => ({
    value: root.rootID,
    label: root.name,
    hint: root.online ? undefined : "离线",
  })),
]);
function prettyBytes(bytes:number|null):string {
  if(bytes===null)return "不设应用配额";
  return (bytes / (1024 ** 3)).toLocaleString("zh-CN",{maximumFractionDigits:2}) + " GiB";
}
function quotaKey(userId:number, q:RootQuota){return `${userId}:${q.rootID}:${q.rootGeneration}`;}
function syncQuotaInputs(p:StoragePolicy){
  for(const q of p.rootQuotas??[])
    quotas.value[quotaKey(p.userId,q)]=q.quotaBytes===null?"":String(q.quotaBytes/(1024**3));
}
function rootName(q:RootQuota){return registeredRoots.value.find(r=>r.rootID===q.rootID)?.name??'原绑定硬盘';}
function isActiveRoot(policy:StoragePolicy,q:RootQuota){
  return policy.locations.some(l=>l.rootID===q.rootID&&l.rootGeneration===q.rootGeneration);
}
function rootAvailable(q:RootQuota){
  return q.quotaBytes===null?'无限制':prettyBytes(Math.max(0,q.quotaBytes-q.accountedBytes-q.reservedBytes));
}
async function checkOnlineUsage(policy:StoragePolicy){
  const assigned=[...new Set(policy.locations.map(l=>l.rootID))];
  if(!assigned.length){usageChecks.value[policy.userId]="尚未分配个人目录，暂无可检查的在线硬盘。";return;}
  pending.value=true;error.value="";
  try{
    let liveBytes=0,checked=0;
    const unavailable:string[]=[];
    for(const rootID of assigned){
      const root=registeredRoots.value.find(r=>r.rootID===rootID);
      if(!root||!root.online||policy.locations.some(l=>l.rootID===rootID&&l.rootGeneration!==root.generation)){
        unavailable.push(root?.name??rootID);continue;
      }
      const query=new URLSearchParams({rootGeneration:String(root.generation)});
      try{
        const result=await api<{liveBytes:number;entriesChecked:number}>(`/api/v2/roots/${encodeURIComponent(rootID)}/storage/users/${policy.userId}/usage-check?${query}`);
        liveBytes+=result.liveBytes;checked+=result.entriesChecked;
      }catch(e){unavailable.push(`${root.name}（${String(e)}）`)}
    }
    usageChecks.value[policy.userId]=`在线文件现场检查：${prettyBytes(liveBytes)}，已检查 ${checked} 项。`+
      (unavailable.length?`未能检查 ${unavailable.join("、")}，结果不完整。`:'本次在线分类目录均已检查。')+
      ` 账本已入账 ${prettyBytes(policy.accountedBytes??0)}，预占 ${prettyBytes(policy.reservedBytes??0)}；回收站和待确认上传不包含在现场文件值里。此操作不会自动删账或改动文件。`;
  }finally{pending.value=false}
}
async function abandonCategory(u:User,category:string,location:StorageLocation){
  if(registeredRoots.value.some(root=>root.rootID===location.rootID)){
    error.value="请先在 Mac 管理端检查硬盘。确实不再使用时，先移除该硬盘的登记。";
    return;
  }
  if(!window.confirm(`确认放弃「${u.username}」的${categories.find(c=>c.id===category)?.label??category}旧存储空间？\n\n此操作只清除 LightIsle 中旧目录的绑定、授权及容量记录，不会删除旧硬盘文件，也不会帮你迁移数据。完成后请重新选择硬盘创建新空间。`))return;
  pending.value=true;error.value="";message.value="";
  try{
    policies.value[u.id]=await api<StoragePolicy>(`/api/v2/storage/users/${u.id}/categories/${category}/abandon`,{
      method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({rootID:location.rootID,generation:location.rootGeneration,confirm:true})
    });
    message.value=`已解除「${u.username}」的旧${categories.find(c=>c.id===category)?.label??category}绑定。请选一块在线硬盘，重新创建空白存储空间。旧盘文件未删除。`;
  }catch(e){error.value="重建前解除旧绑定失败："+String(e)}
  finally{pending.value=false}
}
async function api<T>(path:string, init:RequestInit={}):Promise<T>{
  const headers = new Headers(init.headers);
  if(init.method && init.method!=="GET")headers.set("X-LightIsle-Request","1");
  const response=await fetch(path,{...init,headers,credentials:"same-origin",cache:"no-store"});
  if(!response.ok){
    const value=await response.json().catch(()=>({})) as {error?:string};
    throw new Error(value.error??("HTTP "+response.status));
  }
  return response.json() as Promise<T>;
}
async function load(){
  if(pending.value)return;
  pending.value=true;error.value="";message.value="";
  try{
    if(props.admin){
      const accounts=await api<{users:User[]}>("/api/v2/users");
      users.value=accounts.users;
      const discovery=await fetch("/api/v2/roots",{credentials:"same-origin",cache:"no-store"});
      rootsKnown.value=discovery.ok;
      registeredRoots.value=discovery.ok ? (await discovery.json() as {roots:Root[]}).roots:[];
      roots.value=registeredRoots.value.filter(r=>r.online);
      const entries=await Promise.all(users.value.map(async u=>
        [u.id,await api<StoragePolicy>(`/api/v2/users/${u.id}/storage`)] as const
      ));
      policies.value=Object.fromEntries(entries);
    }else{
      const policy=await api<StoragePolicy>("/api/v2/me/storage");
      policies.value={[policy.userId]:policy};
      try{
        registeredRoots.value=(await api<{roots:Root[]}>("/api/v2/roots")).roots;
        rootsKnown.value=true;
      }catch{
        registeredRoots.value=[];rootsKnown.value=false;
      }
    }
    for(const p of Object.values(policies.value))syncQuotaInputs(p);
  }catch(e){error.value="读取存储配置失败："+String(e)}
  finally{pending.value=false}
}
async function saveQuota(u:User,q:RootQuota){
  const input=quotas.value[quotaKey(u.id,q)]?.trim()??"";
  const gib=Number(input);
  if(!input||!Number.isFinite(gib)||gib<0||gib>1048576){
    error.value="请输入 0–1048576 GiB 的有效配额";return;
  }
  pending.value=true;error.value="";message.value="";
  try{
    const result=await api<StoragePolicy>(`/api/v2/users/${u.id}/storage/roots/${encodeURIComponent(q.rootID)}/quota`,{
      method:"PUT",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({quotaBytes:Math.round(gib*1024**3),generation:q.rootGeneration})
    });
    policies.value[u.id]=result;
    syncQuotaInputs(result);
    message.value="已保存「"+u.username+"」在「"+rootName(q)+"」的专属额度，其他硬盘不变。";
  }catch(e){error.value="设置配额失败："+String(e)}
  finally{pending.value=false}
}
async function assign(u:User,category:string){
  const chosen=roots.value.find(root=>root.rootID===selection.value[`${u.id}:${category}`]);
  if(!chosen){error.value="请选择在线硬盘";return;}
  pending.value=true;error.value="";message.value="";
  try{
    await api(`/api/v2/roots/${chosen.rootID}/users/${u.id}/storage/${category}`,{
      method:"PUT",headers:{"X-LightIsle-Root-Generation":String(chosen.generation)}
    });
    policies.value[u.id]=await api<StoragePolicy>(`/api/v2/users/${u.id}/storage`);
    syncQuotaInputs(policies.value[u.id]);
    message.value="已在「"+chosen.name+"」中创建并授权该成员的专属目录。";
  }catch(e){error.value="分配目录失败："+String(e)}
  finally{pending.value=false}
}
function selectedLocation(p:StoragePolicy,category:string){
  return p.locations.find(l=>l.category===category);
}
function rootLabel(location:StorageLocation){
  if(!rootsKnown.value)return "硬盘状态暂不可用 / "+location.relativePath;
  const root=registeredRoots.value.find(r=>r.rootID===location.rootID);
  return (root?.name??"已移除的原硬盘")+(root&&!root.online?" · 离线":"")+" / "+location.relativePath;
}
onMounted(load);
</script>

<template>
  <section class="storage-panel">
    <div class="storage-heading">
      <div><h3>{{admin?"成员存储空间":"我的存储空间"}}</h3>
        <p>每个成员在每块硬盘独立分配额度；同盘多个内容类别共享该盘额度，默认每盘 100 GiB。</p></div>
      <button type="button" :disabled="pending" @click="load">刷新</button>
    </div>
    <p v-if="error" class="storage-error" role="alert">{{error}}</p>
    <p v-if="message" class="storage-message" role="status">{{message}}</p>
    <p class="storage-tip">家庭使用建议：硬盘离线先检查连接并重插；无法恢复时，在 Mac 管理端移除旧登记，再回来解除旧绑定、选择新硬盘创建空白空间。此操作不删除旧盘文件。</p>
    <p v-if="pending" role="status">正在读取或保存…</p>
    <p v-if="admin&&!roots.length" class="storage-tip">
      当前没有可供管理的多根在线硬盘。请先在 Mac 原生管理端登记硬盘并启用多根开发预览。
    </p>
    <div v-for="policy in Object.values(policies)" :key="policy.userId" class="storage-user">
      <template v-if="admin">
        <div class="storage-user-title">
          <strong>{{users.find(u=>u.id===policy.userId)?.username??('账号 '+policy.userId)}}</strong>
          <span>已分配 {{new Set(policy.locations.map(l=>l.rootID)).size}} 块硬盘</span>
        </div>
      </template>
      <strong v-else>我的硬盘额度</strong>
      <p v-if="!(policy.rootQuotas??[]).length" class="storage-tip">尚未分配专属硬盘。分配后该盘默认 100 GiB，管理员不设应用额度。</p>
      <div v-for="q in policy.rootQuotas??[]" :key="q.rootID+':'+q.rootGeneration" class="storage-per-disk">
        <div class="storage-user-title">
          <strong>{{rootName(q)}} · {{prettyBytes(q.quotaBytes)}}</strong>
          <small>{{isActiveRoot(policy,q)?(registeredRoots.find(r=>r.rootID===q.rootID)?.online===false?'离线 · 请接回原盘':'当前绑定'):'历史代际账本'}}</small>
        </div>
        <progress v-if="q.quotaBytes!==null&&q.quotaBytes>0" :value="Math.min(q.quotaBytes,q.accountedBytes+q.reservedBytes)" :max="q.quotaBytes" />
        <small>已用 {{prettyBytes(q.accountedBytes)}} · 预占 {{prettyBytes(q.reservedBytes)}} · 可用额度 {{rootAvailable(q)}}</small>
        <div v-if="admin&&q.quotaBytes!==null&&isActiveRoot(policy,q)" class="storage-quota">
          <label :for="'quota-'+quotaKey(policy.userId,q)">该硬盘额度 (GiB)</label>
          <input :id="'quota-'+quotaKey(policy.userId,q)" v-model="quotas[quotaKey(policy.userId,q)]" type="number" min="0" max="1048576" step="1" />
          <button :disabled="pending" type="button" @click="saveQuota(users.find(u=>u.id===policy.userId)!,q)">保存这块盘</button>
        </div>
      </div>
      <p class="storage-tip">各盘分别计费，不设跨盘总额度。其他写入渠道尚未纳入，账本数字不代表硬盘全部实际占用。</p>
      <div v-if="admin" class="storage-usage-check">
        <button type="button" :disabled="pending||!rootsKnown" @click="checkOnlineUsage(policy)">核对在线文件占用</button>
        <small v-if="usageChecks[policy.userId]">{{usageChecks[policy.userId]}}</small>
      </div>
      <div v-for="category in categories" :key="category.id" class="storage-category">
        <span class="storage-category-label">{{category.label}}</span>
        <template v-if="selectedLocation(policy,category.id)">
          <small>{{rootLabel(selectedLocation(policy,category.id)!)}}</small>
          <template v-if="admin">
            <small v-if="registeredRoots.some(root=>root.rootID===selectedLocation(policy,category.id)!.rootID&&!root.online)">请检查硬盘连接；确实放弃时，先到 Mac 管理端移除登记</small>
            <button v-else-if="rootsKnown&&!registeredRoots.some(root=>root.rootID===selectedLocation(policy,category.id)!.rootID)"
              type="button" :disabled="pending" @click="abandonCategory(users.find(u=>u.id===policy.userId)!,category.id,selectedLocation(policy,category.id)!)">放弃旧空间并重建…</button>
          </template>
        </template>
        <template v-else-if="admin">
          <AppleSelect
            v-model="selection[`${policy.userId}:${category.id}`]"
            :options="rootOptions"
            :disabled="pending||!roots.length"
            :aria-label="'选择'+category.label+'的硬盘'"
            size="sm"
          />
          <button type="button" :disabled="pending||!selection[`${policy.userId}:${category.id}`]" @click="assign(users.find(u=>u.id===policy.userId)!,category.id)">创建专属目录</button>
        </template>
        <small v-else>管理员尚未分配</small>
      </div>
      <small v-if="policy.enforcement==='pending'" class="storage-pending">容量拦截：开发中</small>
    </div>
  </section>
</template>

<style scoped>
.storage-panel{border:1px solid var(--fluid-card-border);border-radius:20px;padding:22px;margin:18px 0;background:var(--fluid-card-fill);box-shadow:var(--fluid-card-shadow)}
.storage-heading,.storage-user-title{display:flex;align-items:center;justify-content:space-between;gap:14px}
.storage-heading h3{margin:0 0 4px;font-size:16px;font-weight:700}.storage-heading p{margin:0;color:var(--text-secondary);font-size:13px}
.storage-user{border:1px solid var(--fluid-card-border);border-radius:16px;padding:16px;margin-top:12px;background:var(--fluid-card-item-fill);box-shadow:var(--fluid-item-card-shadow)}
.storage-user-title span,.storage-category small,.storage-pending{font-size:12px;color:var(--text-secondary)}
.storage-quota,.storage-category{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-top:12px}
.storage-per-disk{display:flex;flex-direction:column;gap:8px;margin-top:12px;padding:14px;border:1px solid var(--fluid-card-border);border-radius:12px}.storage-per-disk small{font-size:12px;color:var(--text-secondary)}.storage-per-disk progress{width:100%;height:9px}
.storage-usage-check{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin-top:10px}.storage-usage-check small{flex:1;min-width:230px;color:var(--text-secondary)}
.storage-category-label{min-width:115px;font-weight:600;color:var(--text-primary)}.storage-category small{flex:1;overflow-wrap:anywhere}
.storage-quota input{width:110px}.storage-category select{min-width:180px}
button,input,select{border:1px solid var(--fluid-card-border);border-radius:11px;padding:8px 14px;background:var(--fluid-card-fill);color:inherit;font-size:13px;transition:transform var(--motion-fast) var(--motion-spring),background var(--motion-fast) ease}
button{cursor:pointer;font-weight:600}button:hover{background:var(--fluid-card-hover);transform:translateY(-1px)}button:disabled{opacity:.5;cursor:not-allowed;transform:none}
.storage-tip{color:var(--text-secondary);font-size:12px}.storage-error{color:var(--error)}.storage-message{color:var(--success)}.storage-pending{display:block;margin-top:12px}
</style>
