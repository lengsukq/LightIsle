<script setup lang="ts">
import { computed, ref, watch } from "vue";
import {
  RefreshCcw, ScrollText, Settings2,
  Play, Sparkles, Cpu, ChevronDown, ChevronUp, HardDrive,
} from "lucide-vue-next";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import AppDetailPanel from "./AppDetailPanel.vue";
import AppStorageLocationsCard from "./AppStorageLocationsCard.vue";
import AppWorkbenchStage from "./AppWorkbenchStage.vue";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleChip from "../../components/ui/IsleChip.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import IsleSearchInput from "../../components/ui/IsleSearchInput.vue";
import {
  AVAILABLE_CHANNELS,
  DELIVERY_LABELS,
  STATE_LABELS,
  accessBadge,
  appStatus,
  categoryLabel,
  cronSummary,
  localTime,
  runtimeBadge,
  type AppLaunchRequest,
  useAppsCenterController,
  workbenchBadge,
} from "../../composables/useAppsCenterController.ts";
const props = defineProps<{ active?: boolean; admin?: boolean; launchRequest?: AppLaunchRequest | null }>();
const emit = defineEmits<{ "launch-handled": [seq: number] }>();
const {
  apps,
  templates,
  isAdmin,
  configuredChannels,
  appStorage,
  selectedInstallLocationId,
  installLocationOptions,
  busy,
  error,
  modalError,
  notice,
  failedIcons,
  launchingAppId,
  activeWorkbenchApp,
  detailApp,
  activeIframeUrl,
  iframeKey,
  workbenchFullscreen,
  accessPolicy,
  accessAllowedUserIDs,
  nonAdminMembers,
  webEnabled,
  webMode,
  webIdleTimeoutSeconds,
  webAutoRestart,
  cronEnabled,
  cronExpr,
  cronTimezone,
  cronEvents,
  cronChannels,
  viewingLogsApp,
  logsLoading,
  webOutput,
  cronRuns,
  restoreInputRef,
  hasCron,
  reload,
  openApp,
  openAppDetail,
  closeAppDetail,
  resetAppDetailDraft,
  saveDetailChanges,
  closeWorkbench,
  refreshWorkbench,
  openInNewTab,
  runAction,
  activateApp,
  loadLogs,
  exportAppData,
  triggerRestoreAppData,
  onRestoreFileChange,
  removeApp,
  installOfficialTemplate,
  mutateAppStorage,
} = useAppsCenterController(props, (seq) => emit("launch-handled", seq));

const appSearchQuery = ref("");
const selectedCategory = ref("all");
const templatesManualExpanded = ref<boolean | null>(null);
const templatesExpanded = computed(() =>
  templatesManualExpanded.value !== null ? templatesManualExpanded.value : apps.value.length === 0,
);
const uninstalledTemplatesCount = computed(() => templates.value.filter((t) => !t.installed).length);

const availableCategories = computed(() => {
  const seen = new Set<string>();
  for (const app of apps.value) {
    if (app.category) seen.add(app.category);
  }
  return Array.from(seen);
});

watch(availableCategories, (cats) => {
  if (selectedCategory.value !== "all" && !cats.includes(selectedCategory.value)) {
    selectedCategory.value = "all";
  }
});

const filteredApps = computed(() => {
  const q = appSearchQuery.value.trim().toLowerCase();
  return apps.value.filter((app) => {
    if (selectedCategory.value !== "all" && app.category !== selectedCategory.value) return false;
    if (!q) return true;
    return (
      app.name.toLowerCase().includes(q) ||
      app.id.toLowerCase().includes(q) ||
      (app.description || "").toLowerCase().includes(q)
    );
  });
});
</script>

