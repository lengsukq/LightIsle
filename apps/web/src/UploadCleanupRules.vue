<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import { apiErrorFromResponse } from "./apiFailure.ts";
import { describeUserFacingError } from "./userFacingError.ts";

const days=ref("30");
const savedDays=ref<number|null>(null);
const busy=ref(false);
const error=ref("");
const notice=ref("");
const controller=new AbortController();
let disposed=false;
async function request(method="GET",body?:object){
  const headers=new Headers(method==="GET"?{}:{"Content-Type":"application/json","X-LightIsle-Request":"1"});
  const response=await fetch("/api/v2/admin/cleanup-rules",{method,headers,credentials:"same-origin",cache:"no-store",signal:controller.signal,body:body?JSON.stringify(body):undefined});
  const result=await response.json().catch(()=>({error:"invalid_response"}));
  if(!response.ok)throw apiErrorFromResponse(response,result);
  if(!Number.isInteger(result.uploadRetentionDays)||result.uploadRetentionDays<0||result.uploadRetentionDays>3650)throw new Error("invalid_response");
  return result.uploadRetentionDays as number;
}
async function load(){
  if(busy.value)return;
  busy.value=true;error.value="";
  try{
    const value=await request();
    if(!disposed){savedDays.value=value;days.value=String(value)}
  }catch(reason){if(!disposed)error.value="无法读取清理规则："+describeUserFacingError(reason)}
  finally{busy.value=false}
}
async function save(){
  if(busy.value||savedDays.value===null)return;
  if(!/^\d+$/.test(days.value)||Number(days.value)>3650){error.value="请输入 0 至 3650 天的整数。";return}
  busy.value=true;error.value="";notice.value="";
  try{
    const value=await request("PUT",{uploadRetentionDays:Number(days.value)});
    if(!disposed){savedDays.value=value;days.value=String(value);notice.value="规则已保存，将用于之后开始的清理。"}
  }catch(reason){if(!disposed)error.value="保存结果尚未确认，请重新读取规则："+describeUserFacingError(reason)}
  finally{busy.value=false}
}
async function disableUntilRepaired(){
  if(busy.value)return;
  busy.value=true;error.value="";notice.value="";
  try{
    const value=await request("PUT",{uploadRetentionDays:0});
    if(!disposed){savedDays.value=value;days.value=String(value);notice.value="自动清理已关闭。核对后可重新设置保留期。"}
  }catch(reason){if(!disposed)error.value="无法确认清理已关闭，请检查 Mac 服务后重试："+describeUserFacingError(reason)}
  finally{busy.value=false}
}
onMounted(()=>void load());
onUnmounted(()=>{disposed=true;controller.abort()});
</script>

<template>
  <div class="upload-cleanup-rules">
    <p>仅清理确认未发布且长期无活动的上传暂存（默认保留 30 天，填 0 关闭自动清理）；已发布文件不受影响。</p>
    <IsleBanner v-if="error" type="error" compact role="alert">
      {{ error }}
      <template #action>
        <IsleButton variant="glass" size="sm" :disabled="busy" @click="load">重新读取</IsleButton>
      </template>
    </IsleBanner>
    <div v-if="error && savedDays === null" style="margin: 4px 0;">
      <IsleButton variant="danger" size="sm" :disabled="busy" @click="disableUntilRepaired">暂停清理并修复规则</IsleButton>
    </div>
    <IsleBanner v-if="notice" type="info" compact role="status">{{ notice }}</IsleBanner>
    <div class="cleanup-rule-row">
      <label>未活动保留天数 <input v-model="days" type="number" min="0" max="3650" step="1" :disabled="busy || savedDays === null" /></label>
      <IsleButton variant="primary" size="sm" :loading="busy" :disabled="busy || savedDays === null" @click="save">
        {{ busy ? '处理中…' : '保存规则' }}
      </IsleButton>
    </div>
  </div>
</template>

<style scoped>
.upload-cleanup-rules{margin:12px 0;display:grid;gap:10px}
.upload-cleanup-rules p{margin:0;font-size:12.5px;color:var(--text-secondary);line-height:1.5}
.cleanup-rule-row{display:flex;align-items:center;gap:10px;flex-wrap:wrap;font-size:13px}
.upload-cleanup-rules input{width:92px;margin-left:8px;padding:7px 10px;border-radius:10px;border:1px solid var(--fluid-card-border);background:var(--fluid-card-fill);color:var(--text-primary);font:inherit}
</style>
