<script setup lang="ts">
import { onMounted, ref } from "vue";
import { RefreshCcw, Trash2, Clock, Bell, FileTerminal, ScrollText } from "lucide-vue-next";

type Task = {
  id:string; name:string; description?:string; enabled:boolean; running:boolean; entry:string;
  lastError?:string; nextRun?:number; schedule:{cron:string;timezone:string};
  notification:{events?:string[];channels?:string[]};
};
type Run={id:number;startedAt:number;finishedAt:number;state:string;exitCode:number;output:string};
const tasks=ref<Task[]>([]);
const channelIDs=ref<string[]>([]);
const busy=ref(false);
const error=ref("");
const notice=ref("");
const selected=ref("");
const runs=ref<Run[]>([]);
const editing=ref<string|null>(null);
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
async function copyAgentPrompt(){
 try{
  if(navigator.clipboard && window.isSecureContext){
   await navigator.clipboard.writeText(agentPrompt);
  }else{
   const editor=document.createElement("textarea");
   editor.value=agentPrompt;
   editor.readOnly=true;
   editor.style.position="fixed";
   editor.style.left="-9999px";
   document.body.appendChild(editor);
   editor.select();
   const copied=document.execCommand("copy");
   editor.remove();
   if(!copied)throw Error("copy_not_available");
  }
  notice.value="已复制任务目录、JSON 协议和 HTML 邮件模板指令，请粘贴给你本地使用的 AI Agent。";
 }catch{
  error.value="浏览器无法写入剪贴板。请从项目 docs/AUTOMATION_AGENT.md 复制完整指令。";
 }
}
async function request(url:string, options:RequestInit={}) {
 const response=await fetch(url,{credentials:"same-origin",cache:"no-store",...options,headers:{"X-LightIsle-Request":"1",...(options.headers||{})}});
 if(!response.ok) throw new Error((await response.json().catch(()=>({error:"请求失败"}))).error||"HTTP "+response.status);
 return response.json();
}
async function reload(refresh=true) {
 busy.value=true;error.value="";notice.value="";
 try {
  const response=await request(refresh?"/api/v1/automation/refresh":"/api/v1/automation/tasks",refresh?{method:"POST"}:{});
  tasks.value=response.tasks||[];
  channelIDs.value=(await request("/api/v1/automation/channels")).channels||[];
 }catch(e){error.value="读取脚本失败："+String(e)}
 finally{busy.value=false}
}
async function loadRuns(id:string){
 selected.value=id;runs.value=[];error.value="";
 try{runs.value=(await request("/api/v1/automation/tasks/"+encodeURIComponent(id)+"/runs")).runs||[]}
 catch(e){error.value="无法读取日志："+String(e)}
}
function edit(task:Task){
 editing.value=task.id;
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
  const response=await request("/api/v1/automation/tasks/"+encodeURIComponent(editing.value),{
   method:"PUT",headers:{"Content-Type":"application/json"},
   body:JSON.stringify({enabled:enabled.value,schedule:{cron:cron.value,timezone:timezone.value},
    notification:{events:events.value,channels:channels.value}})
  });
  tasks.value=response.tasks||[];
  notice.value="任务设置已保存；脚本代码和环境变量没有被改动。";editing.value=null;
 }catch(e){error.value="保存失败："+String(e)}
 finally{busy.value=false}
}
async function toggle(task:Task){
 busy.value=true;error.value="";
 try{
  const res=await request("/api/v1/automation/tasks/"+encodeURIComponent(task.id),{
   method:"PUT",headers:{"Content-Type":"application/json"},
   body:JSON.stringify({enabled:!task.enabled,schedule:task.schedule,notification:task.notification||{}})
  });
  tasks.value=res.tasks||[];
 }catch(e){error.value=String(e)}
 finally{busy.value=false}
}
async function remove(task:Task){
 if(!confirm("确定删除“"+task.name+"”及其本地脚本目录吗？该操作不可恢复。"))return;
 busy.value=true;error.value="";
 try{
  await request("/api/v1/automation/tasks/"+encodeURIComponent(task.id),{method:"DELETE"});
  tasks.value=tasks.value.filter(t=>t.id!==task.id);
  notice.value="脚本目录已删除。";
  if(selected.value===task.id){selected.value="";runs.value=[]}
 }catch(e){error.value="删除失败："+String(e)}
 finally{busy.value=false}
}
function flip(list:string[],value:string){
 return list.includes(value)?list.filter(v=>v!==value):[...list,value];
}
onMounted(()=>{void reload(true)});
</script>

