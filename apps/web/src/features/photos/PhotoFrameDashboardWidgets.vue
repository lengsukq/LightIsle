<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from "vue";
import { CalendarHeart, MessageSquareHeart, Pin } from "lucide-vue-next";
import {
  burnInShiftForStep,
  fetchFamilyBoardPreview,
  formatCountdownLabel,
  formatReminderMilestone,
  listFamilyReminders,
  PHOTO_FRAME_DASHBOARD_REFRESH_MS,
  reminderCategoryLabel,
  type FamilyBoardPreviewMessage,
  type FamilyReminder,
  type LunarDate,
} from "../overview/familyRemindersApi.ts";

const props = defineProps<{
  active: boolean;
  nowClock: string;
  nowDate: string;
  captionText?: string;
  nightDim?: boolean;
}>();

const todayLunar = ref<LunarDate | null>(null);
const reminders = ref<FamilyReminder[]>([]);
const boardMessages = ref<FamilyBoardPreviewMessage[]>([]);
const burnInStep = ref(0);
const lastUpdatedLabel = ref("");

let refreshTimer: number | undefined;
let burnInTimer: number | undefined;
let fetchAbort: AbortController | null = null;

const lunarLine = computed(() => {
  if (!todayLunar.value) return "";
  return `农历 ${todayLunar.value.display} · ${todayLunar.value.ganZhi}${todayLunar.value.zodiac}年`;
});

const upcomingReminders = computed(() => reminders.value.slice(0, 4));
const displayedMessages = computed(() => boardMessages.value.slice(0, 3));

const antiBurnInStyle = computed(() => {
  const shift = burnInShiftForStep(burnInStep.value);
  return {
    transform: `translate3d(${shift.x}px, ${shift.y}px, 0)`,
  };
});

async function refreshDashboardData() {
  if (!props.active) return;
  fetchAbort?.abort();
  const controller = new AbortController();
  fetchAbort = controller;

  const [remResult, boardResult] = await Promise.allSettled([
    listFamilyReminders({ days: 14 }, { signal: controller.signal }),
    fetchFamilyBoardPreview(3, { signal: controller.signal }),
  ]);
  if (fetchAbort !== controller || controller.signal.aborted) return;

  if (remResult.status === "fulfilled") {
    todayLunar.value = remResult.value.todayLunar ?? null;
    reminders.value = remResult.value.reminders;
  }
  if (boardResult.status === "fulfilled") {
    boardMessages.value = boardResult.value;
  }
  const now = new Date();
  lastUpdatedLabel.value = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")} 更新`;
}

function stopTimers() {
  fetchAbort?.abort();
  fetchAbort = null;
  if (refreshTimer !== undefined) {
    window.clearInterval(refreshTimer);
    refreshTimer = undefined;
  }
  if (burnInTimer !== undefined) {
    window.clearInterval(burnInTimer);
    burnInTimer = undefined;
  }
}

function startTimers() {
  stopTimers();
  void refreshDashboardData();
  refreshTimer = window.setInterval(() => {
    if (!document.hidden && props.active) {
      void refreshDashboardData();
    }
  }, PHOTO_FRAME_DASHBOARD_REFRESH_MS);
  burnInTimer = window.setInterval(() => {
    if (!document.hidden && props.active) {
      burnInStep.value += 1;
    }
  }, 60 * 1000);
}

watch(
  () => props.active,
  (isActive) => {
    if (isActive) startTimers();
    else stopTimers();
  },
  { immediate: true },
);

onBeforeUnmount(() => {
  stopTimers();
});
</script>

<template>
  <div
    class="photo-dash-layer"
    :class="{ 'is-night-dim': nightDim }"
    :style="antiBurnInStyle"
    aria-label="家庭看板浮层"
  >
    <div class="photo-dash-clock-card">
      <div class="photo-dash-time">{{ nowClock }}</div>
      <div class="photo-dash-date">{{ nowDate }}</div>
      <div v-if="lunarLine" class="photo-dash-lunar">{{ lunarLine }}</div>
      <div v-if="captionText" class="photo-dash-caption">{{ captionText }}</div>
    </div>

    <div class="photo-dash-widgets-col">
      <section v-if="upcomingReminders.length > 0" class="photo-dash-card" aria-label="未来 14 天家庭倒数">
        <header class="photo-dash-card-head">
          <CalendarHeart :size="14" aria-hidden="true" />
          <span>近期倒数 · 14 天</span>
          <small v-if="lastUpdatedLabel" class="photo-dash-updated">{{ lastUpdatedLabel }}</small>
        </header>
        <ul class="photo-dash-list">
          <li v-for="rem in upcomingReminders" :key="rem.id" class="photo-dash-item">
            <div class="photo-dash-item-main">
              <strong class="photo-dash-item-title">{{ rem.title }}</strong>
              <span class="photo-dash-item-sub">
                {{ reminderCategoryLabel(rem.category) }}
                <template v-if="rem.lunarLabel"> · 农历 {{ rem.lunarLabel }}</template>
                <template v-else> · {{ rem.nextSolarDate }}</template>
                <template v-if="formatReminderMilestone(rem)"> · {{ formatReminderMilestone(rem) }}</template>
              </span>
            </div>
            <span class="photo-dash-pill" :class="{ 'is-today': rem.daysUntil <= 1 }">
              {{ formatCountdownLabel(rem.daysUntil) }}
            </span>
          </li>
        </ul>
      </section>

      <section v-if="displayedMessages.length > 0" class="photo-dash-card" aria-label="家庭留言板摘要">
        <header class="photo-dash-card-head">
          <MessageSquareHeart :size="14" aria-hidden="true" />
          <span>家庭留言板</span>
        </header>
        <ul class="photo-dash-list">
          <li v-for="msg in displayedMessages" :key="msg.id" class="photo-dash-board-item">
            <div class="photo-dash-board-meta">
              <span v-if="msg.pinned" class="photo-dash-pin"><Pin :size="11" /> 置顶</span>
              <span class="photo-dash-tag">{{ msg.tag || "留言" }}</span>
              <span class="photo-dash-author">{{ msg.authorUsername }}</span>
            </div>
            <p class="photo-dash-board-text">{{ msg.content }}</p>
          </li>
        </ul>
      </section>
    </div>
  </div>
