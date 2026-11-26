<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { Bell, CalendarHeart } from "lucide-vue-next";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleChip from "../../components/ui/IsleChip.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import {
  LUNAR_DAY_OPTIONS,
  LUNAR_MONTH_OPTIONS,
  REMIND_ADVANCE_PRESETS,
  REMINDER_CATEGORIES,
  REMINDER_COLORS,
  REMINDER_REPEAT_OPTIONS,
  validateFamilyReminderInput,
  type FamilyReminder,
  type FamilyReminderInput,
  type ReminderCalendarType,
  type ReminderCategory,
  type ReminderColor,
  type ReminderRepeatRule,
} from "./familyRemindersApi.ts";

const props = defineProps<{
  open: boolean;
  reminder: FamilyReminder | null;
  busy?: boolean;
  serverError?: string;
}>();

const emit = defineEmits<{
  close: [];
  submit: [payload: FamilyReminderInput];
}>();

const title = ref("");
const category = ref<ReminderCategory>("birthday");
const calendarType = ref<ReminderCalendarType>("solar");
const solarDate = ref("");
const lunarYear = ref("");
const lunarMonth = ref<number>(1);
const lunarDay = ref<number>(1);
const isLeapMonth = ref(false);
const repeatRule = ref<ReminderRepeatRule>("yearly");
const intervalDays = ref<number>(30);
const remindDays = ref<number[]>([7, 1, 0]);
const notifyEnabled = ref(true);
const color = ref<ReminderColor>("amber");
const notes = ref("");
const validationError = ref("");

const isEditing = computed(() => Boolean(props.reminder));
const modalTitle = computed(() => (isEditing.value ? "编辑家庭提醒" : "新建家庭提醒"));
const modalDesc = computed(() =>
  calendarType.value === "lunar"
    ? "支持 1900–2100 传统农历换算，自动推算下次公历日期与周岁/周年"
    : "设置生日、纪念日、周期家务或缴费提醒，到期前自动通知家人",
);

const repeatSelectOptions = computed(() =>
  REMINDER_REPEAT_OPTIONS.filter((opt) => calendarType.value === "solar" || opt.lunarAllowed).map((opt) => ({
    value: opt.value,
    label: opt.label,
  })),
);

const displayError = computed(() =>
  validationError.value || (props.serverError ? describeUserFacingError(new Error(props.serverError)) : ""),
);

