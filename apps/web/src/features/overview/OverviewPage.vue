<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import {
  Activity, ArrowDownToLine, ArrowUpRight, ChevronDown, Clapperboard, CopyCheck, Cpu, Folder, HardDrive, Images,
  LayoutDashboard, Monitor, RefreshCcw, Router, Search, Server, ShieldCheck, Sparkles, Trash2, Wallet, WifiOff, Wrench,
} from "lucide-vue-next";
import RecentSearchPopover from "../../components/ui/RecentSearchPopover.vue";
import IsleCharts from "../../components/ui/IsleCharts.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import FamilyBoardCarousel from "./FamilyBoardCarousel.vue";
import { ISLE_CHART_COLORS } from "../../components/ui/isleChartsMath.ts";
import {
  buildHostDiskSegments,
  buildHostMemorySegments,
  buildQuotaSegments,
  filterHomeLaunchableApps,
  homeAppBadge,
  homeAppCategoryKey,
  homeAppCategoryLabel,
  isHomeAppReady,
  type OverviewApps,
  type OverviewIdentity,
  type OverviewPending,
  type OverviewPersonalSpace,
  type OverviewSearch,
  type OverviewTelemetry,
} from "./overviewPageModels.ts";
import type { PublicAppItem } from "../../types/appsCenter.ts";

