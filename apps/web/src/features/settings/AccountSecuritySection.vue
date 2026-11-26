<script setup lang="ts">
import { computed, ref, type Component } from "vue";
import {
  AppWindow,
  ChevronDown,
  ChevronRight,
  ChevronUp,
  Globe,
  Images,
  KeyRound,
  Laptop,
  LogOut,
  Monitor,
  RefreshCw,
  ShieldCheck,
  Smartphone,
  Tablet,
} from "lucide-vue-next";
import type { LoginSession } from "../auth/useAccountSessions.ts";
import {
  partitionLoginSessions,
  presentLoginSession,
  type SessionDeviceIconKind,
} from "./accountSessionPresentation.ts";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleDisclosure from "../../components/ui/IsleDisclosure.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import UserStoragePanel from "../storage/UserStoragePanel.vue";
import PendingMedia from "./PendingMedia.vue";

const DEFAULT_VISIBLE_OTHER_SESSIONS = 5;

const props = defineProps<{
  user: { username: string; role: string };
  loginSessions: LoginSession[];
  sessionsLoading: boolean;
  sessionsLoaded: boolean;
  sessionsTruncated: boolean;
  sessionsError: string;
  sessionsMessage: string;
  sessionsUpdatedLabel: string;
  rootFeatureContextReady: boolean;
  pendingMediaOpen: boolean;
  rootViewKey: string;
  selectedRootId: string;
  selectedRootGeneration: number;
}>();

const emit = defineEmits<{
  (e: "open-password"): void;
  (e: "refresh-sessions"): void;
  (e: "revoke-session", target: LoginSession | "others"): void;
  (e: "update:pendingMediaOpen", open: boolean): void;
}>();

const showAllOtherSessions = ref(false);

const DEVICE_ICONS: Record<SessionDeviceIconKind, Component> = {
  laptop: Laptop,
  monitor: Monitor,
  smartphone: Smartphone,
  tablet: Tablet,
  app: AppWindow,
  globe: Globe,
};

const partitioned = computed(() => partitionLoginSessions(props.loginSessions));
const currentItems = computed(() =>
  partitioned.value.currentSessions.map((session) => ({
    session,
    meta: presentLoginSession(session),
  })),
);
const otherItems = computed(() =>
  partitioned.value.otherSessions.map((session) => ({
    session,
    meta: presentLoginSession(session),
  })),
);
const visibleOtherItems = computed(() =>
  showAllOtherSessions.value
    ? otherItems.value
    : otherItems.value.slice(0, DEFAULT_VISIBLE_OTHER_SESSIONS),
);
const hiddenOtherCount = computed(() =>
  Math.max(0, otherItems.value.length - visibleOtherItems.value.length),
);
const hasMoreOtherSessions = computed(
  () => otherItems.value.length > DEFAULT_VISIBLE_OTHER_SESSIONS,
);
</script>

