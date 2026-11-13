import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { parse } from "@vue/compiler-sfc";
import { describeUserFacingError } from "../src/userFacingError.ts";
import {
  buildAccessPutPayload,
  buildConfigPutPayload,
  createAppsCenterClient,
  getAppDataBackupUrl,
  normalizeLogsResponse,
} from "../src/appsCenterApi.ts";

const appsViewSource = readFileSync(new URL("../src/AppsCenterView.vue", import.meta.url), "utf8");
const appVueSource = readFileSync(new URL("../src/App.vue", import.meta.url), "utf8");
const appShellSource = readFileSync(new URL("../src/AppShell.html", import.meta.url), "utf8");
const fileSearchControlsSource = readFileSync(new URL("../src/FileSearchControls.vue", import.meta.url), "utf8");

test("userFacingError translates App Center error codes into actionable Chinese", () => {
  assert.match(describeUserFacingError(new Error("app_origin_isolated")), /轻应用.*核心管理接口/);
  assert.match(describeUserFacingError(new Error("app_invalid")), /轻应用配置无效/);
  assert.match(describeUserFacingError(new Error("app_not_found")), /轻应用不存在|刷新应用中心/);
  assert.match(describeUserFacingError(new Error("app_forbidden")), /没有访问该轻应用的权限/);
});

test("normalizeLogsResponse accepts both webOutput/cronRuns and logs/runs (P1-2)", () => {
  const fromLegacy = normalizeLogsResponse({
    logs: "Listening on 127.0.0.1:49100",
    runs: [{ state: "success", exitCode: 0 }],
  });
  assert.equal(fromLegacy.webOutput, "Listening on 127.0.0.1:49100");
  assert.equal(fromLegacy.cronRuns.length, 1);

  const fromPrimary = normalizeLogsResponse({
    webOutput: "Ready",
    cronRuns: [{ state: "failure", exitCode: 1 }],
  });
  assert.equal(fromPrimary.webOutput, "Ready");
  assert.equal(fromPrimary.cronRuns[0].state, "failure");
});

test("createAppsCenterClient enforces exact Go Core HTTP routes, headers, and selective payloads", async () => {
  const calls = [];
  const client = createAppsCenterClient(async (url, options = {}) => {
    calls.push({ url, options });
    return {
      ok: true,
      status: 200,
      async json() {
        if (String(url).endsWith("/logs")) {
          return { logs: "server-ready", runs: [{ state: "success", exitCode: 0 }] };
        }
        return {
          apps: [{ id: "network-pulse", name: "轻屿网络脉搏" }],
          isAdmin: true,
          members: [{ id: 2, username: "alice", role: "member" }],
          configuredChannels: ["bark", "email"],
        };
      },
    };
  });

  // 1. GET /api/v2/apps and POST /api/v2/apps/refresh
  const listRes = await client.fetchApps(false);
  assert.equal(calls.at(-1).url, "/api/v2/apps");
  assert.equal(calls.at(-1).options.headers["X-LightIsle-Request"], "1");
  assert.equal(listRes.members[0].username, "alice");

  await client.fetchApps(true);
  assert.equal(calls.at(-1).url, "/api/v2/apps/refresh");
  assert.equal(calls.at(-1).options.method, "POST");

  // 2. POST /api/v2/apps/{id}/launch
  await client.launchApp("cpe-monitor");
  assert.equal(calls.at(-1).url, "/api/v2/apps/cpe-monitor/launch");
  assert.equal(calls.at(-1).options.method, "POST");

  // 4. POST /api/v2/apps/{id}/action (P0-2)
  await client.runAction("cpe-monitor", "start");
  assert.equal(calls.at(-1).url, "/api/v2/apps/cpe-monitor/action");
  assert.equal(calls.at(-1).options.method, "POST");
  assert.deepEqual(JSON.parse(calls.at(-1).options.body), { action: "start" });

  // 5. PUT /api/v2/apps/{id} for access only (P0-3: static app with PublicCronView hasCron: false, enabled: false)
  const staticApp = {
    id: "network-pulse",
    revision: "rev-static",
    web: { enabled: true, mode: "static" },
    cron: { hasCron: false, enabled: false, events: [], channels: [] },
  };
  await client.saveAccess(staticApp, "selected_members", [2, 3]);
  assert.equal(calls.at(-1).url, "/api/v2/apps/network-pulse");
  assert.equal(calls.at(-1).options.method, "PUT");
  assert.deepEqual(JSON.parse(calls.at(-1).options.body), {
    revision: "rev-static",
    access: { policy: "selected_members", allowedUserIDs: [2, 3] },
  });

  // 6. PUT /api/v2/apps/{id} for config omits absent cron module on static app even when cron.enabled === false (P1-3)
  await client.saveConfig(
    staticApp,
    { enabled: true, mode: "static", idleTimeoutSeconds: 900, autoRestart: false },
    { enabled: true, cron: "*/15 * * * *", timezone: "Asia/Shanghai", events: ["failure"], channels: [] }
  );
  const savedStaticCfg = JSON.parse(calls.at(-1).options.body);
  assert.equal("cron" in savedStaticCfg, false);
  assert.equal("access" in savedStaticCfg, false);
  assert.equal(savedStaticCfg.web.mode, "static");

  // 7. GET /api/v2/apps/{id}/logs
  const logs = await client.fetchLogs("cpe-monitor");
  assert.equal(calls.at(-1).url, "/api/v2/apps/cpe-monitor/logs");
  assert.equal(logs.webOutput, "server-ready");
  assert.equal(logs.cronRuns.length, 1);

  // 8. Data backup & restore (P2-2)
  assert.equal(getAppDataBackupUrl("cpe-monitor"), "/api/v2/apps/cpe-monitor/data-backup");
  await client.restoreAppData("cpe-monitor", new Uint8Array([1, 2, 3]));
  assert.equal(calls.at(-1).url, "/api/v2/apps/cpe-monitor/data-restore");
  assert.equal(calls.at(-1).options.method, "POST");

  // 9. App data storage locations (1 internal + 1 external) & template install target
  await client.mutateAppStorage({
    action: "add",
    kind: "external",
    path: "/Volumes/MediaUSB/LightIsleApps",
  });
  assert.equal(calls.at(-1).url, "/api/v2/apps/storage");
  assert.equal(calls.at(-1).options.method, "PUT");
  assert.deepEqual(JSON.parse(calls.at(-1).options.body), {
    action: "add",
    kind: "external",
    path: "/Volumes/MediaUSB/LightIsleApps",
  });

  await client.installTemplate("family-subscriptions", "external");
  assert.equal(calls.at(-1).url, "/api/v2/apps/templates/family-subscriptions/install");
  assert.deepEqual(JSON.parse(calls.at(-1).options.body), { locationId: "external" });

  // 10. DELETE /api/v2/apps/{id}
  await client.deleteApp("cpe-monitor");
  assert.equal(calls.at(-1).url, "/api/v2/apps/cpe-monitor");
  assert.equal(calls.at(-1).options.method, "DELETE");
});

