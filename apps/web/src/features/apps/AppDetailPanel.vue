<script setup lang="ts">
import { computed, ref } from "vue";
import { TIMINGS_MS } from "../../constants/timings.ts";
import {
  Archive,
  ArrowLeft,
  Bell,
  Check,
  ChevronRight,
  Clock,
  Copy,
  Cpu,
  Download,
  Globe,
  Lock,
  Play,
  RefreshCcw,
  RotateCw,
  ScrollText,
  Square,
  Trash2,
  Upload,
  Users,
} from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import {
  hasCronModule,
  hasWebModule,
  normalizeAccessPolicy,
} from "./appsCenterApi.ts";
import {
  AVAILABLE_CHANNELS,
  DELIVERY_LABELS,
  STATE_LABELS,
  WEB_MODE_OPTIONS,
  appMode,
  appStatus,
  categoryLabel,
  flipItem,
  localTime,
  runtimeBadge,
} from "../../composables/useAppsCenterController.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import type { AppCronRunEntry, AppMemberSummary, PublicAppItem } from "../../types/appsCenter.ts";

const props = defineProps<{
  app: PublicAppItem;
  busy: boolean;
  launching: boolean;
  iconFailed: boolean;
  error: string;
  notice: string;
  nonAdminMembers: AppMemberSummary[];
  configuredChannels: string[];
  accessPolicy: "admin_only" | "selected_members" | "all_members";
  accessAllowedUserIDs: number[];
  webEnabled: boolean;
  webMode: "static" | "on-demand" | "persistent";
  webIdleTimeoutSeconds: number;
  webAutoRestart: boolean;
  cronEnabled: boolean;
  cronExpr: string;
  cronTimezone: string;
  cronEvents: string[];
  cronChannels: string[];
  logsLoading: boolean;
  webOutput: string;
  cronRuns: AppCronRunEntry[];
}>();

const emit = defineEmits<{
  back: [];
  refresh: [];
  "icon-error": [];
  launch: [];
  activate: [];
  action: [action: "start" | "stop" | "restart" | "run_cron"];
  "update:accessPolicy": [val: "admin_only" | "selected_members" | "all_members"];
  "update:accessAllowedUserIDs": [val: number[]];
  "update:webEnabled": [val: boolean];
  "update:webMode": [val: "static" | "on-demand" | "persistent"];
  "update:webIdleTimeoutSeconds": [val: number];
  "update:webAutoRestart": [val: boolean];
  "update:cronEnabled": [val: boolean];
  "update:cronExpr": [val: string];
  "update:cronTimezone": [val: string];
  "update:cronEvents": [val: string[]];
  "update:cronChannels": [val: string[]];
  save: [opts: { saveAccessPart: boolean; saveConfigPart: boolean }];
  reset: [];
  "reload-logs": [];
  "export-data": [];
  "export-package": [];
  "restore-data": [];
  delete: [];
}>();

const copiedLogs = ref(false);
const hasWeb = computed(() => hasWebModule(props.app));
const hasCron = computed(() => hasCronModule(props.app));

const idlePresets = [
  { secs: 300, label: "5 分钟" },
  { secs: 900, label: "15 分钟" },
  { secs: 1800, label: "30 分钟" },
  { secs: 3600, label: "1 小时" },
];

const cronPresets = [
  { expr: "*/15 * * * *", label: "每 15 分钟" },
  { expr: "0 * * * *", label: "每小时" },
  { expr: "0 3 * * *", label: "每天 03:00" },
];

const effectiveIdleSeconds = computed(() =>
  props.webIdleTimeoutSeconds > 0 ? props.webIdleTimeoutSeconds : 900,
);

const idleMinutesDisplay = computed(() =>
  Math.max(1, Math.round(effectiveIdleSeconds.value / 60)),
);

function formatIdleDuration(seconds: number): string {
  if (seconds % 3600 === 0) return `${seconds / 3600} 小时`;
  if (seconds % 60 === 0) return `${seconds / 60} 分钟`;
  const mins = Math.floor(seconds / 60);
  const rem = seconds % 60;
  return mins > 0 ? `${mins} 分 ${rem} 秒` : `${rem} 秒`;
}

function sameSortedNums(a: number[], b: number[]): boolean {
  const sa = [...a].sort((x, y) => x - y);
  const sb = [...b].sort((x, y) => x - y);
  return sa.length === sb.length && sa.every((v, idx) => v === sb[idx]);
}

