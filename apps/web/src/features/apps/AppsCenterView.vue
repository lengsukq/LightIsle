<script setup lang="ts">
import { computed, ref, watch } from "vue";
import {
  AlertCircle, ArrowUpCircle, ChevronRight, Clock, Cpu,
  Globe, HardDrive, Lock, Play, RefreshCcw, ScrollText, Settings2,
  Sparkles, Upload, Users,
} from "lucide-vue-next";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import AppDetailPanel from "./AppDetailPanel.vue";
import AppStorageLocationsCard from "./AppStorageLocationsCard.vue";
import AppStoreSection from "./AppStoreSection.vue";
import AppWorkbenchStage from "./AppWorkbenchStage.vue";
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
  appMode,
  appStatus,
  categoryLabel,
  localTime,
  type AppLaunchRequest,
  useAppsCenterController,
  workbenchBadge,
} from "../../composables/useAppsCenterController.ts";
import type { PublicAppItem } from "../../types/appsCenter.ts";

const props = defineProps<{ active?: boolean; admin?: boolean; launchRequest?: AppLaunchRequest | null }>();
const emit = defineEmits<{ "launch-handled": [seq: number] }>();
const {
  apps,
  store,
  storeLoading,
  storeActionPluginId,
  storeError,
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
  packageInputRef,
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
  openLogsModal,
  exportAppData,
  exportAppPackage,
  triggerImportAppPackage,
  onImportPackageFileChange,
  triggerRestoreAppData,
  onRestoreFileChange,
  removeApp,
  refreshStore,
  saveStoreConfig,
  installStorePlugin,
  upgradeStorePlugin,
  mutateAppStorage,
} = useAppsCenterController(props, (seq) => emit("launch-handled", seq));

const appSearchQuery = ref("");
const selectedCategory = ref("all");
const storageModalOpen = ref(false);

const storeUpdateByAppId = computed(() => {
  const map = new Map<string, NonNullable<typeof store.value>["plugins"][number]>();
  for (const item of store.value?.plugins ?? []) {
    if (item.updateAvailable) map.set(item.id, item);
  }
  return map;
});

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

function hasAppIssue(app: PublicAppItem): boolean {
  return Boolean(app.diagnostic || app.lastError || app.validationError || app.web?.lastError);
}

function appIssueSummary(app: PublicAppItem): string {
  if (app.diagnostic?.summary) return app.diagnostic.summary;
  const raw = app.lastError || app.validationError || app.web?.lastError;
  return raw ? describeUserFacingError(raw) : "";
}

function cardStatus(app: PublicAppItem): { variant: "warning" | "danger" | "online" | "accent" | "neutral"; label: string } {
  if (app.pendingActivation) return { variant: "warning", label: "待首次激活" };
  if (hasAppIssue(app)) return { variant: "danger", label: "运行异常" };
  const status = appStatus(app);
  const mode = appMode(app);
  if (status === "running") return { variant: "online", label: mode === "persistent" ? "常驻运行" : "运行中" };
  if (status === "starting") return { variant: "accent", label: "正在唤醒" };
  if (mode === "static") return { variant: "neutral", label: "静态就绪" };
  return { variant: "neutral", label: "休眠就绪" };
}

