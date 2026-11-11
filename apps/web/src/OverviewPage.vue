<script setup lang="ts">
import { computed } from "vue";
import {
  Activity, ArrowUpRight, Clapperboard, Folder, HardDrive, Images,
  Monitor, RefreshCcw, Search, Server, ShieldCheck, WifiOff,
} from "lucide-vue-next";
import type {
  OverviewIdentity, OverviewPending, OverviewPersonalSpace, OverviewSearch, OverviewTelemetry,
} from "./overviewPageModels.ts";

const props = defineProps<{
  identity: OverviewIdentity;
  search: OverviewSearch;
  telemetry: OverviewTelemetry;
  personalSpace: OverviewPersonalSpace;
  pending: OverviewPending;
}>();
const emit = defineEmits<{
  "update:query": [value: string];
  "update:spotlight": [value: boolean];
  "update:expanded": [value: boolean];
  search: [];
  "return-to-files": [];
  refresh: [];
  navigate: [page: "files" | "photos" | "cinema"];
  "open-account-settings": [];
  "open-pending": [];
}>();
const query = computed({
  get: () => props.search.query,
  set: (value: string) => emit("update:query", value.trim()),
});
const spotlight = computed({
  get: () => props.search.spotlight,
  set: (value: boolean) => emit("update:spotlight", value),
});
</script>