function sameSortedStrs(a: string[], b: string[]): boolean {
  const sa = [...a].sort();
  const sb = [...b].sort();
  return sa.length === sb.length && sa.every((v, idx) => v === sb[idx]);
}

const accessDirty = computed(() => {
  const origPolicy = normalizeAccessPolicy(props.app.access?.policy);
  if (props.accessPolicy !== origPolicy) return true;
  if (props.accessPolicy === "selected_members") {
    return !sameSortedNums(props.accessAllowedUserIDs, props.app.access?.allowedUserIDs || []);
  }
  return false;
});

const configDirty = computed(() => {
  if (hasWeb.value) {
    if (props.webEnabled !== (props.app.web?.enabled ?? true)) return true;
    if (props.webMode !== appMode(props.app)) return true;
    const origIdle = props.app.web?.idleTimeoutSeconds && props.app.web.idleTimeoutSeconds > 0 ? props.app.web.idleTimeoutSeconds : 900;
    const curIdle = effectiveIdleSeconds.value;
    if (curIdle !== origIdle) return true;
    if (props.webAutoRestart !== (props.app.web?.autoRestart ?? true)) return true;
  }
  if (hasCron.value) {
    const c = props.app.cron;
    if (props.cronEnabled !== (c?.enabled ?? false)) return true;
    if (props.cronExpr.trim() !== (c?.cron || c?.schedule?.cron || "*/15 * * * *")) return true;
    if (props.cronTimezone.trim() !== (c?.timezone || c?.schedule?.timezone || "Asia/Shanghai")) return true;
    if (!sameSortedStrs(props.cronEvents, c?.events || c?.notification?.events || ["failure", "timeout"])) return true;
    if (!sameSortedStrs(props.cronChannels, c?.channels || c?.notification?.channels || [])) return true;
  }
  return false;
});

const isDirty = computed(() => accessDirty.value || configDirty.value);

function onIdleMinutesInput(event: Event) {
  const raw = (event.target as HTMLInputElement).value.trim();
  if (!raw) return;
  const parsedMins = Number(raw);
  if (Number.isFinite(parsedMins) && parsedMins >= 1) {
    const clampedSecs = Math.min(86400, Math.max(60, Math.round(parsedMins * 60)));
    emit("update:webIdleTimeoutSeconds", clampedSecs);
  }
}

function onIdleMinutesBlur(event: FocusEvent) {
  const el = event.target as HTMLInputElement;
  const parsedMins = Number(el.value.trim());
  if (!el.value.trim() || !Number.isFinite(parsedMins) || parsedMins < 1) {
    el.value = String(idleMinutesDisplay.value);
    return;
  }
  const clampedMins = Math.min(1440, Math.max(1, Math.round(parsedMins)));
  el.value = String(clampedMins);
  if (clampedMins * 60 !== effectiveIdleSeconds.value) {
    emit("update:webIdleTimeoutSeconds", clampedMins * 60);
  }
}

function runBadgeVariant(state: string): "online" | "danger" | "warning" | "accent" {
  if (state === "success") return "online";
  if (state === "failure" || state === "timeout") return "danger";
  if (state === "running") return "accent";
  return "warning";
}

async function copyWebLogs() {
  if (!props.webOutput.trim()) return;
  if (await copyTextToClipboard(props.webOutput)) {
    copiedLogs.value = true;
    setTimeout(() => { copiedLogs.value = false; }, TIMINGS_MS.COPIED_FEEDBACK);
  }
}
</script>

