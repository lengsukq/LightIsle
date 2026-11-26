<script setup lang="ts">
import { computed, defineAsyncComponent, inject, nextTick, onMounted, ref, watch, type Component } from "vue";
import {
  Activity, ChevronRight, Folder, HardDrive, Images, KeyRound, Link2,
  RefreshCw, ShieldCheck, UserPlus, Users, Workflow,
} from "lucide-vue-next";
import { SETTINGS_VIEW_CTX } from "../../contexts/shellContexts.ts";
import type { ShellSettingsGroup } from "../../utils/shellRouteGuard.ts";
import { useSlidingIndicator } from "../../composables/useSlidingIndicator.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import IsleActionMenu from "../../components/ui/IsleActionMenu.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import IsleSlidingIndicator from "../../components/ui/IsleSlidingIndicator.vue";
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
  pendingMediaOpen, adminPendingMediaOpen, togglePendingMedia,
} = ctx;

const settingsGroups = computed<Array<{ key: ShellSettingsGroup; label: string; icon: Component }>>(() => {
  if (user.value?.role === "admin") {
    return [
      { key: "storage", label: "成员与空间", icon: Users },
      { key: "files", label: "文件与连接", icon: Link2 },
      { key: "ops", label: "状态与维护", icon: Activity },
      { key: "cache", label: "缓存管理", icon: HardDrive },
      { key: "account", label: "账号与安全", icon: ShieldCheck },
    ];
  }
  return [
    { key: "account", label: "账号与安全", icon: ShieldCheck },
    { key: "files", label: "文件与连接", icon: Link2 },
    { key: "cache", label: "本地缓存", icon: HardDrive },
  ];
});

let allocRequestSeq = 0;
const pendingAllocRequest = ref<{ userId: number; seq: number } | null>(null);
const navRef = ref<HTMLElement | null>(null);
const createMemberModalOpen = ref(false);
const passwordModalOpen = ref(false);
const accountsRefreshing = ref(false);
const accountsUpdatedAt = ref(0);
const sharesUpdatedAt = ref(0);
const sessionsUpdatedAt = ref(0);

const { indicatorStyle: settingsNavIndicatorStyle, indicatorReady: settingsNavIndicatorReady } = useSlidingIndicator({
  containerRef: navRef,
  activeSelector: "button.active",
  watchSources: [settingsGroup, () => user.value?.role, active],
});

function formatUpdatedTime(ts: number): string {
  if (!ts) return "";
  return "更新于 " + formatDateTime(ts).replace(/^.*?\s/, "");
}

async function refreshAccountsSilent() {
  if (user.value?.role !== "admin" || accountsRefreshing.value) return;
  accountsRefreshing.value = true;
  try {
    await loadAccounts();
    accountsUpdatedAt.value = Date.now();
  } finally {
    accountsRefreshing.value = false;
  }
}

async function refreshSharesSilent() {
  if (!rootFeatureContextReady.value || sharesLoading.value) return;
  await loadMyShares();
  sharesUpdatedAt.value = Date.now();
}

async function refreshSessionsSilent() {
  if (sessionsLoading.value) return;
  await loadLoginSessions();
  sessionsUpdatedAt.value = Date.now();
}

function openCreateMemberModal() {
  createUserError.value = "";
  createMemberModalOpen.value = true;
}

function closeCreateMemberModal() {
  createMemberModalOpen.value = false;
  createUserError.value = "";
}

async function submitCreateMember() {
  await createMemberAccount();
  if (!createUserError.value && createUserNotice.value) {
    createMemberModalOpen.value = false;
    accountsUpdatedAt.value = Date.now();
  }
}

function openOwnPasswordModal() {
  passwordError.value = "";
  passwordModalOpen.value = true;
}

function closeOwnPasswordModal() {
  passwordModalOpen.value = false;
  passwordError.value = "";
  currentPassword.value = "";
  nextPassword.value = "";
  repeatPassword.value = "";
}

async function scrollActiveNavIntoView(smooth = true) {
  await nextTick();
  const nav = navRef.value;
  if (!nav) return;
  const activeBtn = nav.querySelector<HTMLElement>("button.active");
  if (!activeBtn || typeof activeBtn.scrollIntoView !== "function") return;
  const reduceMotion = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  activeBtn.scrollIntoView({ behavior: smooth && !reduceMotion ? "smooth" : "auto", block: "nearest", inline: "nearest" });
}

