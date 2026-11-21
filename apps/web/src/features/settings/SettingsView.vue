<script setup lang="ts">
import { computed, defineAsyncComponent, inject, ref } from "vue";
import {
  Activity, ChevronRight, Folder, Images, LogOut, Monitor, RefreshCcw,
  ShieldCheck, Workflow,
} from "lucide-vue-next";
import { SETTINGS_VIEW_CTX } from "../../contexts/shellContexts.ts";
import type { ShellSettingsGroup } from "../../utils/shellRouteGuard.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import IsleActionMenu from "../../components/ui/IsleActionMenu.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import CacheManagementPanel from "./CacheManagementPanel.vue";
import DavAccess from "../storage/DavAccess.vue";
import SmbManagement from "../storage/SmbManagement.vue";
import TailscaleGuideCard from "../storage/TailscaleGuideCard.vue";
import UserStoragePanel from "../storage/UserStoragePanel.vue";
import DiskManagement from "../storage/DiskManagement.vue";
import AlertsView from "./AlertsView.vue";
import OpsTaskCenter from "./OpsTaskCenter.vue";
import UploadMaintenance from "./UploadMaintenance.vue";
import UploadCleanupRules from "./UploadCleanupRules.vue";
import OpsDiagnostics from "./OpsDiagnostics.vue";
import BetaDiagnosticReport from "./BetaDiagnosticReport.vue";
import AuditLogView from "./AuditLogView.vue";
import PendingReservations from "./PendingReservations.vue";
import PendingMedia from "./PendingMedia.vue";

const AutomationView = defineAsyncComponent(() => import("../automation/AutomationView.vue"));

const ctx = inject(SETTINGS_VIEW_CTX);
if (!ctx) throw new Error("SettingsView requires SETTINGS_VIEW_CTX");

const {
  active, settingsGroup, user, sharedRoots, selectedRootID, selectedRoot,
  selectedRootGeneration, multiRootMode, rootViewKey, rootDiscoveryState, rootDiscoveryError,
  rootFeatureContextReady, accounts, userError, currentPassword, nextPassword, repeatPassword,
  passwordBusy, passwordError, newUsername, newPassword, creatingUser, createUserError,
  createUserNotice, lastCreatedMember, clearLastCreatedMember, memberActionBusy,
  memberActionError, memberActionNotice, resetTargetUser, resetMemberNewPassword,
  resetMemberRepeatPassword, resetMemberBusy, resetMemberError, loadAccounts,
  createMemberAccount, toggleMemberEnabled, openResetMemberPassword, closeResetMemberPassword,
  submitResetMemberPassword, changeOwnPassword, grantUser, grants, grantError, grantNotice,
  grantPathInput, grantCanWrite, grantBusy, editGrants, saveGrant, toggleGrantWrite, removeGrant,
  loginSessions, sessionsLoading, sessionsLoaded, sessionsTruncated, sessionsError,
  sessionsMessage, loadLoginSessions, revokeLoginSession, activeShares, sharesLoading,
  sharesError, sharesLoaded, loadMyShares, revokeFileShare, tasks, taskError, taskHistory,
  taskHistoryError, taskHistoryLoading, taskHistoryNextCursor, refreshTaskCenter, taskControl,
  startMediaTask, reloadTaskHistory, advancedDiagnosticsOpen, automationDisclosureOpen,
  pendingMediaOpen, adminPendingMediaOpen, togglePendingMedia, toggleAdvanced, logout,
} = ctx;

const settingsGroups = computed<Array<{ key: ShellSettingsGroup; label: string }>>(() => {
  if (user.value?.role === "admin") {
    return [
      { key: "storage", label: "成员与空间" },
      { key: "files", label: "文件与连接" },
      { key: "ops", label: "状态与维护" },
      { key: "account", label: "账号与缓存" },
    ];
  }
  return [
    { key: "account", label: "账号与安全" },
    { key: "files", label: "文件与连接" },
    { key: "cache", label: "本地缓存" },
  ];
});