<template>
  <div class="app-detail-page" :class="{ 'has-dirty-bar': isDirty }">
    <div class="app-detail-topbar">
      <IsleButton variant="glass" size="sm" @click="emit('back')">
        <template #icon><ArrowLeft :size="15" /></template>
        返回应用中心
      </IsleButton>
      <IsleButton variant="glass" size="sm" :disabled="busy" @click="emit('refresh')">
        <template #icon><RefreshCcw :size="14" :class="{ spinning: busy }" /></template>
        刷新状态
      </IsleButton>
    </div>

    <IsleBanner v-if="error" type="error" :message="error" />
    <IsleBanner v-if="notice" type="success" :message="notice" />

    <section class="app-detail-hero">
      <div class="app-detail-hero-head">
        <div class="app-detail-hero-icon">
          <img v-if="app.iconUrl && !iconFailed" :src="app.iconUrl" :alt="app.name + ' 图标'" class="app-icon-img" @error="emit('icon-error')" />
          <Cpu v-else :size="26" />
        </div>
        <div class="app-detail-hero-meta">
          <div class="app-detail-title-row">
            <h2>{{ app.name }}</h2>
            <IsleBadge variant="category" size="sm">{{ categoryLabel(app.category) }}</IsleBadge>
            <IsleBadge :variant="appStatus(app) === 'running' ? 'online' : 'neutral'" dot size="sm">{{ runtimeBadge(app) }}</IsleBadge>
            <IsleBadge v-if="app.pendingActivation" variant="warning" dot size="sm">待首次激活</IsleBadge>
          </div>
          <p class="app-detail-desc">{{ app.description || "轻屿本地家庭轻应用" }}</p>
          <div class="app-detail-subpills">
            <span>ID: {{ app.id }}<template v-if="app.version"> · v{{ app.version }}</template></span>
            <span>{{ app.locationKind === 'external' ? `其他盘 · ${app.locationName || '外置盘'}` : `内置盘 · ${app.locationName || 'Mac 内置盘'}` }}</span>
          </div>
        </div>
      </div>

      <div v-if="app.diagnostic" class="app-diag-box" role="alert">
        <div class="app-diag-title">{{ app.diagnostic.summary }}</div>
        <p class="app-diag-line"><strong>原因：</strong>{{ app.diagnostic.reason }}</p>
        <pre v-if="app.diagnostic.logExcerpt" class="app-diag-pre">{{ app.diagnostic.logExcerpt }}</pre>
        <p v-if="app.diagnostic.checks?.length" class="app-diag-line"><strong>排查：</strong>{{ app.diagnostic.checks[0] }}</p>
        <p v-if="app.diagnostic.solutions?.length" class="app-diag-line"><strong>解决：</strong>{{ app.diagnostic.solutions[0] }}</p>
      </div>
      <IsleBanner v-else-if="app.lastError || app.validationError || app.web?.lastError" type="warning" compact :message="describeUserFacingError(app.lastError || app.validationError || app.web?.lastError)" />

      <div class="app-detail-hero-actions">
        <IsleButton v-if="app.pendingActivation" variant="primary" :disabled="busy" @click="emit('activate')">
          <template #icon><Check :size="15" /></template>
          确认激活
        </IsleButton>
        <IsleButton v-if="app.web?.enabled !== false" :variant="app.pendingActivation ? 'glass' : 'primary'" :loading="launching" :disabled="launching" @click="emit('launch')">
          <template #icon><Play :size="15" /></template>
          {{ launching ? "正在唤醒轻应用..." : "立即打开" }}
        </IsleButton>
        <template v-if="appMode(app) !== 'static'">
          <IsleButton v-if="appStatus(app) === 'running'" variant="glass" :disabled="busy" @click="emit('action', 'restart')">
            <template #icon><RotateCw :size="14" /></template>
            重启
          </IsleButton>
          <IsleButton v-if="appStatus(app) === 'running'" variant="glass" :disabled="busy" @click="emit('action', 'stop')">
            <template #icon><Square :size="14" /></template>
            停止
          </IsleButton>
          <IsleButton v-else variant="glass" :disabled="busy" @click="emit('action', 'start')">
            <template #icon><Play :size="14" /></template>
            启动进程
          </IsleButton>
        </template>
        <IsleButton v-if="hasCron" variant="glass" :disabled="busy" @click="emit('action', 'run_cron')">
          <template #icon><Clock :size="14" /></template>
          立即采集
        </IsleButton>
      </div>
    </section>

    <div class="app-detail-grid">
      <section class="app-detail-card">
        <header class="app-detail-card-head">
          <Users :size="16" />
          <div>
            <h3>家庭成员访问权限</h3>
            <p>控制哪些成员账号可在应用中心与首页看到并免密使用此应用</p>
          </div>
        </header>
        <IsleGroupedList variant="item" flush class="app-option-cards-grouped">
          <label class="app-option-card" :class="{ selected: accessPolicy === 'admin_only' }">
            <input type="radio" class="app-sr-input" value="admin_only" :checked="accessPolicy === 'admin_only'" @change="emit('update:accessPolicy', 'admin_only')" />
            <span class="app-option-icon"><Lock :size="16" /></span>
            <div class="app-option-body"><strong>仅管理员</strong><small>仅家庭管理员可见与使用（默认推荐）</small></div>
            <span class="app-option-check"><Check :size="13" /></span>
          </label>
          <label class="app-option-card" :class="{ selected: accessPolicy === 'selected_members' }">
            <input type="radio" class="app-sr-input" value="selected_members" :checked="accessPolicy === 'selected_members'" @change="emit('update:accessPolicy', 'selected_members')" />
            <span class="app-option-icon"><Users :size="16" /></span>
            <div class="app-option-body"><strong>指定家庭成员</strong><small>管理员与已勾选成员可使用</small></div>
            <span class="app-option-check"><Check :size="13" /></span>
          </label>
          <label class="app-option-card" :class="{ selected: accessPolicy === 'all_members' }">
            <input type="radio" class="app-sr-input" value="all_members" :checked="accessPolicy === 'all_members'" @change="emit('update:accessPolicy', 'all_members')" />
            <span class="app-option-icon"><Globe :size="16" /></span>
            <div class="app-option-body"><strong>全员可用</strong><small>所有已登录家庭成员均可用</small></div>
            <span class="app-option-check"><Check :size="13" /></span>
          </label>
        </IsleGroupedList>

        <div v-if="accessPolicy === 'selected_members'" class="app-inset-panel">
          <span class="app-field-caption">选择已授权的家庭成员</span>
          <div class="app-member-pill-wrap">
            <p v-if="nonAdminMembers.length === 0" class="apps-hint">暂无普通家庭成员账号。</p>
            <label v-for="m in nonAdminMembers" :key="m.id" class="app-pill-check" :class="{ checked: accessAllowedUserIDs.includes(m.id) }">
              <input type="checkbox" class="app-sr-input" :checked="accessAllowedUserIDs.includes(m.id)" @change="emit('update:accessAllowedUserIDs', flipItem(accessAllowedUserIDs, m.id))" />
              <span class="app-member-dot">{{ m.username.slice(0, 1).toUpperCase() }}</span>
              <span>{{ m.username }}</span>
            </label>
          </div>
        </div>
      </section>

      <section v-if="hasWeb" class="app-detail-card">
        <header class="app-detail-card-head">
          <Globe :size="16" />
          <div>
            <h3>Web 服务与生命周期</h3>
            <p>配置访问入口开关、进程唤醒策略及自动休眠规则</p>
          </div>
        </header>
        <IsleGroupedList variant="item" flush>
          <label class="app-toggle-row">
            <div><strong>启用 Web 界面入口</strong><small>关闭后将在首页和应用列表隐藏打开按钮</small></div>
            <input type="checkbox" class="app-apple-switch" :checked="webEnabled" @change="emit('update:webEnabled', ($event.target as HTMLInputElement).checked)" />
          </label>
          <label v-if="webMode === 'persistent'" class="app-toggle-row">
            <div><strong>进程异常退出时自动重启</strong><small>守护进程检测到崩溃后自动恢复服务</small></div>
            <input type="checkbox" class="app-apple-switch" :checked="webAutoRestart" @change="emit('update:webAutoRestart', ($event.target as HTMLInputElement).checked)" />
          </label>
        </IsleGroupedList>

        <div class="app-inset-panel">
          <div class="apps-inputs apps-inputs-single">
            <label>运行模式
              <AppleSelect :model-value="webMode" block :options="WEB_MODE_OPTIONS" @update:model-value="emit('update:webMode', $event as 'static' | 'on-demand' | 'persistent')" />
            </label>
          </div>
          <div v-if="webMode === 'on-demand'" class="app-idle-control">
            <div class="app-idle-head">
              <span>闲置自动休眠时长</span>
              <span class="app-idle-helper">{{ formatIdleDuration(effectiveIdleSeconds) }} · {{ effectiveIdleSeconds }} 秒</span>
            </div>
            <div class="app-preset-row">
              <button v-for="p in idlePresets" :key="p.secs" type="button" class="app-preset-chip" :class="{ active: effectiveIdleSeconds === p.secs }" @click="emit('update:webIdleTimeoutSeconds', p.secs)">{{ p.label }}</button>
            </div>
            <div class="app-idle-custom-row">
              <span class="app-idle-custom-label">自定义时长</span>
              <div class="app-unit-input">
                <input
                  :value="String(idleMinutesDisplay)"
                  type="number"
                  min="1"
                  max="1440"
                  step="1"
                  aria-label="闲置自动休眠分钟数"
                  @input="onIdleMinutesInput"
                  @blur="onIdleMinutesBlur"
                />
                <span class="app-unit-suffix">分钟</span>
              </div>
              <span class="app-idle-seconds-hint">空闲超期自动释放内存</span>
            </div>
          </div>
        </div>
      </section>

      <section v-if="hasCron" class="app-detail-card app-detail-card-wide">
        <header class="app-detail-card-head">
          <Clock :size="16" />
          <div>
            <h3>定时任务 (Cron) 与告警通知</h3>
            <p>调整调度周期与提醒渠道；邮件模板格式将保留插件本地脚本配置</p>
          </div>
        </header>
        <IsleGroupedList variant="item" flush>
          <label class="app-toggle-row">
            <div><strong>启用后台定时任务调度</strong><small>按照下方 Cron 表达式定时执行脚本</small></div>
            <input type="checkbox" class="app-apple-switch" :checked="cronEnabled" @change="emit('update:cronEnabled', ($event.target as HTMLInputElement).checked)" />
          </label>
        </IsleGroupedList>
        <div class="app-inset-panel">
          <div class="app-preset-row">
            <button v-for="p in cronPresets" :key="p.expr" type="button" class="app-preset-chip" :class="{ active: cronExpr.trim() === p.expr }" @click="emit('update:cronExpr', p.expr)">{{ p.label }} ({{ p.expr }})</button>
          </div>
          <div class="apps-inputs">
            <label>五段 Cron 表达式<input :value="cronExpr" class="app-mono-input" placeholder="*/15 * * * *" @input="emit('update:cronExpr', ($event.target as HTMLInputElement).value.trim())" /></label>
            <label>时区<input :value="cronTimezone" placeholder="Asia/Shanghai" @input="emit('update:cronTimezone', ($event.target as HTMLInputElement).value.trim())" /></label>
          </div>
        </div>
        <div class="app-inset-panel">
          <div class="app-pill-groups">
            <div>
              <span class="app-field-caption"><Bell :size="13" /> 通知事件</span>
              <div class="app-member-pill-wrap">
                <label v-for="ev in [{ id: 'failure', name: '执行失败' }, { id: 'timeout', name: '执行超时' }, { id: 'success', name: '执行成功' }]" :key="ev.id" class="app-pill-check" :class="{ checked: cronEvents.includes(ev.id) }">
                  <input type="checkbox" class="app-sr-input" :checked="cronEvents.includes(ev.id)" @change="emit('update:cronEvents', flipItem(cronEvents, ev.id))" />
                  <span>{{ ev.name }}</span>
                </label>
              </div>
            </div>
            <div>
              <span class="app-field-caption">通知渠道</span>
              <div class="app-member-pill-wrap">
                <label v-for="ch in AVAILABLE_CHANNELS" :key="ch.id" class="app-pill-check" :class="{ checked: cronChannels.includes(ch.id), disabled: !configuredChannels.includes(ch.id) && !cronChannels.includes(ch.id) }">
                  <input type="checkbox" class="app-sr-input" :disabled="!configuredChannels.includes(ch.id) && !cronChannels.includes(ch.id)" :checked="cronChannels.includes(ch.id)" @change="emit('update:cronChannels', flipItem(cronChannels, ch.id))" />
                  <span>{{ ch.label }}<small v-if="!configuredChannels.includes(ch.id)">（未配置）</small></span>
                </label>
              </div>
            </div>
          </div>
        </div>
      </section>
    </div>

    <Teleport to="body">
      <Transition name="isle-hud-float">
        <div v-if="isDirty" class="app-detail-save-bar" role="region" aria-label="未保存的配置修改">
          <div class="app-detail-save-copy">
            <span class="app-detail-save-dot" aria-hidden="true" />
            <span>有尚未保存的配置修改</span>
          </div>
          <div class="app-detail-save-actions">
            <IsleButton variant="glass" size="sm" :disabled="busy" @click="emit('reset')">还原修改</IsleButton>
            <IsleButton variant="primary" size="sm" :loading="busy" :disabled="busy" @click="emit('save', { saveAccessPart: accessDirty, saveConfigPart: configDirty })">保存设置</IsleButton>
          </div>
        </div>
      </Transition>
    </Teleport>

    <section class="app-detail-card">
      <header class="app-detail-card-head app-detail-card-head-split">
        <div class="app-detail-head-left">
          <ScrollText :size="16" />
          <div><h3>运行日志与定时记录</h3><p>实时查看控制台最近输出及 Cron 执行记录</p></div>
        </div>
        <div class="app-detail-head-actions">
          <IsleButton variant="glass" size="sm" :loading="logsLoading" :disabled="logsLoading" @click="emit('reload-logs')">
            <template #icon><RefreshCcw :size="13" /></template>
            刷新日志
          </IsleButton>
          <IsleButton variant="glass" size="sm" :disabled="!webOutput.trim()" @click="copyWebLogs">
            <template #icon><Copy :size="13" /></template>
            {{ copiedLogs ? "已复制" : "复制日志" }}
          </IsleButton>
        </div>
      </header>
      <pre class="apps-log-pre">{{ webOutput || "（当前无 Web 进程日志输出，或应用处于休眠/静态状态）" }}</pre>
      <div v-if="cronRuns.length > 0" class="app-detail-runs">
        <details v-for="(run, idx) in cronRuns" :key="run.id ?? idx" class="apps-log-detail">
          <summary>
            <ChevronRight :size="14" class="apps-log-chevron" aria-hidden="true" />
            <IsleBadge :variant="runBadgeVariant(run.state)" dot size="sm">{{ STATE_LABELS[run.state] || run.state }}</IsleBadge>
            <span>{{ localTime(run.startedAt) }}</span>
            <span v-if="run.exitCode >= 0" class="apps-hint">退出码 {{ run.exitCode }}</span>
          </summary>
          <pre class="apps-log-pre app-detail-runs-pre">{{ run.output || "（没有标准输出）" }}</pre>
          <p v-for="(status, channel) in run.deliveries" :key="channel" class="apps-hint">
            {{ AVAILABLE_CHANNELS.find(c => c.id === channel)?.label || channel }} · {{ DELIVERY_LABELS[status] || status }}
          </p>
        </details>
      </div>
    </section>

    <section class="app-detail-card">
      <header class="app-detail-card-head">
        <Archive :size="16" />
        <div>
          <h3>数据导出与备份</h3>
          <p>导出分享插件包，或备份、恢复独立的 plugin-data 业务数据归档</p>
        </div>
      </header>
      <IsleGroupedList variant="item" flush>
        <div class="app-action-row">
          <div class="app-action-row-copy">
            <strong>导出分享包 (.liapp.zip)</strong>
            <small>打包插件源码与配置，方便分享或迁移到其他 LightIsle 主机</small>
          </div>
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="emit('export-package')">
            <template #icon><Download :size="14" /></template>
            导出分享包
          </IsleButton>
        </div>
        <div class="app-action-row">
          <div class="app-action-row-copy">
            <strong>导出数据 (.tar.gz)</strong>
            <small>备份独立的 plugin-data 运行数据归档到本地</small>
          </div>
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="emit('export-data')">
            <template #icon><Download :size="14" /></template>
            导出数据
          </IsleButton>
        </div>
        <div class="app-action-row">
          <div class="app-action-row-copy">
            <strong>恢复备份</strong>
            <small>从 .tar.gz / .tgz 数据归档恢复并替换当前应用业务数据</small>
          </div>
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="emit('restore-data')">
            <template #icon><Upload :size="14" /></template>
            恢复备份
          </IsleButton>
        </div>
      </IsleGroupedList>
    </section>

    <section class="app-detail-card app-detail-danger-card">
      <header class="app-detail-card-head">
        <Trash2 :size="16" />
        <div>
          <h3>卸载插件</h3>
          <p>卸载插件仅移除 plugins/ 代码目录，独立业务数据目录 plugin-data/ 会安全保留</p>
        </div>
      </header>
      <div class="app-danger-row">
        <div class="app-danger-copy">
          <strong>移除此轻应用插件</strong>
          <small>{{ appStatus(app) === 'running' ? '应用正在运行中，请先在顶部停止进程后再删除插件。' : '移除后可随时通过插件包或官方模板重新安装并继续使用原数据。' }}</small>
        </div>
        <IsleButton
          variant="danger"
          size="sm"
          :disabled="busy || appStatus(app) === 'running'"
          :title="appStatus(app) === 'running' ? '应用正在运行，请先停止进程后再删除插件' : '删除插件（保留业务数据）'"
          @click="emit('delete')"
        >
          <template #icon><Trash2 :size="14" /></template>
          删除插件
        </IsleButton>
      </div>
    </section>
  </div>
</template>
