<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import {
  Activity, ArrowDownToLine, ArrowUpRight, Clapperboard, CopyCheck, Folder, HardDrive, Images,
  Monitor, RefreshCcw, Search, Server, ShieldCheck, Sparkles, Trash2, WifiOff,
} from "lucide-vue-next";
import RecentSearchPopover from "./RecentSearchPopover.vue";
import IsleCharts from "./IsleCharts.vue";
import { ISLE_CHART_COLORS } from "./isleChartsMath.ts";
import {
  buildHostDiskSegments,
  buildHostMemorySegments,
  buildQuotaSegments,
  type OverviewIdentity,
  type OverviewPending,
  type OverviewPersonalSpace,
  type OverviewSearch,
  type OverviewTelemetry,
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
  "select-history": [term: string];
  "delete-history": [term: string];
  "clear-history": [];
  "open-duplicates": [];
  "open-trash": [];
  "open-similar-photos": [];
  refresh: [];
  navigate: [page: "files" | "photos" | "cinema" | "downloads"];
  "open-account-settings": [];
  "open-pending": [];
}>();
const query = computed({
  get: () => props.search.query,
  set: (value: string) => emit("update:query", value),
});
const spotlight = computed({
  get: () => props.search.spotlight,
  set: (value: boolean) => emit("update:spotlight", value),
});
const searchBarRef = ref<HTMLElement | null>(null);
const searchInputRef = ref<HTMLInputElement | null>(null);
const searchFocused = ref(false);
const searchComposing = ref(false);
const recentOpen = computed(
  () => searchFocused.value && !props.search.query.trim() && (props.search.recentQueries?.length ?? 0) > 0,
);

const cpuSparkPoints = computed(() => {
  if (props.telemetry.error || !props.telemetry.stats) return [];
  if (props.telemetry.cpuHistory?.length) return props.telemetry.cpuHistory;
  return props.telemetry.cpu != null ? [props.telemetry.cpu] : [];
});

const memSparkPoints = computed(() => {
  if (props.telemetry.error || !props.telemetry.stats) return [];
  if (props.telemetry.memoryHistory?.length) return props.telemetry.memoryHistory;
  return props.telemetry.usedMemory != null ? [props.telemetry.usedMemory] : [];
});

const hostMemorySegments = computed(() =>
  props.telemetry.stats && !props.telemetry.error && props.telemetry.stats.memoryTotal > 0
    ? buildHostMemorySegments(props.telemetry.stats, props.telemetry.bytes)
    : [],
);

const hostDiskSegments = computed(() =>
  props.telemetry.stats && !props.telemetry.error && props.telemetry.stats.diskTotal > 0
    ? buildHostDiskSegments(props.telemetry.stats, props.telemetry.bytes)
    : [],
);

const personalQuotaCharts = computed(() => {
  const summary = props.personalSpace.summary;
  if (!summary) return [];
  const rootQuotas = summary.rootQuotas ?? [];
  const bounded = rootQuotas
    .filter((q) => q.quotaBytes !== null && q.quotaBytes > 0)
    .map((q) => {
      const quota = q.quotaBytes as number;
      const used = Math.min(100, Math.round(((q.accountedBytes + q.reservedBytes) / quota) * 100));
      return {
        key: `${q.rootID}:${q.rootGeneration}`,
        label: props.personalSpace.rootNames?.[q.rootID] || "存储位置",
        quotaBytes: quota,
        usedPercent: used,
        segments: buildQuotaSegments(q.accountedBytes, q.reservedBytes, quota, props.personalSpace.bytes),
      };
    });
  if (!bounded.length && summary.quotaBytes !== null && summary.quotaBytes > 0) {
    const quota = summary.quotaBytes;
    const used = Math.min(100, Math.round(((summary.accountedBytes + summary.reservedBytes) / quota) * 100));
    return [{
      key: "summary",
      label: "个人总空间额度",
      quotaBytes: quota,
      usedPercent: used,
      segments: buildQuotaSegments(summary.accountedBytes, summary.reservedBytes, quota, props.personalSpace.bytes),
    }];
  }
  return bounded;
});

