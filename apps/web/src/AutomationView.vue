<script setup lang="ts">
import { ref, watch } from "vue";
import { RefreshCcw, Trash2, Clock, Bell, FileTerminal, ScrollText } from "lucide-vue-next";
import { apiRequest } from "./apiClient.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { copyTextToClipboard } from "./clipboard.ts";
import { requestConfirm } from "./useConfirmDialog.ts";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";

type Task = {
  id:string; name:string; description?:string; enabled:boolean; running:boolean; entry:string;
  lastError?:string; nextRun?:number; revision?:string; lastRun?:RunSummary; schedule:{cron:string;timezone:string};
  notification:{events?:string[];channels?:string[]};
};
type RunSummary={startedAt:number;finishedAt:number;state:string;exitCode:number};
type Run=RunSummary & {id:number;output:string;deliveries?:Record<string,string>};
const props=defineProps<{active:boolean}>();
const tasks=ref<Task[]>([]);
const channelIDs=ref<string[]>([]);
const busy=ref(false);
const error=ref("");
const notice=ref("");
const selected=ref("");
const runs=ref<Run[]>([]);
const editing=ref<string|null>(null);
const revision=ref<string>();
const cron=ref("");
const timezone=ref("");
const enabled=ref(false);
const events=ref<string[]>([]);
const channels=ref<string[]>([]);
const available=[{id:"bark",label:"Bark"},{id:"webhook",label:"Webhook"},{id:"email",label:"邮件"},{id:"wecom",label:"企业微信"},{id:"dingtalk",label:"钉钉"}];
const agentPrompt = `你是用户本地使用的外部 AI Agent，请在当前 Mac 上为 LightIsle 创建或修改自动化脚本。先确认 LightIsle 实际 data-dir，不要猜测路径。
一个任务目录为 automation/scripts/<task-id>/，其中 task.json 需要：
{"schemaVersion":1,"id":"daily-report","name":"日报","enabled":false,"entry":"run.sh","args":[],"envFile":"env.json","schedule":{"cron":"0 8 * * *","timezone":"Asia/Shanghai"},"timeoutSeconds":600,"notification":{"events":["failure","timeout"],"channels":["email"],"email":{"mode":"content","file":"email.html","subject":"轻屿自动化报告"}}}
请按实际需求改写 ID、Cron、名称和脚本（首行正确 Shebang，脚本 chmod 700）。依赖和解释器用户自行准备，LightIsle 不安装依赖或提供代码编辑器。
邮件支持 mode=builtin（品牌边框模板，不需要 file）、mode=content（自定义 HTML 片段替换内置边框中间内容）和 mode=custom（自定义完整 HTML 邮件，彻底替换内置模板）。content/custom 的 HTML 由 Agent 写到任务目录 email.html，task.json 用 notification.email.file 引用。
HTML 安全占位符只有 {{task.name}}、{{task.id}}、{{run.state}}、{{run.message}}、{{run.finishedAt}}、{{run.exitCode}}。请不要输出密钥。env.json 可包含环境变量但应 chmod 600；通知 SMTP、企业微信、钉钉、Bark 和 Webhook 凭据只在 Mac 管理端 Keychain 配置，不可写入 task.json。
脚本执行退出码 0 表示成功；其他表示失败。默认 enabled=false，最后告诉用户到 Web 自动化页点击刷新并手动启用。请只改本地任务文件，不修改 LightIsle 源代码，也不调用 Agent 插件或任务注册 API。`;
async function copyAgentPrompt() {
  if (await copyTextToClipboard(agentPrompt)) {
    notice.value = "已复制任务目录、JSON 协议和 HTML 邮件模板指令，请粘贴给你本地使用的 AI Agent。";
  } else {
    error.value = "浏览器无法写入剪贴板。请从项目 docs/AUTOMATION_AGENT.md 复制完整指令。";
  }
}
async function request(url:string, options:RequestInit={}) {
 return apiRequest<Record<string, any>>(url, options);
}
async function reload(refresh=true) {
 if(busy.value)return;
 busy.value=true;error.value="";notice.value="";
 try {
  const response=await request(refresh?"/api/v2/automation/refresh":"/api/v2/automation/tasks",refresh?{method:"POST"}:{});
  tasks.value=response.tasks||[];
  channelIDs.value=(await request("/api/v2/automation/channels")).channels||[];
 }catch(e){error.value="读取脚本失败："+describeUserFacingError(e)}
 finally{busy.value=false}
}
async function loadRuns(id:string){
 selected.value=id;runs.value=[];error.value="";
 try{
  const response=await request("/api/v2/automation/tasks/"+encodeURIComponent(id)+"/runs");
  if(selected.value===id)runs.value=response.runs||[];
 }catch(e){if(selected.value===id)error.value="无法读取日志："+describeUserFacingError(e)}
}
function edit(task:Task){
 editing.value=task.id;
 revision.value=task.revision;
 cron.value=task.schedule.cron;
 timezone.value=task.schedule.timezone;
 enabled.value=task.enabled;
 channels.value=[...(task.notification?.channels||[])];
 events.value=[...(task.notification?.events||["failure","timeout"])];
}
async function save(){
 if(!editing.value)return;
 busy.value=true;error.value="";
 try {
  const response=await request("/api/v2/automation/tasks/"+encodeURIComponent(editing.value),{
   method:"PUT",headers:{"Content-Type":"application/json"},
   body:JSON.stringify({enabled:enabled.value,revision:revision.value,schedule:{cron:cron.value,timezone:timezone.value},
    notification:{events:events.value,channels:channels.value}})
  });
  tasks.value=response.tasks||[];
  notice.value="任务设置已保存；脚本代码和环境变量没有被改动。";editing.value=null;
 }catch(e){error.value="保存失败："+describeUserFacingError(e)}
 finally{busy.value=false}
}
async function toggle(task:Task){
 busy.value=true;error.value="";
 try{
  const res=await request("/api/v2/automation/tasks/"+encodeURIComponent(task.id),{
   method:"PUT",headers:{"Content-Type":"application/json"},
   body:JSON.stringify({enabled:!task.enabled,revision:task.revision,schedule:task.schedule,notification:task.notification||{}})
  });
  tasks.value=res.tasks||[];
 }catch(e){error.value=describeUserFacingError(e)}
 finally{busy.value=false}
}
async function remove(task:Task){
 const confirmed = await requestConfirm({
  title: `删除自动化任务「${task.name}」`,
  message: `确定删除「${task.name}」吗？这将永久删除 Mac 上的 automation/scripts/${task.id}/ 及其中的文件。`,
  confirmText: "确认删除",
  variant: "danger",
 });
 if(!confirmed)return;
 busy.value=true;error.value="";
 try{
  await request("/api/v2/automation/tasks/"+encodeURIComponent(task.id),{method:"DELETE"});
  tasks.value=tasks.value.filter(t=>t.id!==task.id);
  notice.value="脚本目录已删除。";
  if(selected.value===task.id){selected.value="";runs.value=[]}
 }catch(e){error.value="删除失败："+describeUserFacingError(e)}
 finally{busy.value=false}
}
function flip(list:string[],value:string){
 return list.includes(value)?list.filter(v=>v!==value):[...list,value];
}
const stateLabels:Record<string,string>={running:"运行中",success:"成功",failure:"失败",timeout:"超时",interrupted:"中断",skipped:"已跳过"};
const deliveryLabels:Record<string,string>={
 queued:"等待发送",sent:"已发送",not_configured:"渠道未配置",backoff:"渠道退避中",queue_full:"发送队列已满",
 interrupted:"发送结果未确认",authentication_failed:"认证失败",tls_failed:"加密连接失败",connection_failed:"连接失败",delivery_failed:"发送失败",
};
function localTime(seconds:number){return new Date(seconds*1000).toLocaleString()}
watch(()=>props.active, active=>{if(active)void reload(true)}, {immediate:true});
</script>

