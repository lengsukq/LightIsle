<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";
import { rootApiPath } from "./rootApi.ts";
import { requestConfirm } from "./useConfirmDialog.ts";
import { apiErrorFromResponse } from "./apiFailure.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { usePendingMediaList, type PendingMediaKind as Kind, type PendingMediaItem as Item } from "./usePendingMediaList.ts";

const props = defineProps<{rootId:string;rootGeneration:number;admin?:boolean}>();
const notice = ref("");
const busy = ref(false);
const controller = new AbortController();
let disposed = false;
async function request<T>(path:string, method="GET", body?:object):Promise<T> {
  const headers = new Headers(method === "GET" ? {} : {"Content-Type":"application/json","X-LightIsle-Request":"1"});
  headers.set("X-LightIsle-Root-Generation", String(props.rootGeneration));
  const response = await fetch(rootApiPath(props.rootId, path), {method,credentials:"same-origin",cache:"no-store",headers,signal:controller.signal,body:body?JSON.stringify(body):undefined});
  const result = await response.json().catch(()=>({error:"invalid_response"}));
  if (!response.ok) throw apiErrorFromResponse(response,result);
  return result as T;
}
const {groups,load,resolved,trackScan,visibilityChanged,dispose} = usePendingMediaList({
  read:(kind,query)=>request(`/api/v2/missing-media/${kind}?${query}`),
  errorLabel:describeUserFacingError,
});
async function recheck(kind:Kind) {
  if(busy.value)return;
  busy.value=true; notice.value="";
  try {
    await request(`/api/v2/missing-media/${kind}/recheck`,"POST");
    if(!disposed){trackScan(kind);notice.value="检查已开始，完成后列表会自动更新。只有能够确认是原文件时，才会自动恢复原来的关联。";}
  } catch(error) {
    if(!disposed && error instanceof Error && error.message==="scan_running"){
      trackScan(kind);notice.value="检查正在进行，完成后列表会自动更新。";
    } else if(!disposed)notice.value="无法开始检查："+describeUserFacingError(error);
  }
  finally { busy.value=false; }
}
async function discard(kind:Kind, item:Item) {
  if(busy.value || !(await requestConfirm({title:"放弃旧媒体记录",message:`放弃“${item.path}”的这条旧记录？\n收藏、相册关联或观看资料可能一并删除，包括其他成员关联的资料。不会删除磁盘上的文件；操作无法撤销。`,confirmText:"确认放弃",variant:"danger"})))return;
  busy.value=true; notice.value="";
  try {
    await request(`/api/v2/missing-media/${kind}/${item.id}`,"DELETE",{confirm:true});
    if(!disposed){ notice.value="旧记录已放弃；磁盘文件未被删除。"; await resolved(kind,item.id); }
  } catch(error) {
    if(!disposed){ notice.value="未能确认处理结果，请核对列表后再操作："+describeUserFacingError(error); await load(kind,false,true); }
  }
  finally { busy.value=false; }
}
async function attach(kind:Kind, item:Item) {
  if(busy.value || !(await requestConfirm({title:"关联到当前文件",message:`确认原位置“${item.path}”现在的文件就是要关联的照片或影片？\n旧收藏、相册关联或观看资料会合并到当前文件；如果不是同一文件，请取消。`,confirmText:"确认关联"})))return;
  busy.value=true; notice.value="";
  try {
    await request(`/api/v2/missing-media/${kind}/${item.id}/attach`,"POST",{confirm:true});
    if(!disposed){ notice.value="旧资料已关联到当前文件。"; await resolved(kind,item.id); }
  } catch(error) {
    if(!disposed){ notice.value="未能确认关联结果，请核对列表后再操作："+describeUserFacingError(error); await load(kind,false,true); }
  }
  finally { busy.value=false; }
}
function reason(value:string) {
  if(value==="identity_changed")return "原位置出现了不同的文件";
  if(value==="identity_unverified")return "无法确认当前文件是否为原文件";
  return "原位置暂时找不到文件";
}
function dataLabel(values:string[]) {
  const labels:Record<string,string>={favorites:"收藏",albums:"相册关联",progress:"观看进度",metadata:"影视资料"};
  return values.map(value=>labels[value]??value).join("、") || "旧资料";
}
onMounted(()=>{ document.addEventListener("visibilitychange",visibilityChanged); void load("photos"); void load("cinema"); });
onUnmounted(()=>{disposed=true;document.removeEventListener("visibilitychange",visibilityChanged);dispose();controller.abort()});
</script>

