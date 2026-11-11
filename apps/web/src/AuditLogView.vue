<script setup lang="ts">
import { onMounted, ref } from "vue";
import { ShieldCheck, RefreshCw } from "lucide-vue-next";
import IsleButton from "./IsleButton.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";
import {describeUserFacingError} from "./userFacingError.ts";
import {readApiFailure} from "./apiFailure.ts";

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
  const url=new URL("/api/v2/audit",window.location.origin);
  url.searchParams.set("limit","40");
  if(!reset&&cursor.value)url.searchParams.set("before",String(cursor.value));
  const response=await fetch(url,{credentials:"same-origin",cache:"no-store"});
  if(!response.ok)throw await readApiFailure(response);
  const page=await response.json() as {events:Event[];nextCursor:number};
  if(current!==generation)return;
  entries.value=reset?page.events:[...entries.value,...page.events];
  cursor.value=page.nextCursor;
 }catch(e){if(current===generation)error.value="读取审计记录失败："+describeUserFacingError(e)}
 finally{if(current===generation)loading.value=false}
}
onMounted(()=>void load(true));
</script>

<template>
  <section class="account-panel audit-panel" aria-label="安全操作审计">
    <div class="account-heading">
      <h3><ShieldCheck :size="18" aria-hidden="true"/> 安全审计</h3>
      <IsleButton variant="ghost" size="sm" :loading="loading" @click="load(true)">
        <template #icon><RefreshCw :size="14"/></template> 刷新
      </IsleButton>
    </div>
    <p>保留最近 90 天（最多 20,000 条）关键操作记录，不含密码、令牌或文件内容。</p>
    <IsleBanner v-if="error" type="error" compact role="alert">
      {{ error }}
      <template #action>
        <IsleButton variant="ghost" size="sm" @click="load(true)">重试</IsleButton>
      </template>
    </IsleBanner>
    <p v-if="loading && !entries.length" class="footnote">正在读取操作审计…</p>
    <IsleEmpty v-else-if="!entries.length && !error" compact description="暂无需要审计的操作。" />
    <div v-for="item in entries" :key="item.id" class="account-row audit-entry">
      <div>
        <strong>{{ labels[item.action] || item.action }} · 用户 #{{ item.actorId }}</strong>
        <small>{{ new Date(item.createdAt * 1000).toLocaleString("zh-CN") }} · {{ item.target }}</small>
      </div>
      <IsleBadge
        :variant="item.outcome === 'success' ? 'online' : item.outcome === 'denied' ? 'danger' : 'warning'"
        size="sm"
      >
        {{ item.outcome === "success" ? "成功" : item.outcome === "denied" ? "被拒绝" : "失败" }}
      </IsleBadge>
    </div>
    <div v-if="cursor" class="gallery-load">
      <IsleButton variant="ghost" size="sm" :loading="loading" @click="load(false)">
        {{ loading ? "加载中…" : "查看更多审计记录" }}
      </IsleButton>
    </div>
  </section>
</template>

<style scoped>
.audit-panel{margin-bottom:20px}
.audit-panel .account-heading h3{display:flex;align-items:center;gap:8px}
.audit-panel p{font-size:12px;color:var(--text-secondary);line-height:1.55}
.audit-entry strong{font-size:13px}
.audit-entry small{display:block;margin-top:4px;font-size:11px;color:var(--text-secondary);overflow-wrap:anywhere}
.audit-status{font-size:11px;font-weight:650;padding:3px 9px;border-radius:9999px;white-space:nowrap}
.audit-status.success{background:rgba(52,199,89,0.12);color:#34c759;border:1px solid rgba(52,199,89,0.25)}
.audit-status.denied{background:rgba(255,59,48,0.12);color:#ff3b30;border:1px solid rgba(255,59,48,0.25)}
.audit-status.failed{background:rgba(255,149,0,0.12);color:#ff9500;border:1px solid rgba(255,149,0,0.25)}
</style>