onMounted(() => {
  void scrollActiveNavIntoView(false);
  if (accounts.value.length) accountsUpdatedAt.value = Date.now();
  if (sharesLoaded.value) sharesUpdatedAt.value = Date.now();
  if (sessionsLoaded.value) sessionsUpdatedAt.value = Date.now();
});

watch(navRef, (el, _prev, onCleanup) => {
  if (!el) return;
  void scrollActiveNavIntoView(false);
  if (typeof ResizeObserver === "undefined") return;
  let raf = 0;
  const ro = new ResizeObserver(() => {
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(() => void scrollActiveNavIntoView(false));
  });
  ro.observe(el);
  onCleanup(() => {
    cancelAnimationFrame(raf);
    ro.disconnect();
  });
});

watch(
  [active, settingsGroup, () => user.value?.role, rootFeatureContextReady],
  ([page, group, role, ready]) => {
    if (page !== "settings" || !role) return;
    if (group === "storage" && role === "admin") void refreshAccountsSilent();
    else if (group === "files" && ready && sharesLoaded.value) void refreshSharesSilent();
    else if (group === "account" && sessionsLoaded.value) void refreshSessionsSilent();
  },
  { immediate: true },
);

watch(sharesLoaded, (loaded) => { if (loaded) sharesUpdatedAt.value = Date.now(); });
watch(sessionsLoaded, (loaded) => { if (loaded) sessionsUpdatedAt.value = Date.now(); });
watch(settingsGroup, () => void scrollActiveNavIntoView(true));

function triggerAllocForMember(userId: number) {
  allocRequestSeq += 1;
  pendingAllocRequest.value = { userId, seq: allocRequestSeq };
  clearLastCreatedMember();
}
</script>