function onSearchKeydown(event: KeyboardEvent) {
  if (event.key === "Enter") {
    if (searchComposing.value || event.isComposing) {
      event.preventDefault();
      return;
    }
    if (props.search.query.trim().length >= 1) {
      searchFocused.value = false;
      emit("search");
    }
    return;
  }
  if (event.key === "Escape") {
    if (searchComposing.value || event.isComposing) return;
    event.preventDefault();
    event.stopPropagation();
    searchFocused.value = false;
    if (props.search.searchingFiles) {
      emit("return-to-files");
    } else if (props.search.query) {
      emit("update:query", "");
    } else {
      searchInputRef.value?.blur();
    }
  }
}

function handleOutsideSearchPointerDown(event: PointerEvent) {
  const target = event.target as Node | null;
  if (searchFocused.value && searchBarRef.value && target && !searchBarRef.value.contains(target)) {
    searchFocused.value = false;
  }
}

onMounted(() => window.addEventListener("pointerdown", handleOutsideSearchPointerDown, true));
onUnmounted(() => window.removeEventListener("pointerdown", handleOutsideSearchPointerDown, true));
</script>

<template>
<div class="content isle-cascade">
  <!-- 1. Hero with warm welcoming & integrated Spotlight Search -->
  <div class="hero">
    <div class="hero-text">
      <p class="eyebrow">轻屿家庭数字空间</p>
      <h1 v-if="identity.isAdmin">管理你的家庭空间，<br /><span>查看这台 Mac 上的轻屿。</span></h1>
      <h1 v-else>欢迎回来，{{ identity.username }}。<br /><span>你的文件与回忆都在这里。</span></h1>
      <p class="hero-desc">{{identity.isAdmin?'查看本机状态、成员空间与家庭影音。':'浏览已授权的文件、相册与家庭影院。'}}</p>
      <div ref="searchBarRef" class="hero-search-bar" style="position: relative">
        <Search :size="16" class="search-icon" />
        <input
          ref="searchInputRef"
          v-model="query"
          maxlength="128"
          type="search"
          :placeholder="search.spotlight ? '搜索文件名或正文内容（支持单字/多词）…' : '搜索文件与文件夹（支持单字、空格多词）…'"
          aria-label="搜索共享目录中的文件和文件夹名称"
          @focus="searchFocused = true"
          @blur="searchFocused = false"
          @compositionstart="searchComposing = true"
          @compositionend="searchComposing = false"
          @keydown="onSearchKeydown"
        />
        <button type="button" :disabled="search.filesLoading || search.query.trim().length < 1" @click="searchFocused = false; emit('search')">
          {{ search.filesLoading&&search.searchingFiles ? "搜索中…" : "搜索共享目录" }}
        </button>
        <button v-if="search.searchingFiles" type="button" class="back-pill" @click="emit('return-to-files')">返回目录</button>
        <RecentSearchPopover
          :open="recentOpen"
          :items="search.recentQueries ?? []"
          @select="searchFocused = false; emit('select-history', $event)"
          @delete="emit('delete-history', $event)"
          @clear="emit('clear-history')"
        />
      </div>
      <div class="hero-actions">
        <label class="hero-status" title="未建立 Spotlight 索引时自动回退为文件名搜索">
          <input v-model="spotlight" type="checkbox" aria-label="使用 macOS Spotlight 搜索文件内容" />
          全文搜索
        </label>
        <span v-if="identity.isAdmin" class="hero-status"><span class="dot" :class="{ off: !!telemetry.error }"></span>{{ telemetry.error ? "连接异常" : "本机服务在线" }}</span>
        <span v-else class="hero-status"><ShieldCheck :size="14" /> 已授权个人空间</span>
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
  <div class="sanctuary-grid" :class="{ 'sanctuary-grid--four': !identity.isAdmin }">
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

    <button v-if="!identity.isAdmin" type="button" class="sanctuary-card" @click="emit('navigate', 'downloads')">
      <div class="sanctuary-icon downloads"><ArrowDownToLine :size="26" /></div>
      <div class="sanctuary-body">
        <div class="sanctuary-head">
          <h3>下载中心</h3>
          <ArrowUpRight :size="18" class="feature-arrow" />
        </div>
        <p>查看与管理个人离线下载任务及保存目录。</p>
        <div class="sanctuary-footer">
          <span class="sanctuary-chip">进度可见</span>
          <span class="sanctuary-action">打开下载 &rarr;</span>
        </div>
      </div>
    </button>
  </div>

  <!-- 3. Mac Sanctuary Vitality (Warm Consolidated Card) -->
  <section v-if="!identity.isAdmin" class="account-panel" aria-label="我的家庭空间" style="margin-top:22px">
    <div class="account-heading"><h2>我的空间</h2></div>
    <p>仅显示已授权的个人内容；硬盘离线时请联系管理员检查连接。</p>
    <p v-if="personalSpace.error" role="status">{{personalSpace.error}}</p>
    <div v-if="personalSpace.summary" class="account-row overview-personal-summary">
      <div style="flex:1; min-width:0;">
        <strong>{{personalSpace.summary.locations.length}} 个分类存储位置已配置</strong>
        <small>{{personalSpace.summary.rootQuotas?.length??0}} 个个人存储目录独立计额，普通成员默认每盘 100 GiB</small>
        <small v-for="q in personalSpace.summary.rootQuotas??[]" :key="q.rootID+':'+q.rootGeneration">
          {{personalSpace.rootNames?.[q.rootID] || "存储位置"}}：{{q.quotaBytes===null?'不限额':telemetry.bytes(q.quotaBytes)}} · 已用 {{telemetry.bytes(q.accountedBytes)}} · 预占 {{telemetry.bytes(q.reservedBytes)}}
        </small>
        <small>已计入 {{personalSpace.bytes(personalSpace.summary.accountedBytes)}} · 上传预占 {{personalSpace.bytes(personalSpace.summary.reservedBytes)}}</small>
        <small v-if="!personalSpace.summary.usageComplete">当前仅统计已接入的写入渠道（应用内已入账 / 传输预占），SMB 等直接写盘方式暂未计入，不能作为全部文件实际用量。</small>
        <div v-if="personalQuotaCharts.length" class="overview-quota-charts">
          <div v-for="qc in personalQuotaCharts" :key="qc.key" class="overview-quota-chart-card">
            <div class="overview-quota-chart-head">
              <strong>{{ qc.label }}</strong>
              <span class="overview-quota-total">限额 {{ personalSpace.bytes(qc.quotaBytes) }}</span>
            </div>
            <div class="overview-quota-chart-body">
              <IsleCharts
                kind="donut"
                :size="52"
                :stroke-width="5"
                :percent="qc.usedPercent"
                :color="qc.usedPercent >= 90 ? ISLE_CHART_COLORS.rose : ISLE_CHART_COLORS.blue"
                :aria-label="`${qc.label} 已用 ${qc.usedPercent}%`"
              />
              <IsleCharts
                kind="segmented"
                :segments="qc.segments"
                :total="qc.quotaBytes"
                :bar-height="10"
                compact-legend
                :aria-label="`${qc.label} 空间构成：已入账、传输预占与剩余额度`"
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    <div class="hero-actions">
      <button type="button" class="account-action" @click="emit('navigate', 'files')">打开我的文件</button>
      <button type="button" class="account-action" @click="emit('open-account-settings')">查看个人空间与账号</button>
      <button type="button" class="account-action" @click="emit('open-duplicates')"><CopyCheck :size="13" /> 重复文件清理</button>
      <button type="button" class="account-action" @click="emit('open-similar-photos')"><Sparkles :size="13" /> 相似照片瘦身</button>
      <button type="button" class="account-action" @click="emit('open-trash')"><Trash2 :size="13" /> 回收站</button>
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
          <div class="vitality-chip-top">
            <div>
              <span class="chip-label"><Activity :size="14" class="chip-icon violet" /> 处理器负载</span>
              <strong class="chip-val">{{ telemetry.stats && !telemetry.error ? (telemetry.cpu == null ? '—' : telemetry.percent(telemetry.cpu) + '%') : '—' }}</strong>
              <small class="chip-sub">{{ telemetry.stats && !telemetry.error ? (telemetry.stats.cpuCount ?? '—') + ' 个计算核心' : telemetry.error ? '状态暂未取得' : telemetry.polling ? '正在读取状态…' : '等待状态采样' }}</small>
            </div>
            <IsleCharts
              kind="donut"
              :size="50"
              :stroke-width="5"
              :percent="telemetry.stats && !telemetry.error && telemetry.cpu != null ? telemetry.percent(telemetry.cpu) : null"
              :color="ISLE_CHART_COLORS.purple"
              aria-label="处理器负载环形仪表"
            />
          </div>
          <IsleCharts
            v-if="cpuSparkPoints.length"
            kind="sparkline"
            :points="cpuSparkPoints"
            :min-bound="0"
            :max-bound="100"
            :spark-height="30"
            :color="ISLE_CHART_COLORS.purple"
            aria-label="处理器最近采样负载趋势"
          />
        </div>
        <div class="vitality-chip">
          <div class="vitality-chip-top">
            <div>
              <span class="chip-label"><Server :size="14" class="chip-icon blue" /> 内存使用</span>
              <strong class="chip-val">{{ telemetry.stats && !telemetry.error && telemetry.usedMemory != null ? telemetry.percent(telemetry.usedMemory) + '%' : '—' }}</strong>
              <small class="chip-sub">{{ telemetry.stats && !telemetry.error ? telemetry.bytes(telemetry.stats.memoryUsed) + ' 已用' : telemetry.error ? '状态暂未取得' : telemetry.polling ? '正在读取状态…' : '等待状态采样' }}</small>
            </div>
            <IsleCharts
              kind="donut"
              :size="50"
              :stroke-width="5"
              :percent="telemetry.stats && !telemetry.error && telemetry.usedMemory != null ? telemetry.percent(telemetry.usedMemory) : null"
              :color="ISLE_CHART_COLORS.blue"
              aria-label="统一内存占比仪表"
            />
          </div>
          <IsleCharts
            v-if="memSparkPoints.length"
            kind="sparkline"
            :points="memSparkPoints"
            :min-bound="0"
            :max-bound="100"
            :spark-height="30"
            :color="ISLE_CHART_COLORS.blue"
            aria-label="内存占用最近采样趋势"
          />
        </div>
        <div class="vitality-chip">
          <div class="vitality-chip-top">
            <div>
              <span class="chip-label"><HardDrive :size="14" class="chip-icon teal" /> 剩余空间</span>
              <strong class="chip-val">{{ telemetry.stats && !telemetry.error ? telemetry.bytes(telemetry.stats.diskFree) : telemetry.error ? '暂未取得空间数据' : telemetry.polling ? '读取中…' : '等待采样' }}</strong>
              <small class="chip-sub">Mac 当前存储设备</small>
            </div>
            <IsleCharts
              kind="donut"
              :size="50"
              :stroke-width="5"
              :percent="telemetry.stats && !telemetry.error && telemetry.usedDisk != null ? telemetry.percent(telemetry.usedDisk) : null"
              :color="ISLE_CHART_COLORS.teal"
              aria-label="系统存储磁盘占用环形仪表"
            />
          </div>
        </div>
        <div class="vitality-chip">
          <span class="chip-label"><Server :size="14" class="chip-icon blue" /> 文件服务内存</span>
          <strong class="chip-val">{{ telemetry.stats && !telemetry.error && telemetry.stats.coreRssBytes != null ? telemetry.bytes(telemetry.stats.coreRssBytes) : '—' }}</strong>
          <small class="chip-sub">{{ telemetry.stats && !telemetry.error && telemetry.stats.coreRssBytes != null ? '仅统计核心服务进程' : '暂时无法获取' }}</small>
        </div>
        <div v-if="telemetry.stats?.power?.available" class="vitality-chip">
          <span class="chip-label"><ShieldCheck :size="14" class="chip-icon teal" /> 供电与 UPS 守护</span>
          <strong class="chip-val">{{ telemetry.stats.power.onBattery ? '备用供电 ' + (telemetry.stats.power.percent ?? '—') + '%' : (telemetry.stats.power.upsPresent ? '市电 + UPS 就绪' : '市电直供') }}</strong>
          <small class="chip-sub">{{ telemetry.stats.power.onBattery ? (telemetry.stats.power.lowBattery ? '低电量保护已启动' : '已自动暂停后台高负载任务') : (telemetry.stats.power.deviceName || '断电联动守护已就绪') }}</small>
        </div>
      </div>

      <div v-if="hostMemorySegments.length" class="vitality-breakdown-grid">
        <div class="vitality-breakdown-item">
          <div class="spec-detail-top">
            <span>统一内存构成（总计 {{ telemetry.stats ? telemetry.bytes(telemetry.stats.memoryTotal) : '—' }}）</span>
            <span>{{ telemetry.usedMemory == null ? '—' : telemetry.percent(telemetry.usedMemory) + '% 已用' }}</span>
          </div>
          <IsleCharts
            kind="segmented"
            :segments="hostMemorySegments"
            :total="telemetry.stats?.memoryTotal ?? 0"
            :bar-height="10"
            compact-legend
            aria-label="轻屿服务内存、系统其他占用与可用内存比例"
          />
        </div>
        <div v-if="hostDiskSegments.length" class="vitality-breakdown-item">
          <div class="spec-detail-top">
            <span>宿主存储构成（总计 {{ telemetry.stats ? telemetry.bytes(telemetry.stats.diskTotal) : '—' }}）</span>
            <span>{{ telemetry.usedDisk == null ? '—' : telemetry.percent(telemetry.usedDisk) + '% 已用' }}</span>
          </div>
          <IsleCharts
            kind="segmented"
            :segments="hostDiskSegments"
            :total="telemetry.stats?.diskTotal ?? 0"
            :bar-height="10"
            compact-legend
            aria-label="宿主存储已用与可用空间比例"
          />
        </div>
      </div>

      <!-- Optional expandable detailed specs for power users -->
      <div v-if="telemetry.expanded" class="vitality-detail-grid">
        <div class="spec-detail-item">
          <div class="spec-detail-top"><span>CPU 利用率</span><span>{{ telemetry.cpu == null ? '—' : telemetry.percent(telemetry.cpu) + '%' }}</span></div>
          <IsleCharts
            v-if="telemetry.cpu != null"
            kind="segmented"
            :segments="[
              { key: 'cpu-busy', label: '计算负载', value: telemetry.percent(telemetry.cpu), color: ISLE_CHART_COLORS.purple },
              { key: 'cpu-idle', label: '空闲', value: Math.max(0, 100 - telemetry.percent(telemetry.cpu)), color: ISLE_CHART_COLORS.slate },
            ]"
            :total="100"
            :bar-height="8"
            compact-legend
            aria-label="CPU 负载比例"
          />
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

<style scoped>
.vitality-chip {
  justify-content: space-between;
  gap: 8px;
}
.vitality-chip-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}
.vitality-chip-top > div:first-child {
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}
.vitality-breakdown-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 14px 18px;
  padding-top: 14px;
  border-top: 1px solid color-mix(in srgb, var(--fluid-rim) 35%, transparent);
}
.vitality-breakdown-item {
  display: flex;
  flex-direction: column;
  gap: 7px;
  min-width: 0;
}
.overview-quota-charts {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
  gap: 10px;
  margin-top: 10px;
}
.overview-quota-chart-card {
  padding: 10px 12px;
  border-radius: 12px;
  border: 1px solid color-mix(in srgb, var(--fluid-card-border, rgba(142, 142, 147, 0.25)) 85%, transparent);
  background: color-mix(in srgb, var(--fluid-card-item-fill, rgba(255, 255, 255, 0.4)) 70%, transparent);
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.overview-quota-chart-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 8px;
  font-size: 12px;
}
.overview-quota-total {
  color: var(--text-tertiary);
}
.overview-quota-chart-body {
  display: flex;
  align-items: center;
  gap: 12px;
}
@media (max-width: 760px) {
  .vitality-breakdown-grid {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
