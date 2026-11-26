<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import {
  Bell, BellOff, Cake, CalendarClock, CalendarHeart, CheckCircle2,
  Pencil, Plus, Receipt, Repeat, Sparkles, Trash2,
} from "lucide-vue-next";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleChip from "../../components/ui/IsleChip.vue";
import IslePageHeader from "../../components/ui/IslePageHeader.vue";
import FamilyReminderModal from "./FamilyReminderModal.vue";
import {
  canEditFamilyReminder,
  completeFamilyReminder,
  createFamilyReminder,
  deleteFamilyReminder,
  formatCountdownLabel,
  formatReminderMilestone,
  listFamilyReminders,
  reminderCategoryLabel,
  reminderRepeatLabel,
  reminderToneClass,
  updateFamilyReminder,
  type FamilyReminder,
  type FamilyReminderInput,
  type LunarDate,
} from "./familyRemindersApi.ts";

const props = defineProps<{
  isAdmin: boolean;
  username: string;
}>();

type ScopeFilter = "upcoming" | "all";

const reminders = ref<FamilyReminder[]>([]);
const todayLunar = ref<LunarDate | null>(null);
const currentUserId = ref(0);
const scope = ref<ScopeFilter>("upcoming");
const loading = ref(true);
const error = ref("");
const busyId = ref<number | null>(null);

const modalOpen = ref(false);
const editingReminder = ref<FamilyReminder | null>(null);
const modalBusy = ref(false);
const modalError = ref("");

const displayedReminders = computed(() => {
  if (scope.value === "upcoming") {
    const within = reminders.value.filter((r) => r.daysUntil <= 14);
    return within.length ? within : reminders.value.slice(0, 6);
  }
  return reminders.value;
});

const upcomingCount = computed(() => reminders.value.filter((r) => r.daysUntil <= 14).length);

const todaySubtitle = computed(() => {
  if (!todayLunar.value) return "生日、纪念日与家务周期倒数";
  return `今日农历 ${todayLunar.value.display}（${todayLunar.value.ganZhi}${todayLunar.value.zodiac}年）`;
});

function canManage(reminder: FamilyReminder): boolean {
  return canEditFamilyReminder(reminder, {
    isAdmin: props.isAdmin,
    currentUserId: currentUserId.value,
    username: props.username,
  });
}

async function fetchReminders() {
  loading.value = true;
  error.value = "";
  try {
    const res = await listFamilyReminders({});
    reminders.value = res.reminders;
    todayLunar.value = res.todayLunar ?? null;
    if (typeof res.currentUserId === "number") {
      currentUserId.value = res.currentUserId;
    }
  } catch (err) {
    error.value = describeUserFacingError(err);
  } finally {
    loading.value = false;
  }
}

function openCreateModal() {
  editingReminder.value = null;
  modalError.value = "";
  modalOpen.value = true;
}

function openEditModal(reminder: FamilyReminder) {
  editingReminder.value = reminder;
  modalError.value = "";
  modalOpen.value = true;
}

async function handleModalSubmit(payload: FamilyReminderInput) {
  if (modalBusy.value) return;
  modalBusy.value = true;
  modalError.value = "";
  try {
    if (editingReminder.value) {
      await updateFamilyReminder(editingReminder.value.id, payload);
    } else {
      await createFamilyReminder(payload);
    }
    modalOpen.value = false;
    editingReminder.value = null;
    await fetchReminders();
  } catch (err) {
    modalError.value = err instanceof Error ? err.message : "保存提醒失败";
  } finally {
    modalBusy.value = false;
  }
}

async function handleComplete(reminder: FamilyReminder) {
  if (busyId.value !== null) return;
  busyId.value = reminder.id;
  error.value = "";
  try {
    await completeFamilyReminder(reminder.id);
    await fetchReminders();
  } catch (err) {
    error.value = "打卡失败：" + describeUserFacingError(err);
  } finally {
    busyId.value = null;
  }
}

async function handleDelete(reminder: FamilyReminder) {
  if (busyId.value !== null) return;
  const confirmed = await requestConfirm({
    title: "删除家庭提醒",
    message: `确定要删除“${reminder.title}”吗？删除后将不再推送到期通知。`,
    confirmText: "确认删除",
    variant: "danger",
  });
  if (!confirmed) return;
  busyId.value = reminder.id;
  error.value = "";
  try {
    await deleteFamilyReminder(reminder.id);
    await fetchReminders();
  } catch (err) {
    error.value = "删除提醒失败：" + describeUserFacingError(err);
  } finally {
    busyId.value = null;
  }
}

onMounted(() => {
  void fetchReminders();
});
</script>