<template>
  <IsleGroupedList title="账号与安全" subtitle="当前登录身份与密码安全设置" flush>
    <div class="acc-profile-row">
      <div class="acc-profile-lead">
        <span class="acc-profile-avatar" aria-hidden="true">{{ user.username.slice(0, 1).toUpperCase() }}</span>
        <div class="acc-profile-copy">
          <div class="acc-profile-title">
            <strong>{{ user.username }}</strong>
            <IsleBadge :variant="user.role === 'admin' ? 'accent' : 'neutral'" size="sm">
              {{ user.role === "admin" ? "管理员" : "家庭成员" }}
            </IsleBadge>
            <span class="acc-online-status">
              <span class="acc-online-dot" aria-hidden="true" />
              已登录
            </span>
          </div>
          <p class="acc-profile-desc">
            {{ user.role === "admin" ? "拥有存储管理、成员授权与系统维护权限" : "家庭成员账号与目录配额由管理员统一维护" }}
          </p>
        </div>
      </div>
    </div>

    <button type="button" class="settings-nav-row acc-password-row" @click="emit('open-password')">
      <div class="acc-nav-lead">
        <span class="acc-nav-icon" aria-hidden="true"><KeyRound :size="16" /></span>
        <div class="acc-nav-copy">
          <strong>修改登录密码</strong>
          <small>更新密码后将自动下线其他所有已登录设备</small>
        </div>
      </div>
      <ChevronRight :size="16" class="acc-row-chevron" aria-hidden="true" />
    </button>
  </IsleGroupedList>

  <UserStoragePanel v-if="user.role !== 'admin'" mode="users" :admin="false" />

  <IsleGroupedList
    title="登录设备与会话"
    subtitle="管理已登录的终端会话，发现异常可随时远程下线"
    flush
  >
    <template #actions>
      <IsleBadge v-if="sessionsLoaded && loginSessions.length" variant="neutral" size="sm" class="acc-tabular">
        共 {{ loginSessions.length }} 台
      </IsleBadge>
      <span v-if="sessionsUpdatedLabel" class="settings-updated-at">{{ sessionsUpdatedLabel }}</span>
      <IsleButton
        variant="ghost"
        size="sm"
        :loading="sessionsLoading"
        aria-label="刷新登录设备"
        title="刷新登录设备"
        @click="emit('refresh-sessions')"
      >
        <template #icon><RefreshCw :size="14" /></template>
      </IsleButton>
      <IsleButton
        v-if="sessionsLoaded && otherItems.length > 0"
        variant="danger"
        size="sm"
        :disabled="sessionsLoading"
        @click="emit('revoke-session', 'others')"
      >
        退出其他设备
      </IsleButton>
    </template>

    <div v-if="!sessionsLoaded && !sessionsLoading" class="acc-empty-wrap">
      <IsleEmpty compact :icon="ShieldCheck" title="正在同步已登录设备…" />
    </div>
    <div v-else-if="sessionsLoaded && !loginSessions.length" class="acc-empty-wrap">
      <IsleEmpty compact description="没有可显示的有效会话。" />
    </div>
    <template v-else>
      <div
        v-for="{ session, meta } in currentItems"
        :key="session.id"
        class="acc-session-row is-current"
        :title="meta.fullTooltip"
      >
        <div class="acc-session-lead">
          <span class="acc-device-icon is-current" aria-hidden="true">
            <component :is="DEVICE_ICONS[meta.iconKind]" :size="17" :stroke-width="1.9" />
          </span>
          <div class="acc-session-copy">
            <div class="acc-session-heading">
              <strong>{{ meta.displayName }}</strong>
              <IsleBadge variant="online" size="sm" dot>本机</IsleBadge>
            </div>
            <small class="acc-session-meta acc-tabular">{{ meta.metaLine }}</small>
          </div>
        </div>
        <IsleButton
          variant="glass"
          size="sm"
          :disabled="sessionsLoading"
          @click="emit('revoke-session', session)"
        >
          <template #icon><LogOut :size="13" /></template>
          退出本机
        </IsleButton>
      </div>

      <div v-if="otherItems.length > 0" class="acc-session-subhead">
        <span>其他已登录设备</span>
        <span class="acc-tabular">{{ otherItems.length }} 台 · 按最近活跃排序</span>
      </div>

      <TransitionGroup
        v-if="visibleOtherItems.length > 0"
        name="isle-list"
        tag="div"
        class="acc-session-list"
      >
        <div
          v-for="{ session, meta } in visibleOtherItems"
          :key="session.id"
          class="acc-session-row"
          :title="meta.fullTooltip"
        >
          <div class="acc-session-lead">
            <span class="acc-device-icon" aria-hidden="true">
              <component :is="DEVICE_ICONS[meta.iconKind]" :size="17" :stroke-width="1.8" />
            </span>
            <div class="acc-session-copy">
              <div class="acc-session-heading">
                <strong>{{ meta.displayName }}</strong>
                <span v-if="meta.isRecent" class="acc-recent-chip">
                  <span class="acc-online-dot" aria-hidden="true" />
                  近期活跃
                </span>
              </div>
              <small class="acc-session-meta acc-tabular">{{ meta.metaLine }}</small>
            </div>
          </div>
          <button
            type="button"
            class="acc-revoke-btn"
            :disabled="sessionsLoading"
            :aria-label="'下线设备：' + meta.displayName"
            @click="emit('revoke-session', session)"
          >
            <LogOut :size="13" aria-hidden="true" />
            <span>下线</span>
          </button>
        </div>
      </TransitionGroup>

      <button
        v-if="hasMoreOtherSessions"
        type="button"
        class="acc-expand-row"
        :aria-expanded="showAllOtherSessions ? 'true' : 'false'"
        @click="showAllOtherSessions = !showAllOtherSessions"
      >
        <template v-if="showAllOtherSessions">
          <ChevronUp :size="15" aria-hidden="true" />
          <span>收起较早登录的设备</span>
        </template>
        <template v-else>
          <ChevronDown :size="15" aria-hidden="true" />
          <span class="acc-tabular">展开其余 {{ hiddenOtherCount }} 台设备</span>
        </template>
      </button>
    </template>

    <template v-if="sessionsTruncated || sessionsError || sessionsMessage" #footnote>
      <div class="acc-foot-stack">
        <span v-if="sessionsTruncated">仅显示最近 100 条会话，可点击上方「退出其他设备」一次性清理。</span>
        <IsleBanner v-if="sessionsError" type="error" compact role="alert" :message="sessionsError" />
        <IsleBanner v-if="sessionsMessage" type="info" compact role="status" :message="sessionsMessage" />
      </div>
    </template>
  </IsleGroupedList>

  <IsleDisclosure
    v-if="user.role !== 'admin' && rootFeatureContextReady"
    :model-value="pendingMediaOpen"
    title="缺失媒体记录核对"
    subtitle="移动或重命名媒体文件后，重新关联收藏与观看进度"
    :icon="Images"
    @update:model-value="emit('update:pendingMediaOpen', $event)"
  >
    <PendingMedia
      v-if="pendingMediaOpen"
      :key="rootViewKey"
      :root-id="selectedRootId"
      :root-generation="selectedRootGeneration"
      :admin="false"
    />
  </IsleDisclosure>
  <IsleBanner v-else-if="user.role !== 'admin'" type="info" compact message="选择硬盘后可检查自己的缺失媒体记录。" />
