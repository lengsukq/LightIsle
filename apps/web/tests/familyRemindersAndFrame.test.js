import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { parse } from "@vue/compiler-sfc";
import { compile } from "@vue/compiler-dom";
import {
  buildDocsArchivePathPrefix,
  burnInShiftForStep,
  canEditFamilyReminder,
  completeFamilyReminder,
  createFamilyReminder,
  deleteFamilyReminder,
  FAMILY_DOCS_CATEGORIES,
  fetchFamilyBoardPreview,
  formatCountdownLabel,
  formatReminderMilestone,
  isNightDimHour,
  listFamilyReminders,
  PHOTO_FRAME_DASHBOARD_REFRESH_MS,
  PHOTO_FRAME_MODE_KEY,
  readPhotoFrameMode,
  savePhotoFrameMode,
  updateFamilyReminder,
  validateFamilyReminderInput,
} from "../src/features/overview/familyRemindersApi.ts";

test("familyRemindersApi routes, query params, and CRUD payloads match Go Core contracts", async () => {
  const calls = [];
  const requester = async (path, options = {}) => {
    calls.push({ path, method: options.method ?? "GET", json: options.json });
    if (path.startsWith("/api/v2/family-reminders?")) {
      return {
        reminders: [{ id: 1, title: "妈妈生日", daysUntil: 3 }],
        todaySolar: "2026-11-26",
        todayLunar: { year: 2026, month: 10, day: 18, isLeap: false, ganZhi: "丙午", zodiac: "马", monthName: "十月", dayName: "十八", display: "十月十八" },
        currentUserId: 2,
      };
    }
    if (path === "/api/v2/family-reminders" && options.method === "POST") {
      return { reminder: { id: 9, ...options.json } };
    }
    if (path === "/api/v2/family-reminders/9" && options.method === "PATCH") {
      return { reminder: { id: 9, title: options.json.title } };
    }
    if (path === "/api/v2/family-reminders/9/complete" && options.method === "POST") {
      return { completed: true, reminder: { id: 9, daysUntil: 30 } };
    }
    if (path === "/api/v2/family-reminders/9" && options.method === "DELETE") {
      return { deleted: true, id: 9 };
    }
    throw new Error(`unexpected call: ${path}`);
  };

  const listed = await listFamilyReminders({ days: 14, category: "birthday" }, { requester });
  assert.equal(listed.reminders.length, 1);
  assert.equal(listed.todayLunar?.display, "十月十八");

  const created = await createFamilyReminder(
    {
      title: "妈妈农历生日",
      category: "birthday",
      calendarType: "lunar",
      year: 1968,
      month: 8,
      day: 15,
      isLeapMonth: false,
      repeatRule: "yearly",
      intervalDays: 0,
      remindDays: [7, 1, 0],
      notifyEnabled: true,
      color: "rose",
      notes: "买鲜花",
    },
    requester,
  );
  assert.equal(created.id, 9);

  await updateFamilyReminder(9, { title: "妈妈中秋生日" }, requester);
  const completed = await completeFamilyReminder(9, requester);
  assert.equal(completed.daysUntil, 30);
  await deleteFamilyReminder(9, requester);

  assert.deepEqual(
    calls.map((c) => `${c.method} ${c.path}`),
    [
      "GET /api/v2/family-reminders?days=14&category=birthday",
      "POST /api/v2/family-reminders",
      "PATCH /api/v2/family-reminders/9",
      "POST /api/v2/family-reminders/9/complete",
      "DELETE /api/v2/family-reminders/9",
    ],
  );
});

test("familyRemindersApi helpers format countdowns, milestones, permissions, and validation accurately", () => {
  assert.equal(formatCountdownLabel(-2), "已过期 2 天");
  assert.equal(formatCountdownLabel(0), "就是今天");
  assert.equal(formatCountdownLabel(1), "明天");
  assert.equal(formatCountdownLabel(12), "还有 12 天");

  assert.equal(formatReminderMilestone({ category: "birthday", yearsCount: 30 }), "30 岁生日");
  assert.equal(formatReminderMilestone({ category: "anniversary", yearsCount: 5 }), "第 5 周年");
  assert.equal(formatReminderMilestone({ category: "chore", yearsCount: 0 }), "");

  const rem = { authorUserId: 7, authorUsername: "alice" };
  assert.equal(canEditFamilyReminder(rem, { isAdmin: true, currentUserId: 1, username: "admin" }), true);
  assert.equal(canEditFamilyReminder(rem, { isAdmin: false, currentUserId: 7, username: "alice" }), true);
  assert.equal(canEditFamilyReminder(rem, { isAdmin: false, currentUserId: 8, username: "bob" }), false);

  const lunarInvalid = validateFamilyReminderInput({
    title: "测试",
    category: "chore",
    calendarType: "lunar",
    year: 0,
    month: 5,
    day: 10,
    isLeapMonth: false,
    repeatRule: "monthly",
    intervalDays: 0,
    remindDays: [1],
    notifyEnabled: true,
    color: "sage",
    notes: "",
  });
  assert.match(lunarInvalid, /农历提醒仅支持/);

  const intervalInvalid = validateFamilyReminderInput({
    title: "换滤芯",
    category: "chore",
    calendarType: "solar",
    year: 2026,
    month: 11,
    day: 26,
    isLeapMonth: false,
    repeatRule: "interval_days",
    intervalDays: 0,
    remindDays: [7, 0],
    notifyEnabled: true,
    color: "sage",
    notes: "",
  });
  assert.match(intervalInvalid, /间隔天数/);
});