<template>
  <section class="automation">
    <header class="auto-header">
      <div><h2>自动化</h2><p>脚本由你在 Mac 本地创建。轻屿只负责定时调度，不提供编辑器或 AI Agent。</p></div>
      <button type="button" class="auto-btn" :disabled="busy" @click="reload(true)"><RefreshCcw :size="15"/> {{busy?"正在刷新":"刷新脚本"}}</button>
    </header>
    <div class="auto-actions"><button type="button" class="auto-btn" @click="copyAgentPrompt">复制给本地 Agent 的脚本规范</button><small>完整规范见项目 docs/AUTOMATION_AGENT.md</small></div>
    <p class="auto-hint">任务位置：LightIsle 应用数据目录 / automation / scripts / 任务ID / task.json。首次进入和点击刷新时读取磁盘。运行环境由用户自行安装。</p>
    <p v-if="error" class="auto-error" role="alert">{{error}}</p>
    <p v-if="notice" class="auto-hint" role="status">{{notice}}</p>
    <p v-if="tasks.length===0&&!busy" class="auto-empty">还没有脚本。请在本机创建任务文件夹和 task.json，然后点击刷新。</p>
    <div v-for="task in tasks" :key="task.id" class="auto-card">
      <div class="auto-task">
        <div class="auto-icon"><FileTerminal :size="21"/></div>
        <div class="auto-main">
          <strong>{{task.name}}</strong>
          <small>{{task.id}} · {{task.entry}}</small>
          <small v-if="task.lastError" class="auto-error">{{task.lastError}}</small>
          <small v-else>{{task.running?"运行中":task.enabled?"已启用":"已暂停"}} · {{task.schedule?.cron||"无 Cron"}} · {{task.schedule?.timezone||"未设置时区"}}</small>
        </div>
      </div>
      <div class="auto-actions">
        <button class="auto-btn" type="button" :disabled="busy||!!task.lastError" @click="toggle(task)">{{task.enabled?"关闭":"启用"}}</button>
        <button class="auto-btn" type="button" :disabled="busy||!!task.lastError" @click="edit(task)"><Clock :size="14"/> Cron</button>
        <button class="auto-btn" type="button" :disabled="busy" @click="loadRuns(task.id)"><ScrollText :size="14"/> 日志</button>
        <button class="auto-btn danger" type="button" :disabled="busy||task.running" @click="remove(task)"><Trash2 :size="14"/> 删除</button>
      </div>
      <div v-if="editing===task.id" class="auto-editor">
        <p>这里只修改任务启停、Cron 和通知；不会编辑脚本代码或 env.json。</p>
        <div class="auto-inputs"><label>五段 Cron<input v-model.trim="cron" placeholder="0 2 * * *"/></label><label>时区<input v-model.trim="timezone" placeholder="Asia/Shanghai"/></label></div>
        <label><input v-model="enabled" type="checkbox"/> 启用此任务</label>
        <div class="auto-checks"><strong><Bell :size="15"/> 通知事件</strong>
          <label v-for="e in [{id:'failure',name:'执行失败'},{id:'timeout',name:'执行超时'},{id:'success',name:'执行成功'}]" :key="e.id">
            <input type="checkbox" :checked="events.includes(e.id)" @change="events=flip(events,e.id)"/>{{e.name}}
          </label>
        </div>
        <div class="auto-checks"><strong>通知渠道</strong>
          <label v-for="ch in available" :key="ch.id"><input type="checkbox" :disabled="!channelIDs.includes(ch.id)" :checked="channels.includes(ch.id)" @change="channels=flip(channels,ch.id)"/>{{ch.label}}<small v-if="!channelIDs.includes(ch.id)">未配置</small></label>
        </div>
        <div class="auto-actions"><button type="button" class="auto-btn primary" :disabled="busy" @click="save">保存设置</button><button type="button" class="auto-btn" @click="editing=null">取消</button></div>
      </div>
      <div v-if="selected===task.id" class="auto-logs">
        <div class="auto-actions"><strong>最近 30 次执行</strong><button class="auto-btn" @click="loadRuns(task.id)">刷新日志</button><button class="auto-btn" @click="selected=''">收起</button></div>
        <p v-if="runs.length===0">暂无执行记录；定时触发后会显示退出码和输出。</p>
        <details v-for="run in runs" :key="run.id">
          <summary>{{new Date(run.startedAt*1000).toLocaleString()}} · {{run.state}} · 退出码 {{run.exitCode}}</summary>
          <pre>{{run.output||"（没有标准输出）"}}</pre>
        </details>
      </div>
    </div>
    <p class="auto-hint">脚本以运行 LightIsle 的 Mac 用户权限执行，具备真实文件访问能力。只运行你信任的本地脚本。</p>
  </section>