const props = defineProps<{
  identity: OverviewIdentity;
  search: OverviewSearch;
  telemetry: OverviewTelemetry;
  personalSpace: OverviewPersonalSpace;
  pending: OverviewPending;
  apps?: OverviewApps;
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
  "open-apps-center": [];
  "open-app": [app: PublicAppItem];
  "refresh-apps": [];
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
const moreMenuRef = ref<HTMLDetailsElement | null>(null);
const searchFocused = ref(false);
const searchComposing = ref(false);
const recentOpen = computed(
  () => searchFocused.value && !props.search.query.trim() && (props.search.recentQueries?.length ?? 0) > 0,
);
const appsState = computed<OverviewApps>(() => props.apps ?? { items: [], loading: false, error: "" });
const launchableApps = computed(() => filterHomeLaunchableApps(appsState.value.items));
const showHomeAppsSection = computed(
  () => props.identity.isAdmin || launchableApps.value.length > 0 || Boolean(appsState.value.error),
);
const failedAppIcons = ref<Set<string>>(new Set());
function markAppIconFailed(appId: string) {
  const next = new Set(failedAppIcons.value);
  next.add(appId);
  failedAppIcons.value = next;
}

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

function onSearchFocusOut(event: FocusEvent) {
  const related = event.relatedTarget as Node | null;
  if (!related || !searchBarRef.value?.contains(related)) {
    searchFocused.value = false;
  }
}

function closeMoreMenu() {
  if (moreMenuRef.value) moreMenuRef.value.open = false;
}

function handleOutsidePointerDown(event: PointerEvent) {
  const target = event.target as Node | null;
  if (searchFocused.value && searchBarRef.value && target && !searchBarRef.value.contains(target)) {
    searchFocused.value = false;
  }
  if (moreMenuRef.value?.open && target && !moreMenuRef.value.contains(target)) {
    moreMenuRef.value.open = false;
  }
}

function handleGlobalKeydown(event: KeyboardEvent) {
  if (event.key === "Escape" && moreMenuRef.value?.open) {
    moreMenuRef.value.open = false;
  }
}

onMounted(() => {
  window.addEventListener("pointerdown", handleOutsidePointerDown, true);
  window.addEventListener("keydown", handleGlobalKeydown);
});
onUnmounted(() => {
  window.removeEventListener("pointerdown", handleOutsidePointerDown, true);
  window.removeEventListener("keydown", handleGlobalKeydown);
});
</script>

<template>
<div class="content isle-cascade">
  <!-- 1. Open Editorial Workspace Hero with Integrated Capsule Spotlight Search -->
  <div class="hero">
    <div class="hero-text">
      <div class="hero-headline-row">
        <h1 v-if="identity.isAdmin">管理你的家庭空间</h1>
        <h1 v-else>欢迎回来，{{ identity.username }}</h1>
        <span v-if="identity.isAdmin" class="hero-status" :class="{ 'is-offline': !!telemetry.error }">
          <span class="dot" :class="{ off: !!telemetry.error }"></span>
          {{ telemetry.error ? "连接异常" : "本机服务在线" }}
        </span>
        <span v-else class="hero-status"><ShieldCheck :size="13" /> 已授权个人空间</span>
      </div>
      <p class="hero-subline">{{ identity.isAdmin ? "查看这台 Mac 上的轻屿。" : "你的文件与回忆都在这里。" }}</p>
      <div ref="searchBarRef" class="hero-search-bar" @focusout="onSearchFocusOut">
        <Search :size="16" class="search-icon" />
        <input
          ref="searchInputRef"
          v-model="query"
          maxlength="128"
          type="search"
          :placeholder="search.spotlight ? '搜索文件名或正文内容…' : '搜索文件与文件夹…'"
          aria-label="搜索共享目录中的文件和文件夹名称"
          @focus="searchFocused = true"
          @compositionstart="searchComposing = true"
          @compositionend="searchComposing = false"
          @keydown="onSearchKeydown"
        />
        <label class="file-spotlight-pill" :class="{ active: spotlight }" title="未建立 Spotlight 索引时自动回退为文件名搜索">
          <input v-model="spotlight" type="checkbox" class="file-spotlight-checkbox" aria-label="使用 macOS Spotlight 搜索文件内容" />
          <span class="spotlight-switch-track" aria-hidden="true"><span class="spotlight-switch-thumb" /></span>
          <span>全文</span>
        </label>
        <button type="button" :disabled="search.filesLoading || search.query.trim().length < 1" @click="searchFocused = false; emit('search')">
          {{ search.filesLoading&&search.searchingFiles ? "搜索中…" : (identity.isAdmin ? "搜索共享目录" : "搜索我的空间") }}
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
    </div>
  </div>

  <!-- 2. Personal Sanctuaries -->
  <IslePageHeader title="数字生活空间" compact style="margin-top: 12px">
    <template #actions>
      <IsleBadge variant="accent" size="sm">本地原片直连</IsleBadge>
    </template>
  </IslePageHeader>
  <div class="sanctuary-grid" :class="{ 'sanctuary-grid--four': identity.isAdmin }">
    <button type="button" class="sanctuary-card" @click="emit('navigate', 'files')">
      <div class="sanctuary-top">
        <div class="sanctuary-icon file"><Folder :size="20" /></div>
        <ArrowUpRight :size="15" class="feature-arrow" />
      </div>
      <div class="sanctuary-body">
        <h3>私人文件</h3>
        <p>浏览、上传与限时外链分享。</p>
        <div class="sanctuary-footer">
          <span class="sanctuary-chip">即时存取</span>
        </div>
      </div>
    </button>

    <button type="button" class="sanctuary-card" @click="emit('navigate', 'photos')">
      <div class="sanctuary-top">
        <div class="sanctuary-icon photos"><Images :size="20" /></div>
        <ArrowUpRight :size="15" class="feature-arrow" />
      </div>
      <div class="sanctuary-body">
        <h3>时光相册</h3>
        <p>时间线、人物相册与足迹地图。</p>
        <div class="sanctuary-footer">
          <span class="sanctuary-chip">原画保存</span>
        </div>
      </div>
    </button>

    <button type="button" class="sanctuary-card" @click="emit('navigate', 'cinema')">
      <div class="sanctuary-top">
        <div class="sanctuary-icon cinema"><Clapperboard :size="20" /></div>
        <ArrowUpRight :size="15" class="feature-arrow" />
      </div>
      <div class="sanctuary-body">
        <h3>私人影院</h3>
        <p>海报墙、外挂字幕与进度续播。</p>
        <div class="sanctuary-footer">
          <span class="sanctuary-chip">无损串流</span>
        </div>
      </div>
    </button>

    <button v-if="identity.isAdmin" type="button" class="sanctuary-card" @click="emit('navigate', 'downloads')">
      <div class="sanctuary-top">
        <div class="sanctuary-icon downloads"><ArrowDownToLine :size="20" /></div>
        <ArrowUpRight :size="15" class="feature-arrow" />
      </div>
      <div class="sanctuary-body">
        <h3>下载中心</h3>
        <p>离线链接与磁力下载管理。</p>
        <div class="sanctuary-footer">
          <span class="sanctuary-chip">管理员可新建</span>
        </div>
      </div>
    </button>
  </div>

  <!-- 2.4 Family Message Board (Swipeable Carousel) -->
  <FamilyBoardCarousel :is-admin="identity.isAdmin" :username="identity.username" />

  <!-- 2.5 Home Light-Apps Tile Launcher -->
  <section v-if="showHomeAppsSection" class="home-apps-section" aria-label="家庭轻应用">
    <IslePageHeader title="家庭轻应用" compact>
      <template #actions>
        <IsleButton variant="glass" size="sm" @click="emit('open-apps-center')">
          <template #icon><LayoutDashboard :size="14" /></template>
          {{ identity.isAdmin ? "管理应用中心" : "全部应用" }}
        </IsleButton>
      </template>
    </IslePageHeader>

    <div v-if="appsState.error" class="home-apps-status" role="status">
      <span>{{ appsState.error }}</span>
      <button type="button" class="toggle-specs-btn" @click="emit('refresh-apps')">重新加载</button>
    </div>

    <div v-if="launchableApps.length > 0" class="home-apps-grid">
      <button
        v-for="app in launchableApps"
        :key="app.id"
        type="button"
        class="home-app-tile"
        :class="{ 'is-warning': !isHomeAppReady(app) }"
        @click="emit('open-app', app)"
      >
        <div class="home-app-icon" :class="'cat-' + homeAppCategoryKey(app.category)">
          <img
            v-if="app.iconUrl && !failedAppIcons.has(app.id)"
            :src="app.iconUrl"
            :alt="app.name + ' 图标'"
            class="home-app-icon-img"
            loading="lazy"
            decoding="async"
            @error="markAppIconFailed(app.id)"
          />
          <Router v-else-if="homeAppCategoryKey(app.category) === 'network'" :size="18" />
          <Clapperboard v-else-if="homeAppCategoryKey(app.category) === 'media'" :size="18" />
          <Wallet v-else-if="homeAppCategoryKey(app.category) === 'finance'" :size="18" />
          <Wrench v-else-if="homeAppCategoryKey(app.category) === 'utility'" :size="18" />
          <Activity v-else-if="homeAppCategoryKey(app.category) === 'system' || homeAppCategoryKey(app.category) === 'automation'" :size="18" />
          <Cpu v-else :size="18" />
        </div>
        <div class="home-app-meta">
          <div class="home-app-title-row">
            <h3>{{ app.name }}</h3>
            <span class="home-app-status-inline" :class="'tone-' + homeAppBadge(app, identity.isAdmin).tone">
              <span class="home-app-dot" aria-hidden="true" />
              <span>{{ homeAppBadge(app, identity.isAdmin).text }}</span>
            </span>
          </div>
          <p class="home-app-desc">{{ app.description || "轻屿本地家庭轻应用" }}</p>
        </div>
        <ArrowUpRight :size="15" class="home-app-arrow" />
      </button>
    </div>

    <button
      v-else-if="identity.isAdmin && !appsState.loading && !appsState.error"
      type="button"
      class="home-apps-guide-tile"
      @click="emit('open-apps-center')"
    >
      <div class="home-app-icon cat-default"><Sparkles :size="18" /></div>
      <div class="home-apps-guide-copy">
        <h3>安装或添加家庭轻应用</h3>
        <p>内置零依赖精选模板，进入应用中心即可一键部署。</p>
      </div>
      <span class="sanctuary-action">进入应用中心 &rarr;</span>
    </button>
  </section>

  <!-- 3. Member Space Summary -->
  <section v-if="!identity.isAdmin" class="account-panel" aria-label="我的家庭空间" style="margin-top:16px">
    <div class="account-heading">
      <h2>我的空间</h2>
      <div class="overview-member-head-actions">
        <button type="button" class="account-action" @click="emit('navigate', 'files')">打开我的文件</button>
        <button type="button" class="account-action" @click="emit('open-account-settings')">空间与账号</button>
        <details ref="moreMenuRef" class="overview-more-menu">
          <summary aria-label="空间整理工具" title="空间整理工具">···</summary>
          <div class="overview-more-popover">
            <button type="button" @click="closeMoreMenu(); emit('open-duplicates')"><CopyCheck :size="13" /> 重复文件清理</button>
            <button type="button" @click="closeMoreMenu(); emit('open-similar-photos')"><Sparkles :size="13" /> 相似照片瘦身</button>
            <button type="button" @click="closeMoreMenu(); emit('open-trash')"><Trash2 :size="13" /> 回收站</button>
          </div>
        </details>
      </div>
    </div>
    <p v-if="personalSpace.error" role="status">{{personalSpace.error}}</p>
    <div v-if="personalSpace.summary" class="account-row overview-personal-summary">
      <div style="flex:1; min-width:0;">
        <strong>{{personalSpace.summary.locations.length}} 个分类存储位置 · {{personalSpace.summary.rootQuotas?.length??0}} 个目录独立计额</strong>
        <template v-for="q in personalSpace.summary.rootQuotas??[]" :key="q.rootID+':'+q.rootGeneration">
          <small v-if="q.quotaBytes === null || q.quotaBytes <= 0">
            {{personalSpace.rootNames?.[q.rootID] || "存储位置"}}：不限额 · 已用 {{telemetry.bytes(q.accountedBytes)}} · 预占 {{telemetry.bytes(q.reservedBytes)}}
          </small>
        </template>
        <small>已计入 {{personalSpace.bytes(personalSpace.summary.accountedBytes)}} · 上传预占 {{personalSpace.bytes(personalSpace.summary.reservedBytes)}}</small>
        <small v-if="!personalSpace.summary.usageComplete">仅统计应用内入账与传输预占，SMB 等直接写盘暂未计入。</small>
        <div v-if="personalQuotaCharts.length" class="overview-quota-charts">
          <div v-for="qc in personalQuotaCharts" :key="qc.key" class="overview-quota-chart-card">
            <div class="overview-quota-chart-head">
              <strong>{{ qc.label }}</strong>
              <span class="overview-quota-total">限额 {{ personalSpace.bytes(qc.quotaBytes) }}</span>
            </div>
            <div class="overview-quota-chart-body">
              <IsleCharts
                kind="donut"
                :size="46"
                :stroke-width="4.5"
                :percent="qc.usedPercent"
                :color="qc.usedPercent >= 90 ? ISLE_CHART_COLORS.rose : ISLE_CHART_COLORS.blue"
                :aria-label="`${qc.label} 已用 ${qc.usedPercent}%`"
              />
              <IsleCharts
                kind="segmented"
                :segments="qc.segments"
                :total="qc.quotaBytes"
                :bar-height="8"
                compact-legend
                :aria-label="`${qc.label} 空间构成：已入账、传输预占与剩余额度`"
              />
            </div>
          </div>
        </div>
      </div>
    </div>
  </section>

  <!-- 4. Mac Host Status (Balanced Horizontal Summary Band + Animated Disclosure Drawer) -->
  <IslePageHeader v-if="identity.isAdmin" title="Mac 运行状态" compact>
    <template #actions>
      <IsleButton variant="glass" size="sm" :disabled="telemetry.polling" @click="emit('refresh')">
        <template #icon><RefreshCcw :size="15" :class="{ spinning: telemetry.polling }" /></template>
        刷新状态
      </IsleButton>
    </template>
  </IslePageHeader>
  <div v-if="identity.isAdmin&&telemetry.error" class="error-notice"><WifiOff :size="17" /> 无法读取系统状态：{{ telemetry.error }}。请确认 Mac App 仍在运行。</div>

  <section v-if="identity.isAdmin" class="vitality-container">
    <div class="vitality-card">
      <div class="vitality-header">
        <div class="vitality-host">
          <div class="host-icon-bubble"><Monitor :size="18" /></div>
          <div class="vitality-host-copy">
            <div class="vitality-host-title-row">
              <strong>{{ telemetry.stats?.architecture ? 'Apple Silicon Mac (' + telemetry.stats.architecture + ')' : 'Mac 主机' }}</strong>
              <span
                v-if="telemetry.stats?.power?.available"
                class="vitality-power-pill"
                :class="{ 'is-battery': telemetry.stats.power.onBattery, 'is-low': telemetry.stats.power.lowBattery }"
                :title="telemetry.stats.power.deviceName || (telemetry.stats.power.onBattery ? '当前使用电池供电' : '电源连接正常')"
              >
                <ShieldCheck :size="12" />
                <span>
                  {{
                    telemetry.stats.power.onBattery
                      ? '电池 ' + (telemetry.stats.power.percent ?? '—') + '%'
                      : (telemetry.stats.power.upsPresent ? '市电 + UPS' : '市电直供')
                  }}
                </span>
              </span>
            </div>
            <small>{{ telemetry.stats && !telemetry.error ? '运行平稳 · 实时监测' : telemetry.error ? '暂时无法获取状态' : telemetry.polling ? '正在读取状态…' : '暂未读取' }}</small>
          </div>
        </div>
        <button
          type="button"
          class="toggle-specs-btn"
          :aria-expanded="telemetry.expanded"
          @click="emit('update:expanded', !telemetry.expanded)"
        >
          <span>{{ telemetry.expanded ? "收起详情" : "硬件详情" }}</span>
          <ChevronDown :size="14" class="specs-chevron" :class="{ 'is-open': telemetry.expanded }" />
        </button>
      </div>

      <div class="vitality-metrics-row">
        <div class="vitality-chip">
          <div class="vitality-chip-top">
            <span class="chip-label"><Activity :size="13" class="chip-icon violet" /> 处理器负载</span>
            <strong class="chip-val">{{ telemetry.stats && !telemetry.error ? (telemetry.cpu == null ? '—' : telemetry.percent(telemetry.cpu) + '%') : '—' }}</strong>
          </div>
          <div class="vitality-chip-viz">
            <IsleCharts
              v-if="cpuSparkPoints.length"
              kind="sparkline"
              :points="cpuSparkPoints"
              :min-bound="0"
              :max-bound="100"
              :spark-height="20"
              :color="ISLE_CHART_COLORS.purple"
              aria-label="处理器最近负载趋势"
            />
            <div v-else class="vitality-slim-track" aria-hidden="true">
              <span
                class="vitality-slim-fill is-violet"
                :style="{ width: (telemetry.stats && !telemetry.error && telemetry.cpu != null ? telemetry.percent(telemetry.cpu) : 0) + '%' }"
              />
            </div>
          </div>
          <small class="chip-sub">{{ telemetry.stats && !telemetry.error ? (telemetry.stats.cpuCount ?? '—') + ' 核心' : telemetry.error ? '状态暂未取得' : '—' }}</small>
        </div>

        <div class="vitality-chip">
          <div class="vitality-chip-top">
            <span class="chip-label"><Server :size="13" class="chip-icon blue" /> 内存使用</span>
            <strong class="chip-val">{{ telemetry.stats && !telemetry.error && telemetry.usedMemory != null ? telemetry.percent(telemetry.usedMemory) + '%' : '—' }}</strong>
          </div>
          <div class="vitality-chip-viz">
            <IsleCharts
              v-if="memSparkPoints.length"
              kind="sparkline"
              :points="memSparkPoints"
              :min-bound="0"
              :max-bound="100"
              :spark-height="20"
              :color="ISLE_CHART_COLORS.blue"
              aria-label="内存占用最近趋势"
            />
            <div v-else class="vitality-slim-track" aria-hidden="true">
              <span
                class="vitality-slim-fill is-blue"
                :style="{ width: (telemetry.stats && !telemetry.error && telemetry.usedMemory != null ? telemetry.percent(telemetry.usedMemory) : 0) + '%' }"
              />
            </div>
          </div>
          <small class="chip-sub">
            {{
              telemetry.stats && !telemetry.error
                ? telemetry.bytes(telemetry.stats.memoryUsed) + ' / ' + telemetry.bytes(telemetry.stats.memoryTotal)
                : telemetry.error ? '状态暂未取得' : '—'
            }}
          </small>
        </div>

        <div class="vitality-chip">
          <div class="vitality-chip-top">
            <span class="chip-label"><HardDrive :size="13" class="chip-icon teal" /> 剩余空间</span>
            <strong class="chip-val">{{ telemetry.stats && !telemetry.error ? telemetry.bytes(telemetry.stats.diskFree) : telemetry.error ? '暂未取得' : '—' }}</strong>
          </div>
          <div class="vitality-chip-viz">
            <div class="vitality-slim-track" aria-hidden="true">
              <span
                class="vitality-slim-fill is-teal"
                :style="{ width: (telemetry.stats && !telemetry.error && telemetry.usedDisk != null ? telemetry.percent(telemetry.usedDisk) : 0) + '%' }"
              />
            </div>
          </div>
          <small class="chip-sub">
            {{
              telemetry.stats && !telemetry.error && telemetry.usedDisk != null
                ? '已用 ' + telemetry.percent(telemetry.usedDisk) + '%' + (telemetry.stats.diskTotal ? ' · 共 ' + telemetry.bytes(telemetry.stats.diskTotal) : '')
                : '宿主存储卷可用余量'
            }}
          </small>
        </div>
      </div>

      <div
        class="vitality-drawer"
        :class="{ 'is-open': telemetry.expanded }"
        :aria-hidden="!telemetry.expanded"
        :inert="!telemetry.expanded"
      >
        <div class="vitality-drawer-inner">
          <div class="vitality-drawer-content">
            <div v-if="hostMemorySegments.length || hostDiskSegments.length" class="vitality-breakdown-grid">
              <div v-if="hostMemorySegments.length" class="vitality-breakdown-item">
                <div class="spec-detail-top">
                  <span>统一内存构成（总计 {{ telemetry.stats ? telemetry.bytes(telemetry.stats.memoryTotal) : '—' }}）</span>
                  <span>{{ telemetry.usedMemory == null ? '—' : telemetry.percent(telemetry.usedMemory) + '% 已用' }}</span>
                </div>
                <IsleCharts
                  kind="segmented"
                  :segments="hostMemorySegments"
                  :total="telemetry.stats?.memoryTotal ?? 0"
                  :bar-height="8"
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
                  :bar-height="8"
                  compact-legend
                  aria-label="宿主存储已用与可用空间比例"
                />
              </div>
            </div>

            <div class="vitality-detail-grid">
              <div class="spec-detail-item">
                <div class="spec-detail-top">
                  <span>处理器核心</span>
                  <strong>{{ telemetry.stats && !telemetry.error ? (telemetry.stats.cpuCount ?? '—') + ' 核心' : '—' }}</strong>
                </div>
              </div>
              <div class="spec-detail-item">
                <div class="spec-detail-top">
                  <span>轻屿服务常驻内存</span>
                  <strong>{{ telemetry.stats && !telemetry.error && telemetry.stats.coreRssBytes != null ? telemetry.bytes(telemetry.stats.coreRssBytes) : '—' }}</strong>
                </div>
              </div>
              <div class="spec-detail-item">
                <div class="spec-detail-top">
                  <span>磁盘活动</span>
                  <strong>{{ telemetry.diskActivity ?? '空闲' }}</strong>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </section>

  <section
    v-if="identity.isAdmin"
    class="account-panel overview-pending-panel"
    :class="{
      'is-calm': pending.offlineCount === 0 && pending.rootsKnown && pending.tasksLoaded && !pending.tasksError && pending.failedTasks === 0 && !pending.rootsError,
      'is-attention': pending.offlineCount > 0 || pending.failedTasks > 0 || !!pending.rootsError || !!pending.tasksError,
    }"
    aria-label="待处理数据概况"
  >
    <template v-if="pending.offlineCount === 0 && pending.rootsKnown && pending.tasksLoaded && !pending.tasksError && pending.failedTasks === 0 && !pending.rootsError">
      <div class="overview-pending-calm-row">
        <div class="overview-pending-calm-copy">
          <h2>待处理数据</h2>
          <span class="overview-pending-calm-sep" aria-hidden="true">·</span>
          <p>已登记硬盘全部在线，{{ pending.rootName || '当前硬盘' }}没有已发现的失败任务（此概况不代表所有数据已核对）。</p>
        </div>
        <button type="button" class="account-action" @click="emit('open-pending')">打开任务中心</button>
      </div>
    </template>
    <template v-else>
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
    </template>
  </section>

  <div class="footnote"><ShieldCheck :size="14" /> <span>原片与文件均存放于本地 Mac。</span></div>
