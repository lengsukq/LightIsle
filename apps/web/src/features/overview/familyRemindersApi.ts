import { apiRequest, type ApiRequestOptions } from "../../api/apiClient.ts";

export interface LunarDate {
  year: number;
  month: number;
  day: number;
  isLeap: boolean;
  ganZhi: string;
  zodiac: string;
  monthName: string;
  dayName: string;
  display: string;
}

export type ReminderCategory = "birthday" | "anniversary" | "chore" | "bill" | "custom";
export type ReminderCalendarType = "solar" | "lunar";
export type ReminderRepeatRule = "yearly" | "monthly" | "weekly" | "interval_days" | "once";
export type ReminderColor = "amber" | "blue" | "rose" | "sage" | "violet";

export interface FamilyReminder {
  id: number;
  authorUserId: number;
  authorUsername: string;
  title: string;
  category: ReminderCategory | string;
  calendarType: ReminderCalendarType | string;
  year: number;
  month: number;
  day: number;
  isLeapMonth: boolean;
  repeatRule: ReminderRepeatRule | string;
  intervalDays: number;
  nextSolarDate: string;
  daysUntil: number;
  yearsCount?: number;
  lunarLabel?: string;
  remindDays: number[];
  remindDaysCsv: string;
  notifyEnabled: boolean;
  color: ReminderColor | string;
  notes: string;
  createdAt: number;
  updatedAt: number;
}

export interface FamilyReminderListResponse {
  reminders: FamilyReminder[];
  todaySolar: string;
  todayLunar?: LunarDate;
  isAdmin?: boolean;
  currentUserId?: number;
  currentUsername?: string;
}

export interface FamilyReminderInput {
  title: string;
  category: ReminderCategory;
  calendarType: ReminderCalendarType;
  year: number;
  month: number;
  day: number;
  isLeapMonth: boolean;
  repeatRule: ReminderRepeatRule;
  intervalDays: number;
  nextSolarDate?: string;
  remindDays: number[];
  notifyEnabled: boolean;
  color: ReminderColor;
  notes: string;
}

export type FamilyReminderPatch = Partial<FamilyReminderInput>;

export interface FamilyBoardPreviewMessage {
  id: number;
  authorUsername: string;
  content: string;
  tag: string;
  color: string;
  pinned: boolean;
  createdAt: number;
}

export type JsonRequester = <T = unknown>(path: string, options?: ApiRequestOptions) => Promise<T>;

export const REMINDER_CATEGORIES: ReadonlyArray<{
  value: ReminderCategory;
  label: string;
  defaultRepeat: ReminderRepeatRule;
  defaultColor: ReminderColor;
}> = [
  { value: "birthday", label: "生日", defaultRepeat: "yearly", defaultColor: "rose" },
  { value: "anniversary", label: "纪念日", defaultRepeat: "yearly", defaultColor: "amber" },
  { value: "chore", label: "家务周期", defaultRepeat: "interval_days", defaultColor: "sage" },
  { value: "bill", label: "账单缴费", defaultRepeat: "monthly", defaultColor: "blue" },
  { value: "custom", label: "其他提醒", defaultRepeat: "once", defaultColor: "violet" },
];

export const REMINDER_REPEAT_OPTIONS: ReadonlyArray<{
  value: ReminderRepeatRule;
  label: string;
  lunarAllowed: boolean;
}> = [
  { value: "yearly", label: "每年重复", lunarAllowed: true },
  { value: "monthly", label: "每月重复", lunarAllowed: false },
  { value: "weekly", label: "每周重复", lunarAllowed: false },
  { value: "interval_days", label: "每隔 N 天", lunarAllowed: false },
  { value: "once", label: "仅此一次", lunarAllowed: true },
];

export const REMINDER_COLORS: ReadonlyArray<{ id: ReminderColor; label: string }> = [
  { id: "amber", label: "暖阳" },
  { id: "rose", label: "晚霞" },
  { id: "sage", label: "青苔" },
  { id: "blue", label: "晴空" },
  { id: "violet", label: "暮紫" },
];

export const REMIND_ADVANCE_PRESETS: ReadonlyArray<{ days: number; label: string }> = [
  { days: 7, label: "提前 7 天" },
  { days: 3, label: "提前 3 天" },
  { days: 1, label: "提前 1 天" },
  { days: 0, label: "当天提醒" },
];

export const LUNAR_MONTH_OPTIONS: ReadonlyArray<{ value: number; label: string }> = [
  "正月", "二月", "三月", "四月", "五月", "六月",
  "七月", "八月", "九月", "十月", "冬月", "腊月",
].map((label, idx) => ({ value: idx + 1, label }));

