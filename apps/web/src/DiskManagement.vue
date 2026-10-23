<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { HardDrive, RefreshCcw, ShieldCheck, AlertTriangle, Pencil, PlugZap, ArrowUpRight } from "lucide-vue-next";
type Disk = {
  id:string; name:string; parent:string; mount:string; filesystem:string;
  protocol:string; smart:string; total:number; free:number; readOnly:boolean;
  mounted:boolean; external:boolean; identity:string;
};
const disks=ref<Disk[]>([]);
const loading=ref(false);
const pending=ref("");
const error=ref("");
const notice=ref("");
const pct=(d:Disk)=>Math.min(100,Math.max(0,Math.round((d.total-d.free)/Math.max(1,d.total)*100)));
const formatSize=(size:number)=>size>0?(size/1024**3).toFixed(1)+" GB":"未知";
const count=computed(()=>disks.value.length);
const errors:Record<string,string>={
  invalid_drive_request:"磁盘标识或名称无效，请检查输入。",
  drive_identity_changed_refresh_required:"设备身份已变化，请刷新列表后再操作。",
  drive_in_use_or_protected:"该硬盘仍被 NAS 或备份占用，不能执行此操作。先切换存储目录并停止相关任务。",
  drive_operation_busy:"后台正在处理存储任务，请稍后重试。",
  drive_operation_not_supported:"此磁盘或控制器不支持受控操作。可以使用 macOS 磁盘工具。",
  drive_discovery_unavailable:"暂时无法读取 macOS 硬盘列表。",
  diskutil_operation_failed:"macOS 拒绝此操作：磁盘可能正被系统或其他应用使用。",
  admin_only:"仅管理员能够管理硬盘。",
};
async function jsonResponse(response:Response){
  const value=await response.json().catch(()=>({})) as {error?:string;disks?:Disk[]};
  if(!response.ok)throw new Error(errors[value.error??""]??value.error??"服务请求失败");
  return value;
}
async function refresh(){
  if(loading.value||pending.value)return;
  loading.value=true;error.value="";
  try{
    const data=await jsonResponse(await fetch("/api/v1/admin/disks",{credentials:"same-origin",cache:"no-store"}));
    disks.value=data.disks??[];
  }catch(e){error.value=e instanceof Error?e.message:"读取磁盘列表失败";}
  finally{loading.value=false;}
}
async function act(d:Disk,action:"rename"|"mount"|"eject"){
  if(pending.value||!d.external||!d.identity||d.identity.length!==64)return;
  let name="";
  if(action==="rename"){
    const result=window.prompt("重命名磁盘「"+d.name+"」\n此操作会改变卷显示名称，不会自动移动文件。",d.name);
    if(result===null||result===d.name)return;
    name=result;
  }else if(!window.confirm(
    action==="eject"
      ?"确认安全弹出「"+d.name+"」？请先完成文件上传与拷贝，NAS 存储卷会受到保护。"
      :"确认挂载「"+d.name+"」？macOS 会验证该卷并挂载。"
  ))return;
  pending.value=d.id;error.value="";notice.value="";
  try{
    const value=await jsonResponse(await fetch("/api/v1/admin/disks/actions",{
      method:"POST",credentials:"same-origin",
      headers:{"Content-Type":"application/json","X-LightIsle-Request":"1"},
      body:JSON.stringify({action,id:d.id,identity:d.identity,name})
    }));
    disks.value=value.disks??[];
    notice.value="操作已提交并由 macOS 返回成功；请核对最新状态。";
  }catch(e){error.value=e instanceof Error?e.message:"操作未完成，请刷新确认";}
  finally{pending.value="";}
}
onMounted(()=>{void refresh();});
</script>