let allocRequestSeq = 0;
const pendingAllocRequest = ref<{ userId: number; seq: number } | null>(null);

function triggerAllocForMember(userId: number) {
  allocRequestSeq += 1;
  pendingAllocRequest.value = { userId, seq: allocRequestSeq };
  clearLastCreatedMember();
}
</script>

<template>
  <div v-if="user" class="content settings-page isle-tab-pane">
    <IslePageHeader title="偏好设置" :subtitle="user.role === 'admin' ? '管理家庭成员与空间、远程连接、运行状态及账号缓存' : '管理账号安全、远程连接与本地缓存'">
      <template #actions>
        <IsleButton variant="glass" size="sm" @click="logout"><template #icon><LogOut :size="14" /></template>退出登录</IsleButton>
      </template>
    </IslePageHeader>

    <div class="settings-workspace">
      <nav class="settings-nav" aria-label="设置分类">
        <button
          v-for="group in settingsGroups"
          :key="group.key"
          type="button"
          :class="{ active: settingsGroup === group.key }"
          @click="settingsGroup = group.key"
        >
          {{ group.label }}
        </button>
      </nav>

      <Transition name="ios-fade" mode="out-in">
        <div :key="settingsGroup" class="settings-stack">
          <CacheManagementPanel v-if="settingsGroup === 'cache' && user.role !== 'admin'" :is-admin="false" :active="active === 'settings'" />

          <template v-if="settingsGroup === 'files'">
            <DavAccess />
            <SmbManagement v-if="user.role === 'admin'" />
            <TailscaleGuideCard v-if="user.role === 'admin'" />
            <IsleCard title="我的文件分享" subtitle="限时外链最长 7 天有效，可随时撤销。">
              <template #icon><Folder :size="18" /></template>
              <template #actions>
                <IsleButton variant="glass" size="sm" :loading="sharesLoading" :disabled="!rootFeatureContextReady" @click="loadMyShares">
                  <template #icon><RefreshCcw :size="14" /></template>{{ sharesLoading ? "加载中…" : "刷新" }}
                </IsleButton>
              </template>
              <p v-if="!rootFeatureContextReady" class="footnote">请先选择一个可访问的共享目录，再管理该目录中的分享。</p>
              <IsleEmpty v-else-if="sharesLoaded && !activeShares.length" compact :icon="Folder" title="暂无有效的分享链接" description="可在「私人文件」页选择文件或文件夹后创建分享链接。" />
              <IsleEmpty v-else-if="!sharesLoaded && !sharesLoading" compact :icon="Folder" title="点击右上角「刷新」加载分享记录" />
              <div v-for="share in activeShares" :key="share.id" class="account-row">
                <div>
                  <strong class="settings-row-title">
                    <span>{{ share.path }}</span>
                    <IsleBadge v-if="share.kind === 'dir'" variant="accent" size="sm">文件夹 ZIP</IsleBadge>
                    <IsleBadge v-if="share.hasPassword" variant="warning" size="sm">密码保护</IsleBadge>
                    <IsleBadge v-if="(share.maxDownloads ?? 0) > 0" variant="neutral" size="sm">限 {{ share.maxDownloads }} 次下载<template v-if="(share.downloadCount ?? 0) > 0">（已用 {{ share.downloadCount }}）</template></IsleBadge>
                  </strong>
                  <small>创建：{{ formatDateTime(share.createdAt * 1000) }} · 到期：{{ formatDateTime(share.expiresAt * 1000) }}</small>
                </div>
                <IsleButton variant="danger" size="sm" @click="revokeFileShare(share)">撤销链接</IsleButton>
              </div>
              <IsleBanner v-if="sharesError" type="error" compact role="alert" :message="sharesError" />
            </IsleCard>
          </template>

          <template v-if="settingsGroup === 'storage' && user.role === 'admin'">
            <IsleCard title="成员账号与权限管理" subtitle="创建家庭成员账号，并配置共享目录或电脑文件访问权限。">
              <template #icon><Monitor :size="18" /></template>
              <template #actions>
                <IsleButton variant="glass" size="sm" @click="loadAccounts"><template #icon><RefreshCcw :size="14" /></template>刷新</IsleButton>
              </template>
              <form class="account-form settings-form-subcard settings-form-gap" @submit.prevent="createMemberAccount">
                <div class="settings-form-grid-2">
                  <label>新成员用户名<input v-model.trim="newUsername" minlength="3" maxlength="32" autocomplete="off" placeholder="3–32 位字母/数字/下划线" required /></label>
                  <label>初始密码<input v-model="newPassword" type="password" minlength="12" maxlength="256" autocomplete="new-password" placeholder="至少 12 位初始密码" required /></label>
                </div>
                <div class="settings-form-actions">
                  <IsleButton type="submit" variant="primary" size="md" :loading="creatingUser">{{ creatingUser ? "正在创建…" : "新增家庭成员" }}</IsleButton>
                </div>
              </form>
              <IsleBanner v-if="createUserError || userError || memberActionError" class="settings-banner-gap" type="error" compact role="alert" :message="createUserError || userError || memberActionError" />
              <IsleBanner v-if="createUserNotice || memberActionNotice" class="settings-banner-gap" type="success" compact role="status" :message="createUserNotice || memberActionNotice">
                <template v-if="lastCreatedMember && createUserNotice" #action>
                  <IsleButton variant="primary" size="sm" @click="triggerAllocForMember(lastCreatedMember.id)">立即分配存储空间</IsleButton>
                </template>
              </IsleBanner>
              <div v-for="account in accounts" :key="account.id" class="account-row">
                <div>
                  <strong class="settings-row-title">
                    <span>{{ account.username }}</span>
                    <IsleBadge :variant="account.role === 'admin' ? 'accent' : 'neutral'" size="sm">{{ account.role === "admin" ? "管理员 · 默认无限配额" : "家庭成员" }}</IsleBadge>
                    <IsleBadge :variant="account.enabled ? 'online' : 'offline'" size="sm" dot>{{ account.enabled ? "已启用" : "已停用" }}</IsleBadge>
                  </strong>
                </div>
                <div v-if="account.role === 'member'" class="settings-row-actions">
                  <IsleButton variant="tonal" size="sm" :disabled="multiRootMode && !selectedRootID" @click="editGrants(account)">共享目录权限</IsleButton>
                  <IsleButton variant="tonal" size="sm" title="前往「电脑文件」页面可视化点选授权目录" @click="active = 'computer'">电脑文件权限</IsleButton>
                  <IsleActionMenu :aria-label="'更多账号操作：' + account.username">
                    <button type="button" role="menuitem" @click="triggerAllocForMember(account.id)">分配存储空间</button>
                    <button type="button" role="menuitem" @click="openResetMemberPassword(account)">重置密码</button>
                    <button type="button" role="menuitem" :class="{ danger: account.enabled }" :disabled="memberActionBusy" @click="toggleMemberEnabled(account)">
                      {{ account.enabled ? "停用账号" : "启用账号" }}
                    </button>
                  </IsleActionMenu>
                </div>
              </div>
              <div v-if="resetTargetUser" class="grant-details-drawer">
                <div class="account-heading"><h3>重置密码 · {{ resetTargetUser.username }}</h3><IsleButton variant="glass" size="sm" @click="closeResetMemberPassword">关闭</IsleButton></div>
                <p>重置后该成员的已有登录会话将立即失效。</p>
                <form class="account-form" @submit.prevent="submitResetMemberPassword">
                  <div class="settings-form-grid-2">
                    <label>新密码<input v-model="resetMemberNewPassword" type="password" minlength="12" maxlength="256" autocomplete="new-password" placeholder="至少 12 位" required /></label>
                    <label>确认新密码<input v-model="resetMemberRepeatPassword" type="password" minlength="12" maxlength="256" autocomplete="new-password" placeholder="再次输入新密码" required /></label>
                  </div>
                  <div class="settings-form-actions"><IsleButton type="submit" variant="primary" size="sm" :loading="resetMemberBusy">{{ resetMemberBusy ? "正在重置…" : "确认重置密码" }}</IsleButton></div>
                </form>
                <IsleBanner v-if="resetMemberError" type="error" compact role="alert" :message="resetMemberError" />
              </div>
              <div v-if="grantUser" class="grant-details-drawer">
                <div class="account-heading"><h3>{{ grantUser.username }} · 共享文件夹授权</h3><IsleButton variant="glass" size="sm" @click="grantUser = null">关闭</IsleButton></div>
                <p>当前管理{{ multiRootMode ? `“${selectedRoot?.name ?? "当前共享目录"}”` : "共享目录" }}的访问授权（输入相对路径，例如 <code>Family</code> 或 <code>.</code>）。</p>
                <form class="account-form settings-grant-form" @submit.prevent="saveGrant">
                  <label>共享文件夹相对路径<input v-model.trim="grantPathInput" placeholder="例如 Family 或 Photos/Shared（留空或 . 代表根目录）" /></label>
                  <label class="settings-inline-check"><input v-model="grantCanWrite" type="checkbox" /><span>允许读写（勾选为读写，不勾选为只读）</span></label>
                  <div class="settings-form-actions"><IsleButton type="submit" variant="primary" size="sm" :loading="grantBusy">{{ grantBusy ? "正在保存…" : "添加 / 更新目录授权" }}</IsleButton></div>
                </form>
                <div v-if="!grants.length" class="footnote">尚未配置共享目录授权。</div>
                <div v-for="g in grants" :key="g.path" class="account-row">
                  <div><strong class="settings-row-title"><span>{{ g.path }}</span><IsleBadge :variant="g.canWrite ? 'online' : 'neutral'" size="sm">{{ g.canWrite ? '可读写' : '只读' }}</IsleBadge></strong></div>
                  <div class="settings-row-actions">
                    <IsleButton variant="glass" size="sm" :disabled="grantBusy" @click="toggleGrantWrite(g)">{{ g.canWrite ? "改为只读" : "改为读写" }}</IsleButton>
                    <IsleButton variant="danger" size="sm" :disabled="grantBusy" @click="removeGrant(g.path)">移除授权</IsleButton>
                  </div>
                </div>
                <IsleBanner v-if="grantNotice" type="success" compact role="status" :message="grantNotice" />
                <IsleBanner v-if="grantError" type="error" compact role="alert" :message="grantError" />
              </div>
            </IsleCard>
            <UserStoragePanel mode="all" :admin="true" :alloc-request="pendingAllocRequest" :account-count="accounts.length" @alloc-handled="pendingAllocRequest = null" />
            <DiskManagement />
          </template>

          <template v-if="settingsGroup === 'ops' && user.role === 'admin'">
            <AlertsView v-if="rootFeatureContextReady" :key="rootViewKey" :root-id="multiRootMode ? selectedRootID : undefined" :root-generation="selectedRootGeneration" />
            <OpsTaskCenter
              :shared-roots="sharedRoots"
              :root-discovery-error="rootDiscoveryError"
              :root-feature-context-ready="rootFeatureContextReady"
              :tasks="tasks"
              :task-error="taskError"
              :task-history="taskHistory"
              :task-history-error="taskHistoryError"
              :task-history-loading="taskHistoryLoading"
              :task-history-next-cursor="taskHistoryNextCursor"
              :root-view-key="rootViewKey"
              :selected-root-id="selectedRootID"
              :selected-root-generation="selectedRootGeneration"
              :admin-pending-media-open="adminPendingMediaOpen"
              :refresh-task-center="refreshTaskCenter"
              :task-control="taskControl"
              :start-media-task="startMediaTask"
              :reload-task-history="reloadTaskHistory"
              :toggle-pending-media="togglePendingMedia"
            />
            <details class="apple-disclosure-card" :open="automationDisclosureOpen" @toggle="toggleAdvanced('automation', $event)">
              <summary>
                <div class="disclosure-title"><Workflow :size="15" class="disclosure-icon" /><span>本地脚本自动化</span></div>
                <ChevronRight :size="14" class="disclosure-chevron" />
              </summary>
              <div class="disclosure-body">
                <AutomationView v-if="automationDisclosureOpen" :active="automationDisclosureOpen" />
              </div>
            </details>
            <details class="apple-disclosure-card" @toggle="toggleAdvanced('diagnostics', $event)">
              <summary>
                <div class="disclosure-title"><Activity :size="15" class="disclosure-icon" /><span>高级排障：上传维护、系统诊断与安全日志</span></div>
                <ChevronRight :size="14" class="disclosure-chevron" />
              </summary>
              <div class="disclosure-body">
                <template v-if="advancedDiagnosticsOpen">
                  <template v-if="rootFeatureContextReady">
                    <UploadMaintenance :key="rootViewKey" :root-id="multiRootMode ? selectedRootID : undefined" :root-generation="selectedRootGeneration" />
                    <div class="settings-divider-block">
                      <div class="account-heading"><h4>上传暂存自动清理规则</h4></div>
                      <UploadCleanupRules />
                    </div>
                  </template>
                  <OpsDiagnostics />
                  <BetaDiagnosticReport />
                  <AuditLogView :accounts="accounts" />
                  <div class="settings-divider-block">
                    <div class="account-heading"><h4>成员容量预占记录</h4></div>
                    <PendingReservations :roots="sharedRoots" :roots-known="rootDiscoveryState === 'multi' && !rootDiscoveryError" @open-storage="settingsGroup = 'storage'" />
                  </div>
                </template>
              </div>
            </details>
          </template>

          <template v-if="settingsGroup === 'account'">
            <IsleCard v-if="user.role !== 'admin'" padding="sm" title="当前用户" :subtitle="user.username + '（家庭成员）'">
              <template #icon><ShieldCheck :size="17" /></template>
              <p class="settings-member-note">家庭成员账号与目录配额由管理员统一维护。</p>
            </IsleCard>
            <UserStoragePanel v-if="user.role !== 'admin'" mode="users" :admin="false" />
            <IsleCard title="修改我的密码" subtitle="更新密码后将自动下线其他所有已登录设备。">
              <template #icon><ShieldCheck :size="18" /></template>
              <form class="account-form settings-form-subcard" @submit.prevent="changeOwnPassword">
                <div class="settings-form-grid-3">
                  <label>当前密码<input v-model="currentPassword" type="password" autocomplete="current-password" placeholder="输入当前登录密码" required /></label>
                  <label>新密码<input v-model="nextPassword" type="password" autocomplete="new-password" minlength="12" maxlength="256" placeholder="至少 12 位新密码" required /></label>
                  <label>确认新密码<input v-model="repeatPassword" type="password" autocomplete="new-password" minlength="12" maxlength="256" placeholder="再次输入新密码" required /></label>
                </div>
                <div class="settings-form-actions">
                  <IsleButton type="submit" variant="primary" size="md" :loading="passwordBusy">{{ passwordBusy ? "正在修改…" : "更新密码并退出所有设备" }}</IsleButton>
                </div>
              </form>
              <IsleBanner v-if="passwordError" class="settings-banner-top" type="error" compact role="alert" :message="passwordError" />
            </IsleCard>
            <IsleCard title="登录设备与会话管理" subtitle="查看已登录终端与最近活跃时间，支持单设备远程下线。">
              <template #icon><ShieldCheck :size="18" /></template>
              <template #actions>
                <IsleButton v-if="sessionsLoaded && loginSessions.length > 1" variant="danger" size="sm" :disabled="sessionsLoading" @click="revokeLoginSession('others')">退出其他设备</IsleButton>
                <IsleButton variant="glass" size="sm" :loading="sessionsLoading" @click="loadLoginSessions">
                  <template #icon><RefreshCcw :size="14" /></template>{{ sessionsLoading ? "刷新中…" : "刷新" }}
                </IsleButton>
              </template>
              <IsleEmpty v-if="!sessionsLoaded && !sessionsLoading" compact :icon="ShieldCheck" title="点击右上角「刷新」读取已登录设备" />
              <div v-for="session in loginSessions" :key="session.id" class="account-row">
                <div>
                  <strong class="settings-row-title">
                    <span>{{ session.deviceLabel || (session.current ? "当前设备" : "未知终端") }}</span>
                    <IsleBadge :variant="session.current ? 'online' : 'neutral'" size="sm" :dot="session.current">{{ session.current ? "本机当前会话" : "远程在线设备" }}</IsleBadge>
                    <IsleBadge v-if="session.clientIp" variant="neutral" size="sm">{{ session.clientIp }}</IsleBadge>
                  </strong>
                  <small>登录：{{ formatDateTime(session.createdAt * 1000) }}<template v-if="session.lastSeenAt"> · 最近活跃：{{ formatDateTime(session.lastSeenAt * 1000) }}</template> · 到期：{{ formatDateTime(session.expiresAt * 1000) }}</small>
                </div>
                <IsleButton :variant="session.current ? 'glass' : 'danger'" size="sm" :disabled="sessionsLoading" @click="revokeLoginSession(session)">{{ session.current ? "退出本机" : "远程下线" }}</IsleButton>
              </div>
              <IsleEmpty v-if="sessionsLoaded && !loginSessions.length" compact description="没有可显示的有效会话。" />
              <p v-if="sessionsTruncated" class="footnote">仅显示最近 100 条会话，可选择退出其他所有设备。</p>
              <IsleBanner v-if="sessionsError" type="error" compact role="alert" :message="sessionsError" />
              <IsleBanner v-if="sessionsMessage" type="info" compact role="status" :message="sessionsMessage" />
            </IsleCard>
            <CacheManagementPanel v-if="user.role === 'admin'" :is-admin="true" :active="active === 'settings'" />
            <IsleCard v-if="user.role !== 'admin'" title="缺失媒体记录核对" subtitle="移动或重命名媒体文件后，重新关联收藏与观看进度。">
              <template #icon><Images :size="18" /></template>
              <details v-if="rootFeatureContextReady" class="apple-disclosure-card settings-disclosure-tight" @toggle="togglePendingMedia(false, $event)">
                <summary>
                  <div class="disclosure-title"><Images :size="15" class="disclosure-icon" /><span>展开检查我的缺失媒体</span></div>
                  <ChevronRight :size="14" class="disclosure-chevron" />
                </summary>
                <div class="disclosure-body">
                  <PendingMedia v-if="pendingMediaOpen" :key="rootViewKey" :root-id="selectedRootID" :root-generation="selectedRootGeneration" :admin="false" />
                </div>
              </details>
              <p v-else class="footnote settings-footnote-flush">选择硬盘后可检查自己的缺失媒体。</p>
            </IsleCard>
          </template>
        </div>
      </Transition>
    </div>
  </div>
</template>

<style scoped>
.settings-form-gap {
  margin-bottom: 14px;
}

.settings-grant-form {
  margin-bottom: 12px;
}

.settings-banner-gap {
  margin-bottom: 10px;
}

.settings-banner-top {
  margin-top: 10px;
}

.settings-row-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.settings-inline-check {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-direction: row;
}

.settings-inline-check input {
  width: auto;
}

.settings-divider-block {
  margin-top: 14px;
  border-top: 1px solid var(--fluid-divider, var(--stroke-subtle));
  padding-top: 12px;
}

.settings-member-note {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary);
}

.settings-disclosure-tight {
  margin-top: 0;
}

.settings-footnote-flush {
  margin: 0;
}
</style>