function accessMeta(app: PublicAppItem): { icon: typeof Lock; label: string } {
  const policy = app.access?.policy || "admin_only";
  if (policy === "all_members") return { icon: Globe, label: "全员" };
  if (policy === "selected_members") return { icon: Users, label: `${(app.access?.allowedUserIDs || []).length} 人` };
  return { icon: Lock, label: "仅管理员" };
}
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
      @export-package="exportAppPackage(detailApp)"
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
          <IsleButton v-if="isAdmin && appStorage" variant="glass" size="sm" :disabled="busy" @click="storageModalOpen = true">
            <template #icon><HardDrive :size="15" /></template>
            数据存储位置
          </IsleButton>
          <IsleButton v-if="isAdmin" variant="glass" size="sm" :disabled="busy" @click="triggerImportAppPackage">
            <template #icon><Upload :size="15" /></template>
            导入插件包
          </IsleButton>
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="reload(isAdmin)">
            <template #icon><RefreshCcw :size="15" :class="{ spinning: busy }" /></template>
            {{ busy ? "正在刷新…" : isAdmin ? "刷新应用列表" : "刷新" }}
          </IsleButton>
        </template>
      </IslePageHeader>

      <IsleBanner v-if="launchingAppId" type="info" compact>
        <template #icon><RefreshCcw :size="16" class="spinning" /></template>
        正在唤醒轻应用...
      </IsleBanner>
      <IsleBanner v-if="error" type="error" compact :message="error" />
      <IsleBanner v-if="notice" type="success" compact :message="notice" />

      <AppStoreSection
        v-if="isAdmin"
        :store="store"
        :store-loading="storeLoading"
        :store-action-plugin-id="storeActionPluginId"
        :store-error="storeError"
        :installed-apps-count="apps.length"
        :busy="busy"
        :app-storage="appStorage"
        :selected-install-location-id="selectedInstallLocationId"
        :install-location-options="installLocationOptions"
        @update:selected-install-location-id="selectedInstallLocationId = $event"
        @refresh="refreshStore(false)"
        @install="installStorePlugin"
        @upgrade="upgradeStorePlugin"
        @save-config="saveStoreConfig"
      />

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
        :title="isAdmin ? '还没有已安装的轻应用' : '暂无已授权的轻应用'"
        :description="isAdmin ? '可在上方「在线插件商店」按需下载安装家庭轻应用，或通过右上角「导入插件包」安装本地 .liapp.zip。' : '如需访问家庭工具，请联系管理员在应用中心授权。'"
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
              <Cpu v-else :size="22" />
            </div>
            <div class="app-title-meta">
              <div class="app-title-line">
                <strong>{{ app.name }}</strong>
                <IsleBadge variant="category" size="sm">{{ categoryLabel(app.category) }}</IsleBadge>
              </div>
              <p class="app-desc">{{ app.description || "轻屿本地家庭轻应用" }}</p>
            </div>
          </div>

          <div class="app-card-status">
            <IsleBadge :variant="cardStatus(app).variant" dot size="sm">{{ cardStatus(app).label }}</IsleBadge>
            <template v-if="isAdmin">
              <span class="app-card-meta-tag">
                <component :is="accessMeta(app).icon" :size="11" aria-hidden="true" />
                <span>{{ accessMeta(app).label }}</span>
              </span>
              <span v-if="app.locationKind === 'external'" class="app-card-meta-tag">
                <HardDrive :size="11" aria-hidden="true" />
                <span>{{ app.locationName || '外置盘' }}</span>
              </span>
              <span v-if="hasCron(app)" class="app-card-meta-tag">
                <Clock :size="11" aria-hidden="true" />
                <span>{{ app.cron?.enabled ? '定时开启' : '定时暂停' }}</span>
              </span>
            </template>
          </div>

          <div v-if="isAdmin && appIssueSummary(app)" class="app-card-issue" role="alert">
            <AlertCircle :size="13" aria-hidden="true" />
            <span class="app-card-issue-text">{{ appIssueSummary(app) }}</span>
            <button type="button" class="app-card-issue-link" @click="openLogsModal(app)">查看日志</button>
          </div>

          <div class="app-card-actions">
            <IsleButton v-if="app.pendingActivation && isAdmin" variant="primary" size="sm" :disabled="busy" @click="activateApp(app)">
              <template #icon><Play :size="14" /></template>
              确认激活
            </IsleButton>
            <IsleButton v-if="app.web?.enabled !== false" :variant="app.pendingActivation && isAdmin ? 'glass' : 'primary'" size="sm" :loading="launchingAppId === app.id" :disabled="!!launchingAppId" @click="openApp(app)">
              <template #icon><Play :size="14" /></template>
              {{ launchingAppId === app.id ? "正在唤醒轻应用..." : "立即打开" }}
            </IsleButton>
            <IsleButton
              v-if="isAdmin && storeUpdateByAppId.has(app.id)"
              variant="tonal"
              size="sm"
              :loading="storeActionPluginId === app.id"
              :disabled="busy || (Boolean(storeActionPluginId) && storeActionPluginId !== app.id)"
              @click="upgradeStorePlugin(storeUpdateByAppId.get(app.id)!)"
            >
              <template #icon><ArrowUpCircle :size="14" /></template>
              更新 v{{ storeUpdateByAppId.get(app.id)!.version }}
            </IsleButton>
            <IsleButton v-if="isAdmin" variant="glass" size="sm" :disabled="busy" @click="openAppDetail(app)">
              <template #icon><Settings2 :size="14" /></template>
              详情与设置
            </IsleButton>
          </div>
        </article>
      </div>
      <input ref="restoreInputRef" type="file" accept=".tar.gz,.tgz,application/gzip" style="display:none" @change="onRestoreFileChange" />
      <input ref="packageInputRef" type="file" accept=".zip,.liapp.zip,application/zip" style="display:none" @change="onImportPackageFileChange" />
    </template>

    <IsleModal
      v-if="isAdmin && appStorage && storageModalOpen"
      title="应用数据存储位置"
      description="管理轻应用代码与独立运行数据的内置盘 / 其他盘位置"
      size="wide"
      @close="storageModalOpen = false"
    >
      <template #icon>
        <HardDrive :size="17" />
      </template>
      <IsleBanner v-if="error" type="error" compact :message="error" class="apps-modal-banner" />
      <IsleBanner v-if="notice" type="success" compact :message="notice" class="apps-modal-banner" />
      <AppStorageLocationsCard
        :storage="appStorage"
        :busy="busy"
        embedded
        @mutate="mutateAppStorage"
      />
      <template #footer>
        <div class="apps-modal-footer-end">
          <IsleButton variant="glass" size="sm" @click="storageModalOpen = false">关闭</IsleButton>
        </div>
      </template>
    </IsleModal>

    <IsleModal v-if="viewingLogsApp" :title="'运行日志 · ' + viewingLogsApp.name" size="wide" @close="viewingLogsApp = null; modalError = ''">
      <template #icon>
        <ScrollText :size="17" />
      </template>
      <template #header-actions>
        <IsleButton variant="glass" size="sm" :loading="logsLoading" :disabled="logsLoading" @click="loadLogs(viewingLogsApp)">
          <template #icon><RefreshCcw :size="14" /></template>
          刷新日志
        </IsleButton>
        <IsleButton v-if="hasCron(viewingLogsApp)" variant="glass" size="sm" :loading="busy" :disabled="busy" @click="runAction(viewingLogsApp, 'run_cron')">
          <template #icon><Play :size="14" /></template>
          立即执行 Cron
        </IsleButton>
      </template>
      <IsleBanner v-if="modalError" type="error" compact :message="modalError" class="apps-modal-banner" />
      <div v-if="viewingLogsApp.diagnostic" class="app-diag-box" role="alert">
        <div class="app-diag-title">{{ viewingLogsApp.diagnostic.summary }}</div>
        <p class="app-diag-line"><strong>原因：</strong>{{ viewingLogsApp.diagnostic.reason }}</p>
        <pre v-if="viewingLogsApp.diagnostic.logExcerpt" class="app-diag-pre">{{ viewingLogsApp.diagnostic.logExcerpt }}</pre>
        <p v-if="viewingLogsApp.diagnostic.checks?.length" class="app-diag-line"><strong>排查：</strong>{{ viewingLogsApp.diagnostic.checks[0] }}</p>
        <p v-if="viewingLogsApp.diagnostic.solutions?.length" class="app-diag-line"><strong>解决：</strong>{{ viewingLogsApp.diagnostic.solutions[0] }}</p>
        <small v-if="viewingLogsApp.diagnostic.dataSafe" class="app-diag-safe">{{ viewingLogsApp.diagnostic.dataSafe }}</small>
      </div>
      <div class="apps-form-section">
        <strong>Web 进程标准输出（最近日志）</strong>
        <pre class="apps-log-pre">{{ webOutput || "（当前无 Web 进程日志输出，或应用处于休眠/静态状态）" }}</pre>
      </div>
      <div class="apps-form-section">
        <strong>定时任务（Cron）最近执行记录</strong>
        <p v-if="cronRuns.length === 0" class="apps-hint">暂无定时执行记录。</p>
        <details v-for="(run, idx) in cronRuns" :key="run.id ?? idx" class="apps-log-detail">
          <summary>
            <ChevronRight :size="14" class="apps-log-chevron" aria-hidden="true" />
            <IsleBadge :variant="run.state === 'success' ? 'online' : (run.state === 'failure' || run.state === 'timeout') ? 'danger' : 'warning'" dot size="sm">{{ STATE_LABELS[run.state] || run.state }}</IsleBadge>
            <span>{{ localTime(run.startedAt) }}</span>
            <span v-if="run.exitCode >= 0" class="apps-hint">退出码 {{ run.exitCode }}</span>
          </summary>
          <pre class="apps-log-pre">{{ run.output || "（没有标准输出）" }}</pre>
          <p v-for="(status, channel) in run.deliveries" :key="channel" class="apps-hint">
            {{ AVAILABLE_CHANNELS.find(c => c.id === channel)?.label || channel }} · {{ DELIVERY_LABELS[status] || status }}
          </p>
        </details>
      </div>
      <template #footer>
        <div class="apps-modal-footer-end">
          <IsleButton variant="glass" @click="viewingLogsApp = null; modalError = ''">关闭</IsleButton>
        </div>
      </template>
    </IsleModal>
  </section>
</template>