</div>
</template>

<style scoped>
/* Compact Horizontal Home Light-Apps Launcher Rows */
.home-apps-grid { grid-template-columns: repeat(auto-fill, minmax(min(100%, 272px), 1fr)); gap: 10px; }
.home-app-tile { flex-direction: row; align-items: center; gap: 12px; padding: 11px 14px; }
.home-app-meta { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.home-app-title-row { display: flex; align-items: center; justify-content: flex-start; gap: 8px; min-width: 0; }
.home-app-title-row h3 { flex: 0 1 auto; min-width: 0; }
.home-app-status-inline { display: inline-flex; align-items: center; gap: 5px; font-size: 11px; font-weight: 550; color: var(--text-tertiary); white-space: nowrap; flex-shrink: 0; }
.home-app-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--text-tertiary); opacity: 0.65; }
.home-app-status-inline.tone-ready,
.home-app-status-inline.tone-running { color: var(--success); }
.home-app-status-inline.tone-ready .home-app-dot,
.home-app-status-inline.tone-running .home-app-dot { background: var(--success); opacity: 1; }
.home-app-status-inline.tone-warn { color: var(--warning); }
.home-app-status-inline.tone-warn .home-app-dot { background: var(--warning); opacity: 1; }
.home-app-desc { margin: 0; display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-height: auto; -webkit-line-clamp: unset; }
.home-app-arrow { flex-shrink: 0; color: var(--text-tertiary); transition: transform var(--motion-fast) var(--motion-spring), color var(--motion-fast) ease; }
@media (hover: hover) {
  .home-app-tile:hover .home-app-arrow { transform: translate3d(2px, -2px, 0); color: var(--accent-primary); }
}

