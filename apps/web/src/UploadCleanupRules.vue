<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import { apiErrorFromResponse } from "./apiFailure.js";
import { describeUserFacingError } from "./userFacingError.js";

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
    <p>只清理确认尚未发布、没有活动且状态可靠的上传暂存文件；已发布文件及无法判断的记录会保留。默认保留 30 天；填 0 可关闭自动清理。正在执行的检查按开始时的规则完成。</p>
    <p v-if="error" class="form-error" role="alert">{{error}} <button type="button" class="refresh" :disabled="busy" @click="load">重新读取</button></p>
    <button v-if="error&&savedDays===null" type="button" class="account-action" :disabled="busy" @click="disableUntilRepaired">暂停清理并修复规则</button>
    <p v-if="notice" role="status">{{notice}}</p>
    <label>未活动保留天数 <input v-model="days" type="number" min="0" max="3650" step="1" :disabled="busy||savedDays===null" /></label>
    <button type="button" class="account-action" :disabled="busy||savedDays===null" @click="save">{{busy?'处理中…':'保存规则'}}</button>
  </div>
</template>

<style scoped>
.upload-cleanup-rules{margin:12px 0}.upload-cleanup-rules input{width:90px;margin:0 8px}
</style>
