import { computed, ref, watch, type ComputedRef, type Ref } from "vue";
import { readApiFailure } from "./apiFailure.ts";
import { createAppsCenterClient } from "./appsCenterApi.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { isHomeAppReady, type PersonalSpaceSummary } from "./overviewPageModels.ts";
import { stripLaunchTicket, workbenchBadge, type AppLaunchRequest } from "./composables/useAppsCenterController.ts";
import type { PublicAppItem } from "./types/appsCenter.ts";
import type { ServerStats } from "./useHostTelemetry.ts";
import type { BackendTask } from "./useTaskCenter.ts";

export function useOverviewAndDisclosures(options: {
  user: Ref<{ username: string; role: "admin" | "member" } | null>;
  activePage?: Ref<string>;
  fetchApps?: () => Promise<{ apps?: PublicAppItem[] }>;
  launchApp?: (appId: string) => Promise<{ app?: PublicAppItem; status?: string; launchUrl?: string; launchPath?: string }>;
  openExternalUrl?: (url: string) => void;
  fileSearch: Ref<string>;
  searchViaSpotlight: Ref<boolean>;
  filesLoading: Ref<boolean>;
  searchingFiles: Ref<boolean>;
  recentSearches?: Ref<string[]>;
  telemetry: {
    stats: Ref<ServerStats | null>;
    error: Ref<string | null>;
    polling: Ref<boolean>;
    cpu: ComputedRef<number | null>;
    usedMemory: ComputedRef<number | null>;
    usedDisk: ComputedRef<number | null>;
    diskActivity: ComputedRef<string | null>;
    bytes: (n: number) => string;
    percent: (used: number, total: number) => number;
  };
  sharedRoots: Ref<Array<{ rootID: string; name: string; generation: number; online: boolean; isDefault?: boolean }>>;
  rootDiscoveryError: Ref<string>;
  rootDiscoveryState: Ref<"unknown" | "multi" | "error">;
  selectedRoot: ComputedRef<{ rootID: string; name: string; generation: number; online: boolean; isDefault?: boolean } | null>;
  taskLoaded: Ref<boolean>;
  taskLoading: Ref<boolean>;
  taskError: Ref<string>;
  tasks: Ref<BackendTask[]>;
}) {
  const showHardwareSpecs = ref(false);
  const isAdminDashboard = computed(() => options.user.value?.role === "admin");
  const personalSpace = ref<PersonalSpaceSummary | null>(null);
  const personalSpaceError = ref("");
  let personalSpaceRequest = 0;

  const overviewAppItems = ref<PublicAppItem[]>([]);
  const overviewAppsLoading = ref(false);
  const overviewAppsError = ref("");
  let overviewAppsRequest = 0;
  const pendingAppLaunch = ref<AppLaunchRequest | null>(null);
  const homeWorkbenchApp = ref<PublicAppItem | null>(null);
  const homeWorkbenchIframeUrl = ref("");
  const homeWorkbenchLaunchPath = ref("");
  const homeWorkbenchIframeKey = ref(0);
  const homeWorkbenchFullscreen = ref(false);
  let homeWorkbenchRequest = 0;

  const homeWorkbenchActive = computed(() => homeWorkbenchApp.value !== null);

  function closeHomeWorkbench(opts: { refresh?: boolean } = {}) {
    homeWorkbenchRequest += 1;
    homeWorkbenchApp.value = null;
    homeWorkbenchIframeUrl.value = "";
    homeWorkbenchLaunchPath.value = "";
    homeWorkbenchFullscreen.value = false;
    if (opts.refresh !== false) void refreshOverviewApps();
  }

  function refreshHomeWorkbench() {
    homeWorkbenchIframeKey.value += 1;
  }

  function toggleHomeWorkbenchFullscreen() {
    homeWorkbenchFullscreen.value = !homeWorkbenchFullscreen.value;
  }

  function openHomeWorkbenchExternal() {
    const app = homeWorkbenchApp.value;
    if (!app) return;
    const target =
      homeWorkbenchLaunchPath.value ||
      stripLaunchTicket(homeWorkbenchIframeUrl.value) ||
      `/apps/${encodeURIComponent(app.id)}/`;
    if (!target) return;
    if (options.openExternalUrl) options.openExternalUrl(target);
    else if (typeof window !== "undefined") window.open(target, "_blank", "noopener");
  }

  async function openHomeApp(app: PublicAppItem) {
    if (!isHomeAppReady(app)) {
      pendingAppLaunch.value = null;
      closeHomeWorkbench({ refresh: false });
      if (options.activePage) {
        options.activePage.value = "apps";
      }
      return;
    }
    const reqId = ++homeWorkbenchRequest;
    const usernameSnapshot = options.user.value?.username ?? "";
    overviewAppsError.value = "";
    const launcher = options.launchApp ?? ((appId: string) => createAppsCenterClient().launchApp(appId));
    try {
      const res = await launcher(app.id);
      if (reqId !== homeWorkbenchRequest || (options.user.value?.username ?? "") !== usernameSnapshot) return;
      if (options.activePage && options.activePage.value !== "overview") return;
      const latestApp = res.app || app;
      const fallbackPath = `/apps/${encodeURIComponent(latestApp.id)}/`;
      const launchUrl = res.launchUrl || latestApp.launchUrl || fallbackPath;
      const cleanPath = res.launchPath || stripLaunchTicket(launchUrl) || fallbackPath;
      homeWorkbenchApp.value = latestApp;
      homeWorkbenchLaunchPath.value = cleanPath;
      homeWorkbenchIframeUrl.value = launchUrl;
      homeWorkbenchIframeKey.value += 1;
      homeWorkbenchFullscreen.value = false;
      pendingAppLaunch.value = null;
    } catch (e) {
      if (reqId !== homeWorkbenchRequest || (options.user.value?.username ?? "") !== usernameSnapshot) return;
      overviewAppsError.value = "打开「" + app.name + "」失败：" + describeUserFacingError(e);
    }
  }

  function clearPendingAppLaunch(seq: number) {
    if (pendingAppLaunch.value?.seq === seq) pendingAppLaunch.value = null;
  }

  if (options.activePage) {
    watch(
      () => options.activePage?.value,
      (page) => {
        if (page && page !== "overview" && homeWorkbenchApp.value) {
          closeHomeWorkbench({ refresh: false });
        }
      },
    );
  }

  async function refreshOverviewApps() {
    if (!options.user.value?.username) {
      overviewAppItems.value = [];
      overviewAppsError.value = "";
      overviewAppsLoading.value = false;
      return;
    }
    const generation = ++overviewAppsRequest;
    overviewAppsLoading.value = true;
    overviewAppsError.value = "";
    try {
      const readApps = options.fetchApps ?? (() => createAppsCenterClient().fetchApps(false));
      const payload = await readApps();
      if (generation === overviewAppsRequest) {
        overviewAppItems.value = Array.isArray(payload?.apps) ? payload.apps : [];
      }
    } catch (e) {
      if (generation === overviewAppsRequest) {
        overviewAppsError.value = "轻应用列表读取失败：" + describeUserFacingError(e);
      }
    } finally {
      if (generation === overviewAppsRequest) {
        overviewAppsLoading.value = false;
      }
    }
  }

  watch(
    [() => options.user.value?.username, () => options.user.value?.role],
    ([username]) => {
      if (!username) {
        overviewAppsRequest += 1;
        overviewAppItems.value = [];
        overviewAppsError.value = "";
        overviewAppsLoading.value = false;
        return;
      }
      void refreshOverviewApps();
    },
    { immediate: true },
  );

  if (options.activePage) {
    watch(
      () => options.activePage?.value,
      (nextPage, prevPage) => {
        if (nextPage === "overview" && prevPage && prevPage !== "overview" && options.user.value?.username) {
          void refreshOverviewApps();
        }
      },
    );
  }

  watch(
    [() => options.user.value?.username, () => options.user.value?.role],
    async ([username, role]) => {
      const generation = ++personalSpaceRequest;
      personalSpace.value = null;
      personalSpaceError.value = "";
      if (!username || role !== "member") return;
      try {
        const response = await fetch("/api/v2/me/storage", { credentials: "same-origin", cache: "no-store" });
        if (!response.ok) throw await readApiFailure(response);
        const data = (await response.json()) as PersonalSpaceSummary;
        if (generation === personalSpaceRequest) personalSpace.value = data;
      } catch (e) {
        if (generation === personalSpaceRequest) {
          personalSpaceError.value = "个人空间信息读取失败：" + describeUserFacingError(e);
        }
      }
    },
    { immediate: true },
  );

  const advancedUploadsOpen = ref(false);
  const advancedDiagnosticsOpen = ref(false);
  const pendingUploadsOpen = ref(false);
  const pendingMediaOpen = ref(false);
  const adminPendingMediaOpen = ref(false);

  function togglePendingMedia(admin: boolean, event: Event) {
    const open = (event.target as HTMLDetailsElement)?.open === true;
    if (admin) adminPendingMediaOpen.value = open;
    else pendingMediaOpen.value = open;
  }

  function togglePendingUploads(event: Event) {
    pendingUploadsOpen.value = (event.target as HTMLDetailsElement)?.open === true;
  }

  function toggleAdvanced(kind: "uploads" | "diagnostics", event: Event) {
    const open = (event.target as HTMLDetailsElement)?.open === true;
    if (kind === "uploads") advancedUploadsOpen.value = open;
    else advancedDiagnosticsOpen.value = open;
  }

  const overviewIdentity = computed(() => ({
    username: options.user.value?.username ?? "",
    isAdmin: isAdminDashboard.value,
  }));

  const overviewSearch = computed(() => ({
    query: options.fileSearch.value,
    spotlight: options.searchViaSpotlight.value,
    filesLoading: options.filesLoading.value,
    searchingFiles: options.searchingFiles.value,
    recentQueries: options.recentSearches?.value ?? [],
  }));

  const cpuHistory = ref<number[]>([]);
  const memoryHistory = ref<number[]>([]);
  watch(
    [() => options.user.value?.role, () => options.telemetry.stats.value],
    ([role, stats]) => {
      if (role !== "admin" || !stats) {
        cpuHistory.value = [];
        memoryHistory.value = [];
        return;
      }
      if (typeof stats.cpuPercent === "number" && Number.isFinite(stats.cpuPercent)) {
        cpuHistory.value = [...cpuHistory.value.slice(-17), Math.min(100, Math.max(0, stats.cpuPercent))];
      }
      if (stats.memoryTotal > 0 && Number.isFinite(stats.memoryUsed)) {
        const memPct = Math.min(100, Math.max(0, (stats.memoryUsed / stats.memoryTotal) * 100));
        memoryHistory.value = [...memoryHistory.value.slice(-17), memPct];
      }
    },
    { immediate: true },
  );

  const overviewTelemetry = computed(() => ({
    error: options.telemetry.error.value,
    stats: options.telemetry.stats.value,
    polling: options.telemetry.polling.value,
    cpu: options.telemetry.cpu.value,
    usedMemory: options.telemetry.usedMemory.value,
    usedDisk: options.telemetry.usedDisk.value,
    diskActivity: options.telemetry.diskActivity.value,
    cpuHistory: cpuHistory.value,
    memoryHistory: memoryHistory.value,
    expanded: showHardwareSpecs.value,
    bytes: options.telemetry.bytes,
    percent: options.telemetry.percent,
  }));

  const overviewPersonalSpace = computed(() => ({
    summary: personalSpace.value,
    error: personalSpaceError.value,
    bytes: options.telemetry.bytes,
    rootNames: Object.fromEntries(options.sharedRoots.value.map((root) => [root.rootID, root.name])),
  }));

  const overviewApps = computed(() => ({
    items: overviewAppItems.value,
    loading: overviewAppsLoading.value,
    error: overviewAppsError.value,
  }));

  const overviewPending = computed(() => ({
    offlineCount: isAdminDashboard.value ? options.sharedRoots.value.filter((root) => !root.online).length : 0,
    rootsError: isAdminDashboard.value ? options.rootDiscoveryError.value : "",
    rootsKnown: isAdminDashboard.value && options.rootDiscoveryState.value === "multi",
    rootName: isAdminDashboard.value ? options.selectedRoot.value?.name ?? "" : "",
    tasksLoaded: isAdminDashboard.value && options.taskLoaded.value,
    tasksLoading: isAdminDashboard.value && options.taskLoading.value,
    tasksError: isAdminDashboard.value ? options.taskError.value : "",
    failedTasks: isAdminDashboard.value ? options.tasks.value.filter((task) => !task.running && !!task.lastError).length : 0,
  }));

  const homeWorkbenchStageProps = computed(() =>
    homeWorkbenchApp.value
      ? {
          app: homeWorkbenchApp.value,
          iframeUrl: homeWorkbenchIframeUrl.value,
          iframeKey: homeWorkbenchIframeKey.value,
          fullscreen: homeWorkbenchFullscreen.value,
          badgeText: workbenchBadge(homeWorkbenchApp.value),
          backLabel: "返回概览",
        }
      : null,
  );

  const homeWorkbenchStageEvents = {
    close: () => closeHomeWorkbench(),
    refresh: refreshHomeWorkbench,
    "toggle-fullscreen": toggleHomeWorkbenchFullscreen,
    "open-external": openHomeWorkbenchExternal,
  };

  function resetOverviewAndDisclosures() {
    personalSpaceRequest += 1;
    personalSpace.value = null;
    personalSpaceError.value = "";
    overviewAppsRequest += 1;
    overviewAppItems.value = [];
    overviewAppsLoading.value = false;
    overviewAppsError.value = "";
    pendingAppLaunch.value = null;
    closeHomeWorkbench({ refresh: false });
    cpuHistory.value = [];
    memoryHistory.value = [];
    showHardwareSpecs.value = false;
    advancedUploadsOpen.value = false;
    advancedDiagnosticsOpen.value = false;
    pendingUploadsOpen.value = false;
    pendingMediaOpen.value = false;
    adminPendingMediaOpen.value = false;
  }

  return {
    showHardwareSpecs,
    isAdminDashboard,
    personalSpace,
    personalSpaceError,
    advancedUploadsOpen,
    advancedDiagnosticsOpen,
    pendingUploadsOpen,
    pendingMediaOpen,
    adminPendingMediaOpen,
    togglePendingMedia,
    togglePendingUploads,
    toggleAdvanced,
    resetOverviewAndDisclosures,
    refreshOverviewApps,
    pendingAppLaunch,
    openHomeApp,
    clearPendingAppLaunch,
    homeWorkbenchActive,
    homeWorkbenchStageProps,
    homeWorkbenchStageEvents,
    closeHomeWorkbench,
    overviewIdentity,
    overviewSearch,
    overviewTelemetry,
    overviewPersonalSpace,
    overviewApps,
    overviewPending,
  };
}