<template>
  <section class="family-reminders-section" aria-label="家庭纪念日与周期提醒">
    <IslePageHeader title="家庭日历与提醒" :subtitle="todaySubtitle" compact>
      <template #actions>
        <div v-if="reminders.length > 0" class="reminders-scope-chips" role="group" aria-label="筛选提醒范围">
          <IsleChip small :selected="scope === 'upcoming'" @select="scope = 'upcoming'">
            近期 ({{ upcomingCount }})
          </IsleChip>
          <IsleChip small :selected="scope === 'all'" @select="scope = 'all'">
            全部 ({{ reminders.length }})
          </IsleChip>
        </div>
        <IsleButton variant="glass" size="sm" @click="openCreateModal">
          <template #icon><Plus :size="14" /></template>
          新建提醒
        </IsleButton>
      </template>
    </IslePageHeader>

    <IsleBanner v-if="error" type="error" compact closable :message="error" @close="error = ''" />

    <div v-if="displayedReminders.length > 0" class="reminders-grid">
      <article
        v-for="item in displayedReminders"
        :key="item.id"
        class="reminder-card"
        :class="[reminderToneClass(item.color), { 'is-urgent': item.daysUntil <= 1 }]"
      >
        <div class="reminder-card-top">
          <div class="reminder-title-group">
            <span class="reminder-cat-icon" aria-hidden="true">
              <Cake v-if="item.category === 'birthday'" :size="14" />
              <CalendarHeart v-else-if="item.category === 'anniversary'" :size="14" />
              <Repeat v-else-if="item.category === 'chore'" :size="14" />
              <Receipt v-else-if="item.category === 'bill'" :size="14" />
              <Sparkles v-else :size="14" />
            </span>
            <strong class="reminder-title" :title="item.title">{{ item.title }}</strong>
          </div>
          <IsleBadge :variant="item.daysUntil <= 0 ? 'danger' : item.daysUntil <= 3 ? 'warning' : 'accent'" size="sm">
            {{ formatCountdownLabel(item.daysUntil) }}
          </IsleBadge>
        </div>

        <div class="reminder-meta-row">
          <span class="reminder-tag">{{ reminderCategoryLabel(item.category) }}</span>
          <span v-if="item.lunarLabel" class="reminder-date-chip">农历 {{ item.lunarLabel }}</span>
          <span class="reminder-date-chip">{{ item.nextSolarDate }}</span>
          <span v-if="formatReminderMilestone(item)" class="reminder-milestone">
            {{ formatReminderMilestone(item) }}
          </span>
        </div>

        <p v-if="item.notes" class="reminder-notes">{{ item.notes }}</p>

        <div class="reminder-card-foot">
          <span class="reminder-foot-meta">
            <span>{{ reminderRepeatLabel(item.repeatRule, item.intervalDays) }}</span>
            <span aria-hidden="true">·</span>
            <span class="reminder-notify-state" :title="item.notifyEnabled ? '已开启提醒通知' : '已静音'">
              <Bell v-if="item.notifyEnabled" :size="11" />
              <BellOff v-else :size="11" />
            </span>
            <span>{{ item.authorUsername }}</span>
          </span>

          <div class="reminder-actions">
            <button
              type="button"
              class="reminder-action-btn is-complete"
              :disabled="busyId === item.id"
              title="打卡完成并推进到下一个周期"
              @click="handleComplete(item)"
            >
              <CheckCircle2 :size="13" />
              <span>完成</span>
            </button>
            <button
              v-if="canManage(item)"
              type="button"
              class="reminder-icon-btn"
              :disabled="busyId === item.id"
              aria-label="编辑提醒"
              title="编辑提醒"
              @click="openEditModal(item)"
            >
              <Pencil :size="13" />
            </button>
            <button
              v-if="canManage(item)"
              type="button"
              class="reminder-icon-btn danger"
              :disabled="busyId === item.id"
              aria-label="删除提醒"
              title="删除提醒"
              @click="handleDelete(item)"
            >
              <Trash2 :size="13" />
            </button>
          </div>
        </div>
      </article>
    </div>

    <div v-else-if="loading" class="reminder-empty-strip" role="status">
      <CalendarClock :size="16" />
      <span>正在读取家庭日历与农历提醒…</span>
    </div>

    <div v-else class="reminder-empty-strip">
      <CalendarHeart :size="17" />
      <div class="reminder-empty-copy">
        <strong>还没有家庭提醒</strong>
        <small>记录家人农历/公历生日、纪念日或周期家务，到期前自动贴心提醒。</small>
      </div>
      <IsleButton variant="glass" size="sm" @click="openCreateModal">添加第一条</IsleButton>
    </div>

    <FamilyReminderModal
      :open="modalOpen"
      :reminder="editingReminder"
      :busy="modalBusy"
      :server-error="modalError"
      @close="modalOpen = false"
      @submit="handleModalSubmit"
    />
  </section>