</template>

<style scoped>
.acc-tabular {
  font-variant-numeric: tabular-nums;
}

/* Profile Hero Row */
.acc-profile-row {
  padding: 16px 18px;
}

.acc-profile-lead {
  display: flex;
  align-items: center;
  gap: 14px;
  min-width: 0;
}

.acc-profile-avatar {
  width: 44px;
  height: 44px;
  border-radius: 999px;
  display: grid;
  place-items: center;
  flex-shrink: 0;
  background: color-mix(in srgb, var(--accent-primary) 12%, var(--fluid-card-item-top));
  border: 1px solid color-mix(in srgb, var(--accent-primary) 24%, var(--fluid-card-border));
  color: var(--accent-primary);
  font-size: 17px;
  font-weight: 700;
  letter-spacing: -0.02em;
}

.acc-profile-copy {
  display: grid;
  gap: 3px;
  min-width: 0;
  flex: 1;
}

.acc-profile-title {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.acc-profile-title strong {
  font-size: 15.5px;
  font-weight: 660;
  letter-spacing: -0.015em;
  color: var(--text-primary);
}

.acc-online-status,
.acc-recent-chip {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 11.5px;
  font-weight: 560;
  color: var(--success, #167a54);
}

.acc-online-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: currentColor;
  flex-shrink: 0;
}

.acc-profile-desc {
  margin: 0;
  font-size: 12.5px;
  line-height: 1.45;
  color: var(--text-secondary);
}

/* Password Action Row */
.acc-password-row {
  padding: 14px 18px;
}

.acc-nav-lead {
  display: flex;
  align-items: center;
  gap: 12px;
  min-width: 0;
  flex: 1;
}

.acc-nav-icon {
  width: 34px;
  height: 34px;
  border-radius: 10px;
  display: grid;
  place-items: center;
  flex-shrink: 0;
  background: color-mix(in srgb, var(--accent-primary) 10%, transparent);
  color: var(--accent-primary);
}

.acc-nav-copy {
  display: grid;
  gap: 2px;
  min-width: 0;
}

.acc-nav-copy strong {
  font-size: 13.5px;
  font-weight: 620;
  color: var(--text-primary);
}

.acc-nav-copy small {
  font-size: 12px;
  color: var(--text-secondary);
}

.acc-row-chevron {
  color: var(--text-tertiary);
  flex-shrink: 0;
}

/* Sessions List */
.acc-empty-wrap {
  padding: 16px 18px;
}

.acc-session-subhead {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: wrap;
  padding: 8px 18px;
  background: color-mix(in srgb, var(--fluid-card-item-top) 68%, transparent);
  font-size: 11.5px;
  font-weight: 600;
  color: var(--text-tertiary);
}

.acc-session-list {
  display: flex;
  flex-direction: column;
  position: relative;
}

.acc-session-list > .acc-session-row + .acc-session-row {
  border-top: 1px solid var(--fluid-divider, rgba(20, 19, 17, 0.06));
}

.acc-session-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 14px;
  padding: 13px 18px;
  min-height: 60px;
  box-sizing: border-box;
  transition: background-color var(--motion-fast, 160ms) ease;
}