<template>
  <section class="apps-center">
    <AppWorkbenchStage
      v-if="activeWorkbenchApp && activeIframeUrl"
      :app="activeWorkbenchApp"
      :iframe-url="activeIframeUrl"
      :iframe-key="iframeKey"
      :fullscreen="workbenchFullscreen"
      :badge-text="workbenchBadge(activeWorkbenchApp)"
      back-label="返回应用中心"
      @close="closeWorkbench"
      @refresh="refreshWorkbench"
      @toggle-fullscreen="workbenchFullscreen = !workbenchFullscreen"
      @open-external="openInNewTab"
    />

    <AppDetailPanel
      v-else-if="detailApp"
      :app="detailApp"
      :busy="busy"
      :launching="launchingAppId === detailApp.id"
      :icon-failed="failedIcons.has(detailApp.id)"
      :error="modalError || error"
      :notice="notice"
      :non-admin-members="nonAdminMembers"
      :configured-channels="configuredChannels"
      :access-policy="accessPolicy"
      :access-allowed-user-i-ds="accessAllowedUserIDs"
      :web-enabled="webEnabled"
      :web-mode="webMode"
      :web-idle-timeout-seconds="webIdleTimeoutSeconds"
      :web-auto-restart="webAutoRestart"
      :cron-enabled="cronEnabled"
      :cron-expr="cronExpr"
      :cron-timezone="cronTimezone"
      :cron-events="cronEvents"
      :cron-channels="cronChannels"
      :logs-loading="logsLoading"
      :web-output="webOutput"
      :cron-runs="cronRuns"
      @back="closeAppDetail"
      @refresh="reload(isAdmin)"
      @icon-error="failedIcons.add(detailApp.id)"
      @launch="openApp(detailApp)"
      @activate="activateApp(detailApp)"
      @action="runAction(detailApp, $event)"
      @update:access-policy="accessPolicy = $event"
      @update:access-allowed-user-i-ds="accessAllowedUserIDs = $event"
      @update:web-enabled="webEnabled = $event"
      @update:web-mode="webMode = $event"
      @update:web-idle-timeout-seconds="webIdleTimeoutSeconds = $event"
      @update:web-auto-restart="webAutoRestart = $event"
      @update:cron-enabled="cronEnabled = $event"
      @update:cron-expr="cronExpr = $event"
      @update:cron-timezone="cronTimezone = $event"
      @update:cron-events="cronEvents = $event"
      @update:cron-channels="cronChannels = $event"
      @save="saveDetailChanges($event)"
      @reset="resetAppDetailDraft"
      @reload-logs="loadLogs(detailApp)"
      @export-data="exportAppData(detailApp)"
      @restore-data="triggerRestoreAppData(detailApp)"
      @delete="removeApp(detailApp)"
    />

    <template v-else>
      <IslePageHeader title="应用中心" subtitle="本地免密家庭轻应用、按需唤醒进程与独立数据存储管理">
        <template #title-extra>
          <IsleHelpButton
            title="家庭轻应用说明"
            :items="[
              { title: '按需唤醒与免二次登录', body: '支持纯静态与按需启动进程，闲置后自动休眠释放内存；已授权家庭成员点击即可免密使用。' },
              { title: '域名与存储跟随', body: '切换局域网、Tailscale 或公网域名时应用自动跟随生效，业务数据可独立存放在内置盘或外置盘。' },
            ]"
          />
        </template>
        <template #actions>
          <IsleBadge v-if="apps.length > 0" variant="neutral" size="sm">已安装 {{ apps.length }}</IsleBadge>
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="reload(isAdmin)">
            <template #icon><RefreshCcw :size="15" :class="{ spinning: busy }" /></template>
            {{ busy ? "正在刷新…" : isAdmin ? "刷新应用列表" : "刷新" }}
          </IsleButton>
        </template>
      </IslePageHeader>

      <details v-if="isAdmin && appStorage" class="apps-admin-storage-disclosure" aria-label="管理员应用存储设置">
        <summary class="apps-admin-storage-summary">
          <HardDrive :size="15" />
          <span>管理员应用存储设置（默认折叠）</span>
          <small>管理轻应用在内置盘/外置盘的存放位置</small>
        </summary>
        <div class="apps-admin-storage-body">
          <AppStorageLocationsCard
            :storage="appStorage"
            :busy="busy"
            @mutate="mutateAppStorage"
          />
        </div>
      </details>

      <IsleBanner v-if="launchingAppId" type="info" compact>
        <template #icon><RefreshCcw :size="16" class="spinning" /></template>
        正在唤醒轻应用...
      </IsleBanner>
      <IsleBanner v-if="error" type="error" compact :message="error" />
      <IsleBanner v-if="notice" type="success" compact :message="notice" />

      <section v-if="isAdmin && templates.length > 0" class="apps-templates-bar" aria-label="官方精选家庭轻应用模板">
        <div class="apps-templates-info" style="flex: 1 1 100%">
          <div class="apps-templates-head">
            <div class="apps-templates-title">
              <Sparkles :size="17" />
              <strong>官方精选家庭轻应用模板</strong>
              <IsleBadge variant="accent" size="sm">零外部依赖</IsleBadge>
              <small v-if="!templatesExpanded && uninstalledTemplatesCount > 0">还有 {{ uninstalledTemplatesCount }} 款精选应用可一键安装</small>
            </div>
            <button
              v-if="apps.length > 0"
              type="button"
              class="apps-templates-toggle"
              :aria-expanded="templatesExpanded"
              @click="templatesManualExpanded = !templatesExpanded"
            >
              <span>{{ templatesExpanded ? "收起模板库" : `展开模板 (${templates.length})` }}</span>
              <ChevronUp v-if="templatesExpanded" :size="14" />
              <ChevronDown v-else :size="14" />
            </button>
          </div>
          <template v-if="templatesExpanded">
            <div v-if="appStorage && appStorage.locations.length > 1" class="apps-install-target-row">
              <span>安装到存储位置：</span>
              <AppleSelect
                v-model="selectedInstallLocationId"
                :options="installLocationOptions"
                size="sm"
                aria-label="选择官方模板安装位置"
              />
            </div>
            <div class="apps-template-shelf">
              <div v-for="tpl in templates" :key="tpl.id" class="apps-template-card">
                <div>
                  <strong>{{ tpl.name }}</strong>
                  <p>{{ tpl.description }}</p>
                </div>
                <IsleButton :variant="tpl.installed ? 'glass' : 'primary'" size="sm" :disabled="busy || tpl.installed" @click="installOfficialTemplate(tpl)">
                  {{ tpl.installed ? '已安装' : '一键安装' }}
                </IsleButton>
              </div>
            </div>
          </template>
        </div>
      </section>

      <div v-if="apps.length > 0" class="apps-filter-toolbar">
        <div class="apps-category-pills" role="group" aria-label="应用分类筛选">
          <IsleChip small :selected="selectedCategory === 'all'" @select="selectedCategory = 'all'">全部 ({{ apps.length }})</IsleChip>
          <IsleChip
            v-for="cat in availableCategories"
            :key="cat"
            small
            :selected="selectedCategory === cat"
            @select="selectedCategory = cat"
          >
            {{ categoryLabel(cat) }}
          </IsleChip>
        </div>
        <IsleSearchInput
          v-model="appSearchQuery"
          placeholder="搜索已安装轻应用…"
          aria-label="搜索已安装轻应用"
          @clear="appSearchQuery = ''"
        />
      </div>

      <IsleEmpty
        v-if="apps.length === 0 && !busy && !error"
        :icon="Sparkles"
        card
        :title="isAdmin ? '暂无轻应用插件' : '暂无已授权的轻应用'"
        :description="isAdmin ? '可在上方一键安装官方精选家庭轻应用，或在 Mac 端 LightIsle 客户端中添加或开发轻应用。' : '如需访问家庭工具，请联系管理员在应用中心授权。'"
      />

      <IsleEmpty
        v-else-if="apps.length > 0 && filteredApps.length === 0"
        :icon="Sparkles"
        card
        compact
        title="没有匹配的轻应用"
        description="尝试清除分类或搜索关键词后重试。"
      >
        <template #action>
          <IsleButton variant="tonal" size="sm" @click="appSearchQuery = ''; selectedCategory = 'all'">重置筛选</IsleButton>
        </template>
      </IsleEmpty>

      <div v-else class="apps-grid">
        <article v-for="app in filteredApps" :key="app.id" class="app-card">
          <div
            class="app-card-top"
            :class="{ 'is-launchable': app.web?.enabled !== false && !app.pendingActivation && !launchingAppId }"
            @click="app.web?.enabled !== false && !app.pendingActivation && !launchingAppId ? openApp(app) : undefined"
          >
            <div class="app-icon-wrap">
              <img v-if="app.iconUrl && !failedIcons.has(app.id)" :src="app.iconUrl" :alt="app.name + ' 图标'" class="app-icon-img" loading="lazy" decoding="async" @error="failedIcons.add(app.id)" />
              <Cpu v-else :size="24" />
            </div>
            <div class="app-title-meta">
              <div class="app-title-line">
                <strong>{{ app.name }}</strong>
                <IsleBadge variant="category" size="sm">{{ categoryLabel(app.category) }}</IsleBadge>
              </div>
              <small v-if="isAdmin" class="app-id-line">{{ app.id }}<template v-if="app.version"> · v{{ app.version }}</template></small>
              <p class="app-desc">{{ app.description || "轻屿本地家庭轻应用" }}</p>
            </div>
          </div>

          <div v-if="isAdmin" class="app-badges">
            <IsleBadge :variant="appStatus(app) === 'running' ? 'online' : 'neutral'" size="sm">{{ runtimeBadge(app) }}</IsleBadge>
            <IsleBadge v-if="app.pendingActivation" variant="warning" size="sm">待首次激活</IsleBadge>
            <IsleBadge v-if="app.locationKind === 'external'" variant="accent" size="sm">
              其他盘 · {{ app.locationName || '外置盘' }}
            </IsleBadge>
            <IsleBadge variant="neutral" size="sm">{{ accessBadge(app) }}</IsleBadge>
            <IsleBadge v-if="hasCron(app)" variant="neutral" size="sm">{{ cronSummary(app) }}</IsleBadge>
          </div>
          <div v-if="isAdmin && app.diagnostic" class="app-diag-box" role="alert">
            <div class="app-diag-title">{{ app.diagnostic.summary }}</div>
            <p class="app-diag-line"><strong>原因：</strong>{{ app.diagnostic.reason }}</p>
            <pre v-if="app.diagnostic.logExcerpt" class="app-diag-pre">{{ app.diagnostic.logExcerpt }}</pre>
            <p v-if="app.diagnostic.checks?.length" class="app-diag-line"><strong>排查：</strong>{{ app.diagnostic.checks[0] }}</p>
            <p v-if="app.diagnostic.solutions?.length" class="app-diag-line"><strong>解决：</strong>{{ app.diagnostic.solutions[0] }}</p>
            <small v-if="app.diagnostic.dataSafe" class="app-diag-safe">{{ app.diagnostic.dataSafe }}</small>
          </div>
          <p v-else-if="isAdmin && (app.lastError || app.validationError || app.web?.lastError)" class="apps-error">
            {{ describeUserFacingError(app.lastError || app.validationError || app.web?.lastError) }}
          </p>
          <small v-if="isAdmin && app.cron?.lastRun" class="app-Subnote">
            上次定时执行：{{ STATE_LABELS[app.cron.lastRun.state] || app.cron.lastRun.state }} · {{ localTime(app.cron.lastRun.finishedAt) }}
          </small>

          <div class="app-card-actions">
            <IsleButton v-if="app.pendingActivation && isAdmin" variant="primary" :disabled="busy" @click="activateApp(app)">
              <Play :size="14" /> 确认激活
            </IsleButton>
            <IsleButton v-if="app.web?.enabled !== false" :variant="app.pendingActivation && isAdmin ? 'glass' : 'primary'" :disabled="!!launchingAppId" @click="openApp(app)">
              <Play :size="14" /> {{ launchingAppId === app.id ? "正在唤醒轻应用..." : "立即打开" }}
            </IsleButton>
            <IsleButton v-if="isAdmin" variant="glass" :disabled="busy" @click="openAppDetail(app)">
              <Settings2 :size="14" /> 详情与设置
            </IsleButton>
          </div>
        </article>
      </div>
      <input ref="restoreInputRef" type="file" accept=".tar.gz,.tgz,application/gzip" style="display:none" @change="onRestoreFileChange" />
    </template>

    <IsleModal
      v-if="viewingLogsApp"
      :title="'运行日志 · ' + viewingLogsApp.name"
      size="wide"
      @close="viewingLogsApp = null; modalError = ''"
    >
      <template #icon>
        <ScrollText :size="17" />
      </template>
      <template #header-actions>
        <IsleButton variant="glass" size="sm" :loading="logsLoading" :disabled="logsLoading" @click="loadLogs(viewingLogsApp)"><RefreshCcw :size="14" /> 刷新日志</IsleButton>
        <IsleButton v-if="hasCron(viewingLogsApp)" variant="glass" size="sm" :loading="busy" :disabled="busy" @click="runAction(viewingLogsApp, 'run_cron')"><Play :size="14" /> 立即执行 Cron</IsleButton>
      </template>
      <IsleBanner v-if="modalError" type="error" compact :message="modalError" style="margin-bottom: 12px" />
      <div class="apps-form-section">
        <strong>Web 进程标准输出（最近日志）</strong>
        <pre class="apps-log-pre">{{ webOutput || "（当前无 Web 进程日志输出，或应用处于休眠/静态状态）" }}</pre>
      </div>
      <div class="apps-form-section">
        <strong>定时任务（Cron）最近执行记录</strong>
        <p v-if="cronRuns.length === 0" class="apps-hint">暂无定时执行记录。</p>
        <details v-for="(run, idx) in cronRuns" :key="run.id ?? idx" class="apps-log-detail">
          <summary>{{ localTime(run.startedAt) }} · {{ STATE_LABELS[run.state] || run.state }}<span v-if="run.exitCode >= 0"> · 退出码 {{ run.exitCode }}</span></summary>
          <pre class="apps-log-pre">{{ run.output || "（没有标准输出）" }}</pre>
          <p v-for="(status, channel) in run.deliveries" :key="channel" class="apps-hint">
            {{ AVAILABLE_CHANNELS.find(c => c.id === channel)?.label || channel }} · {{ DELIVERY_LABELS[status] || status }}
          </p>
        </details>
      </div>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;width:100%">
          <IsleButton variant="glass" @click="viewingLogsApp = null; modalError = ''">关闭</IsleButton>
        </div>
      </template>
    </IsleModal>
  </section>
</template>