function todayIso(): string {
  const now = new Date();
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function hydrateFromProps() {
  validationError.value = "";
  const r = props.reminder;
  if (!r) {
    title.value = "";
    category.value = "birthday";
    calendarType.value = "solar";
    solarDate.value = todayIso();
    lunarYear.value = "";
    lunarMonth.value = 1;
    lunarDay.value = 1;
    isLeapMonth.value = false;
    repeatRule.value = "yearly";
    intervalDays.value = 30;
    remindDays.value = [7, 1, 0];
    notifyEnabled.value = true;
    color.value = "rose";
    notes.value = "";
    return;
  }
  title.value = r.title;
  category.value = (REMINDER_CATEGORIES.some((c) => c.value === r.category) ? r.category : "custom") as ReminderCategory;
  calendarType.value = r.calendarType === "lunar" ? "lunar" : "solar";
  if (calendarType.value === "lunar") {
    lunarYear.value = r.year > 0 ? String(r.year) : "";
    lunarMonth.value = r.month >= 1 && r.month <= 12 ? r.month : 1;
    lunarDay.value = r.day >= 1 && r.day <= 30 ? r.day : 1;
    isLeapMonth.value = Boolean(r.isLeapMonth);
    solarDate.value = r.nextSolarDate || todayIso();
  } else {
    const y = r.year > 0 ? r.year : new Date().getFullYear();
    const m = String(Math.max(1, Math.min(12, r.month || 1))).padStart(2, "0");
    const d = String(Math.max(1, Math.min(31, r.day || 1))).padStart(2, "0");
    solarDate.value = r.year > 0 ? `${y}-${m}-${d}` : (r.nextSolarDate || todayIso());
    lunarYear.value = "";
    lunarMonth.value = 1;
    lunarDay.value = 1;
    isLeapMonth.value = false;
  }
  repeatRule.value = (REMINDER_REPEAT_OPTIONS.some((o) => o.value === r.repeatRule) ? r.repeatRule : "yearly") as ReminderRepeatRule;
  intervalDays.value = r.intervalDays > 0 ? r.intervalDays : 30;
  remindDays.value = Array.isArray(r.remindDays) && r.remindDays.length ? [...r.remindDays] : [7, 1, 0];
  notifyEnabled.value = r.notifyEnabled !== false;
  color.value = (REMINDER_COLORS.some((c) => c.id === r.color) ? r.color : "amber") as ReminderColor;
  notes.value = r.notes || "";
}

watch(
  () => [props.open, props.reminder] as const,
  ([isOpen]) => {
    if (isOpen) hydrateFromProps();
  },
  { immediate: true },
);

function selectCategory(nextCat: ReminderCategory) {
  category.value = nextCat;
  if (!isEditing.value) {
    const meta = REMINDER_CATEGORIES.find((c) => c.value === nextCat);
    if (meta) {
      color.value = meta.defaultColor;
      if (calendarType.value === "solar") {
        repeatRule.value = meta.defaultRepeat;
      } else {
        repeatRule.value = meta.defaultRepeat === "once" ? "once" : "yearly";
      }
    }
  }
}

function setCalendarType(nextType: ReminderCalendarType) {
  calendarType.value = nextType;
  if (nextType === "lunar" && repeatRule.value !== "yearly" && repeatRule.value !== "once") {
    repeatRule.value = "yearly";
  }
}

function toggleRemindDay(day: number) {
  if (remindDays.value.includes(day)) {
    if (remindDays.value.length <= 1) return;
    remindDays.value = remindDays.value.filter((d) => d !== day);
  } else {
    remindDays.value = [...remindDays.value, day].sort((a, b) => b - a);
  }
}

function handleSubmit() {
  validationError.value = "";
  let year = 0;
  let month = 1;
  let day = 1;
  let nextSolarDate: string | undefined;

  if (calendarType.value === "lunar") {
    if (lunarYear.value.trim()) {
      const parsed = Number.parseInt(lunarYear.value.trim(), 10);
      if (!Number.isFinite(parsed)) {
        validationError.value = "起始年份必须是数字。";
        return;
      }
      year = parsed;
    }
    month = lunarMonth.value;
    day = lunarDay.value;
  } else {
    const parts = solarDate.value.split("-").map((p) => Number.parseInt(p, 10));
    if (parts.length !== 3 || parts.some((n) => !Number.isFinite(n))) {
      validationError.value = "请选择有效的公历日期。";
      return;
    }
    [year, month, day] = parts;
    if (repeatRule.value === "once" || repeatRule.value === "interval_days" || repeatRule.value === "weekly") {
      nextSolarDate = solarDate.value;
    }
  }

  const payload: FamilyReminderInput = {
    title: title.value.trim(),
    category: category.value,
    calendarType: calendarType.value,
    year,
    month,
    day,
    isLeapMonth: calendarType.value === "lunar" ? isLeapMonth.value : false,
    repeatRule: repeatRule.value,
    intervalDays: repeatRule.value === "interval_days" ? Math.round(Number(intervalDays.value) || 0) : 0,
    ...(nextSolarDate ? { nextSolarDate } : {}),
    remindDays: [...remindDays.value].sort((a, b) => b - a),
    notifyEnabled: notifyEnabled.value,
    color: color.value,
    notes: notes.value.trim(),
  };

  const err = validateFamilyReminderInput(payload);
  if (err) {
    validationError.value = err;
    return;
  }
  emit("submit", payload);
}
</script>

<template>
  <IsleModal :open="open" :title="modalTitle" :description="modalDesc" size="md" @close="emit('close')">
    <template #icon><CalendarHeart :size="16" /></template>

    <form id="family-reminder-form" class="reminder-modal-form" @submit.prevent="handleSubmit">
      <IsleBanner v-if="displayError" type="error" compact :message="displayError" />

      <label class="reminder-field">
        <span>标题</span>
        <input
          v-model="title"
          type="text"
          maxlength="80"
          autofocus
          placeholder="例如：妈妈农历生日、净水器换滤芯、结婚纪念日"
          required
        />
      </label>

      <div class="reminder-field">
        <span>分类</span>
        <div class="reminder-chip-row" role="radiogroup" aria-label="提醒分类">
          <IsleChip
            v-for="cat in REMINDER_CATEGORIES"
            :key="cat.value"
            small
            :selected="category === cat.value"
            @select="selectCategory(cat.value)"
          >
            {{ cat.label }}
          </IsleChip>
        </div>
      </div>

      <div class="reminder-grid-two">
        <div class="reminder-field">
          <span>日历类型</span>
          <div class="reminder-segment" role="radiogroup" aria-label="日历类型">
            <button
              type="button"
              :class="{ active: calendarType === 'solar' }"
              @click="setCalendarType('solar')"
            >
              公历
            </button>
            <button
              type="button"
              :class="{ active: calendarType === 'lunar' }"
              @click="setCalendarType('lunar')"
            >
              农历
            </button>
          </div>
        </div>

        <div class="reminder-field">
          <span>重复周期</span>
          <AppleSelect
            v-model="repeatRule"
            :options="repeatSelectOptions"
            size="md"
            block
            aria-label="重复周期"
          />
        </div>
      </div>

      <div v-if="calendarType === 'solar'" class="reminder-grid-two">
        <label class="reminder-field">
          <span>公历日期（出生/起始或下次日期）</span>
          <input v-model="solarDate" type="date" required />
        </label>
        <label v-if="repeatRule === 'interval_days'" class="reminder-field">
          <span>间隔天数（天）</span>
          <input v-model.number="intervalDays" type="number" min="1" max="3650" step="1" required />
        </label>
      </div>

      <div v-else class="reminder-lunar-grid">
        <label class="reminder-field">
          <span>起始年份（选填，算周岁/周年）</span>
          <input v-model="lunarYear" type="number" min="1900" max="2100" placeholder="例如 1968，可留空" />
        </label>
        <div class="reminder-field">
          <span>农历月份</span>
          <AppleSelect v-model="lunarMonth" :options="[...LUNAR_MONTH_OPTIONS]" size="md" block aria-label="农历月份" />
        </div>
        <div class="reminder-field">
          <span>农历日期</span>
          <AppleSelect v-model="lunarDay" :options="[...LUNAR_DAY_OPTIONS]" size="md" block aria-label="农历日期" />
        </div>
        <label class="reminder-checkbox-row">
          <input v-model="isLeapMonth" type="checkbox" />
          <span>这是闰月日期</span>
        </label>
      </div>

      <div class="reminder-field">
        <span>提前提醒时机</span>
        <div class="reminder-chip-row" role="group" aria-label="提前提醒时机">
          <IsleChip
            v-for="preset in REMIND_ADVANCE_PRESETS"
            :key="preset.days"
            small
            :selected="remindDays.includes(preset.days)"
            @select="toggleRemindDay(preset.days)"
          >
            {{ preset.label }}
          </IsleChip>
        </div>
      </div>

      <div class="reminder-grid-two">
        <div class="reminder-field">
          <span>卡片色调</span>
          <div class="reminder-color-row" role="radiogroup" aria-label="卡片色调">
            <button
              v-for="c in REMINDER_COLORS"
              :key="c.id"
              type="button"
              class="reminder-color-dot"
              :class="[`dot-${c.id}`, { active: color === c.id }]"
              :title="c.label"
              :aria-label="`色调：${c.label}`"
              @click="color = c.id"
            />
          </div>
        </div>
        <label class="reminder-checkbox-row reminder-notify-toggle">
          <input v-model="notifyEnabled" type="checkbox" />
          <Bell :size="14" aria-hidden="true" />
          <span>开启到期提醒通知</span>
        </label>
      </div>

      <label class="reminder-field">
        <span>备注（选填）</span>
        <textarea
          v-model="notes"
          rows="2"
          maxlength="300"
          placeholder="可写滤芯型号、礼物想法或交费账号提示…"
        />
      </label>
    </form>

    <template #footer>
      <IsleButton variant="glass" :disabled="busy" @click="emit('close')">取消</IsleButton>
      <IsleButton type="submit" form="family-reminder-form" variant="primary" :loading="busy">
        {{ isEditing ? "保存修改" : "添加提醒" }}
      </IsleButton>
    </template>
  </IsleModal>
</template>

<style scoped>
.reminder-modal-form { display: flex; flex-direction: column; gap: 12px; }
.reminder-field { display: flex; flex-direction: column; gap: 5px; min-width: 0; }
.reminder-field > span { font-size: 12px; font-weight: 600; color: var(--text-secondary); }
.reminder-field input[type="text"],
.reminder-field input[type="date"],
.reminder-field input[type="number"],
.reminder-field textarea {
  width: 100%; box-sizing: border-box; padding: 7px 11px; border-radius: 10px;
  border: 1px solid var(--fluid-card-border); background: var(--fluid-card-item-fill);
  color: var(--text-primary); font: inherit; font-size: 13px;
}
.reminder-field textarea { resize: vertical; min-height: 60px; }
.reminder-chip-row { display: flex; flex-wrap: wrap; gap: 6px; }
.reminder-grid-two { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; align-items: end; }
.reminder-lunar-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; }
.reminder-segment {
  display: grid; grid-template-columns: 1fr 1fr; padding: 3px; border-radius: 10px;
  background: var(--fluid-card-item-fill); border: 1px solid var(--fluid-card-border); gap: 3px;
}
.reminder-segment button {
  height: 29px; border: 0; border-radius: 7px; background: transparent;
  color: var(--text-secondary); font: inherit; font-size: 12.5px; font-weight: 600; cursor: pointer;
}
.reminder-segment button.active {
  background: var(--surface-elevated); color: var(--text-primary);
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
}
.reminder-checkbox-row {
  grid-column: 1 / -1; display: inline-flex; align-items: center; gap: 7px;
  font-size: 12.5px; color: var(--text-secondary); cursor: pointer; user-select: none;
}
.reminder-notify-toggle { grid-column: auto; min-height: 32px; color: var(--text-primary); font-weight: 550; }
.reminder-color-row { display: flex; align-items: center; gap: 6px; min-height: 32px; }
.reminder-color-dot {
  width: 26px; height: 26px; padding: 3px; background-clip: content-box; border-radius: 999px;
  border: 2px solid transparent; cursor: pointer;
}
.reminder-color-dot.active { border-color: var(--text-primary); transform: scale(1.08); }
.dot-amber { background-color: #e8a64d; }
.dot-rose { background-color: #d96b85; }
.dot-sage { background-color: #3ea377; }
.dot-blue { background-color: #3b9ca8; }
.dot-violet { background-color: #8a72c2; }
@media (max-width: 600px) {
  .reminder-grid-two, .reminder-lunar-grid { grid-template-columns: minmax(0, 1fr); }
}
</style>