</template>

<style scoped>
.photo-dash-layer {
  position: absolute;
  inset: max(68px, env(safe-area-inset-top)) max(24px, env(safe-area-inset-right)) max(24px, env(safe-area-inset-bottom)) max(24px, env(safe-area-inset-left));
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 20px;
  pointer-events: none;
  transition: transform 1.6s ease, opacity 0.6s ease;
}
.photo-dash-layer.is-night-dim {
  opacity: 0.72;
}
.photo-dash-clock-card {
  max-width: min(460px, 52vw);
  padding: 18px 22px;
  border-radius: 22px;
  background: rgba(14, 15, 20, 0.44);
  border: 1px solid rgba(255, 255, 255, 0.16);
  -webkit-backdrop-filter: blur(22px) saturate(145%);
  backdrop-filter: blur(22px) saturate(145%);
  box-shadow: 0 18px 44px rgba(0, 0, 0, 0.36);
}
.photo-dash-time {
  font-size: clamp(48px, 7.5vw, 92px);
  font-weight: 600;
  line-height: 0.98;
  letter-spacing: -0.03em;
  font-variant-numeric: tabular-nums;
  text-shadow: 0 4px 18px rgba(0, 0, 0, 0.4);
}
.photo-dash-date {
  margin-top: 8px;
  font-size: clamp(15px, 1.8vw, 19px);
  font-weight: 550;
  color: rgba(255, 255, 255, 0.94);
  font-variant-numeric: tabular-nums;
}
.photo-dash-lunar {
  margin-top: 4px;
  font-size: clamp(13px, 1.4vw, 15px);
  color: rgba(255, 232, 186, 0.92);
  font-weight: 500;
}
.photo-dash-caption {
  margin-top: 8px;
  font-size: 12.5px;
  color: rgba(255, 255, 255, 0.78);
  word-break: break-word;
}
.photo-dash-widgets-col {
  width: min(360px, 40vw);
  display: flex;
  flex-direction: column;
  gap: 12px;
  max-height: 100%;
  overflow: hidden;
}
.photo-dash-card {
  padding: 13px 15px;
  border-radius: 18px;
  background: rgba(14, 15, 20, 0.46);
  border: 1px solid rgba(255, 255, 255, 0.16);
  -webkit-backdrop-filter: blur(22px) saturate(145%);
  backdrop-filter: blur(22px) saturate(145%);
  box-shadow: 0 14px 36px rgba(0, 0, 0, 0.32);
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.photo-dash-card-head {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  font-weight: 650;
  color: rgba(255, 255, 255, 0.88);
  letter-spacing: 0.02em;
}
.photo-dash-updated {
  margin-left: auto;
  font-size: 11px;
  font-weight: 500;
  color: rgba(255, 255, 255, 0.6);
  font-variant-numeric: tabular-nums;
}
.photo-dash-list {
  margin: 0;
  padding: 0;
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 7px;
}
.photo-dash-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}
.photo-dash-item-main {
  display: flex;
  flex-direction: column;
  gap: 1px;
  min-width: 0;
}
.photo-dash-item-title {
  font-size: 13px;
  font-weight: 600;
  color: #ffffff;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.photo-dash-item-sub {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.72);
  font-variant-numeric: tabular-nums;
}
.photo-dash-pill {
  flex-shrink: 0;
  padding: 2px 8px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 650;
  background: rgba(255, 255, 255, 0.16);
  color: #ffffff;
  font-variant-numeric: tabular-nums;
}
.photo-dash-pill.is-today {
  background: rgba(232, 166, 77, 0.34);
  color: #ffe8b8;
}
.photo-dash-board-item {
  display: flex;
  flex-direction: column;
  gap: 3px;
  padding-top: 6px;
  border-top: 1px solid rgba(255, 255, 255, 0.1);
}
.photo-dash-board-item:first-child {
  padding-top: 0;
  border-top: 0;
}
.photo-dash-board-meta {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 11px;
  color: rgba(255, 255, 255, 0.72);
}
.photo-dash-pin {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  color: #ffd58a;
  font-weight: 600;
}
.photo-dash-tag {
  padding: 1px 6px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.14);
  color: rgba(255, 255, 255, 0.92);
}
.photo-dash-author {
  margin-left: auto;
}
.photo-dash-board-text {
  margin: 0;
  font-size: 12.5px;
  line-height: 1.4;
  color: rgba(255, 255, 255, 0.94);
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
@media (max-width: 820px) {
  .photo-dash-layer {
    flex-direction: column;
    align-items: stretch;
    justify-content: flex-end;
    gap: 12px;
  }
  .photo-dash-clock-card,
  .photo-dash-widgets-col {
    max-width: 100%;
    width: 100%;
  }
}
@media (prefers-reduced-motion: reduce) {
  .photo-dash-layer {
    transform: none !important;
    transition: none;
  }
}
</style>