export const LUNAR_DAY_OPTIONS: ReadonlyArray<{ value: number; label: string }> = [
  "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
  "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
  "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
].map((label, idx) => ({ value: idx + 1, label }));

export function reminderCategoryLabel(category: string): string {
  return REMINDER_CATEGORIES.find((c) => c.value === category)?.label ?? "提醒";
}

export function reminderRepeatLabel(rule: string, intervalDays = 0): string {
  if (rule === "interval_days" && intervalDays > 0) return `每 ${intervalDays} 天`;
  return REMINDER_REPEAT_OPTIONS.find((r) => r.value === rule)?.label ?? "不重复";
}

export function reminderToneClass(color?: string): string {
  const allowed = new Set<string>(["amber", "blue", "rose", "sage", "violet"]);
  return `tone-${color && allowed.has(color) ? color : "amber"}`;
}

export function formatCountdownLabel(daysUntil: number): string {
  if (!Number.isFinite(daysUntil)) return "";
  if (daysUntil < 0) return `已过期 ${Math.abs(daysUntil)} 天`;
  if (daysUntil === 0) return "就是今天";
  if (daysUntil === 1) return "明天";
  return `还有 ${daysUntil} 天`;
}

export function formatReminderMilestone(reminder: FamilyReminder): string {
  if (!reminder.yearsCount || reminder.yearsCount <= 0) return "";
  if (reminder.category === "birthday") return `${reminder.yearsCount} 岁生日`;
  if (reminder.category === "anniversary") return `第 ${reminder.yearsCount} 周年`;
  return `第 ${reminder.yearsCount} 年`;
}

export function canEditFamilyReminder(
  reminder: FamilyReminder,
  identity: { isAdmin: boolean; currentUserId: number; username: string },
): boolean {
  if (identity.isAdmin) return true;
  if (identity.currentUserId > 0 && reminder.authorUserId === identity.currentUserId) return true;
  return Boolean(identity.username) && reminder.authorUsername.toLowerCase() === identity.username.toLowerCase();
}

export function validateFamilyReminderInput(input: FamilyReminderInput): string {
  const title = input.title.trim();
  if (!title) return "请输入提醒标题。";
  if ([...title].length > 80) return "标题不能超过 80 个字符。";
  if (input.year !== 0 && (input.year < 1900 || input.year > 2100)) {
    return "起始年份需在 1900 至 2100 之间，或留空。";
  }
  if (input.month < 1 || input.month > 12) return "请选择有效的月份。";
  const maxDay = input.calendarType === "lunar" ? 30 : 31;
  if (input.day < 1 || input.day > maxDay) return "请选择有效的日期。";
  if (input.calendarType === "lunar" && input.repeatRule !== "yearly" && input.repeatRule !== "once") {
    return "农历提醒仅支持「每年重复」或「仅此一次」。";
  }
  if (input.repeatRule === "interval_days" && (input.intervalDays < 1 || input.intervalDays > 3650)) {
    return "间隔天数需在 1 至 3650 天之间。";
  }
  if (!input.remindDays.length) return "请至少选择一个提前提醒时机。";
  if ([...input.notes.trim()].length > 300) return "备注不能超过 300 个字符。";
  return "";
}

export async function listFamilyReminders(
  params: { days?: number; category?: string } = {},
  options: { signal?: AbortSignal; requester?: JsonRequester } = {},
): Promise<FamilyReminderListResponse> {
  const query = new URLSearchParams();
  if (typeof params.days === "number" && params.days > 0) {
    query.set("days", String(params.days));
  }
  if (params.category) {
    query.set("category", params.category);
  }
  const suffix = query.size ? `?${query.toString()}` : "";
  const req = options.requester ?? apiRequest;
  const res = await req<FamilyReminderListResponse>(`/api/v2/family-reminders${suffix}`, {
    method: "GET",
    signal: options.signal,
  });
  return {
    reminders: Array.isArray(res?.reminders) ? res.reminders : [],
    todaySolar: res?.todaySolar ?? "",
    todayLunar: res?.todayLunar,
    isAdmin: res?.isAdmin,
    currentUserId: res?.currentUserId,
    currentUsername: res?.currentUsername,
  };
}

export async function createFamilyReminder(
  input: FamilyReminderInput,
  requester: JsonRequester = apiRequest,
): Promise<FamilyReminder> {
  const res = await requester<{ reminder: FamilyReminder }>("/api/v2/family-reminders", {
    method: "POST",
    json: input,
  });
  return res.reminder;
}

