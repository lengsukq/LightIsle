<script setup lang="ts">
import { onMounted, ref } from "vue";
import { apiFetch, apiRequest } from "./apiClient.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleBadge from "./IsleBadge.vue";

type StorageLocation = { category:string; rootID:string; rootGeneration:number; relativePath:string };
type RootQuota = {rootID:string;rootGeneration:number;quotaBytes:number|null;accountedBytes:number;reservedBytes:number};
type StoragePolicy = {
  userId:number; role?:string; unlimited?:boolean; quotaBytes:number|null; rootQuotas:RootQuota[]; locations:StorageLocation[]; enforcement:string;
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
const usageChecks=ref<Record<number,string>>({});
const categories = [
  {id:"files",label:"普通文件与下载"},
  {id:"photos",label:"照片"},
  {id:"videos",label:"视频"},
];
function prettyBytes(bytes:number|null):string {
  if(bytes===null)return "不设应用配额";
  return (bytes / (1024 ** 3)).toLocaleString("zh-CN",{maximumFractionDigits:2}) + " GiB";
}
function rootName(q:RootQuota){return registeredRoots.value.find(r=>r.rootID===q.rootID)?.name??'原绑定硬盘';}
function isActiveRoot(policy:StoragePolicy,q:RootQuota){
  return policy.locations.some(l=>l.rootID===q.rootID&&l.rootGeneration===q.rootGeneration) ||
    registeredRoots.value.some(r=>r.rootID===q.rootID&&r.generation===q.rootGeneration);
}
function allocatedDiskCount(policy:StoragePolicy){
  return new Set([
    ...policy.locations.map(l=>l.rootID),
    ...(policy.rootQuotas??[]).filter(q=>isActiveRoot(policy,q)).map(q=>q.rootID),
  ]).size;
}
function diskLocations(policy:StoragePolicy,q:RootQuota){
  return policy.locations.filter(l=>l.rootID===q.rootID&&l.rootGeneration===q.rootGeneration);
}
function rootAvailable(q:RootQuota){
  return q.quotaBytes===null?'无限制':prettyBytes(Math.max(0,q.quotaBytes-q.accountedBytes-q.reservedBytes));
}
function isUserUnlimited(policy:StoragePolicy){
  return policy.unlimited===true || policy.role==="admin" || users.value.find(u=>u.id===policy.userId)?.role==="admin";
}
async function checkOnlineUsage(policy:StoragePolicy){
  const assigned=[...new Set(policy.locations.map(l=>l.rootID))];
  if(!assigned.length){usageChecks.value[policy.userId]="尚未分配个人目录，暂无可检查的在线硬盘。";return;}
  pending.value=true;error.value="";
  try{
    const reports:string[]=[];
    const unavailable:string[]=[];
    for(const rootID of assigned){
      const root=registeredRoots.value.find(r=>r.rootID===rootID);
      if(!root||!root.online||policy.locations.some(l=>l.rootID===rootID&&l.rootGeneration!==root.generation)){
        unavailable.push(root?.name??rootID);continue;
      }
      const query=new URLSearchParams({rootGeneration:String(root.generation)});
      try{
        const result=await api<{liveBytes:number;entriesChecked:number;ledgerBytes:number;reservedBytes:number}>(`/api/v2/roots/${encodeURIComponent(rootID)}/storage/users/${policy.userId}/usage-check?${query}`);
        reports.push(`${root.name}：在线文件 ${prettyBytes(result.liveBytes)}（${result.entriesChecked} 项），账本已入账 ${prettyBytes(result.ledgerBytes)}，预占 ${prettyBytes(result.reservedBytes)}`);
      }catch(e){unavailable.push(`${root.name}（${describeUserFacingError(e)}）`)}
    }
    usageChecks.value[policy.userId]=(reports.length?`在线文件现场检查：${reports.join("；")}。`:'没有可用的在线硬盘检查结果。')+
      (unavailable.length?` 未能检查 ${unavailable.join("、")}，结果不完整。`:' 本次在线分类目录均已检查。')+
      ` 已入账可能包含回收站，预占可能与现场文件重叠；账本尚不完整，结果仅供核对。此操作不会自动删账或改动文件。`;
  }finally{pending.value=false}
}
function api<T>(path:string, init:RequestInit={}):Promise<T>{
  return apiRequest<T>(path, init);
}
async function load(){
  if(pending.value)return;
  pending.value=true;error.value="";
  try{
    if(props.admin){
      const accounts=await api<{users:User[]}>("/api/v2/users");
      users.value=accounts.users;
      const discovery=await apiFetch("/api/v2/roots");
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
  }catch(e){error.value="读取存储配置失败："+describeUserFacingError(e)}
  finally{pending.value=false}
}
function selectedLocation(p:StoragePolicy,category:string){
  return p.locations.find(l=>l.category===category);
}
function rootLabel(location:StorageLocation){
  if(!rootsKnown.value)return "硬盘状态暂不可用 · 成员专属空间（"+location.relativePath+"）";
  const root=registeredRoots.value.find(r=>r.rootID===location.rootID);
  return (root?.name??"已移除的原硬盘")+(root&&!root.online?" · 离线":"")+" · 成员专属空间（"+location.relativePath+"）";
}
onMounted(load);
</script>

<template>
  <section class="storage-panel">
    <div class="storage-heading">
      <div><h3>{{admin?"成员存储空间（只读查看）":"我的存储空间"}}</h3>
        <p>个人文件、照片与视频保存在所选硬盘；管理员默认不限配额，成员按盘独立分配额度。</p></div>
      <IsleButton variant="glass" size="sm" :disabled="pending" @click="load">刷新</IsleButton>
    </div>
    <IsleBanner v-if="error" type="error" compact :message="error" style="margin-top: 10px" />
    <IsleBanner v-if="admin" type="info" compact message="存储目录分配、配额调整与跨盘迁移请在 Mac 管理端或客户端操作，网页端仅提供只读查看与占用核对。" style="margin-top: 10px" />
    <p v-if="pending" role="status">正在读取…</p>
    <div v-for="policy in Object.values(policies)" :key="policy.userId" class="storage-user">
      <template v-if="admin">
        <div class="storage-user-title">
          <strong>{{users.find(u=>u.id===policy.userId)?.username??('账号 '+policy.userId)}}</strong>
          <span>{{isUserUnlimited(policy)?'管理员 · 默认无限配额 · ':''}}已分配 {{allocatedDiskCount(policy)}} 块硬盘</span>
        </div>
      </template>
      <strong v-else>我的硬盘额度</strong>
      <p v-if="!(policy.rootQuotas??[]).length" class="storage-tip">
        {{isUserUnlimited(policy)?'管理员默认无限配额（仅受所选磁盘实际可用空间限制）。':'尚未分配专属硬盘。分配后该盘默认 100 GiB，管理员不设应用额度。'}}
      </p>
      <div v-for="q in policy.rootQuotas??[]" :key="q.rootID+':'+q.rootGeneration" class="storage-per-disk">
        <div class="storage-user-title">
          <strong>{{rootName(q)}} · {{prettyBytes(q.quotaBytes)}}</strong>
          <IsleBadge
            :variant="isActiveRoot(policy,q) ? (registeredRoots.find(r=>r.rootID===q.rootID)?.online===false ? 'danger' : (diskLocations(policy,q).length ? 'online' : 'warning')) : 'neutral'"
            size="sm"
            :title="'登记代次 #'+q.rootGeneration"
          >
            {{isActiveRoot(policy,q)?(registeredRoots.find(r=>r.rootID===q.rootID)?.online===false?'离线 · 请接回原盘':(diskLocations(policy,q).length?'当前绑定':'已预留配额 · 待添加目录')):'旧版硬盘历史账本（代次 #'+q.rootGeneration+'）'}}
          </IsleBadge>
        </div>
        <progress v-if="q.quotaBytes!==null&&q.quotaBytes>0" :value="Math.min(q.quotaBytes,q.accountedBytes+q.reservedBytes)" :max="q.quotaBytes" />
        <small>已用 {{prettyBytes(q.accountedBytes)}} · 预占 {{prettyBytes(q.reservedBytes)}} · 可用额度 {{rootAvailable(q)}}</small>
        <small v-if="diskLocations(policy,q).length">
          该盘目录：{{diskLocations(policy,q).map(l=>(categories.find(c=>c.id===l.category)?.label??l.category)+' ('+l.relativePath+')').join('、')}}
        </small>
        <small v-else>该盘暂未创建分类目录。</small>
      </div>
      <p class="storage-tip">各盘分别计费，不设跨盘总额度。其他写入渠道尚未纳入，账本数字不代表硬盘全部实际占用。</p>
      <div v-if="admin" class="storage-usage-check">
        <IsleButton variant="glass" size="sm" :disabled="pending||!rootsKnown" @click="checkOnlineUsage(policy)">核对在线文件占用</IsleButton>
        <small v-if="usageChecks[policy.userId]">{{usageChecks[policy.userId]}}</small>
      </div>
      <div v-for="category in categories" :key="category.id" class="storage-category">
        <span class="storage-category-label">{{category.label}}</span>
        <template v-if="selectedLocation(policy,category.id)">
          <small>{{rootLabel(selectedLocation(policy,category.id)!)}}</small>
          <small v-if="admin&&registeredRoots.some(root=>root.rootID===selectedLocation(policy,category.id)!.rootID&&!root.online)">离线 · 请检查硬盘连接</small>
        </template>
        <small v-else>尚未分配（请在 Flutter 客户端或 Mac 原生管理端分配）</small>
      </div>
      <small v-if="policy.enforcement==='pending'" class="storage-pending" title="enforcement=pending">配额状态：已对网页/App 上传与下载生效（SMB / 局域网直写暂未纳入硬拦截）</small>
    </div>
  </section>
</template>

<style scoped>
.storage-panel{border:1px solid var(--fluid-card-border);border-radius:20px;padding:24px;margin:18px 0;background:var(--fluid-card-fill);box-shadow:var(--fluid-card-shadow)}
.storage-heading,.storage-user-title{display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap}
.storage-heading h3{margin:0 0 4px;font-size:16px;font-weight:700}.storage-heading p{margin:0;color:var(--text-secondary);font-size:13px}
.storage-user{border-top:1px solid var(--stroke-subtle);padding-top:16px;margin-top:16px}
.storage-user:first-of-type{border-top:0;padding-top:0;margin-top:14px}
.storage-user-title span,.storage-category small,.storage-pending{font-size:12px;color:var(--text-secondary)}
.storage-category{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-top:8px;padding:4px 0}
.storage-per-disk{display:flex;flex-direction:column;gap:6px;margin-top:10px;padding:10px 0;border-bottom:1px solid var(--stroke-subtle)}.storage-per-disk small{font-size:12px;color:var(--text-secondary)}.storage-per-disk progress{width:100%;height:8px;border-radius:4px}
.storage-usage-check{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin-top:12px}.storage-usage-check small{flex:1;min-width:230px;color:var(--text-secondary)}
.storage-category-label{min-width:115px;font-weight:600;color:var(--text-primary);font-size:12.5px}.storage-category small{flex:1;overflow-wrap:anywhere}
button{border:1px solid var(--fluid-card-border);border-radius:10px;padding:6px 13px;background:var(--fluid-card-fill);color:inherit;font-size:12.5px;cursor:pointer;font-weight:600;transition:transform var(--motion-fast) var(--motion-spring),background var(--motion-fast) ease}
button:hover{background:var(--fluid-card-hover);transform:translateY(-1px)}button:disabled{opacity:.5;cursor:not-allowed;transform:none}
.storage-tip{color:var(--text-secondary);font-size:12px;line-height:1.5;margin:8px 0}.storage-error{color:var(--error)}.storage-pending{display:block;margin-top:12px}
</style>
