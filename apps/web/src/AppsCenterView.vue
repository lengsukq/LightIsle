<script setup lang="ts">
import { ref } from "vue";
import {
  RefreshCcw, Trash2, Clock, Bell, ScrollText, Settings2,
  Play, Square, RotateCw, ExternalLink, Maximize2, Minimize2,
  ArrowLeft, Sparkles, Cpu, Globe, Lock, Users, Copy, Terminal,
  Download, Upload, Eye, EyeOff, KeyRound, ChevronRight,
} from "lucide-vue-next";
import { describeUserFacingError } from "./userFacingError.ts";
import AppsMcpDebugModal from "./AppsMcpDebugModal.vue";
import McpClientWizardModal from "./McpClientWizardModal.vue";
import AgentConnections from "./AgentConnections.vue";
import AppleSelect from "./AppleSelect.vue";
import IsleModal from "./IsleModal.vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleEmpty from "./IsleEmpty.vue";
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
  useAppsCenterController,
  workbenchBadge,
} from "./composables/useAppsCenterController.ts";
import type {
  AppCronRunEntry,
  AppDiagnostic,
  AppMemberSummary,
  PublicAppItem,
} from "./types/appsCenter.ts";

export type AppMember = AppMemberSummary;
export type CronRun = AppCronRunEntry;
export type { AppDiagnostic };
export type AppItem = PublicAppItem;

const props = defineProps<{ active?: boolean; admin?: boolean }>();
const {
  apps,
  templates,
  isAdmin,
  mcpEnabled,
  mcpLanEnabled,
  mcpToken,
  mcpPrompt,
  lanMcpPrompt,
  mcpConfigJson,
  lanHttpUrl,
  lanSseUrl,
  mcpLogs,
  showingMcpDebugModal,
  showingClientWizard,
  configuredChannels,
  busy,
  error,
  notice,
  failedIcons,
  launchingAppId,
  activeWorkbenchApp,
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
  applyAppsPayload,
  reload,
  toggleMcp,
  toggleMcpLan,
  rotateMcpToken,
  refreshMcpLogs,
  clearMcpLogs,
  copyMcpPrompt,
  handleDebugCopy,
  openApp,
  closeWorkbench,
  refreshWorkbench,
  openInNewTab,
  runAction,
  openAccessModal,
  saveAccess,
  openConfigDrawer,
  saveConfig,
  loadLogs,
  openLogsModal,
  exportAppData,
  triggerRestoreAppData,
  onRestoreFileChange,
  removeApp,
  installOfficialTemplate,
} = useAppsCenterController(props);

const showMasterMcpToken = ref(false);
function maskedToken(tok: string): string {
  if (!tok) return "尚未生成";
  return tok.length <= 12 ? "••••••••" : `${tok.slice(0, 6)}••••••${tok.slice(-4)}`;
}
</script>

