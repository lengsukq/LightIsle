import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { parse } from "@vue/compiler-sfc";
import { ref } from "vue";
import { describeUserFacingError } from "../src/api/userFacingError.ts";
import {
  buildAccessPutPayload,
  buildConfigPutPayload,
  createAppsCenterClient,
  getAppDataBackupUrl,
  normalizeLogsResponse,
} from "../src/features/apps/appsCenterApi.ts";
import { findAutoLaunchTarget } from "../src/composables/useAppsCenterController.ts";
import { filterHomeLaunchableApps } from "../src/features/overview/overviewPageModels.ts";
import { useOverviewAndDisclosures } from "../src/features/overview/useOverviewAndDisclosures.ts";

const appsViewSource = readFileSync(new URL("../src/features/apps/AppsCenterView.vue", import.meta.url), "utf8");
const appDetailPanelSource = readFileSync(new URL("../src/features/apps/AppDetailPanel.vue", import.meta.url), "utf8");
const appWorkbenchStageSource = readFileSync(new URL("../src/features/apps/AppWorkbenchStage.vue", import.meta.url), "utf8");
const appVueSource = readFileSync(new URL("../src/App.vue", import.meta.url), "utf8");
const appShellSource = readFileSync(new URL("../src/AppShell.html", import.meta.url), "utf8");
const filesViewSource = readFileSync(new URL("../src/features/files/FilesView.vue", import.meta.url), "utf8");
const settingsViewSource = readFileSync(new URL("../src/features/settings/SettingsView.vue", import.meta.url), "utf8");
const fileSearchControlsSource = readFileSync(new URL("../src/features/files/FileSearchControls.vue", import.meta.url), "utf8");

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

  await client.refreshStore();
  assert.equal(calls.at(-1).url, "/api/v2/apps/store/refresh");
  assert.equal(calls.at(-1).options.method, "POST");

  await client.updateStoreConfig({ registryUrl: "", mirrorPrefix: "https://ghfast.top/" });
  assert.equal(calls.at(-1).url, "/api/v2/apps/store/config");
  assert.equal(calls.at(-1).options.method, "PUT");
  assert.deepEqual(JSON.parse(calls.at(-1).options.body), {
    registryUrl: "",
    mirrorPrefix: "https://ghfast.top/",
  });

  await client.installStorePlugin("family-subscriptions", "external");
  assert.equal(calls.at(-1).url, "/api/v2/apps/store/family-subscriptions/install");
  assert.deepEqual(JSON.parse(calls.at(-1).options.body), { locationId: "external" });

  await client.upgradeStorePlugin("family-subscriptions");
  assert.equal(calls.at(-1).url, "/api/v2/apps/store/family-subscriptions/upgrade");
  assert.equal(calls.at(-1).options.method, "POST");

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
    new URL("../src/features/apps/AppStorageLocationsCard.vue", import.meta.url),
    "utf8",
  );
  const parsedStorage = parse(storageCardSource, { filename: "AppStorageLocationsCard.vue" });
  assert.equal(parsedStorage.errors.length, 0);
  assert.match(storageCardSource, /应用数据存储位置/);
  assert.match(storageCardSource, /1 内置盘 \+ 1 其他盘/);
  assert.match(storageCardSource, /添加其他盘位置/);
  const storeSectionSource = readFileSync(
    new URL("../src/features/apps/AppStoreSection.vue", import.meta.url),
    "utf8",
  );
  const parsedStore = parse(storeSectionSource, { filename: "AppStoreSection.vue" });
  assert.equal(parsedStore.errors.length, 0);
  assert.match(storeSectionSource, /在线插件商店/);
  assert.match(template, /<AppStoreSection/);
  assert.match(template, /<AppStorageLocationsCard/);
  assert.match(template, /<AppDetailPanel/);
  assert.match(template, /详情与设置/);
  assert.match(template, /<AppWorkbenchStage/);
  assert.match(template, /back-label="返回应用中心"/);

  const detailParsed = parse(appDetailPanelSource, { filename: "AppDetailPanel.vue" });
  assert.equal(detailParsed.errors.length, 0);
  const detailTemplate = detailParsed.descriptor.template?.content ?? "";
  assert.match(detailTemplate, /返回应用中心/);
  assert.match(detailTemplate, /家庭成员访问权限/);
  assert.match(detailTemplate, /Web 服务与生命周期/);
  assert.match(detailTemplate, /定时任务 \(Cron\) 与告警通知/);
  assert.match(detailTemplate, /导出数据/);
  assert.match(detailTemplate, /恢复备份/);
  assert.match(detailTemplate, /删除插件/);
  assert.match(detailTemplate, /value="admin_only"/);
  assert.match(detailTemplate, /value="selected_members"/);
  assert.match(detailTemplate, /value="all_members"/);

  const stageParsed = parse(appWorkbenchStageSource, { filename: "AppWorkbenchStage.vue" });
  assert.equal(stageParsed.errors.length, 0);
  const stageTemplate = stageParsed.descriptor.template?.content ?? "";
  assert.match(
    stageTemplate,
    /sandbox="allow-scripts allow-forms allow-same-origin allow-popups allow-downloads"/
  );
  assert.match(stageTemplate, /\{\{\s*backLabel\s*\}\}/);
  assert.match(stageTemplate, /刷新画面/);
  assert.match(stageTemplate, /全屏展开/);
  assert.match(stageTemplate, /退出全屏/);
  assert.match(stageTemplate, /新标签页打开/);
  assert.match(template, /正在唤醒轻应用\.\.\./);
  assert.doesNotMatch(template, /AI Agent \(MCP\) 服务/);
  assert.doesNotMatch(template, /允许局域网 \/ Cloud MCP 访问/);
  assert.doesNotMatch(template, /<AgentConnections/);
  assert.doesNotMatch(template, /<McpClientWizardModal/);
  assert.doesNotMatch(template, /<AppsMcpDebugModal/);
  assert.match(template, /刷新应用列表/);
  assert.match(template, /运行日志/);
  assert.doesNotMatch(template, /editingAccessApp|editingConfigApp/);
});