test("fetchFamilyBoardPreview prioritizes pinned messages before latest timestamps", async () => {
  const preview = await fetchFamilyBoardPreview(2, {
    requester: async (path) => {
      assert.match(path, /^\/api\/v2\/board\/messages/);
      return {
        messages: [
          { id: 1, authorUsername: "bob", content: "买牛奶", tag: "采购", color: "blue", pinned: false, createdAt: 300 },
          { id: 2, authorUsername: "alice", content: "周末聚餐", tag: "留言", color: "amber", pinned: true, createdAt: 100 },
          { id: 3, authorUsername: "mom", content: "记得关窗", tag: "提醒", color: "rose", pinned: false, createdAt: 200 },
        ],
      };
    },
  });
  assert.deepEqual(
    preview.map((m) => m.id),
    [2, 1],
  );
});

test("photo frame dashboard persistence, night dimming, anti-burn-in shift, and docs archive prefix helpers", () => {
  const mem = new Map();
  const storage = {
    getItem: (k) => mem.get(k) ?? null,
    setItem: (k, v) => { mem.set(k, v); },
  };
  assert.equal(readPhotoFrameMode(storage), "frame");
  savePhotoFrameMode("dashboard", storage);
  assert.equal(mem.get(PHOTO_FRAME_MODE_KEY), "dashboard");
  assert.equal(readPhotoFrameMode(storage), "dashboard");
  assert.equal(PHOTO_FRAME_DASHBOARD_REFRESH_MS, 5 * 60 * 1000);

  assert.equal(isNightDimHour(new Date(2026, 10, 26, 22, 0)), true);
  assert.equal(isNightDimHour(new Date(2026, 10, 26, 6, 59)), true);
  assert.equal(isNightDimHour(new Date(2026, 10, 26, 7, 0)), false);
  assert.equal(isNightDimHour(new Date(2026, 10, 26, 21, 59)), false);

  for (let step = -3; step < 12; step += 1) {
    const shift = burnInShiftForStep(step);
    assert.ok(Math.abs(shift.x) <= 6 && Math.abs(shift.y) <= 6);
  }

  assert.deepEqual([...FAMILY_DOCS_CATEGORIES], ["证件", "发票", "保修", "合同", "体检", "其他"]);
  assert.equal(buildDocsArchivePathPrefix("users/alice/photos/", ""), "users/alice/photos/家庭档案");
  assert.equal(buildDocsArchivePathPrefix("/users/alice/photos", "发票"), "users/alice/photos/家庭档案/发票");
  assert.equal(buildDocsArchivePathPrefix("", "保修"), "家庭档案/保修");
});

test("reminders, photo frame dashboard, and family docs archive SFCs compile cleanly and honor UI guardrails", () => {
  const sfcPaths = [
    "../src/features/overview/FamilyRemindersSection.vue",
    "../src/features/overview/FamilyReminderModal.vue",
    "../src/features/photos/PhotoFrameOverlay.vue",
    "../src/features/photos/PhotoFrameDashboardWidgets.vue",
    "../src/features/photos/FamilyDocsArchiveView.vue",
    "../src/features/photos/PhotosView.vue",
    "../src/features/photos/PhotosTimelineToolbar.vue",
  ];
  for (const rel of sfcPaths) {
    const src = readFileSync(new URL(rel, import.meta.url), "utf8");
    const lines = src.split("\n").length;
    assert.ok(lines < 800, `${rel} has ${lines} lines; must be < 800`);
    const parsed = parse(src, { filename: rel });
    assert.equal(parsed.errors.length, 0, `${rel} SFC parse errors: ${parsed.errors.join("; ")}`);
    const compiled = compile(parsed.descriptor.template.content, { mode: "function" });
    assert.ok(compiled.code.length > 0, `${rel} template failed to compile`);
    assert.doesNotMatch(src, /<select[\s>]/i, `${rel} must use AppleSelect instead of native <select>`);
    assert.doesNotMatch(src, /window\.(confirm|alert|prompt)\s*\(/, `${rel} must not use window.confirm/alert/prompt`);
    assert.doesNotMatch(src, /:deep\(/, `${rel} must not use :deep()`);
  }

  const frameSrc = readFileSync(new URL("../src/features/photos/PhotoFrameOverlay.vue", import.meta.url), "utf8");
  assert.match(frameSrc, /纯净相框/);
  assert.match(frameSrc, /家庭看板/);
  assert.match(frameSrc, /PhotoFrameDashboardWidgets/);

  const docsSrc = readFileSync(new URL("../src/features/photos/FamilyDocsArchiveView.vue", import.meta.url), "utf8");
  assert.match(docsSrc, /pathPrefix/);
  assert.match(docsSrc, /"ocr"/);
  assert.match(docsSrc, /\/api\/v2\/photos\/ocr-priority/);
  assert.match(docsSrc, /一键复制文本/);
});