</template>
<style scoped>
.automation{display:grid;gap:16px;max-width:1100px}
.auto-header{display:flex;justify-content:space-between;align-items:center;gap:16px}
.auto-header h2{font-size:24px;margin:0}.auto-header p,.auto-hint,.auto-empty{color:var(--text-secondary,#768093);font-size:13px;line-height:1.6}
.auto-card{border:1px solid var(--border,rgba(130,145,160,.2));border-radius:19px;padding:18px;display:grid;gap:13px;background:var(--surface,rgba(130,140,155,.06))}
.auto-task{display:flex;align-items:center;gap:12px}.auto-icon{border-radius:12px;padding:10px;background:rgba(114,137,172,.12)}
.auto-main{display:grid;gap:3px;min-width:0}.auto-main small{font-size:12px;color:var(--text-secondary,#768093)}
.auto-actions{display:flex;flex-wrap:wrap;align-items:center;gap:9px}
.auto-btn{display:inline-flex;align-items:center;gap:6px;border:1px solid rgba(130,145,160,.3);background:transparent;color:inherit;border-radius:10px;padding:8px 12px;cursor:pointer;font:inherit;font-size:13px}
.auto-btn:disabled{opacity:.45;cursor:not-allowed}.auto-btn.primary{background:#427ad9;color:white}.auto-btn.danger{color:#ca5360}
.auto-error{color:#c55d63;font-size:13px}.auto-editor,.auto-logs{padding:14px;border-radius:14px;background:rgba(125,137,150,.07);display:grid;gap:12px}
.auto-editor p{font-size:12px;margin:0}.auto-inputs{display:flex;flex-wrap:wrap;gap:10px}.auto-inputs label{display:grid;gap:5px;font-size:12px}.auto-inputs input{padding:8px;border-radius:8px;border:1px solid rgba(130,145,160,.4);background:transparent;color:inherit}
.auto-checks{display:flex;gap:12px;flex-wrap:wrap;font-size:13px}.auto-checks strong{display:flex;align-items:center;gap:5px}.auto-checks label{display:flex;align-items:center;gap:5px}.auto-checks small{opacity:.6}
.auto-logs details{border-top:1px solid rgba(125,135,145,.25);padding-top:8px}.auto-logs summary{cursor:pointer;font-size:12px}.auto-logs pre{overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;max-height:260px;font-size:12px}
@media(max-width:600px){.auto-header{align-items:flex-start;flex-direction:column}.auto-inputs{display:grid}.auto-btn{font-size:12px}}
</style>
