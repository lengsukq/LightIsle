<script setup lang="ts">
import { onMounted, ref, computed } from "vue";
import { Activity, Network, RefreshCcw, Download } from "lucide-vue-next";
import {describeUserFacingError} from "./userFacingError.js";

type Metric={
  timestamp:number;cpuPercent:number|null;memoryPercent:number;diskPercent:number;
  downloadBps:number|null;uploadBps:number|null;
};
type Interface={name:string;up:boolean;addresses:string[]};
type Diagnostics={
  interfaces:Interface[];gatewayIPv4:string;defaultInterface:string;
  requestTransport:string;observedAt:string;tips:string[];
};
const history=ref<Metric[]>([]);
const diagnostics=ref<Diagnostics|null>(null);
const loading=ref(false);
const error=ref("");
const limit=ref(180);
const lastSeen=computed(()=>history.value.length?new Date(history.value[history.value.length-1].timestamp*1000).toLocaleString():"尚未收集");

function polyline(key:"cpuPercent"|"memoryPercent"|"diskPercent"){
  const values=history.value;
  const count=values.length;
  if(count<2)return "";
  return values.map((p,i)=>{
    const raw=p[key];
    if(raw===null||!Number.isFinite(raw))return null;
    const x=10+(i/Math.max(count-1,1))*480;
    const y=110-Math.min(100,Math.max(0,raw))*0.95;
    return [x.toFixed(1),y.toFixed(1)].join(",");
  }).filter(Boolean).join(" ");
}
async function load(){
  if(loading.value)return;
  loading.value=true;error.value="";
  try{
    const [a,b]=await Promise.all([
      fetch("/api/v2/system/history?limit="+limit.value,{credentials:"same-origin",cache:"no-store"}),
      fetch("/api/v2/system/diagnostics",{credentials:"same-origin",cache:"no-store"})
    ]);
    if(!a.ok)throw new Error("HTTP "+a.status);
    if(!b.ok)throw new Error("HTTP "+b.status);
    const metrics=await a.json() as {samples:Metric[]};
    diagnostics.value=await b.json() as Diagnostics;
    history.value=Array.isArray(metrics.samples)?metrics.samples:[];
  }catch(e){error.value="无法读取本机诊断："+describeUserFacingError(e);}
  finally{loading.value=false;}
}
function exportReport(){
  if(!diagnostics.value)return;
  const report={exportedAt:new Date().toISOString(),scope:"管理员主动导出的本地诊断，不包含账号与文件内容",
    diagnostics:diagnostics.value,history:history.value};
  const url=URL.createObjectURL(new Blob([JSON.stringify(report,null,2)],{type:"application/json"}));
  const a=document.createElement("a");a.href=url;a.download="lightisle-diagnostics.json";a.click();
  setTimeout(()=>URL.revokeObjectURL(url),1000);
}
onMounted(()=>{void load();});
</script>

<template>
  <section class="account-panel ops-diagnostics">
    <div class="account-heading">
      <h3><Activity :size="17"/> 资源历史与网络诊断</h3>
      <div class="ops-diagnostic-actions">
        <select v-model.number="limit" aria-label="资源历史时间范围" :disabled="loading" @change="load">
          <option :value="180">最近 3 小时</option><option :value="720">最近 12 小时</option>
          <option :value="1440">最近 24 小时</option><option :value="2880">最近 48 小时</option>
        </select>
        <button type="button" class="refresh" :disabled="loading" @click="load"><RefreshCcw :size="15"/> 刷新</button>
        <button type="button" class="refresh" :disabled="!diagnostics" @click="exportReport"><Download :size="15"/> 导出诊断</button>
      </div>
    </div>
    <p class="footnote">Mac 每分钟记录一次 CPU、内存、数据盘和网速汇总；SQLite 最多保留 48 小时 / 2880 条。只有管理员能查看，不记录文件名、进程名或外部网站。</p>
    <p v-if="error" class="form-error" role="alert">{{error}} <button class="account-action" @click="load">重试</button></p>
    <p v-if="loading&&!history.length" role="status">正在读取历史指标…</p>
    <div v-if="history.length>1" class="ops-plot" role="img" aria-label="历史 CPU、内存和磁盘使用率百分比折线">
      <svg viewBox="0 0 500 130" preserveAspectRatio="none" aria-hidden="true">
        <path d="M 10 15 H 490 M 10 62.5 H 490 M 10 110 H 490" fill="none" stroke="currentColor" stroke-opacity=".15" stroke-dasharray="3 4"/>
        <polyline :points="polyline('cpuPercent')" fill="none" stroke="#0071E3" stroke-width="2.5" vector-effect="non-scaling-stroke"/>
        <polyline :points="polyline('memoryPercent')" fill="none" stroke="#34A853" stroke-width="2.5" vector-effect="non-scaling-stroke"/>
        <polyline :points="polyline('diskPercent')" fill="none" stroke="#E98A32" stroke-width="2.5" vector-effect="non-scaling-stroke"/>
      </svg>
    </div>
    <p v-else class="footnote">历史样本不足两条。保持 Mac App 运行，稍后会看到曲线。</p>
    <p class="ops-legend"><span>● CPU</span><span>● 内存</span><span>● 数据盘</span><small>最近采样：{{lastSeen}}</small></p>
    <div v-if="diagnostics" class="ops-network">
      <h4><Network :size="17"/> Mac 本机网络</h4>
      <p class="footnote">当前请求：{{diagnostics.requestTransport}} · 默认网关：{{diagnostics.gatewayIPv4||"未检测到"}} · 默认出口：{{diagnostics.defaultInterface||"未检测到"}}</p>
      <div v-for="item in diagnostics.interfaces" :key="item.name" class="account-row">
        <div><strong>{{item.name}} · {{item.up?"已启用":"未启用"}}</strong><small>{{item.addresses.length?item.addresses.join("、"):"没有分配非链路本地 IP 地址"}}</small></div>
      </div>
      <p v-if="!diagnostics.interfaces.length" class="footnote">没有发现可报告的以太网/网络桥接口。</p>
      <p v-for="tip in diagnostics.tips" :key="tip" class="footnote">{{tip}}</p>
    </div>
  </section>
</template>

<style scoped>
.ops-diagnostics{margin-bottom:20px}.ops-diagnostics h3,.ops-network h4{display:flex;align-items:center;gap:7px}
.ops-diagnostic-actions{display:flex;gap:7px;flex-wrap:wrap}.ops-diagnostic-actions select{border-radius:12px;border:1px solid var(--stroke-subtle,#ddd);padding:7px;color:inherit;background:var(--surface-base,#fff)}
.ops-plot{height:184px;max-width:100%;padding:15px 12px 8px;border:1px solid var(--stroke-subtle,#ddd);background:var(--surface-base,#fff);border-radius:16px}
.ops-plot svg{height:100%;width:100%}.ops-legend{display:flex;gap:17px;flex-wrap:wrap;font-size:12px}
.ops-legend span:nth-child(1){color:#0071E3}.ops-legend span:nth-child(2){color:#34A853}.ops-legend span:nth-child(3){color:#E98A32}.ops-network{margin-top:24px}
@media(max-width:650px){.ops-diagnostic-actions{width:100%}.ops-plot{height:145px}}
</style>