.acc-session-row:hover {
  background: color-mix(in srgb, var(--text-primary) 2.5%, transparent);
}

.acc-session-row.is-current {
  background: color-mix(in srgb, var(--accent-primary) 4.5%, transparent);
  padding: 15px 18px;
}

.acc-session-row.is-current:hover {
  background: color-mix(in srgb, var(--accent-primary) 6%, transparent);
}

.acc-session-lead {
  display: flex;
  align-items: center;
  gap: 12px;
  min-width: 0;
  flex: 1 1 220px;
}

.acc-device-icon {
  width: 36px;
  height: 36px;
  border-radius: 10px;
  display: grid;
  place-items: center;
  flex-shrink: 0;
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-secondary);
}

.acc-device-icon.is-current {
  background: color-mix(in srgb, var(--accent-primary) 12%, var(--fluid-card-top));
  border-color: color-mix(in srgb, var(--accent-primary) 24%, var(--fluid-card-border));
  color: var(--accent-primary);
}

.acc-session-copy {
  display: grid;
  gap: 3px;
  min-width: 0;
  flex: 1;
}

.acc-session-heading {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.acc-session-heading strong {
  font-size: 13.5px;
  font-weight: 620;
  color: var(--text-primary);
  overflow-wrap: anywhere;
}

.acc-session-meta {
  display: block;
  font-size: 12px;
  line-height: 1.4;
  color: var(--text-secondary);
  overflow-wrap: anywhere;
}

/* Restrained per-row sign-out control (avoids red button wall) */
.acc-revoke-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  min-height: 30px;
  padding: 0 11px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: transparent;
  color: var(--text-secondary);
  font: inherit;
  font-size: 12px;
  font-weight: 560;
  cursor: pointer;
  flex-shrink: 0;
  white-space: nowrap;
  transition:
    color var(--motion-fast, 160ms) ease,
    border-color var(--motion-fast, 160ms) ease,
    background-color var(--motion-fast, 160ms) ease;
}

.acc-revoke-btn:hover:not(:disabled),
.acc-revoke-btn:focus-visible {
  color: var(--error, #c93b3b);
  border-color: color-mix(in srgb, var(--error, #c93b3b) 34%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--error, #c93b3b) 9%, transparent);
}

.acc-revoke-btn:focus-visible {
  outline: 2px solid var(--error, #c93b3b);
  outline-offset: 2px;
}

.acc-revoke-btn:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

/* Progressive disclosure footer row */
.acc-expand-row {
  width: 100%;
  min-height: 44px;
  padding: 10px 18px;
  border: 0;
  background: transparent;
  color: var(--accent-primary);
  font: inherit;
  font-size: 12.5px;
  font-weight: 600;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  cursor: pointer;
  transition: background-color var(--motion-fast, 160ms) ease;
}

.acc-expand-row:hover {
  background: var(--fluid-card-hover);
}

.acc-expand-row:focus-visible {
  outline: 2px solid var(--accent-primary);
  outline-offset: -2px;
}

.acc-foot-stack {
  display: grid;
  gap: 6px;
}

@media (max-width: 600px) {
  .acc-profile-row,
  .acc-password-row,
  .acc-session-row,
  .acc-session-subhead {
    padding-inline: 14px;
  }

  .acc-session-row {
    flex-wrap: wrap;
    gap: 10px;
  }
}

@media (prefers-reduced-motion: reduce) {
  .acc-session-row,
  .acc-revoke-btn,
  .acc-expand-row {
    transition: none;
  }
}
</style>