test("AppsCenterView SFC parses cleanly and includes sandboxed iframe workbench, MCP bar, and role-adaptive controls", () => {
  const parsed = parse(appsViewSource, { filename: "AppsCenterView.vue" });
  assert.equal(parsed.errors.length, 0);
  const template = parsed.descriptor.template?.content ?? "";
  const storageCardSource = readFileSync(
    new URL("../src/AppStorageLocationsCard.vue", import.meta.url),
    "utf8",
  );
  const parsedStorage = parse(storageCardSource, { filename: "AppStorageLocationsCard.vue" });
  assert.equal(parsedStorage.errors.length, 0);
  assert.match(storageCardSource, /应用数据存储位置/);
  assert.match(storageCardSource, /1 内置盘 \+ 1 其他盘/);
  assert.match(storageCardSource, /添加其他盘位置/);
  assert.match(template, /<AppStorageLocationsCard/);

  assert.match(
    template,
    /sandbox="allow-scripts allow-forms allow-same-origin allow-popups allow-downloads"/
  );
  assert.match(template, /返回应用中心/);
  assert.match(template, /刷新画面/);
  assert.match(template, /全屏展开/);
  assert.match(template, /退出全屏/);
  assert.match(template, /新标签页打开/);
  assert.match(template, /正在唤醒轻应用\.\.\./);
  assert.doesNotMatch(template, /AI Agent \(MCP\) 服务/);
  assert.doesNotMatch(template, /允许局域网 \/ Cloud MCP 访问/);
  assert.doesNotMatch(template, /<AgentConnections/);
  assert.doesNotMatch(template, /<McpClientWizardModal/);
  assert.doesNotMatch(template, /<AppsMcpDebugModal/);
  assert.match(template, /刷新应用列表/);
  assert.match(template, /成员权限/);
  assert.match(template, /生命周期与定时/);
  assert.match(template, /运行日志/);
  assert.match(template, /导出数据/);
  assert.match(template, /恢复数据/);
  assert.match(template, /value="admin_only"/);
  assert.match(template, /value="selected_members"/);
  assert.match(template, /value="all_members"/);
});

test("App.vue and AppShell.html integrate the Apps Center tab under 生活空间 for both admins and members", () => {
  assert.match(appVueSource, /key:\s*"apps"\s*as\s*Page,\s*title:\s*"应用中心".*group:\s*"space"/);
  assert.match(appVueSource, /validPages/);
  assert.match(appShellSource, /<AppsCenterView\s+:active="active === 'apps'"/);
  assert.doesNotMatch(appShellSource, /<AgentConnections/);
  assert.match(appShellSource, /<FileSearchControls/);
  assert.match(fileSearchControlsSource, /file-spotlight-pill/);
  assert.match(appShellSource, /管理员请前往「任务与通知」统一核对/);
});
