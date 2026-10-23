<script setup lang="ts">
import { onMounted, ref } from "vue";
import { ShieldCheck, RefreshCw } from "lucide-vue-next";

type Event={id:number;actorId:number;action:string;target:string;outcome:"success"|"denied"|"failed";createdAt:number};
const entries=ref<Event[]>([]);
const cursor=ref(0),loading=ref(false),error=ref("");
let generation=0;
const labels:Record<string,string>={
 account_password_change:"修改账号密码",
 user_or_grant_change:"账号 / 文件权限修改",
 file_share_change:"公开分享链接操作",
 public_share_download:"公开分享下载",
 file_write:"文件管理操作",
 upload_write:"文件续传操作",
 gallery_write:"图库操作",
 cinema_write:"影视资料操作",
};
async function load(reset=false){
 if(loading.value&&!reset)return;
 const current=reset?++generation:generation;
 loading.value=true;error.value="";
 try{
  const url=new URL("/api/v1/audit",window.location.origin);
  url.searchParams.set("limit","40");
  if(!reset&&cursor.value)url.searchParams.set("before",String(cursor.value));
  const response=await fetch(url,{credentials:"same-origin",cache:"no-store"});
  if(!response.ok)throw new Error("HTTP "+response.status);
  const page=await response.json() as {events:Event[];nextCursor:number};
  if(current!==generation)return;
  entries.value=reset?page.events:[...entries.value,...page.events];
  cursor.value=page.nextCursor;
 }catch(e){if(current===generation)error.value="读取审计记录失败："+(e instanceof Error?e.message:"未知错误")}
 finally{if(current===generation)loading.value=false}
}
onMounted(()=>void load(true));
</script>

<template>
 <section class="account-panel audit-panel" aria-label="安全操作审计">
  <div class="account-heading">
   <h3><ShieldCheck :size="18" aria-hidden="true"/> 安全审计</h3>
   <button type="button" class="refresh" :disabled="loading" @click="load(true)"><RefreshCw :size="14"/> 刷新</button>
  </div>
  <p>管理员可查看最近 90 天、最多 20,000 条操作记录。仅记录账号编号、操作类型、接口类别和结果；不保存密码、会话令牌、分享密钥或文件内容。</p>
  <p v-if="error" class="form-error" role="alert">{{error}} <button type="button" @click="load(true)">重试</button></p>
  <p v-if="loading&&!entries.length" class="footnote">正在读取操作审计…</p>
  <p v-else-if="!entries.length&&!error" class="footnote">暂无需要审计的操作。</p>
  <div v-for="item in entries" :key="item.id" class="account-row audit-entry">
   <div>
    <strong>{{labels[item.action]||item.action}} · 用户 #{{item.actorId}}</strong>
    <small>{{new Date(item.createdAt*1000).toLocaleString("zh-CN")}} · {{item.target}}</small>
   </div>
   <span :class="['audit-status',item.outcome]">{{item.outcome==="success"?"成功":item.outcome==="denied"?"被拒绝":"失败"}}</span>
  </div>
  <div v-if="cursor" class="gallery-load"><button type="button" :disabled="loading" @click="load(false)">{{loading?"加载中…":"查看更多审计记录"}}</button></div>
 </section>
</template>

<style scoped>
.audit-panel{margin-bottom:20px}
.audit-panel .account-heading h3{display:flex;align-items:center;gap:8px}
.audit-panel p{font-size:12px;color:var(--text-secondary);line-height:1.55}
.audit-entry strong{font-size:13px}
.audit-entry small{display:block;margin-top:4px;font-size:11px;color:var(--text-secondary);overflow-wrap:anywhere}
.audit-status{font-size:11px;white-space:nowrap}
.audit-status.success{color:var(--text-secondary)}
.audit-status.denied,.audit-status.failed{color:var(--warning)}
</style>
