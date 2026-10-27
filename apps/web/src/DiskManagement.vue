<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { HardDrive, RefreshCcw, ShieldCheck, AlertTriangle, Pencil, PlugZap, ArrowUpRight, Activity, HeartPulse } from "lucide-vue-next";
import {describeUserFacingError} from "./userFacingError.js";
type Disk = {
  id:string; name:string; parent:string; mount:string; filesystem:string;
  protocol:string; smart:string; total:number; free:number; readOnly:boolean;
  mounted:boolean; external:boolean; identity:string;
};
type HealthSample = {
  timestamp:number;source:string;reason?:string;temperature?:number;
  passed:boolean|null;lifeUsed?:number;powerOnHours?:number;risk:string;
};
type SmartReport = {
  device:string; source:string; reason?:string; model?:string; serial?:string;
  firmware?:string; temperature?:number; passed?:boolean; powerOnHours?:number; lifeUsed?:number;
};
type Volume = {
  name:string; mount:string; device:string; filesystem:string;
  total:number; free:number; readOnly:boolean;
};
const disks=ref<Disk[]>([]);
const volumes=ref<Volume[]>([]);
const smart=ref<Record<string,SmartReport>>({});
const healthHistory=ref<Record<string,HealthSample[]>>({});
const healthRisk=ref<Record<string,string>>({});
const healthNote=ref<Record<string,string>>({});
const smartOpen=ref<Record<string,boolean>>({});
const smartLoading=ref("");
const loading=ref(false);
const pending=ref("");
const error=ref("");
const notice=ref("");
const pct=(d:Disk)=>Math.min(100,Math.max(0,Math.round((d.total-d.free)/Math.max(1,d.total)*100)));
const vpct=(v:Volume)=>Math.min(100,Math.max(0,Math.round((v.total-v.free)/Math.max(1,v.total)*100)));
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
const smartReasons:Record<string,string>={
  smartctl_not_installed:"未安装 smartmontools，无法读取详细健康信息。可执行 brew install smartmontools 后重试；当前仅显示 macOS 基础 SMART 状态。",
  smartctl_permission_required:"macOS 限制普通权限进程直读设备 SMART，详细数据需要管理员权限；当前仅显示 macOS 基础 SMART 状态。",
  smartctl_device_unsupported:"该磁盘的桥接芯片或控制器不支持通过 smartctl 读取 SMART；当前仅显示 macOS 基础 SMART 状态。",
  smartctl_query_failed:"SMART 查询失败，请稍后重试。",
};
const smartReason=(report?:SmartReport)=>!report?"正在读取健康信息…":smartReasons[report.reason??""]??"暂时无法读取该磁盘的健康详情。";
async function jsonResponse(response:Response){
  const value=await response.json().catch(()=>({})) as {error?:string;disks?:Disk[]};
  if(!response.ok)throw new Error(errors[value.error??""]??describeUserFacingError(new Error(value.error??"HTTP "+response.status)));
  return value;
}
async function refresh(){
  if(loading.value||pending.value)return;
  loading.value=true;error.value="";
  try{
    const data=await jsonResponse(await fetch("/api/v2/admin/disks",{credentials:"same-origin",cache:"no-store"}));
    disks.value=data.disks??[];
    const system=await fetch("/api/v2/system",{credentials:"same-origin",cache:"no-store"});
    if(system.ok)volumes.value=((await system.json()) as {volumes?:Volume[]}).volumes??[];
  }catch(e){error.value=describeUserFacingError(e);}
  finally{loading.value=false;}
}
async function toggleSmart(d:Disk){
  smartOpen.value[d.id]=!smartOpen.value[d.id];
  if(!smartOpen.value[d.id]||smart.value[d.id])return;
  await refreshSmart(d);
}
async function refreshSmart(d:Disk){
  if(smartLoading.value)return;
  smartLoading.value=d.id;
  healthNote.value[d.id]="";
  try{
    const response=await fetch("/api/v2/admin/disks/"+d.id+"/smart",{credentials:"same-origin",cache:"no-store"});
    const value=await response.json().catch(()=>({})) as {report?:SmartReport;risk?:string;historyRecorded?:boolean};
    if(!response.ok)throw new Error("smart_failed");
    if(value.report)smart.value[d.id]=value.report;
    healthRisk.value[d.id]=value.risk??"unknown";
    if(!value.historyRecorded)healthNote.value[d.id]="该设备没有可持久关联的历史记录，或数据库暂不可用。";
    const historyResponse=await fetch("/api/v2/admin/disks/"+d.id+"/smart/history",{credentials:"same-origin",cache:"no-store"});
    if(historyResponse.ok){
      const history=await historyResponse.json() as {samples?:HealthSample[]};
      healthHistory.value[d.id]=Array.isArray(history.samples)?history.samples:[];
    }else{healthNote.value[d.id]="历史读取不可用。当前 SMART 状态仍可查看。";}
  }catch{
    smart.value[d.id]={device:d.id,source:"none",reason:"smartctl_query_failed"};
    healthRisk.value[d.id]="unknown";
    healthNote.value[d.id]="未能读取健康报告。请检查磁盘连接或 smartctl 权限。";
  }
  finally{if(smartLoading.value===d.id)smartLoading.value="";}
}
const healthLabel=(risk?:string)=>{
  switch(risk){
    case "critical":return "严重：SMART 自检明确失败";
    case "warning":return "注意：温度或寿命达到提示阈值";
    case "ok":return "当前已读取指标未触发预设阈值";
    default:return "未知：无法证明磁盘健康";
  }
};
function temperaturePoints(id:string){
  const known=(healthHistory.value[id]??[]).filter(s=>typeof s.temperature==="number");
  if(known.length<2)return "";
  const min=known[0].timestamp,span=Math.max(1,known[known.length-1].timestamp-min);
  return known.map(s=>[8+284*(s.timestamp-min)/span,78-60*Math.min(100,Math.max(0,s.temperature!))/100]
    .map(n=>n.toFixed(1)).join(",")).join(" ");
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
    const value=await jsonResponse(await fetch("/api/v2/admin/disks/actions",{
      method:"POST",credentials:"same-origin",
      headers:{"Content-Type":"application/json","X-LightIsle-Request":"1"},
      body:JSON.stringify({action,id:d.id,identity:d.identity,name})
    }));
    disks.value=value.disks??[];
    notice.value="操作已提交并由 macOS 返回成功；请核对最新状态。";
  }catch(e){error.value=describeUserFacingError(e);}
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
        <span>{{d.mounted?"已用 "+pct(d)+"% · 可用 "+formatSize(d.free)+" / 总计 "+formatSize(d.total):"总计 "+formatSize(d.total)}}</span>
      </div>
      <button type="button" class="disk-admin-smart-toggle" :disabled="smartLoading===d.id" @click="toggleSmart(d)">
        <HeartPulse :size="14"/>{{smartOpen[d.id]?"收起健康详情":"健康详情"}}{{smartLoading===d.id?"…":""}}
      </button>
      <div v-if="smartOpen[d.id]" class="disk-admin-smart">
        <div class="disk-admin-health-title">
          <strong :class="{'smart-bad':healthRisk[d.id]==='critical','smart-warning':healthRisk[d.id]==='warning'}">{{healthLabel(healthRisk[d.id])}}</strong>
          <button type="button" :disabled="!!smartLoading" @click="refreshSmart(d)">重新读取 SMART</button>
        </div>
        <template v-if="smart[d.id]&&smart[d.id].source==='smartctl'">
          <div class="disk-admin-smart-grid">
            <span>型号</span><strong>{{smart[d.id].model||"未知"}}</strong>
            <span>序列号</span><strong>{{smart[d.id].serial||"未知"}}</strong>
            <span>固件</span><strong>{{smart[d.id].firmware||"未知"}}</strong>
            <span>温度</span><strong>{{smart[d.id].temperature!=null?smart[d.id].temperature+" °C":"—"}}</strong>
            <span>SMART 结论</span><strong :class="{'smart-bad':smart[d.id].passed===false,'smart-good':smart[d.id].passed===true}">{{smart[d.id].passed===true?"健康（已通过）":smart[d.id].passed===false?"警告：SMART 报告异常":"未报告"}}</strong>
            <span>通电时长</span><strong>{{smart[d.id].powerOnHours!=null?smart[d.id].powerOnHours+" 小时":"—"}}</strong>
            <span>已用寿命</span><strong>{{smart[d.id].lifeUsed!=null?smart[d.id].lifeUsed+"%":"—"}}</strong>
          </div>
        </template>
        <p v-else class="disk-admin-smart-reason"><AlertTriangle :size="14"/>{{smartReason(smart[d.id])}}</p>
        <small>macOS 基础 SMART 状态（diskutil）：{{d.smart||"未知/不支持"}}</small>
        <p v-if="healthNote[d.id]" class="disk-admin-smart-reason">{{healthNote[d.id]}}</p>
        <div class="disk-health-history">
          <strong>按需健康历史（最近 30 天）</strong>
          <small>仅在手动读取 SMART 时记录。并非后台连续监控；相同 BSD 磁盘号不代表同一块硬盘。</small>
          <template v-if="(healthHistory[d.id]??[]).length">
            <svg v-if="temperaturePoints(d.id)" viewBox="0 0 300 86" role="img" aria-label="历史温度变化曲线">
              <path d="M 8 18 H 292 M 8 48 H 292 M 8 78 H 292" fill="none" stroke="currentColor" opacity=".15" stroke-dasharray="3 4"/>
              <polyline :points="temperaturePoints(d.id)" fill="none" stroke="var(--accent-primary)" stroke-width="2.5" stroke-linecap="round"/>
            </svg>
            <div v-for="(item,i) in [...healthHistory[d.id]].reverse().slice(0,4)" :key="i" class="disk-health-item">
              <span>{{new Date(item.timestamp*1000).toLocaleString()}}</span>
              <span>{{item.temperature!=null?item.temperature+" °C":"温度未知"}} · {{healthLabel(item.risk)}}</span>
            </div>
          </template>
          <small v-else>尚无历史样本，点击读取后才会记录；硬盘不支持 SMART 时也保留未知状态。</small>
        </div>
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
    <div v-if="volumes.length" class="disk-admin-volumes">
      <h4><Activity :size="15"/> 存储卷概览</h4>
      <div v-for="v in volumes" :key="v.mount" class="disk-admin-volume">
        <div class="disk-admin-volume-main">
          <strong>{{v.name}}</strong>
          <span>{{v.mount}} · {{v.filesystem||"未知格式"}} · {{v.readOnly?"只读":"可写"}}</span>
        </div>
        <div v-if="v.total>0" class="disk-admin-capacity disk-admin-volume-capacity">
          <div class="disk-admin-meter"><div :style="{width:vpct(v)+'%'}"></div></div>
          <span>已用 {{vpct(v)}}% · 可用 {{formatSize(v.free)}} / {{formatSize(v.total)}}</span>
        </div>
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
.disk-admin-smart-toggle{display:inline-flex;align-items:center;gap:6px;align-self:flex-start;margin-top:12px;border:1px solid var(--fluid-card-border);border-radius:11px;padding:7px 11px;background:var(--fluid-card-fill);font-size:12px;font-weight:600;color:var(--text-primary);cursor:pointer}
.disk-admin-smart-toggle:hover{background:var(--fluid-card-hover)}
.disk-admin-smart-toggle:disabled{opacity:.5;cursor:wait}
.disk-admin-smart{margin-top:11px;padding:12px 14px;border-radius:14px;background:var(--fluid-card-fill);display:grid;gap:8px}
.disk-admin-smart-grid{display:grid;grid-template-columns:auto 1fr;gap:6px 16px;font-size:12px}
.disk-admin-smart-grid span{color:var(--text-secondary)}
.disk-admin-smart-grid strong{color:var(--text-primary);font-weight:600;overflow-wrap:anywhere}
.disk-admin-smart-grid .smart-good{color:var(--accent-primary)}
.disk-admin-smart-grid .smart-bad{color:var(--danger, #d94f4f)}
.disk-admin-smart-reason{margin:0;display:flex;gap:7px;align-items:flex-start;font-size:12px;line-height:1.6;color:var(--text-secondary)}
.disk-admin-smart small{font-size:11px;color:var(--text-secondary)}
.disk-admin-health-title{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}
.disk-admin-health-title button{border:1px solid var(--fluid-card-border);border-radius:10px;background:var(--fluid-card-item-fill);color:var(--text-primary);padding:6px 10px;cursor:pointer;font-size:11px}
.disk-admin-health-title strong{font-size:12px;font-weight:650}
.disk-admin-health-title .smart-warning{color:#b87717}
.disk-admin-health-title .smart-bad{color:var(--danger,#d94f4f)}
.disk-health-history{display:grid;gap:7px;margin-top:10px;border-top:1px solid var(--fluid-card-border);padding-top:12px}
.disk-health-history>strong{font-size:12px}
.disk-health-history svg{width:100%;max-height:116px;background:var(--fluid-card-item-fill);border-radius:10px}
.disk-health-item{display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;font-size:11px;color:var(--text-secondary)}
.disk-admin-volumes{display:grid;gap:10px;margin-top:4px}
.disk-admin-volumes h4{display:flex;align-items:center;gap:8px;margin:0;font-size:13px;color:var(--text-primary)}
.disk-admin-volume{padding:12px 14px;border-radius:14px;border:1px solid var(--fluid-card-border);background:var(--fluid-card-item-fill);display:grid;gap:8px}
.disk-admin-volume-main{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
.disk-admin-volume-main strong{font-size:13px;color:var(--text-primary)}
.disk-admin-volume-main span{font-size:11px;color:var(--text-secondary)}
.disk-admin-volume-capacity{margin-top:0}
@media(max-width:600px){.disk-admin-main{flex-wrap:wrap}.disk-admin-status{margin-left:auto}.disk-admin-capacity{flex-wrap:wrap}}
</style>