<template>
  <div v-if="user" class="content settings-page isle-tab-pane">
    <IslePageHeader
      title="偏好设置"
      :subtitle="user.role === 'admin' ? '管理家庭成员与空间、远程连接、运行状态及账号缓存' : '管理账号安全、远程连接与本地缓存'"
    />

    <div class="settings-workspace">
      <nav ref="navRef" class="settings-nav" aria-label="设置分类">
        <IsleSlidingIndicator class="settings-nav-indicator" variant="nav" :ready="settingsNavIndicatorReady" :pill-rect="settingsNavIndicatorStyle" />
        <button
          v-for="group in settingsGroups"
          :key="group.key"
          type="button"
          :class="{ active: settingsGroup === group.key }"
          @click="settingsGroup = group.key"
        >
          <span class="settings-nav-icon" aria-hidden="true"><component :is="group.icon" :size="16" :stroke-width="1.9" /></span>
          <span class="settings-nav-label">{{ group.label }}</span>
        </button>
      </nav>

      <div class="settings-stage">
        <Transition name="settings-pane-fade">
          <div :key="settingsGroup" class="settings-stack">
            <CacheManagementPanel v-if="settingsGroup === 'cache'" :is-admin="user.role === 'admin'" :active="active === 'settings'" />

            <template v-if="settingsGroup === 'files'">
              <DavAccess />
              <SmbManagement v-if="user.role === 'admin'" />
              <TailscaleGuideCard v-if="user.role === 'admin'" />

              <IsleGroupedList title="我的文件分享" subtitle="限时外链最长 7 天有效，可随时撤销" flush>
                <template #actions>
                  <span v-if="sharesUpdatedAt" class="settings-updated-at">{{ formatUpdatedTime(sharesUpdatedAt) }}</span>
                  <IsleButton variant="ghost" size="sm" :loading="sharesLoading" :disabled="!rootFeatureContextReady" aria-label="刷新文件分享" title="刷新文件分享" @click="refreshSharesSilent">
                    <template #icon><RefreshCw :size="14" /></template>
                  </IsleButton>
                </template>
                <p v-if="!rootFeatureContextReady" class="settings-empty-pad footnote">请先选择一个可访问的共享目录，再管理该目录中的分享。</p>
                <div v-else-if="sharesLoaded && !activeShares.length" class="settings-empty-pad">
                  <IsleEmpty compact :icon="Folder" title="暂无有效的分享链接" description="可在「私人文件」页选择文件或文件夹后创建分享链接。" />
                </div>
                <div v-else-if="!sharesLoaded && !sharesLoading" class="settings-empty-pad">
                  <IsleEmpty compact :icon="Folder" title="正在同步分享记录…" />
                </div>
                <TransitionGroup v-else name="isle-list" tag="div" class="settings-grouped-rows">
                  <div v-for="share in activeShares" :key="share.id" class="account-row">
                    <div>
                      <strong class="settings-row-title">
                        <span>{{ share.path }}</span>
                        <IsleBadge v-if="share.kind === 'dir'" variant="accent" size="sm">文件夹 ZIP</IsleBadge>
                        <IsleBadge v-if="share.hasPassword" variant="warning" size="sm">密码保护</IsleBadge>
                        <IsleBadge v-if="(share.maxDownloads ?? 0) > 0" variant="neutral" size="sm">
                          限 {{ share.maxDownloads }} 次下载<template v-if="(share.downloadCount ?? 0) > 0">（已用 {{ share.downloadCount }}）</template>
                        </IsleBadge>
                      </strong>
                      <small class="settings-tabular">创建：{{ formatDateTime(share.createdAt * 1000) }} · 到期：{{ formatDateTime(share.expiresAt * 1000) }}</small>
                    </div>
                    <IsleButton variant="danger" size="sm" @click="revokeFileShare(share)">撤销链接</IsleButton>
                  </div>
                </TransitionGroup>
                <template v-if="sharesError" #footnote>
                  <IsleBanner type="error" compact role="alert" :message="sharesError" />
                </template>
              </IsleGroupedList>
            </template>

            <template v-if="settingsGroup === 'storage' && user.role === 'admin'">
              <IsleBanner v-if="createUserError || userError || memberActionError" type="error" compact role="alert" :message="createUserError || userError || memberActionError" />
              <IsleBanner v-if="createUserNotice || memberActionNotice" type="success" compact role="status" :message="createUserNotice || memberActionNotice">
                <template v-if="lastCreatedMember && createUserNotice" #action>
                  <IsleButton variant="primary" size="sm" @click="triggerAllocForMember(lastCreatedMember.id)">立即分配存储空间</IsleButton>
                </template>
              </IsleBanner>

              <IsleGroupedList title="成员账号与权限" subtitle="管理家庭成员账号、共享目录与电脑文件访问权限" flush>
                <template #actions>
                  <span v-if="accountsUpdatedAt" class="settings-updated-at">{{ formatUpdatedTime(accountsUpdatedAt) }}</span>
                  <IsleButton variant="ghost" size="sm" :loading="accountsRefreshing" aria-label="刷新成员账号" title="刷新成员账号" @click="refreshAccountsSilent">
                    <template #icon><RefreshCw :size="14" /></template>
                  </IsleButton>
                  <IsleButton variant="primary" size="sm" @click="openCreateMemberModal">
                    <template #icon><UserPlus :size="14" /></template>新增成员
                  </IsleButton>
                </template>

                <button type="button" class="settings-nav-row" @click="openCreateMemberModal">
                  <div class="settings-nav-row-lead">
                    <span class="settings-row-icon" aria-hidden="true"><UserPlus :size="16" /></span>
                    <div><strong>新增家庭成员</strong><small>创建成员账号并按需分配独立存储空间</small></div>
                  </div>
                  <ChevronRight :size="16" class="settings-row-chevron" aria-hidden="true" />
                </button>

                <TransitionGroup name="isle-list" tag="div" class="settings-grouped-rows">
                  <div v-for="account in accounts" :key="account.id" class="account-row">
                    <div class="settings-member-lead">
                      <span class="settings-avatar" aria-hidden="true">{{ account.username.slice(0, 1).toUpperCase() }}</span>
                      <div class="settings-member-meta">
                        <strong class="settings-row-title">
                          <span>{{ account.username }}</span>
                          <IsleBadge :variant="account.role === 'admin' ? 'accent' : 'neutral'" size="sm">
                            {{ account.role === "admin" ? "管理员 · 默认无限配额" : "家庭成员" }}
                          </IsleBadge>
                          <IsleBadge :variant="account.enabled ? 'online' : 'offline'" size="sm" dot>
                            {{ account.enabled ? "已启用" : "已停用" }}
                          </IsleBadge>
                        </strong>
                      </div>
                    </div>
                    <div v-if="account.role === 'member'" class="settings-row-actions">
                      <label class="settings-inline-switch" :title="account.enabled ? '点击停用该成员账号' : '点击启用该成员账号'">
                        <input
                          type="checkbox"
                          class="app-apple-switch"
                          :checked="account.enabled"
                          :disabled="memberActionBusy"
                          :aria-label="(account.enabled ? '停用' : '启用') + account.username"
                          @change="toggleMemberEnabled(account)"
                        />
                      </label>
                      <IsleActionMenu label="管理" :aria-label="'管理成员：' + account.username">
                        <button type="button" role="menuitem" :disabled="multiRootMode && !selectedRootID" @click="editGrants(account)">共享目录权限</button>
                        <button type="button" role="menuitem" @click="active = 'computer'">电脑文件权限</button>
                        <button type="button" role="menuitem" @click="triggerAllocForMember(account.id)">分配存储空间</button>
                        <button type="button" role="menuitem" @click="openResetMemberPassword(account)">重置密码</button>
                        <button type="button" role="menuitem" :class="{ danger: account.enabled }" :disabled="memberActionBusy" @click="toggleMemberEnabled(account)">
                          {{ account.enabled ? "停用账号" : "启用账号" }}
                        </button>
                      </IsleActionMenu>
                    </div>
                  </div>
                </TransitionGroup>
              </IsleGroupedList>

              <UserStoragePanel mode="all" :admin="true" :alloc-request="pendingAllocRequest" :account-count="accounts.length" @alloc-handled="pendingAllocRequest = null" />
              <DiskManagement />
            </template>

            <template v-if="settingsGroup === 'ops' && user.role === 'admin'">
              <AlertsView :key="rootViewKey" :root-id="rootFeatureContextReady && multiRootMode && selectedRoot?.online ? selectedRootID : undefined" :root-generation="selectedRootGeneration" />
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

              <IsleDisclosure
                v-model="automationDisclosureOpen"
                class="settings-automation-disclosure"
                title="本地脚本自动化"
                subtitle="调度本机 automation/scripts 定时脚本、Cron 周期与多渠道通知"
                :icon="Workflow"
              >
                <AutomationView v-if="automationDisclosureOpen" :active="automationDisclosureOpen" />
              </IsleDisclosure>

              <IsleDisclosure
                v-model="advancedDiagnosticsOpen"
                title="高级排障：上传维护、系统诊断与安全日志"
                subtitle="默认折叠，按需加载上传暂存、系统遥测、审计与容量预占排查工具"
                :icon="Activity"
              >
                <template v-if="advancedDiagnosticsOpen">
                  <template v-if="rootFeatureContextReady">
                    <UploadMaintenance :key="rootViewKey" :root-id="multiRootMode ? selectedRootID : undefined" :root-generation="selectedRootGeneration" />
                    <IsleDisclosure title="上传暂存自动清理规则" subtitle="设置确认未发布且长期无活动的暂存文件保留天数">
                      <UploadCleanupRules />
                    </IsleDisclosure>
                  </template>
                  <OpsDiagnostics />
                  <BetaDiagnosticReport />
                  <AuditLogView :accounts="accounts" />
                  <IsleDisclosure title="成员容量预占记录" subtitle="排查进行中或结果待确认的容量预占条目">
                    <PendingReservations :roots="sharedRoots" :roots-known="rootDiscoveryState === 'multi' && !rootDiscoveryError" @open-storage="settingsGroup = 'storage'" />
                  </IsleDisclosure>
                </template>
              </IsleDisclosure>
            </template>

            <template v-if="settingsGroup === 'account'">
              <IsleGroupedList title="账号与安全" subtitle="当前登录身份与密码安全设置" flush>
                <div class="account-row">
                  <div class="settings-member-lead">
                    <span class="settings-avatar" aria-hidden="true">{{ user.username.slice(0, 1).toUpperCase() }}</span>
                    <div class="settings-member-meta">
                      <strong class="settings-row-title">
                        <span>{{ user.username }}</span>
                        <IsleBadge :variant="user.role === 'admin' ? 'accent' : 'neutral'" size="sm">{{ user.role === "admin" ? "管理员" : "家庭成员" }}</IsleBadge>
                        <IsleBadge variant="online" size="sm" dot>当前已登录</IsleBadge>
                      </strong>
                      <small>{{ user.role === "admin" ? "拥有存储管理、成员授权与系统维护权限。" : "家庭成员账号与目录配额由管理员统一维护。" }}</small>
                    </div>
                  </div>
                </div>

                <button type="button" class="settings-nav-row" @click="openOwnPasswordModal">
                  <div class="settings-nav-row-lead">
                    <span class="settings-row-icon" aria-hidden="true"><KeyRound :size="16" /></span>
                    <div><strong>修改登录密码</strong><small>更新密码后将自动下线其他所有已登录设备</small></div>
                  </div>
                  <ChevronRight :size="16" class="settings-row-chevron" aria-hidden="true" />
                </button>
              </IsleGroupedList>

              <UserStoragePanel v-if="user.role !== 'admin'" mode="users" :admin="false" />

              <IsleGroupedList title="登录设备与会话" subtitle="查看已登录终端与最近活跃时间，支持单设备远程下线" flush>
                <template #actions>
                  <span v-if="sessionsUpdatedAt" class="settings-updated-at">{{ formatUpdatedTime(sessionsUpdatedAt) }}</span>
                  <IsleButton variant="ghost" size="sm" :loading="sessionsLoading" aria-label="刷新登录设备" title="刷新登录设备" @click="refreshSessionsSilent">
                    <template #icon><RefreshCw :size="14" /></template>
                  </IsleButton>
                  <IsleButton v-if="sessionsLoaded && loginSessions.length > 1" variant="danger" size="sm" :disabled="sessionsLoading" @click="revokeLoginSession('others')">
                    退出其他设备
                  </IsleButton>
                </template>
                <div v-if="!sessionsLoaded && !sessionsLoading" class="settings-empty-pad">
                  <IsleEmpty compact :icon="ShieldCheck" title="正在同步已登录设备…" />
                </div>
                <div v-else-if="sessionsLoaded && !loginSessions.length" class="settings-empty-pad">
                  <IsleEmpty compact description="没有可显示的有效会话。" />
                </div>
                <TransitionGroup v-else name="isle-list" tag="div" class="settings-grouped-rows">
                  <div v-for="session in loginSessions" :key="session.id" class="account-row">
                    <div>
                      <strong class="settings-row-title">
                        <span>{{ session.deviceLabel || (session.current ? "当前设备" : "未知终端") }}</span>
                        <IsleBadge :variant="session.current ? 'online' : 'neutral'" size="sm" :dot="session.current">
                          {{ session.current ? "本机当前会话" : "远程在线设备" }}
                        </IsleBadge>
                        <IsleBadge v-if="session.clientIp" variant="neutral" size="sm">{{ session.clientIp }}</IsleBadge>
                      </strong>
                      <small class="settings-tabular">
                        登录：{{ formatDateTime(session.createdAt * 1000) }}<template v-if="session.lastSeenAt"> · 最近活跃：{{ formatDateTime(session.lastSeenAt * 1000) }}</template> · 到期：{{ formatDateTime(session.expiresAt * 1000) }}
                      </small>
                    </div>
                    <IsleButton :variant="session.current ? 'glass' : 'danger'" size="sm" :disabled="sessionsLoading" @click="revokeLoginSession(session)">
                      {{ session.current ? "退出本机" : "远程下线" }}
                    </IsleButton>
                  </div>
                </TransitionGroup>
                <template v-if="sessionsTruncated || sessionsError || sessionsMessage" #footnote>
                  <div class="settings-foot-stack">
                    <span v-if="sessionsTruncated">仅显示最近 100 条会话，可选择退出其他所有设备。</span>
                    <IsleBanner v-if="sessionsError" type="error" compact role="alert" :message="sessionsError" />
                    <IsleBanner v-if="sessionsMessage" type="info" compact role="status" :message="sessionsMessage" />
                  </div>
                </template>
              </IsleGroupedList>

              <IsleDisclosure
                v-if="user.role !== 'admin' && rootFeatureContextReady"
                v-model="pendingMediaOpen"
                title="缺失媒体记录核对"
                subtitle="移动或重命名媒体文件后，重新关联收藏与观看进度"
                :icon="Images"
              >
                <PendingMedia v-if="pendingMediaOpen" :key="rootViewKey" :root-id="selectedRootID" :root-generation="selectedRootGeneration" :admin="false" />
              </IsleDisclosure>
              <IsleBanner v-else-if="user.role !== 'admin'" type="info" compact message="选择硬盘后可检查自己的缺失媒体记录。" />
            </template>
          </div>
        </Transition>
      </div>
    </div>

    <IsleModal :open="createMemberModalOpen" title="新增家庭成员" description="为新成员创建独立登录账号；创建后建议立即为其分配存储空间。" size="sm" @close="closeCreateMemberModal">
      <template #icon><UserPlus :size="16" /></template>
      <form id="create-member-form" class="account-form" @submit.prevent="submitCreateMember">
        <label>新成员用户名<input v-model.trim="newUsername" minlength="3" maxlength="32" autocomplete="off" placeholder="3–32 位字母/数字/下划线" autofocus required /></label>
        <label>初始密码<input v-model="newPassword" type="password" minlength="12" maxlength="256" autocomplete="new-password" placeholder="至少 12 位初始密码" required /></label>
      </form>
      <IsleBanner v-if="createUserError" type="error" compact role="alert" :message="createUserError" />
      <template #footer>
        <IsleButton variant="glass" size="sm" @click="closeCreateMemberModal">取消</IsleButton>
        <IsleButton type="submit" form="create-member-form" variant="primary" size="sm" :loading="creatingUser">{{ creatingUser ? "正在创建…" : "创建成员账号" }}</IsleButton>
      </template>
    </IsleModal>

    <IsleModal :open="Boolean(resetTargetUser)" :title="resetTargetUser ? `重置密码 · ${resetTargetUser.username}` : '重置成员密码'" description="重置后该成员的已有登录会话将立即失效。" size="sm" @close="closeResetMemberPassword">
      <template #icon><KeyRound :size="16" /></template>
      <form id="reset-member-password-form" class="account-form" @submit.prevent="submitResetMemberPassword">
        <label>新密码<input v-model="resetMemberNewPassword" type="password" minlength="12" maxlength="256" autocomplete="new-password" placeholder="至少 12 位" autofocus required /></label>
        <label>确认新密码<input v-model="resetMemberRepeatPassword" type="password" minlength="12" maxlength="256" autocomplete="new-password" placeholder="再次输入新密码" required /></label>
      </form>
      <IsleBanner v-if="resetMemberError" type="error" compact role="alert" :message="resetMemberError" />
      <template #footer>
        <IsleButton variant="glass" size="sm" @click="closeResetMemberPassword">取消</IsleButton>
        <IsleButton type="submit" form="reset-member-password-form" variant="primary" size="sm" :loading="resetMemberBusy">{{ resetMemberBusy ? "正在重置…" : "确认重置密码" }}</IsleButton>
      </template>
    </IsleModal>

    <IsleModal
      :open="Boolean(grantUser)"
      :title="grantUser ? `${grantUser.username} · 共享文件夹授权` : '共享文件夹授权'"
      :description="multiRootMode ? `管理「${selectedRoot?.name ?? '当前共享目录'}」的访问授权（输入相对路径，如 Family 或 .）` : '管理共享目录访问授权（输入相对路径，如 Family 或 .）'"
      size="md"
      @close="grantUser = null"
    >
      <template #icon><Folder :size="16" /></template>
      <form class="account-form" @submit.prevent="saveGrant">
        <label>共享文件夹相对路径<input v-model.trim="grantPathInput" placeholder="例如 Family 或 Photos/Shared（留空或 . 代表根目录）" autofocus /></label>
        <label class="settings-inline-check">
          <input v-model="grantCanWrite" type="checkbox" class="isle-checkbox" />
          <span>允许读写（勾选为读写，不勾选为只读）</span>
        </label>
        <div class="settings-form-actions">
          <IsleButton type="submit" variant="primary" size="sm" :loading="grantBusy">{{ grantBusy ? "正在保存…" : "添加 / 更新目录授权" }}</IsleButton>
        </div>
      </form>
      <IsleBanner v-if="grantNotice" type="success" compact role="status" :message="grantNotice" />
      <IsleBanner v-if="grantError" type="error" compact role="alert" :message="grantError" />
      <IsleGroupedList v-if="grants.length" variant="item" title="已授权目录" flush>
        <div class="settings-grouped-rows">
          <div v-for="g in grants" :key="g.path" class="account-row">
            <div>
              <strong class="settings-row-title">
                <span>{{ g.path }}</span>
                <IsleBadge :variant="g.canWrite ? 'online' : 'neutral'" size="sm">{{ g.canWrite ? "可读写" : "只读" }}</IsleBadge>
              </strong>
            </div>
            <div class="settings-row-actions">
              <IsleButton variant="glass" size="sm" :disabled="grantBusy" @click="toggleGrantWrite(g)">{{ g.canWrite ? "改为只读" : "改为读写" }}</IsleButton>
              <IsleButton variant="danger" size="sm" :disabled="grantBusy" @click="removeGrant(g.path)">移除授权</IsleButton>
            </div>
          </div>
        </div>
      </IsleGroupedList>
      <IsleEmpty v-else compact description="尚未配置共享目录授权。" />
    </IsleModal>

    <IsleModal :open="passwordModalOpen" title="修改我的密码" description="更新密码后将自动下线其他所有已登录设备。" size="sm" @close="closeOwnPasswordModal">
      <template #icon><KeyRound :size="16" /></template>
      <form id="own-password-form" class="account-form" @submit.prevent="changeOwnPassword">
        <label>当前密码<input v-model="currentPassword" type="password" autocomplete="current-password" placeholder="输入当前登录密码" autofocus required /></label>
        <label>新密码<input v-model="nextPassword" type="password" autocomplete="new-password" minlength="12" maxlength="256" placeholder="至少 12 位新密码" required /></label>
        <label>确认新密码<input v-model="repeatPassword" type="password" autocomplete="new-password" minlength="12" maxlength="256" placeholder="再次输入新密码" required /></label>
      </form>
      <IsleBanner v-if="passwordError" type="error" compact role="alert" :message="passwordError" />
      <template #footer>
        <IsleButton variant="glass" size="sm" @click="closeOwnPasswordModal">取消</IsleButton>
        <IsleButton type="submit" form="own-password-form" variant="primary" size="sm" :loading="passwordBusy">{{ passwordBusy ? "正在修改…" : "更新密码并退出所有设备" }}</IsleButton>
      </template>
    </IsleModal>
  </div>
