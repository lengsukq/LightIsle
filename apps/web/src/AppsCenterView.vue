<script setup lang="ts">
import {
  RefreshCcw, Clock, Bell, ScrollText, Settings2,
  Play, Sparkles, Cpu, Globe, Lock, Users,
} from "lucide-vue-next";
import { describeUserFacingError } from "./userFacingError.ts";
import AppDetailPanel from "./AppDetailPanel.vue";
import AppStorageLocationsCard from "./AppStorageLocationsCard.vue";
import AppWorkbenchStage from "./AppWorkbenchStage.vue";
import AppleSelect from "./AppleSelect.vue";
import IsleModal from "./IsleModal.vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleEmpty from "./IsleEmpty.vue";
import IsleHelpButton from "./IsleHelpButton.vue";
import IslePageHeader from "./IslePageHeader.vue";
import {
  AVAILABLE_CHANNELS,
  DELIVERY_LABELS,
  STATE_LABELS,
  WEB_MODE_OPTIONS,
  accessBadge,
  appMode,
  appStatus,
  categoryLabel,
  cronSummary,
  flipItem,
  localTime,
  runtimeBadge,
  type AppLaunchRequest,
  useAppsCenterController,
  workbenchBadge,
} from "./composables/useAppsCenterController.ts";
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
  editingAccessApp,
  accessPolicy,
  accessAllowedUserIDs,
  nonAdminMembers,
  editingConfigApp,
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
  hasWeb,
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
  saveAccess,
  saveConfig,
  activateApp,
  loadLogs,
  exportAppData,
  triggerRestoreAppData,
  onRestoreFileChange,
  removeApp,
  installOfficialTemplate,
  mutateAppStorage,
} = useAppsCenterController(props, (seq) => emit("launch-handled", seq));
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
      <IslePageHeader title="应用中心">
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
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="reload(isAdmin)">
            <template #icon><RefreshCcw :size="15" :class="{ spinning: busy }" /></template>
            {{ busy ? "正在刷新…" : isAdmin ? "刷新应用列表" : "刷新" }}
          </IsleButton>
        </template>
      </IslePageHeader>

      <section v-if="isAdmin && appStorage" aria-label="应用数据存储位置">
        <AppStorageLocationsCard
          :storage="appStorage"
          :busy="busy"
          @mutate="mutateAppStorage"
        />
      </section>

      <IsleBanner v-if="launchingAppId" type="info" compact style="margin-bottom: 14px">
        <template #icon><RefreshCcw :size="16" class="spinning" /></template>
        正在唤醒轻应用...
      </IsleBanner>
      <IsleBanner v-if="error" type="error" compact style="margin-bottom: 14px" :message="error" />
      <IsleBanner v-if="notice" type="success" compact style="margin-bottom: 14px" :message="notice" />

      <section v-if="isAdmin && templates.length > 0" class="apps-templates-bar" aria-label="官方精选家庭轻应用模板">
        <div class="apps-templates-info" style="flex: 1 1 100%">
          <div class="apps-templates-title">
            <Sparkles :size="17" />
            <strong>官方精选家庭轻应用模板</strong>
            <IsleBadge variant="accent" size="sm">零外部依赖</IsleBadge>
          </div>
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
        </div>
      </section>

      <IsleEmpty
        v-if="apps.length === 0 && !busy && !error"
        :icon="Sparkles"
        card
        :title="isAdmin ? '暂无轻应用插件' : '暂无已授权的轻应用'"
        :description="isAdmin ? '可在上方一键安装官方精选家庭轻应用，或在 Mac 端 LightIsle 客户端中添加或开发轻应用。' : '如需访问家庭工具，请联系管理员在应用中心授权。'"
      />

      <div v-else class="apps-grid">
        <article v-for="app in apps" :key="app.id" class="app-card">
          <div class="app-card-top">
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
            <IsleBadge :variant="app.locationKind === 'external' ? 'accent' : 'neutral'" size="sm">
              {{ app.locationKind === 'external' ? `其他盘 · ${app.locationName || '外置盘'}` : `内置盘 · ${app.locationName || 'Mac 内置盘'}` }}
            </IsleBadge>
            <IsleBadge variant="neutral" size="sm">{{ accessBadge(app) }}</IsleBadge>
            <IsleBadge variant="neutral" size="sm">{{ cronSummary(app) }}</IsleBadge>
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
      v-if="editingAccessApp"
      :title="'成员权限 · ' + editingAccessApp.name"
      size="md"
      :close-on-backdrop="!busy"
      :close-on-esc="!busy"
      :show-close="!busy"
      @close="editingAccessApp = null; modalError = ''"
    >
      <template #icon>
        <Users :size="17" />
      </template>
      <IsleBanner v-if="modalError" type="error" compact :message="modalError" style="margin-bottom: 12px" />
      <div class="apps-radio-group">
        <label class="apps-radio-option"><input v-model="accessPolicy" type="radio" value="admin_only" /><div><strong><Lock :size="14" /> 仅管理员（默认推荐）</strong><small>仅管理员可见与使用</small></div></label>
        <label class="apps-radio-option"><input v-model="accessPolicy" type="radio" value="selected_members" /><div><strong><Users :size="14" /> 指定家庭成员</strong><small>管理员与勾选成员可见并使用</small></div></label>
        <label class="apps-radio-option"><input v-model="accessPolicy" type="radio" value="all_members" /><div><strong><Globe :size="14" /> 全员可用</strong><small>所有已登录家庭成员可用</small></div></label>
      </div>
      <div v-if="accessPolicy === 'selected_members'" class="apps-member-checklist">
        <strong>选择允许访问的家庭成员</strong>
        <p v-if="nonAdminMembers.length === 0" class="apps-hint">暂无普通家庭成员账号。</p>
        <label v-for="m in nonAdminMembers" :key="m.id" class="apps-check-item">
          <input type="checkbox" class="isle-checkbox" :checked="accessAllowedUserIDs.includes(m.id)" @change="accessAllowedUserIDs = flipItem(accessAllowedUserIDs, m.id)" />
          <span>{{ m.username }}</span>
        </label>
      </div>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:10px;width:100%">
          <IsleButton variant="glass" :disabled="busy" @click="editingAccessApp = null; modalError = ''">取消</IsleButton>
          <IsleButton variant="primary" :loading="busy" :disabled="busy" @click="saveAccess">保存权限</IsleButton>
        </div>
      </template>
    </IsleModal>

    <IsleModal
      v-if="editingConfigApp"
      :title="'生命周期与定时 · ' + editingConfigApp.name"
      size="md"
      :close-on-backdrop="!busy"
      :close-on-esc="!busy"
      :show-close="!busy"
      @close="editingConfigApp = null; modalError = ''"
    >
      <template #icon>
        <Settings2 :size="17" />
      </template>
      <IsleBanner v-if="modalError" type="error" compact :message="modalError" style="margin-bottom: 12px" />
      <div v-if="hasWeb(editingConfigApp)" class="apps-form-section">
        <strong>Web 运行模式</strong>
        <label class="apps-check-item"><input v-model="webEnabled" type="checkbox" /> 启用 Web 界面入口</label>
        <div class="apps-inputs">
          <label>运行模式
            <AppleSelect v-model="webMode" block :options="WEB_MODE_OPTIONS" />
          </label>
          <label v-if="webMode === 'on-demand'">闲置自动休眠时长（秒）
            <input v-model.number="webIdleTimeoutSeconds" type="number" min="60" max="86400" step="60" />
          </label>
        </div>
        <label v-if="webMode === 'persistent'" class="apps-check-item"><input v-model="webAutoRestart" type="checkbox" /> 进程异常退出时自动重启</label>
      </div>
      <div v-if="hasCron(editingConfigApp)" class="apps-form-section">
        <strong><Clock :size="14" /> 后台定时采集 / 任务 (Cron)</strong>
        <label class="apps-check-item"><input v-model="cronEnabled" type="checkbox" /> 启用定时任务调度</label>
        <div class="apps-inputs">
          <label>五段 Cron 表达式<input v-model.trim="cronExpr" placeholder="*/15 * * * *" /></label>
          <label>时区<input v-model.trim="cronTimezone" placeholder="Asia/Shanghai" /></label>
        </div>
        <div class="apps-checks">
          <strong><Bell :size="14" /> 通知事件</strong>
          <label v-for="ev in [{ id: 'failure', name: '执行失败' }, { id: 'timeout', name: '执行超时' }, { id: 'success', name: '执行成功' }]" :key="ev.id">
            <input type="checkbox" class="isle-checkbox" :checked="cronEvents.includes(ev.id)" @change="cronEvents = flipItem(cronEvents, ev.id)" />{{ ev.name }}
          </label>
        </div>
        <div class="apps-checks">
          <strong>通知渠道</strong>
          <label v-for="ch in AVAILABLE_CHANNELS" :key="ch.id">
            <input type="checkbox" class="isle-checkbox" :disabled="!configuredChannels.includes(ch.id)" :checked="cronChannels.includes(ch.id)" @change="cronChannels = flipItem(cronChannels, ch.id)" />
            {{ ch.label }}<small v-if="!configuredChannels.includes(ch.id)">未配置</small>
          </label>
        </div>
      </div>
      <template #footer>
        <div style="display:flex;justify-content:flex-end;gap:10px;width:100%">
          <IsleButton variant="glass" :disabled="busy" @click="editingConfigApp = null; modalError = ''">取消</IsleButton>
          <IsleButton variant="primary" :loading="busy" :disabled="busy" @click="saveConfig">保存设置</IsleButton>
        </div>
      </template>
    </IsleModal>

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