<template>
  <section class="apps-center">
    <div v-if="activeWorkbenchApp && activeIframeUrl" class="app-workbench" :class="{ fullscreen: workbenchFullscreen }">
      <header class="workbench-topbar">
        <div class="workbench-left">
          <IsleButton variant="glass" size="sm" @click="closeWorkbench"><ArrowLeft :size="15" /> 返回应用中心</IsleButton>
          <strong class="workbench-title">{{ activeWorkbenchApp.name }}</strong>
          <IsleBadge variant="accent" size="sm">{{ workbenchBadge(activeWorkbenchApp) }}</IsleBadge>
        </div>
        <div class="workbench-actions">
          <IsleButton variant="glass" size="sm" @click="refreshWorkbench"><RotateCw :size="14" /> 刷新画面</IsleButton>
          <IsleButton variant="glass" size="sm" @click="workbenchFullscreen = !workbenchFullscreen">
            <Minimize2 v-if="workbenchFullscreen" :size="14" /><Maximize2 v-else :size="14" />
            {{ workbenchFullscreen ? "退出全屏" : "全屏展开" }}
          </IsleButton>
          <IsleButton variant="primary" size="sm" @click="openInNewTab"><ExternalLink :size="14" /> 新标签页打开</IsleButton>
        </div>
      </header>
      <iframe
        :key="iframeKey" :src="activeIframeUrl"
        sandbox="allow-scripts allow-forms allow-same-origin allow-popups allow-downloads"
        referrerpolicy="no-referrer"
        class="app-workbench-iframe" :title="activeWorkbenchApp.name"
      />
    </div>

    <template v-else>
      <header class="apps-header">
        <div>
          <h2>应用中心</h2>
          <p v-if="isAdmin">按需唤醒家庭轻应用与定时采集插件，闲置自动休眠并支持按成员授权。</p>
          <p v-else>打开已授权的家庭轻应用，免二次登录。</p>
        </div>
        <IsleButton variant="glass" :disabled="busy" @click="reload(isAdmin)">
          <RefreshCcw :size="15" :class="{ spinning: busy }" />
          {{ busy ? "正在刷新…" : isAdmin ? "刷新应用列表" : "刷新" }}
        </IsleButton>
      </header>

      <section v-if="isAdmin" class="mcp-unified-card" aria-label="AI Agent (MCP) 服务">
        <!-- 主开关层级：默认启用本机免令牌直连 -->
        <div class="mcp-layer-row">
          <div class="mcp-bar-info">
            <div class="mcp-title-row">
              <Terminal :size="17" />
              <strong>AI Agent (MCP) 服务</strong>
              <IsleBadge :variant="mcpEnabled ? 'online' : 'offline'" dot size="sm">
                {{ mcpEnabled ? (mcpLanEnabled ? "本机直连 + 远程已开启" : "本机免令牌直连已开启") : "已关闭" }}
              </IsleBadge>
            </div>
            <small>打开主开关默认启用本机免令牌直连（<code>lightisled mcp</code>，兼容 Gemini 桌面端沙盒桥接、Claude Desktop 与 Cursor）；关闭主开关将联动关闭局域网 / Cloud MCP 访问。</small>
          </div>
          <div class="mcp-bar-actions">
            <IsleButton variant="primary" :disabled="busy" @click="showingClientWizard = true">
              <Sparkles :size="14" /> 客户端接入向导
            </IsleButton>
            <IsleButton variant="glass" :disabled="busy" @click="copyMcpPrompt(false)">
              <Copy :size="14" /> 复制提示词
            </IsleButton>
            <button
              type="button"
              role="switch"
              :aria-checked="mcpEnabled"
              aria-label="开启或关闭 AI Agent (MCP) 服务"
              class="isle-switch"
              :class="{ on: mcpEnabled }"
              :disabled="busy"
              @click="toggleMcp()"
            >
              <span class="isle-switch-thumb"></span>
              <span class="isle-switch-text">{{ mcpEnabled ? "已开启" : "已关闭" }}</span>
            </button>
          </div>
        </div>

        <!-- 从属子开关：仅主开关开启后展示 -->
        <Transition name="mcp-slide">
          <div v-if="mcpEnabled" class="mcp-sub-container">
            <div class="mcp-layer-row mcp-sub-row">
              <div class="mcp-bar-info">
                <div class="mcp-title-row">
                  <Globe :size="16" />
                  <strong>允许局域网 / Cloud MCP 访问</strong>
                  <IsleBadge :variant="mcpLanEnabled ? 'accent' : 'neutral'" size="sm">
                    {{ mcpLanEnabled ? "/api/v2/mcp 已就绪" : "仅本机直连" }}
                  </IsleBadge>
                </div>
                <small>开启后可在局域网或 Gemini Cloud MCP 中通过 Streamable HTTP (<code>/api/v2/mcp</code>) 与 SSE 持 Bearer Token 接入，并可查看实时调用日志。</small>
              </div>
              <div class="mcp-bar-actions">
                <IsleButton variant="glass" size="sm" :disabled="busy" @click="showingMcpDebugModal = true">
                  <Terminal :size="14" /> MCP 交互调试台
                </IsleButton>
                <button
                  type="button"
                  role="switch"
                  :aria-checked="mcpLanEnabled"
                  aria-label="允许局域网或 Cloud MCP 访问"
                  class="isle-switch"
                  :class="{ on: mcpLanEnabled }"
                  :disabled="busy"
                  @click="toggleMcpLan()"
                >
                  <span class="isle-switch-thumb"></span>
                  <span class="isle-switch-text">{{ mcpLanEnabled ? "已允许" : "未开启" }}</span>
                </button>
              </div>
            </div>

            <!-- 打开子开关才平滑展开：远程 URL、鉴权 Token 管理与底部可折叠调用日志 -->
            <Transition name="mcp-slide">
              <div v-if="mcpLanEnabled" class="mcp-lan-expanded">
                <div class="mcp-remote-urls">
                  <div class="mcp-endpoint-item">
                    <span>Streamable HTTP / Cloud MCP URL</span>
                    <div class="mcp-endpoint-line">
                      <code>{{ lanHttpUrl || "/api/v2/mcp" }}</code>
                      <IsleButton variant="glass" size="sm" @click="handleDebugCopy(lanHttpUrl || '/api/v2/mcp', '已复制 Streamable HTTP 端点 URL')">
                        <Copy :size="13" /> 复制 URL
                      </IsleButton>
                    </div>
                  </div>
                  <div class="mcp-endpoint-item">
                    <span>备用 SSE 端点 URL</span>
                    <div class="mcp-endpoint-line">
                      <code>{{ lanSseUrl || "/api/v2/mcp/sse" }}</code>
                      <IsleButton variant="glass" size="sm" @click="handleDebugCopy(lanSseUrl || '/api/v2/mcp/sse', '已复制 SSE 端点 URL')">
                        <Copy :size="13" /> 复制 SSE
                      </IsleButton>
                    </div>
                  </div>
                </div>

                <div class="mcp-token-box">
                  <div class="mcp-token-row">
                    <div>
                      <strong>系统管理员 Master Token</strong>
                      <code class="mcp-token-value">{{ showMasterMcpToken ? mcpToken : maskedToken(mcpToken) }}</code>
                    </div>
                    <div class="mcp-bar-actions">
                      <IsleButton variant="glass" size="sm" @click="showMasterMcpToken = !showMasterMcpToken">
                        <EyeOff v-if="showMasterMcpToken" :size="13" />
                        <Eye v-else :size="13" />
                        {{ showMasterMcpToken ? "隐藏" : "显示" }}
                      </IsleButton>
                      <IsleButton variant="glass" size="sm" :disabled="!mcpToken" @click="handleDebugCopy(mcpToken, '已复制系统级 MCP Bearer Token')">
                        <Copy :size="13" /> 复制 Token
                      </IsleButton>
                      <IsleButton variant="glass" size="sm" :disabled="busy" @click="rotateMcpToken">
                        <KeyRound :size="13" /> 轮换 Token
                      </IsleButton>
                    </div>
                  </div>
                  <div class="mcp-agent-tokens-divider">
                    <AgentConnections compact />
                  </div>
                </div>

                <details class="mcp-logs-collapse">
                  <summary>
                    <span class="mcp-logs-title"><ChevronRight :size="14" class="mcp-log-chev" /> 最近 MCP 调用日志（{{ mcpLogs.length }} 条）</span>
                    <span class="mcp-logs-summary-actions" @click.stop>
                      <button type="button" class="mcp-mini-btn" :disabled="busy" @click="refreshMcpLogs">刷新</button>
                      <button v-if="mcpLogs.length" type="button" class="mcp-mini-btn" :disabled="busy" @click="clearMcpLogs">清空</button>
                    </span>
                  </summary>
                  <div class="mcp-logs-body">
                    <p v-if="!mcpLogs.length" class="mcp-logs-empty">暂无最近调用记录。</p>
                    <div v-else class="mcp-logs-list">
                      <div v-for="(entry, idx) in mcpLogs.slice(0, 15)" :key="idx" class="mcp-log-entry" :class="{ err: entry.isError }">
                        <code>[{{ entry.transport }}] {{ entry.method }} {{ entry.target || "" }}</code>
                        <small>{{ entry.durationMs }} ms · {{ entry.remoteAddr || "local" }}</small>
                      </div>
                    </div>
                  </div>
                </details>
              </div>
            </Transition>
          </div>
        </Transition>
      </section>

      <IsleBanner v-if="launchingAppId" type="info" compact style="margin-bottom: 14px">
        <template #icon><RefreshCcw :size="16" class="spinning" /></template>
        正在唤醒轻应用...
      </IsleBanner>
      <IsleBanner v-if="error" type="error" compact style="margin-bottom: 14px" :message="error" />
      <IsleBanner v-if="notice" type="success" compact style="margin-bottom: 14px" :message="notice" />

      <section v-if="isAdmin && templates.length > 0" class="mcp-bar" aria-label="官方精选家庭轻应用模板">
        <div class="mcp-bar-info" style="flex: 1 1 100%">
          <div class="mcp-title-row">
            <Sparkles :size="17" />
            <strong>官方精选家庭轻应用模板（0 MB 纯静态即装即用）</strong>
            <IsleBadge variant="accent" size="sm">零外部依赖</IsleBadge>
          </div>
          <small>随包内置高频家庭小工具，点击即可安装到 <code>plugins/</code> 目录并可在「成员权限」中授权给家人。</small>
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
        :description="isAdmin ? '开启上方 MCP 服务并复制提示词给本地 AI Agent，即可生成或接入家庭轻应用。' : '如需访问家庭工具，请联系管理员在应用中心授权。'"
      />

      <div v-else class="apps-grid">
        <article v-for="app in apps" :key="app.id" class="app-card">
          <div class="app-card-top">
            <div class="app-icon-wrap">
              <img v-if="app.iconUrl && !failedIcons.has(app.id)" :src="app.iconUrl" :alt="app.name + ' 图标'" class="app-icon-img" @error="failedIcons.add(app.id)" />
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
            <IsleButton v-if="app.web?.enabled !== false" variant="primary" :disabled="!!launchingAppId" @click="openApp(app)">
              <Play :size="14" /> {{ launchingAppId === app.id ? "正在唤醒轻应用..." : "立即打开" }}
            </IsleButton>
            <template v-if="isAdmin">
              <IsleButton variant="glass" :disabled="busy" @click="openAccessModal(app)"><Users :size="14" /> 成员权限</IsleButton>
              <IsleButton variant="glass" :disabled="busy" @click="openConfigDrawer(app)"><Settings2 :size="14" /> 生命周期与定时</IsleButton>
              <IsleButton variant="glass" :disabled="busy" @click="openLogsModal(app)"><ScrollText :size="14" /> 运行日志</IsleButton>
              <template v-if="appMode(app) !== 'static'">
                <IsleButton v-if="appStatus(app) === 'running'" variant="glass" :disabled="busy" @click="runAction(app, 'stop')"><Square :size="13" /> 停止</IsleButton>
                <IsleButton v-else variant="glass" :disabled="busy" @click="runAction(app, 'start')"><Play :size="13" /> 启动</IsleButton>
              </template>
              <IsleButton v-if="hasCron(app)" variant="glass" :disabled="busy" @click="runAction(app, 'run_cron')"><Clock :size="13" /> 立即采集</IsleButton>
              <IsleButton variant="glass" :disabled="busy" @click="exportAppData(app)"><Download :size="13" /> 导出数据</IsleButton>
              <IsleButton variant="glass" :disabled="busy" @click="triggerRestoreAppData(app)"><Upload :size="13" /> 恢复数据</IsleButton>
              <IsleButton variant="danger" :disabled="busy || appStatus(app) === 'running'" @click="removeApp(app)"><Trash2 :size="13" /> 删除</IsleButton>
            </template>
          </div>
        </article>
      </div>
      <input ref="restoreInputRef" type="file" accept=".tar.gz,.tgz,application/gzip" style="display:none" @change="onRestoreFileChange" />
    </template>

    <IsleModal
      v-if="editingAccessApp"
      :title="'成员权限 · ' + editingAccessApp.name"
      size="md"
      @close="editingAccessApp = null"
    >
      <template #icon>
        <Users :size="17" />
      </template>
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
          <IsleButton variant="glass" @click="editingAccessApp = null">取消</IsleButton>
          <IsleButton variant="primary" :disabled="busy" @click="saveAccess">保存权限</IsleButton>
        </div>
      </template>
    </IsleModal>

    <IsleModal
      v-if="editingConfigApp"
      :title="'生命周期与定时 · ' + editingConfigApp.name"
      size="md"
      @close="editingConfigApp = null"
    >
      <template #icon>
        <Settings2 :size="17" />
      </template>
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
          <IsleButton variant="glass" @click="editingConfigApp = null">取消</IsleButton>
          <IsleButton variant="primary" :disabled="busy" @click="saveConfig">保存设置</IsleButton>
        </div>
      </template>
    </IsleModal>

    <IsleModal
      v-if="viewingLogsApp"
      :title="'运行日志 · ' + viewingLogsApp.name"
      size="wide"
      @close="viewingLogsApp = null"
    >
      <template #icon>
        <ScrollText :size="17" />
      </template>
      <template #header-actions>
        <IsleButton variant="glass" size="sm" :disabled="logsLoading" @click="loadLogs(viewingLogsApp)"><RefreshCcw :size="14" /> 刷新日志</IsleButton>
        <IsleButton v-if="hasCron(viewingLogsApp)" variant="glass" size="sm" :disabled="busy" @click="runAction(viewingLogsApp, 'run_cron')"><Play :size="14" /> 立即执行 Cron</IsleButton>
      </template>
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
          <IsleButton variant="glass" @click="viewingLogsApp = null">关闭</IsleButton>
        </div>
      </template>
    </IsleModal>

    <AppsMcpDebugModal
      v-if="showingMcpDebugModal"
      :apps="apps"
      :mcp-enabled="mcpEnabled"
      :mcp-lan-enabled="mcpLanEnabled"
      :mcp-token="mcpToken"
      :mcp-prompt="mcpPrompt"
      :lan-mcp-prompt="lanMcpPrompt"
      :mcp-config-json="mcpConfigJson"
      :lan-http-url="lanHttpUrl"
      :lan-sse-url="lanSseUrl"
      :mcp-logs="mcpLogs"
      @close="showingMcpDebugModal = false"
      @updated="applyAppsPayload"
      @copy="handleDebugCopy"
    />

    <McpClientWizardModal
      :open="showingClientWizard"
      :mcp-enabled="mcpEnabled"
      :mcp-lan-enabled="mcpLanEnabled"
      :mcp-token="mcpToken"
      :mcp-prompt="mcpPrompt"
      :lan-mcp-prompt="lanMcpPrompt"
      :lan-http-url="lanHttpUrl"
      :lan-sse-url="lanSseUrl"
      :busy="busy"
      @close="showingClientWizard = false"
      @copy="handleDebugCopy"
      @enable-mcp="toggleMcp(true)"
      @enable-lan-mcp="toggleMcpLan(true)"
    />
  </section>
</template>

<style scoped src="./AppsCenterView.css"></style>