</template>

<style scoped>
.family-reminders-section { margin-top: 18px; display: flex; flex-direction: column; gap: 10px; }
.reminders-scope-chips { display: inline-flex; align-items: center; gap: 5px; }
.reminders-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 285px), 1fr)); gap: 10px; }
.reminder-card {
  --rem-tone: #d9912b;
  display: flex; flex-direction: column; gap: 7px; padding: 13px 15px; border-radius: 15px;
  border: 1px solid color-mix(in srgb, var(--rem-tone) 24%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--rem-tone) 6%, var(--fluid-card-top));
  transition: border-color 0.16s ease, transform 0.16s ease;
}
.reminder-card.tone-amber { --rem-tone: #d9912b; }
.reminder-card.tone-rose { --rem-tone: #d96b85; }
.reminder-card.tone-sage { --rem-tone: #3ea377; }
.reminder-card.tone-blue { --rem-tone: #3b9ca8; }
.reminder-card.tone-violet { --rem-tone: #8a72c2; }
.reminder-card.is-urgent { border-color: color-mix(in srgb, var(--rem-tone) 52%, var(--fluid-card-border)); }
.reminder-card-top { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.reminder-title-group { display: flex; align-items: center; gap: 7px; min-width: 0; }
.reminder-cat-icon {
  width: 24px; height: 24px; border-radius: 7px; display: grid; place-items: center; flex-shrink: 0;
  background: color-mix(in srgb, var(--rem-tone) 16%, transparent); color: var(--rem-tone);
}
.reminder-title {
  font-size: 13.5px; font-weight: 650; color: var(--text-primary);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.reminder-meta-row { display: flex; align-items: center; flex-wrap: wrap; gap: 5px; font-size: 11.5px; }
.reminder-tag, .reminder-date-chip, .reminder-milestone {
  padding: 2px 7px; border-radius: 999px; font-variant-numeric: tabular-nums;
}
.reminder-tag { background: color-mix(in srgb, var(--rem-tone) 14%, transparent); color: var(--rem-tone); font-weight: 600; }
.reminder-date-chip { background: var(--fluid-card-item-fill); color: var(--text-secondary); }
.reminder-milestone { background: color-mix(in srgb, var(--accent-primary) 12%, transparent); color: var(--accent-primary); font-weight: 600; }
.reminder-notes {
  margin: 0; font-size: 12px; color: var(--text-secondary); line-height: 1.45;
  display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
}
.reminder-card-foot {
  margin-top: auto; padding-top: 6px; border-top: 1px solid color-mix(in srgb, var(--fluid-card-border) 70%, transparent);
  display: flex; align-items: center; justify-content: space-between; gap: 8px;
}
.reminder-foot-meta { display: inline-flex; align-items: center; gap: 5px; font-size: 11.5px; color: var(--text-tertiary); min-width: 0; }
.reminder-notify-state { display: inline-flex; align-items: center; }
.reminder-actions { display: inline-flex; align-items: center; gap: 4px; flex-shrink: 0; }
.reminder-action-btn, .reminder-icon-btn {
  display: inline-flex; align-items: center; gap: 4px; border-radius: 8px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
  color: var(--text-secondary); cursor: pointer; font-size: 11.5px; font-weight: 600;
}
.reminder-action-btn { height: 26px; padding: 0 8px; }
.reminder-action-btn.is-complete:hover:not(:disabled) { color: var(--success, #167a54); border-color: color-mix(in srgb, var(--success, #167a54) 36%, transparent); }
.reminder-icon-btn { width: 26px; height: 26px; justify-content: center; padding: 0; }
.reminder-icon-btn:hover:not(:disabled) { color: var(--text-primary); background: var(--fluid-card-hover); }
.reminder-icon-btn.danger:hover:not(:disabled) { color: var(--error, #c93b3b); }
.reminder-empty-strip {
  display: flex; align-items: center; gap: 12px; padding: 14px 16px; border-radius: 15px;
  border: 1px dashed var(--fluid-card-border); background: var(--fluid-card-item-fill); color: var(--text-secondary);
}
.reminder-empty-copy { flex: 1; display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.reminder-empty-copy strong { font-size: 13px; color: var(--text-primary); }
.reminder-empty-copy small { font-size: 12px; color: var(--text-secondary); }
@media (prefers-reduced-motion: reduce) {
  .reminder-card { transition: none; }
}
</style>