<template>
  <section class="automation">
    <header class="auto-header">
      <div><h2>自动化</h2><p>定时调度本机脚本，管理通知与运行日志。</p></div>
      <div class="auto-actions">
        <IsleButton variant="glass" @click="copyAgentPrompt">复制脚本规范</IsleButton>
        <IsleButton variant="primary" :disabled="busy" @click="reload(true)">
          <template #icon><RefreshCcw :size="15" :class="{ spinning: busy }"/></template>
          {{busy?"正在刷新…":"刷新脚本"}}
        </IsleButton>
      </div>
    </header>
    <IsleBanner v-if="error" type="error" compact :message="error" />
    <IsleBanner v-if="notice" type="success" compact :message="notice" />
    <IsleEmpty
      v-if="tasks.length === 0 && !busy && !error"
      card
      :icon="FileTerminal"
      title="暂无自动化脚本"
    >
      在应用数据目录 <code>automation/scripts/&lt;任务ID&gt;/task.json</code> 创建任务后点击「刷新脚本」（完整协议见 <code>docs/AUTOMATION_AGENT.md</code>）。
    </IsleEmpty>
    <div v-for="task in tasks" :key="task.id" class="auto-card">
      <div class="auto-task">
        <div class="auto-icon"><FileTerminal :size="21"/></div>
        <div class="auto-main">
          <strong>{{task.name}}</strong>
          <small>{{task.id}} · {{task.entry}}</small>
          <small v-if="task.lastError" class="auto-error">{{describeUserFacingError(task.lastError)}}</small>
          <small v-else>{{task.running?"运行中":task.enabled?"已启用":"已暂停"}} · {{task.schedule?.cron||"无 Cron"}} · {{task.schedule?.timezone||"未设置时区"}}</small>
          <small v-if="task.nextRun">下次执行 {{localTime(task.nextRun)}}（本机时间）</small>
          <small v-if="task.lastRun">上次结果 {{stateLabels[task.lastRun.state]||task.lastRun.state}} · {{localTime(task.lastRun.finishedAt)}}</small>
        </div>
      </div>
      <div class="auto-actions">
        <IsleButton variant="glass" size="sm" :disabled="busy||!!task.lastError" @click="toggle(task)">{{task.enabled?"关闭":"启用"}}</IsleButton>
        <IsleButton variant="glass" size="sm" :disabled="busy||!!task.lastError" @click="edit(task)"><template #icon><Clock :size="14"/></template>Cron</IsleButton>
        <IsleButton variant="glass" size="sm" :disabled="busy" @click="loadRuns(task.id)"><template #icon><ScrollText :size="14"/></template>日志</IsleButton>
        <IsleButton variant="danger" size="sm" :disabled="busy||task.running" @click="remove(task)"><template #icon><Trash2 :size="14"/></template>删除</IsleButton>
      </div>
      <div v-if="editing===task.id" class="auto-editor">
        <p>这里只修改任务启停、Cron 和通知；不会编辑脚本代码或 env.json。</p>
        <div class="auto-inputs"><label>五段 Cron<input v-model.trim="cron" placeholder="0 2 * * *"/></label><label>时区<input v-model.trim="timezone" placeholder="Asia/Shanghai"/></label></div>
        <label><input v-model="enabled" type="checkbox" class="isle-checkbox"/> 启用此任务</label>
        <div class="auto-checks"><strong><Bell :size="15"/> 通知事件</strong>
          <label v-for="e in [{id:'failure',name:'执行失败'},{id:'timeout',name:'执行超时'},{id:'success',name:'执行成功'}]" :key="e.id">
            <input type="checkbox" class="isle-checkbox" :checked="events.includes(e.id)" @change="events=flip(events,e.id)"/>{{e.name}}
          </label>
        </div>
        <div class="auto-checks"><strong>通知渠道</strong>
          <label v-for="ch in available" :key="ch.id"><input type="checkbox" class="isle-checkbox" :disabled="!channelIDs.includes(ch.id)" :checked="channels.includes(ch.id)" @change="channels=flip(channels,ch.id)"/>{{ch.label}}<small v-if="!channelIDs.includes(ch.id)">未配置</small></label>
        </div>
        <div class="auto-actions">
          <IsleButton variant="primary" size="sm" :disabled="busy" @click="save">保存设置</IsleButton>
          <IsleButton variant="glass" size="sm" @click="editing=null">取消</IsleButton>
        </div>
      </div>
      <div v-if="selected===task.id" class="auto-logs">
        <div class="auto-actions">
          <strong>最近 30 次执行</strong>
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="loadRuns(task.id)">刷新日志</IsleButton>
          <IsleButton variant="glass" size="sm" @click="selected=''">收起</IsleButton>
        </div>
        <p v-if="runs.length===0">暂无执行记录；定时触发后会显示退出码和输出。</p>
        <details v-for="run in runs" :key="run.id">
          <summary>{{localTime(run.startedAt)}} · {{stateLabels[run.state]||run.state}} <span v-if="run.exitCode>=0"> · 退出码 {{run.exitCode}}</span></summary>
          <pre>{{run.output||"（没有标准输出）"}}</pre>
          <p v-for="(status, channel) in run.deliveries" :key="channel">
            {{available.find(item=>item.id===channel)?.label||channel}} · {{deliveryLabels[status]||status}}
          </p>
        </details>
      </div>
    </div>
    <IsleBanner type="info" compact message="脚本以当前 Mac 用户权限执行，请仅运行你信任的本地脚本。" />
  </section>