<template>
  <section class="pending-media">
    <p>{{admin?"查看当前硬盘所有目录中待处理的缺失媒体记录。":"显示你在当前硬盘个人目录中待处理的缺失媒体记录。"}}原收藏、相册与观看进度会保留。</p>
    <IsleBanner v-if="notice" type="info" compact role="status">{{ notice }}</IsleBanner>
    <div v-for="kind in (['photos','cinema'] as const)" :key="kind" class="pending-kind">
      <div class="account-heading">
        <h4>{{ kind === 'photos' ? '照片与视频' : '影视' }}</h4>
        <div style="display: flex; gap: 8px;">
          <IsleButton variant="glass" size="sm" :loading="busy" @click="recheck(kind)">重新检查</IsleButton>
          <IsleButton variant="glass" size="sm" :loading="groups[kind].loading" @click="load(kind)">刷新</IsleButton>
        </div>
      </div>
      <IsleBanner v-if="groups[kind].error" type="error" compact role="alert">{{ groups[kind].error }}</IsleBanner>
      <p v-else-if="groups[kind].loading && !groups[kind].loaded">正在读取…</p>
      <p v-if="groups[kind].loaded && groups[kind].scan==='running'" class="footnote">检查正在进行，当前结果尚不完整；完成后会自动更新。</p>
      <IsleBanner v-else-if="groups[kind].loaded && groups[kind].scan==='failed'" type="warning" compact role="alert">
        上次检查未完成，结果可能不完整。请检查硬盘连接后重新检查。
      </IsleBanner>
      <p v-else-if="groups[kind].loaded && groups[kind].scan==='not_checked'" class="footnote">尚未完成检查，当前结果可能不完整。</p>
      <p v-else-if="groups[kind].loaded && groups[kind].scan==='finished'" class="footnote">最近一次检查已结束；如果只检查了部分目录，其他目录可能尚未核对。</p>
      <IsleEmpty v-if="groups[kind].loaded && !groups[kind].items.length && !groups[kind].error" compact description="当前没有已发现的缺失记录。" />
      <div v-for="item in groups[kind].items" :key="item.id" class="account-row">
        <div class="pending-path">
          <strong>{{ item.path }}</strong>
          <small>{{ reason(item.reason) }} · 保留：{{ dataLabel(item.data) }}{{ item.canManage ? '' : ' · 当前没有写入权限，请联系管理员' }}</small>
        </div>
        <div class="pending-actions">
          <IsleButton variant="tonal" size="sm" :disabled="busy || !item.canManage" @click="attach(kind, item)">关联当前文件…</IsleButton>
          <IsleButton variant="danger" size="sm" :disabled="busy || !item.canManage" @click="discard(kind, item)">放弃旧记录…</IsleButton>
        </div>
      </div>
      <IsleButton v-if="groups[kind].next" variant="glass" size="sm" :loading="groups[kind].loading" @click="load(kind, true)">加载更多</IsleButton>
    </div>
  </section>
</template>

<style scoped>
.pending-media{margin-top:12px}.pending-kind{margin-top:16px}.pending-path{min-width:0;overflow-wrap:anywhere}.pending-kind .account-heading button+button{margin-left:8px}.pending-actions{display:flex;flex-wrap:wrap;gap:8px}
</style>