</template>

<style scoped>
.settings-stack .account-row > div:first-child { min-width: 0; flex: 1 1 200px; overflow-wrap: anywhere; }
.settings-row-title, .settings-row-title > span { min-width: 0; overflow-wrap: anywhere; }
.settings-tabular { font-variant-numeric: tabular-nums; }
.settings-empty-pad { padding: 14px 16px; margin: 0; }
.settings-foot-stack { display: grid; gap: 6px; }
.settings-nav-row-lead, .settings-member-lead { display: flex; align-items: center; gap: 11px; min-width: 0; flex: 1 1 200px; }
.settings-nav-row-lead > div, .settings-member-meta { min-width: 0; flex: 1; }
.settings-nav-row-lead strong { display: block; font-size: 13.5px; font-weight: 620; color: var(--text-primary); }
.settings-nav-row-lead small { display: block; font-size: 11.5px; color: var(--text-secondary); margin-top: 2px; }
.settings-row-icon, .settings-avatar {
  width: 32px;
  height: 32px;
  border-radius: 9px;
  display: grid;
  place-items: center;
  flex-shrink: 0;
  background: color-mix(in srgb, var(--accent-primary) 11%, transparent);
  color: var(--accent-primary);
  font-size: 13px;
  font-weight: 700;
}
.settings-avatar { border-radius: 999px; }
.settings-row-chevron { color: var(--text-tertiary); flex-shrink: 0; }
.settings-inline-switch { display: inline-flex; align-items: center; cursor: pointer; }
.settings-row-actions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; flex-shrink: 0; max-width: 100%; }
.settings-inline-check { display: inline-flex; align-items: center; gap: 8px; flex-direction: row; width: fit-content; cursor: pointer; }
.settings-automation-disclosure :deep(.automation) { gap: 10px; }
.settings-automation-disclosure :deep(.automation .auto-card) { box-shadow: none; }
</style>