</template>
<style scoped>
.automation{display:grid;gap:16px;max-width:1100px}
.auto-header{display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap}
.auto-header h2{font-size:22px;margin:0;font-weight:750}.auto-header p{color:var(--text-secondary);font-size:13px;line-height:1.6;margin:4px 0 0}
.auto-card{border:1px solid var(--fluid-card-border);border-radius:20px;padding:20px;display:grid;gap:14px;background:var(--fluid-card-fill);box-shadow:var(--fluid-card-shadow);transition:transform var(--motion-fast) var(--motion-spring),opacity var(--motion-fast) ease}
.auto-card:hover{transform:translateY(-2px);box-shadow:var(--fluid-hover-shadow)}
.auto-task{display:flex;align-items:center;gap:14px}.auto-icon{border-radius:14px;padding:10px;background:color-mix(in srgb,var(--accent-primary) 12%,transparent);color:var(--accent-primary)}
.auto-main{display:grid;gap:3px;min-width:0}.auto-main strong{font-size:15px;color:var(--text-primary);font-weight:650}.auto-main small{font-size:12px;color:var(--text-secondary)}
.auto-actions{display:flex;flex-wrap:wrap;align-items:center;gap:10px}
.auto-error{color:var(--error);font-size:13px}.auto-editor,.auto-logs{padding:14px 0 0 0;border-top:1px solid var(--stroke-subtle);background:transparent;display:grid;gap:12px}
.auto-editor p{font-size:12px;margin:0}.auto-inputs{display:flex;flex-wrap:wrap;gap:12px}.auto-inputs label{display:grid;gap:5px;font-size:12px;color:var(--text-secondary)}.auto-inputs input{padding:8px 12px;border-radius:9px;border:1px solid var(--stroke-subtle);background:var(--surface-base);color:inherit}
.auto-checks{display:flex;gap:14px;flex-wrap:wrap;font-size:13px}.auto-checks strong{display:flex;align-items:center;gap:5px}.auto-checks label{display:flex;align-items:center;gap:5px}.auto-checks small{opacity:.6}
.auto-logs details{border-top:1px solid var(--fluid-card-border);padding-top:10px}.auto-logs summary{cursor:pointer;font-size:12.5px;font-weight:600}.auto-logs pre{overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;max-height:260px;font-size:12px;border-radius:10px;padding:10px;background:rgba(0,0,0,0.18)}
@media(max-width:600px){.auto-header{align-items:flex-start;flex-direction:column}.auto-inputs{display:grid}}
@media(prefers-reduced-motion:reduce){.auto-card{transition:none}}
</style>
