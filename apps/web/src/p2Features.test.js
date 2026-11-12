import assert from "node:assert/strict";
import test from "node:test";
import { usePhotoMemories } from "./usePhotoMemories.ts";
import { createAppsCenterClient } from "./appsCenterApi.ts";
import { useAccountSessions } from "./useAccountSessions.ts";

test("usePhotoMemories loads and resets smart memory cards per root epoch", async () => {
  let epoch = 1;
  let disposed = false;
  const calls = [];
  const memoriesCtl = usePhotoMemories({
    api: async (url) => {
      calls.push(url);
      return {
        memories: [
          {
            id: "live-moments",
            kind: "live",
            title: "实况鲜活瞬间",
            subtitle: "12 张实况照片",
            count: 12,
            coverAssetId: 101,
          },
          {
            id: "trip-1710000000",
            kind: "trip",
            title: "2026年03月 · 足迹漫游",
            subtitle: "28 张定位影像",
            count: 28,
            coverAssetId: 205,
            takenFrom: 1710000000,
          },
        ],
      };
    },
    apiPath: (p) => `/roots/abc/1${p}`,
    getRootEpoch: () => epoch,
    isDisposed: () => disposed,
  });

  await memoriesCtl.refreshSmartMemories();
  assert.equal(calls.length, 1);
  assert.equal(calls[0], "/roots/abc/1/api/v2/photos/memories");
  assert.equal(memoriesCtl.smartMemories.value.length, 2);
  assert.equal(memoriesCtl.smartMemories.value[0]?.kind, "live");

  memoriesCtl.resetSmartMemories();
  assert.equal(memoriesCtl.smartMemories.value.length, 0);

  disposed = true;
  await memoriesCtl.refreshSmartMemories();
  assert.equal(memoriesCtl.smartMemories.value.length, 0);
});

test("createAppsCenterClient installs official builtin templates via POST", async () => {
  const seen = [];
  const client = createAppsCenterClient(async (url, init) => {
    seen.push({ url, method: init?.method, headers: init?.headers });
    return {
      ok: true,
      async json() {
        return {
          ok: true,
          app: { id: "family-subscriptions", name: "家庭订阅管家", mode: "static" },
          templates: [{ id: "family-subscriptions", installed: true }],
        };
      },
    };
  });

  const res = await client.installTemplate("family-subscriptions");
  assert.equal(seen.length, 1);
  assert.equal(seen[0]?.url, "/api/v2/apps/templates/family-subscriptions/install");
  assert.equal(seen[0]?.method, "POST");
  assert.equal(res.app?.id, "family-subscriptions");
});

test("useAccountSessions preserves deviceLabel, clientIp, and lastSeenAt metadata", async () => {
  const ctl = useAccountSessions({
    authenticated: () => true,
    read: async () => ({
      sessions: [
        {
          id: 9,
          createdAt: 1710000000,
          lastSeenAt: 1710003600,
          expiresAt: 1712592000,
          clientIp: "100.88.12.34",
          deviceLabel: "iPhone · Safari",
          current: false,
        },
      ],
      truncated: false,
    }),
    logoutCurrent: async () => {},
    onCurrentLogout: () => {},
    confirm: async () => true,
    revoke: async () => {},
  });

  await ctl.loadLoginSessions();
  assert.equal(ctl.loginSessions.value.length, 1);
  assert.equal(ctl.loginSessions.value[0]?.deviceLabel, "iPhone · Safari");
  assert.equal(ctl.loginSessions.value[0]?.clientIp, "100.88.12.34");
  assert.equal(ctl.loginSessions.value[0]?.lastSeenAt, 1710003600);
});