test("App.vue and AppShell.html integrate the Apps Center tab under 生活空间 for both admins and members", () => {
  assert.match(appVueSource, /key:\s*"apps"\s*as\s*Page,\s*title:\s*"应用中心".*group:\s*"space"/);
  assert.match(appVueSource, /validPages/);
  assert.match(appShellSource, /<AppsCenterView\s+v-if="visitedPages\.apps"\s+:active="active === 'apps'"/);
  assert.match(appShellSource, /:apps="overviewApps"/);
  assert.match(appShellSource, /@open-app="openHomeApp"/);
  assert.match(appShellSource, /:launch-request="pendingAppLaunch"/);
  assert.match(appShellSource, /@launch-handled="clearPendingAppLaunch"/);
  assert.doesNotMatch(appShellSource, /<AgentConnections/);
  assert.match(filesViewSource, /<FileSearchControls/);
  assert.match(fileSearchControlsSource, /file-spotlight-pill/);
  assert.doesNotMatch(settingsViewSource, /管理员请前往「任务与通知」统一核对/);
});

test("Home tile helpers filter non-web apps, sort ready apps first, and guard auto-launch targets", () => {
  const apps = [
    { id: "z-pending", name: "待激活", pendingActivation: true, web: { enabled: true, mode: "on-demand" } },
    { id: "cron-only", name: "纯后台", web: { enabled: false, mode: "none" } },
    { id: "a-ready", name: "网络脉搏", web: { enabled: true, mode: "static" } },
    { id: "b-invalid", name: "配置异常", valid: false, web: { enabled: true, mode: "on-demand" } },
  ];
  const filtered = filterHomeLaunchableApps(apps);
  assert.deepEqual(filtered.map((a) => a.id), ["a-ready", "b-invalid", "z-pending"]);

  assert.equal(findAutoLaunchTarget(apps, { appId: "a-ready", seq: 1 })?.id, "a-ready");
  assert.equal(findAutoLaunchTarget(apps, { appId: "z-pending", seq: 2 }), null);
  assert.equal(findAutoLaunchTarget(apps, { appId: "b-invalid", seq: 3 }), null);
  assert.equal(findAutoLaunchTarget(apps, { appId: "cron-only", seq: 4 }), null);
  assert.equal(findAutoLaunchTarget(apps, { appId: "missing", seq: 5 }), null);
});

test("useOverviewAndDisclosures opens ready home apps directly inside overview and returns straight to overview", async () => {
  assert.match(appShellSource, /active === 'overview' && homeWorkbenchStageProps/);
  assert.match(appShellSource, /<AppWorkbenchStage v-bind="homeWorkbenchStageProps" v-on="homeWorkbenchStageEvents"/);

  const activePage = ref("overview");
  const launchedIds = [];
  const externalUrls = [];
  const readyApp = {
    id: "vault",
    name: "Vault",
    status: "ready",
    launchUrl: "/apps/vault/",
    runtime: { web: { enabled: true, mode: "on-demand", status: "stopped" } },
  };
  const pendingApp = {
    id: "draft",
    name: "Draft",
    status: "pendingActivation",
    pendingActivation: true,
    runtime: { web: { enabled: true, mode: "on-demand", status: "stopped" } },
  };

  const state = useOverviewAndDisclosures({
    user: ref({ username: "admin", role: "admin" }),
    activePage,
    fetchApps: async () => ({ apps: [readyApp, pendingApp] }),
    launchApp: async (appId) => {
      launchedIds.push(appId);
      return {
        app: { ...readyApp, runtime: { web: { enabled: true, mode: "on-demand", status: "running", memoryMB: 12 } } },
        launchUrl: "/apps/vault/?__li_ticket=t1",
        launchPath: "/apps/vault/",
      };
    },
    openExternalUrl: (url) => externalUrls.push(url),
    fileSearch: ref(""),
    searchViaSpotlight: ref(false),
    filesLoading: ref(false),
    searchingFiles: ref(false),
    telemetry: {
      stats: ref(null),
      error: ref(null),
      polling: ref(false),
      cpu: { value: null },
      usedMemory: { value: null },
      usedDisk: { value: null },
      diskActivity: { value: null },
      bytes: (n) => String(n),
      percent: () => 0,
    },
    sharedRoots: ref([]),
    rootDiscoveryError: ref(""),
    rootDiscoveryState: ref("unknown"),
    selectedRoot: { value: null },
    taskLoaded: ref(true),
    taskLoading: ref(false),
    taskError: ref(""),
    tasks: ref([]),
  });

  await state.openHomeApp(readyApp);
  assert.deepEqual(launchedIds, ["vault"]);
  assert.equal(activePage.value, "overview");
  assert.equal(state.homeWorkbenchActive.value, true);
  assert.equal(state.homeWorkbenchStageProps.value?.backLabel, "返回概览");
  assert.equal(state.homeWorkbenchStageProps.value?.iframeUrl, "/apps/vault/?__li_ticket=t1");

  state.homeWorkbenchStageEvents["open-external"]();
  assert.deepEqual(externalUrls, ["/apps/vault/"]);

  state.homeWorkbenchStageEvents.close();
  assert.equal(state.homeWorkbenchActive.value, false);
  assert.equal(activePage.value, "overview");

  await state.openHomeApp(pendingApp);
  assert.equal(activePage.value, "apps");
  assert.equal(state.homeWorkbenchActive.value, false);
});