<template>
<div class="content isle-cascade">
  <!-- 1. Hero with warm welcoming & integrated Spotlight Search -->
  <div class="hero">
    <div class="hero-text">
      <p class="eyebrow">LIGHTISLE SANCTUARY</p>
      <h1 v-if="identity.isAdmin">管理你的家庭空间，<br /><span>查看这台 Mac 上的轻屿。</span></h1>
      <h1 v-else>欢迎回来，{{ identity.username }}。<br /><span>你的文件与回忆都在这里。</span></h1>
      <p class="hero-desc">{{identity.isAdmin?'查看本机状态、成员空间与家庭影音。':'浏览已授权的文件、相册与家庭影院。'}}</p>
      <div class="hero-search-bar">
        <Search :size="16" class="search-icon" />
        <input
          v-model.trim="query"
          maxlength="128"
          type="search"
          :placeholder="search.spotlight ? '搜索文件名或正文内容…' : '搜索文件与文件夹…'"
          aria-label="搜索共享目录中的文件和文件夹名称"
          @keydown.enter="emit('search')"
        />
        <button type="button" :disabled="search.filesLoading || search.query.length < 2" @click="emit('search')">
          {{ search.filesLoading&&search.searchingFiles ? "搜索中…" : "搜索共享目录" }}
        </button>
        <button v-if="search.searchingFiles" type="button" class="back-pill" @click="emit('return-to-files')">返回目录</button>
      </div>
      <div class="hero-actions">
        <label class="hero-status" title="未建立 Spotlight 索引时自动回退为文件名搜索">
          <input v-model="spotlight" type="checkbox" aria-label="使用 macOS Spotlight 搜索文件内容" />
          全文搜索
        </label>
        <span class="hero-status"><span class="dot" :class="{ off: !!telemetry.error }"></span>{{ telemetry.error ? "连接异常" : "本机服务在线" }}</span>
      </div>
    </div>
    <div class="hero-art" aria-hidden="true">
      <div class="orb orb-a"></div><div class="orb orb-b"></div><div class="orb orb-c"></div>
      <div class="hero-glass"><img src="/brand-icon.svg" alt="" class="hero-brand-image" /></div>
    </div>
  </div>

  <!-- 2. Personal Sanctuaries (Content First!) -->
  <div class="section-heading apps-heading">
    <div><h2>数字生活空间</h2><p>跨设备浏览本地文件、相册与家庭影音。</p></div>
    <span class="planned-tag">本地存储</span>
  </div>
  <div class="sanctuary-grid">
    <button type="button" class="sanctuary-card" @click="emit('navigate', 'files')">
      <div class="sanctuary-icon file"><Folder :size="26" /></div>
      <div class="sanctuary-body">
        <div class="sanctuary-head">
          <h3>私人文件</h3>
          <ArrowUpRight :size="18" class="feature-arrow" />
        </div>
        <p>浏览、上传与分享已授权目录文件。</p>
        <div class="sanctuary-footer">
          <span class="sanctuary-chip">即时存取</span>
          <span class="sanctuary-action">浏览文件 &rarr;</span>
        </div>
      </div>
    </button>

    <button type="button" class="sanctuary-card" @click="emit('navigate', 'photos')">
      <div class="sanctuary-icon photos"><Images :size="26" /></div>
      <div class="sanctuary-body">
        <div class="sanctuary-head">
          <h3>时光相册</h3>
          <ArrowUpRight :size="18" class="feature-arrow" />
        </div>
        <p>按时间线、相册与足迹地图查看原片。</p>
        <div class="sanctuary-footer">
          <span class="sanctuary-chip">原画保存</span>
          <span class="sanctuary-action">翻阅相册 &rarr;</span>
        </div>
      </div>
    </button>

    <button type="button" class="sanctuary-card" @click="emit('navigate', 'cinema')">
      <div class="sanctuary-icon cinema"><Clapperboard :size="26" /></div>
      <div class="sanctuary-body">
        <div class="sanctuary-head">
          <h3>私人影院</h3>
          <ArrowUpRight :size="18" class="feature-arrow" />
        </div>
        <p>海报墙浏览、外挂字幕与跨端续播。</p>
        <div class="sanctuary-footer">
          <span class="sanctuary-chip">无损串流</span>
          <span class="sanctuary-action">开启放映 &rarr;</span>
        </div>
      </div>
    </button>
  </div>

  <!-- 3. Mac Sanctuary Vitality (Warm Consolidated Card) -->
  <section v-if="!identity.isAdmin" class="account-panel" aria-label="我的家庭空间" style="margin-top:22px">
    <div class="account-heading"><h2>我的空间</h2></div>
    <p>仅显示已授权的个人内容；硬盘离线时请联系管理员检查连接。</p>
    <p v-if="personalSpace.error" role="status">{{personalSpace.error}}</p>
    <div v-if="personalSpace.summary" class="account-row">
      <div>
        <strong>{{personalSpace.summary.locations.length}} 个分类存储位置已配置</strong>
        <small>{{personalSpace.summary.rootQuotas?.length??0}} 块存储根独立计费，普通成员默认每盘 100 GiB</small>
        <small v-for="q in personalSpace.summary.rootQuotas??[]" :key="q.rootID+':'+q.rootGeneration">
          硬盘 {{q.rootID.slice(0,6)}}：{{q.quotaBytes===null?'不限额':telemetry.bytes(q.quotaBytes)}} · 已用 {{telemetry.bytes(q.accountedBytes)}} · 预占 {{telemetry.bytes(q.reservedBytes)}}
        </small>
        <small>已计入 {{personalSpace.bytes(personalSpace.summary.accountedBytes)}} · 上传预占 {{personalSpace.bytes(personalSpace.summary.reservedBytes)}}</small>
        <small v-if="!personalSpace.summary.usageComplete">当前仅统计已接入的写入渠道，不能作为全部文件实际用量。</small>
      </div>
    </div>
    <div class="hero-actions">
      <button type="button" class="account-action" @click="emit('navigate', 'files')">打开我的文件</button>
      <button type="button" class="account-action" @click="emit('open-account-settings')">查看个人空间与账号</button>
    </div>
  </section>

  <section
    v-if="identity.isAdmin"
    class="account-panel overview-pending-panel"
    :class="{ 'is-attention': pending.offlineCount > 0 || pending.failedTasks > 0 || !!pending.rootsError || !!pending.tasksError }"
    aria-label="待处理数据概况"
  >
    <div class="account-heading">
      <h2>待处理数据</h2>
      <button type="button" class="account-action" @click="emit('open-pending')">打开任务中心</button>
    </div>
    <div class="overview-pending-items">
      <p v-if="pending.rootsError" role="alert">硬盘状态读取失败，概况不完整：{{pending.rootsError}}</p>
      <p v-else-if="!pending.rootsKnown">正在确认已登记硬盘，待处理概况尚不完整。</p>
      <p v-else-if="pending.offlineCount">{{pending.offlineCount}} 块已登记硬盘离线，请检查原硬盘连接。</p>
      <p v-else>当前没有发现离线的已登记硬盘。</p>
      <p v-if="pending.tasksError" role="alert">{{pending.tasksError}}；当前硬盘的任务概况不完整。</p>
      <p v-else-if="pending.tasksLoading&&!pending.tasksLoaded">正在读取当前硬盘任务状态…</p>
      <p v-else-if="pending.tasksLoaded">{{pending.rootName||'当前硬盘'}}：{{pending.failedTasks?`${pending.failedTasks} 项任务未完成`:'没有已发现的失败任务'}}。</p>
      <p v-else>当前硬盘任务状态尚未读取。</p>
    </div>
    <p class="footnote">缺失媒体与上传残留请打开任务中心检查；此概况不代表所有数据已核对。</p>
  </section>

  <div v-if="identity.isAdmin" class="section-heading">
    <div><h2>轻屿运行体征</h2><p>实时查看宿主 Mac 负载、内存与磁盘余量。</p></div>
    <button class="refresh" type="button" @click="emit('refresh')" :disabled="telemetry.polling">
      <RefreshCcw :size="15" :class="{ spinning: telemetry.polling }" /> 刷新状态
    </button>
  </div>
  <div v-if="identity.isAdmin&&telemetry.error" class="error-notice"><WifiOff :size="17" /> 无法读取系统状态：{{ telemetry.error }}。请确认 Mac App 仍在运行。</div>

  <section v-if="identity.isAdmin" class="vitality-container">
    <div class="vitality-card">
      <div class="vitality-header">
        <div class="vitality-host">
          <div class="host-icon-bubble"><Monitor :size="22" /></div>
          <div>
            <strong>{{ telemetry.stats?.architecture ? 'Apple Silicon Mac (' + telemetry.stats.architecture + ')' : '宿主 Mac 设备' }}</strong>
            <small>{{ telemetry.stats && !telemetry.error ? '正在运行 · 设备状态已更新' : telemetry.error ? '暂时无法获取状态' : telemetry.polling ? '正在读取状态…' : '等待刷新' }}</small>
          </div>
        </div>
        <button type="button" class="toggle-specs-btn" @click="emit('update:expanded', !telemetry.expanded)">
          {{ telemetry.expanded ? "收起详细指标" : "查看硬件详情" }}
        </button>
      </div>

      <div class="vitality-metrics-row">
        <div class="vitality-chip">
          <span class="chip-label"><Activity :size="14" class="chip-icon violet" /> 处理器负载</span>
          <strong class="chip-val">{{ telemetry.stats && !telemetry.error ? (telemetry.cpu == null ? '—' : telemetry.percent(telemetry.cpu) + '%') : '—' }}</strong>
          <small class="chip-sub">{{ telemetry.stats && !telemetry.error ? (telemetry.stats.cpuCount ?? '—') + ' 个计算核心' : telemetry.error ? '状态暂未取得' : telemetry.polling ? '正在读取状态…' : '等待状态采样' }}</small>
        </div>
        <div class="vitality-chip">
          <span class="chip-label"><Server :size="14" class="chip-icon blue" /> 内存使用</span>
          <strong class="chip-val">{{ telemetry.stats && !telemetry.error && telemetry.usedMemory != null ? telemetry.percent(telemetry.usedMemory) + '%' : '—' }}</strong>
          <small class="chip-sub">{{ telemetry.stats && !telemetry.error ? telemetry.bytes(telemetry.stats.memoryUsed) + ' 已用' : telemetry.error ? '状态暂未取得' : telemetry.polling ? '正在读取状态…' : '等待状态采样' }}</small>
        </div>
        <div class="vitality-chip">
          <span class="chip-label"><HardDrive :size="14" class="chip-icon teal" /> 剩余空间</span>
          <strong class="chip-val">{{ telemetry.stats && !telemetry.error ? telemetry.bytes(telemetry.stats.diskFree) : telemetry.error ? '暂未取得空间数据' : telemetry.polling ? '读取中…' : '等待采样' }}</strong>
          <small class="chip-sub">Mac 当前存储设备</small>
        </div>
        <div class="vitality-chip">
          <span class="chip-label"><Server :size="14" class="chip-icon blue" /> 文件服务内存</span>
          <strong class="chip-val">{{ telemetry.stats && !telemetry.error && telemetry.stats.coreRssBytes != null ? telemetry.bytes(telemetry.stats.coreRssBytes) : '—' }}</strong>
          <small class="chip-sub">{{ telemetry.stats && !telemetry.error && telemetry.stats.coreRssBytes != null ? '仅统计核心服务进程' : '暂时无法获取' }}</small>
        </div>
      </div>

      <!-- Optional expandable detailed tracks for power users -->
      <div v-if="telemetry.expanded" class="vitality-detail-grid">
        <div class="spec-detail-item">
          <div class="spec-detail-top"><span>CPU 利用率</span><span>{{ telemetry.cpu == null ? '—' : telemetry.percent(telemetry.cpu) + '%' }}</span></div>
          <div class="progress-track"><div class="progress-bar purple" :style="{ width: telemetry.cpu == null ? '0' : telemetry.percent(telemetry.cpu) + '%' }"></div></div>
        </div>
        <div class="spec-detail-item">
          <div class="spec-detail-top"><span>统一内存占用</span><span>{{ telemetry.stats && !telemetry.error ? telemetry.bytes(telemetry.stats.memoryUsed) + ' / ' + telemetry.bytes(telemetry.stats.memoryTotal) : '—' }}</span></div>
          <div class="progress-track"><div class="progress-bar bright-blue" :style="{ width: telemetry.usedMemory == null ? '0' : telemetry.percent(telemetry.usedMemory) + '%' }"></div></div>
        </div>
        <div class="spec-detail-item">
          <div class="spec-detail-top"><span>存储磁盘空间</span><span>{{ telemetry.usedDisk == null ? '—' : telemetry.percent(telemetry.usedDisk) + '%' }}</span></div>
          <div class="progress-track"><div class="progress-bar aqua" :style="{ width: telemetry.usedDisk == null ? '0' : telemetry.percent(telemetry.usedDisk) + '%' }"></div></div>
        </div>
        <div class="spec-detail-item">
          <div class="spec-detail-top"><span>磁盘活动</span><span>{{ telemetry.diskActivity ?? '空闲' }}</span></div>
        </div>
      </div>
    </div>
  </section>

  <div class="footnote"><ShieldCheck :size="15" /> <span>所有原片与文件均保存在本地 Mac。</span></div>
</div>
</template>