export async function updateFamilyReminder(
  id: number,
  patch: FamilyReminderPatch,
  requester: JsonRequester = apiRequest,
): Promise<FamilyReminder> {
  const res = await requester<{ reminder: FamilyReminder }>(`/api/v2/family-reminders/${encodeURIComponent(String(id))}`, {
    method: "PATCH",
    json: patch,
  });
  return res.reminder;
}

export async function deleteFamilyReminder(
  id: number,
  requester: JsonRequester = apiRequest,
): Promise<void> {
  await requester(`/api/v2/family-reminders/${encodeURIComponent(String(id))}`, {
    method: "DELETE",
  });
}

export async function completeFamilyReminder(
  id: number,
  requester: JsonRequester = apiRequest,
): Promise<FamilyReminder> {
  const res = await requester<{ completed: boolean; reminder: FamilyReminder }>(
    `/api/v2/family-reminders/${encodeURIComponent(String(id))}/complete`,
    { method: "POST" },
  );
  return res.reminder;
}

export async function fetchFamilyBoardPreview(
  limit = 3,
  options: { signal?: AbortSignal; requester?: JsonRequester } = {},
): Promise<FamilyBoardPreviewMessage[]> {
  const req = options.requester ?? apiRequest;
  const res = await req<{ messages?: FamilyBoardPreviewMessage[] }>("/api/v2/board/messages?limit=12", {
    method: "GET",
    signal: options.signal,
  });
  const list = Array.isArray(res?.messages) ? res.messages : [];
  const sorted = [...list].sort((a, b) => {
    if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
    return (b.createdAt ?? 0) - (a.createdAt ?? 0);
  });
  return sorted.slice(0, Math.max(1, limit));
}

export type PhotoFrameDisplayMode = "frame" | "dashboard";
export const PHOTO_FRAME_MODE_KEY = "lightisle.photoFrame.mode";
export const PHOTO_FRAME_DASHBOARD_REFRESH_MS = 5 * 60 * 1000;

export function readPhotoFrameMode(storage?: Pick<Storage, "getItem"> | null): PhotoFrameDisplayMode {
  try {
    const store = storage ?? (typeof window !== "undefined" ? window.localStorage : null);
    const val = store?.getItem(PHOTO_FRAME_MODE_KEY);
    return val === "dashboard" ? "dashboard" : "frame";
  } catch {
    return "frame";
  }
}

export function savePhotoFrameMode(
  mode: PhotoFrameDisplayMode,
  storage?: Pick<Storage, "setItem"> | null,
): void {
  try {
    const store = storage ?? (typeof window !== "undefined" ? window.localStorage : null);
    store?.setItem(PHOTO_FRAME_MODE_KEY, mode);
  } catch {
    // Ignore storage quota or private-mode restrictions.
  }
}

export function isNightDimHour(date: Date = new Date()): boolean {
  const h = date.getHours();
  return h >= 22 || h < 7;
}

const BURN_IN_PATTERN: ReadonlyArray<{ x: number; y: number }> = [
  { x: 0, y: 0 },
  { x: 3, y: 2 },
  { x: 5, y: -2 },
  { x: 2, y: -4 },
  { x: -3, y: -3 },
  { x: -5, y: 1 },
  { x: -2, y: 4 },
  { x: 1, y: 3 },
];

export function burnInShiftForStep(step: number): { x: number; y: number } {
  const idx = ((Math.trunc(step) % BURN_IN_PATTERN.length) + BURN_IN_PATTERN.length) % BURN_IN_PATTERN.length;
  return BURN_IN_PATTERN[idx];
}

export const FAMILY_DOCS_ROOT_FOLDER = "家庭档案";
export const FAMILY_DOCS_CATEGORIES = ["证件", "发票", "保修", "合同", "体检", "其他"] as const;
export type FamilyDocsCategory = (typeof FAMILY_DOCS_CATEGORIES)[number];

export function buildDocsArchivePathPrefix(personalPhotosPath: string, category: string): string {
  const cleanRoot = personalPhotosPath.replace(/^\/+|\/+$/g, "");
  const base = cleanRoot ? `${cleanRoot}/${FAMILY_DOCS_ROOT_FOLDER}` : FAMILY_DOCS_ROOT_FOLDER;
  const cleanCat = category.trim().replace(/^\/+|\/+$/g, "");
  return cleanCat ? `${base}/${cleanCat}` : base;
}
