import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  classifySessionDevice,
  formatRelativeActivity,
  partitionLoginSessions,
  presentLoginSession,
} from "../src/features/settings/accountSessionPresentation.ts";

test("classifySessionDevice maps desktop, mobile, LightIsle client, and fallback labels to icons", () => {
  assert.deepEqual(classifySessionDevice({ deviceLabel: "Mac · Chrome", current: false }), {
    displayName: "Mac · Chrome",
    iconKind: "laptop",
  });
  assert.deepEqual(classifySessionDevice({ deviceLabel: "Windows · Chrome", current: false }), {
    displayName: "Windows · Chrome",
    iconKind: "monitor",
  });
  assert.deepEqual(classifySessionDevice({ deviceLabel: "Android · Chrome", current: false }), {
    displayName: "Android · Chrome",
    iconKind: "smartphone",
  });
  assert.deepEqual(classifySessionDevice({ deviceLabel: "iPad · Safari", current: false }), {
    displayName: "iPad · Safari",
    iconKind: "tablet",
  });
  assert.deepEqual(classifySessionDevice({ deviceLabel: "轻屿客户端", current: false }), {
    displayName: "轻屿客户端",
    iconKind: "app",
  });
  assert.deepEqual(classifySessionDevice({ deviceLabel: "", current: false }), {
    displayName: "未知终端",
    iconKind: "globe",
  });
  assert.deepEqual(classifySessionDevice({ deviceLabel: "", current: true }), {
    displayName: "当前设备",
    iconKind: "globe",
  });
});

test("formatRelativeActivity and presentLoginSession produce concise human-readable metadata and full tooltips", () => {
  const nowMs = Date.UTC(2026, 10, 26, 14, 0, 0);
  const nowSec = Math.floor(nowMs / 1000);

  assert.deepEqual(formatRelativeActivity(nowSec - 120, nowMs), {
    label: "刚刚活跃",
    isRecent: true,
  });
  assert.deepEqual(formatRelativeActivity(nowSec - 20 * 60, nowMs), {
    label: "20 分钟前活跃",
    isRecent: true,
  });
  assert.deepEqual(formatRelativeActivity(nowSec - 3 * 24 * 3600, nowMs), {
    label: "3 天前活跃",
    isRecent: false,
  });

  const remote = presentLoginSession(
    {
      id: "s-remote",
      deviceLabel: "轻屿客户端",
      clientIp: "192.168.31.40",
      createdAt: nowSec - 2 * 24 * 3600,
      lastSeenAt: nowSec - 2 * 24 * 3600,
      expiresAt: nowSec + 28 * 24 * 3600,
      current: false,
    },
    nowMs,
  );
  assert.equal(remote.iconKind, "app");
  assert.equal(remote.isRecent, false);
  assert.match(remote.metaLine, /^192\.168\.31\.40 · 2 天前活跃 · \d{2}\/\d{2} 到期$/);
  assert.match(remote.fullTooltip, /登录：/);
  assert.match(remote.fullTooltip, /最近活跃：/);
  assert.match(remote.fullTooltip, /到期：/);
  assert.match(remote.fullTooltip, /IP：192\.168\.31\.40/);

  const current = presentLoginSession(
    {
      id: "s-cur",
      deviceLabel: "当前设备",
      createdAt: nowSec - 10 * 24 * 3600,
      lastSeenAt: nowSec - 5,
      expiresAt: nowSec + 20 * 24 * 3600,
      current: true,
    },
    nowMs,
  );
  assert.equal(current.isRecent, true);
  assert.match(current.metaLine, /登录 · .*到期$/);
});

test("partitionLoginSessions isolates current session and sorts other sessions by most recently active", () => {
  const { currentSessions, otherSessions } = partitionLoginSessions([
    { id: "old", createdAt: 100, lastSeenAt: 150, expiresAt: 900, current: false },
    { id: "cur", createdAt: 50, lastSeenAt: 500, expiresAt: 900, current: true },
    { id: "newest", createdAt: 200, lastSeenAt: 400, expiresAt: 900, current: false },
    { id: "mid", createdAt: 300, expiresAt: 900, current: false },
  ]);
  assert.deepEqual(currentSessions.map((s) => s.id), ["cur"]);
  assert.deepEqual(otherSessions.map((s) => s.id), ["newest", "mid", "old"]);
});

test("IsleGroupedList flush mode does not override slotted child padding with higher specificity", () => {
  const groupedList = readFileSync(new URL("../src/components/ui/IsleGroupedList.vue", import.meta.url), "utf8");
  assert.match(groupedList, /\.isle-grouped-card:not\(\.is-flush\)\s*>\s*:slotted\(\*\)/);
  assert.doesNotMatch(groupedList, /\.isle-grouped-card\.is-flush\s*>\s*:slotted\(\*\)\s*\{[^}]*padding\s*:/);
});