/* Host Summary Band + Animated Disclosure Drawer */
.vitality-host-copy { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.vitality-host-title-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.vitality-power-pill { display: inline-flex; align-items: center; gap: 4px; padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 600; color: var(--success); background: color-mix(in srgb, var(--success) 11%, transparent); border: 1px solid color-mix(in srgb, var(--success) 22%, transparent); font-variant-numeric: tabular-nums; }
.vitality-power-pill.is-battery { color: var(--warning); background: color-mix(in srgb, var(--warning) 12%, transparent); border-color: color-mix(in srgb, var(--warning) 26%, transparent); }
.vitality-power-pill.is-low { color: var(--error); background: color-mix(in srgb, var(--error) 12%, transparent); border-color: color-mix(in srgb, var(--error) 28%, transparent); }
.specs-chevron { transition: transform 240ms var(--motion-spring); }
.specs-chevron.is-open { transform: rotate(180deg); }
.vitality-chip { height: 100%; min-height: 98px; justify-content: space-between; gap: 8px; }
.vitality-chip-top { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; }
.vitality-chip-viz { display: flex; align-items: center; min-height: 20px; }
.vitality-slim-track { width: 100%; height: 5px; border-radius: 999px; background: color-mix(in srgb, var(--text-primary) 9%, transparent); overflow: hidden; }
.vitality-slim-fill { display: block; height: 100%; border-radius: inherit; transition: width 360ms var(--motion-spring); }
.vitality-slim-fill.is-violet { background: var(--brand-violet, #7b63b8); }
.vitality-slim-fill.is-blue { background: var(--accent-primary); }
.vitality-slim-fill.is-teal { background: var(--success); }

.vitality-drawer { display: grid; grid-template-rows: 0fr; opacity: 0; visibility: hidden; transition: grid-template-rows 280ms var(--motion-spring), opacity 200ms ease, visibility 0s linear 280ms; }
.vitality-drawer.is-open { grid-template-rows: 1fr; opacity: 1; visibility: visible; transition: grid-template-rows 280ms var(--motion-spring), opacity 220ms ease, visibility 0s linear 0s; }
.vitality-drawer-inner { min-height: 0; overflow: hidden; }
.vitality-drawer-content { display: flex; flex-direction: column; gap: 12px; padding-top: 14px; border-top: 1px solid var(--fluid-divider, var(--stroke-subtle)); }
.vitality-breakdown-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px 16px; }
.vitality-breakdown-item { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
.vitality-detail-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px 14px; padding-top: 10px; border-top: 1px solid color-mix(in srgb, var(--fluid-divider, var(--stroke-subtle)) 60%, transparent); }
.spec-detail-top strong { color: var(--text-primary); font-weight: 650; font-variant-numeric: tabular-nums; }

.overview-member-head-actions { display: flex; align-items: center; gap: 7px; flex-wrap: wrap; }
.overview-more-menu { position: relative; }
.overview-more-menu > summary { list-style: none; width: 34px; height: 34px; border-radius: 999px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill); color: var(--text-secondary); display: grid; place-items: center; cursor: pointer; font-weight: 700; letter-spacing: 0.5px; user-select: none; transition: background-color 150ms ease, color 150ms ease, border-color 150ms ease; }
.overview-more-menu > summary::-webkit-details-marker { display: none; }
.overview-more-menu > summary:hover, .overview-more-menu[open] > summary { color: var(--text-primary); background: var(--fluid-card-hover); border-color: var(--fluid-card-border-strong); }
.overview-more-popover { position: absolute; right: 0; top: calc(100% + 6px); z-index: 30; min-width: 168px; max-width: min(220px, calc(100vw - 48px)); padding: 5px; border-radius: 12px; border: 1px solid var(--fluid-card-border-strong, var(--fluid-card-border)); background: var(--surface-elevated); box-shadow: var(--shadow-float); display: flex; flex-direction: column; gap: 2px; }
.overview-more-popover button { width: 100%; min-height: 32px; padding: 5px 10px; border: 0; border-radius: 8px; background: transparent; color: var(--text-primary); font-size: 12.5px; font-weight: 550; display: flex; align-items: center; gap: 7px; text-align: left; cursor: pointer; }
.overview-more-popover button:hover { background: var(--fluid-card-hover); color: var(--accent-primary); }
.overview-quota-charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 240px), 1fr)); gap: 8px; margin-top: 8px; }
.overview-quota-chart-card { padding: 9px 11px; border-radius: 11px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill); display: flex; flex-direction: column; gap: 6px; }
.overview-quota-chart-head { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; font-size: 11.5px; }
.overview-quota-total { color: var(--text-tertiary); font-variant-numeric: tabular-nums; }
.overview-quota-chart-body { display: flex; align-items: center; gap: 10px; }

@media (max-width: 767px) {
  .vitality-breakdown-grid,
  .vitality-detail-grid { grid-template-columns: minmax(0, 1fr); }
  .overview-more-menu > summary { width: 40px; height: 40px; }
}
@media (max-width: 640px) {
  .account-heading { flex-wrap: wrap; }
  .overview-member-head-actions { width: 100%; }
  .overview-more-menu { margin-left: auto; }
}
@media (max-width: 560px) {
  .vitality-chip { min-height: 92px; }
}
@media (prefers-reduced-motion: reduce) {
  .home-app-arrow,
  .specs-chevron,
  .vitality-slim-fill,
  .vitality-drawer,
  .vitality-drawer.is-open,
  .overview-more-menu > summary { transition: none; }
}
</style>