<template>
  <section class="account-panel disk-admin-panel">
    <div class="account-heading">
      <div>
        <h3><HardDrive :size="18"/> 硬盘基础管理</h3>
        <p>Mac 外置磁盘 · {{count}} 个设备 · 管理员专用</p>
      </div>
      <button type="button" class="refresh" :disabled="loading||!!pending" @click="refresh">
        <RefreshCcw :size="15" :class="{spinning:loading}"/>{{loading?"检测中":"刷新"}}
      </button>
    </div>
    <p class="disk-admin-note">统一由 LightIsle Core 验证设备身份并执行受限 macOS 操作；不支持强制弹出、后台格式化或系统盘修改。</p>
    <p v-if="error" role="alert" class="form-error">{{error}}</p>
    <p v-if="notice" role="status" class="footnote">{{notice}}</p>
    <div v-if="!count&&!loading" class="disk-admin-empty">没有发现可管理的外置磁盘。请连接硬盘并刷新。</div>
    <div v-for="d in disks" :key="d.id" class="disk-admin-item">
      <div class="disk-admin-main">
        <span class="disk-admin-icon"><HardDrive :size="20"/></span>
        <div class="disk-admin-name">
          <strong>{{d.name}}</strong>
          <span>{{d.id}} · {{d.filesystem||"格式未知"}} · {{d.protocol||"连接方式未知"}}</span>
          <small>{{d.mount||"尚未挂载"}} · {{d.readOnly?"只读":"可写"}} · SMART：{{d.smart||"未知/不支持"}}</small>
        </div>
        <span class="disk-admin-status" :class="{offline:!d.mounted}">{{d.mounted?"已挂载":"未挂载"}}</span>
      </div>
      <div v-if="d.total>0" class="disk-admin-capacity">
        <div class="disk-admin-meter"><div :style="{width:pct(d)+'%'}"></div></div>
        <span>{{d.mounted?"可用 "+formatSize(d.free)+" / 总计 "+formatSize(d.total):"总计 "+formatSize(d.total)}}</span>
      </div>
      <div class="disk-admin-actions">
        <template v-if="!d.identity">
          <span class="disk-admin-warning"><AlertTriangle :size="14"/> 设备唯一身份不可验证，禁止修改</span>
        </template>
        <template v-else>
          <button v-if="d.mounted" :disabled="!!pending" type="button" @click="act(d,'rename')"><Pencil :size="14"/> 重命名</button>
          <button v-if="d.mounted" :disabled="!!pending" type="button" @click="act(d,'eject')"><ArrowUpRight :size="14"/> 安全弹出</button>
          <button v-else :disabled="!!pending" type="button" @click="act(d,'mount')"><PlugZap :size="14"/> 挂载</button>
          <span v-if="pending===d.id" class="disk-admin-pending">macOS 正在处理…</span>
        </template>
      </div>
    </div>
    <div class="disk-admin-footer"><ShieldCheck :size="16"/> SMART 不支持读取并不等于健康。格式化为 APFS 或 exFAT 请在 Mac 的「磁盘工具」中操作，并先备份原文件。</div>
  </section>
</template>

<style scoped>
.disk-admin-panel{display:grid;gap:12px}
.disk-admin-panel .account-heading h3{display:flex;align-items:center;gap:9px;margin:0}
.disk-admin-panel .account-heading p{margin:6px 0 0;font-size:12px;color:var(--text-secondary)}
.disk-admin-note{margin:0!important;font-size:12px;line-height:1.7;color:var(--text-secondary)}
.disk-admin-item{padding:16px 18px;border-radius:19px;border:1px solid var(--fluid-card-border);background:var(--fluid-card-item-fill)}
.disk-admin-main{display:flex;align-items:center;gap:12px}
.disk-admin-icon{width:42px;height:42px;border-radius:14px;background:color-mix(in srgb,var(--accent-primary) 10%,transparent);color:var(--accent-primary);display:grid;place-items:center;flex:none}
.disk-admin-name{display:grid;gap:3px;min-width:0;flex:1}
.disk-admin-name strong{font-size:14px;color:var(--text-primary)}
.disk-admin-name span,.disk-admin-name small{color:var(--text-secondary);font-size:11px;overflow-wrap:anywhere}
.disk-admin-status{border-radius:30px;padding:5px 10px;font-size:10px;font-weight:650;background:color-mix(in srgb,var(--accent-primary) 10%,transparent);color:var(--accent-primary)}
.disk-admin-status.offline{background:var(--fluid-card-fill);color:var(--text-secondary)}
.disk-admin-capacity{display:flex;align-items:center;gap:12px;margin-top:13px}
.disk-admin-meter{height:6px;flex:1;min-width:60px;border-radius:8px;background:var(--stroke-subtle);overflow:hidden}
.disk-admin-meter>div{height:100%;border-radius:inherit;background:var(--accent-primary)}
.disk-admin-capacity span{font-size:11px;color:var(--text-secondary)}
.disk-admin-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:14px}
.disk-admin-actions button{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--fluid-card-border);border-radius:11px;padding:8px 12px;background:var(--fluid-card-fill);font-size:12px;font-weight:600;color:var(--text-primary);cursor:pointer}
.disk-admin-actions button:hover{background:var(--fluid-card-hover)}
.disk-admin-actions button:disabled{opacity:.5;cursor:wait}
.disk-admin-warning,.disk-admin-pending{font-size:11px;color:var(--text-secondary);display:flex;gap:6px;align-items:center}
.disk-admin-footer{display:flex;gap:9px;align-items:flex-start;font-size:11px;line-height:1.6;color:var(--text-secondary)}
.disk-admin-footer svg{flex:none;margin-top:1px}
.disk-admin-empty{padding:24px;text-align:center;font-size:12px;color:var(--text-secondary)}
@media(max-width:600px){.disk-admin-main{flex-wrap:wrap}.disk-admin-status{margin-left:auto}.disk-admin-capacity{flex-wrap:wrap}}
</style>
