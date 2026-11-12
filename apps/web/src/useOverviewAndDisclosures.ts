import { computed, ref, watch, type ComputedRef, type Ref } from "vue";
import { readApiFailure } from "./apiFailure.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import type { ServerStats } from "./useHostTelemetry.ts";
import type { PersonalSpaceSummary } from "./overviewPageModels.ts";
import type { BackendTask } from "./useTaskCenter.ts";

export function useOverviewAndDisclosures(options: {
  user: Ref<{ username: string; role: "admin" | "member" } | null>;
  fileSearch: Ref<string>;
  searchViaSpotlight: Ref<boolean>;
  filesLoading: Ref<boolean>;
  searchingFiles: Ref<boolean>;
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
  const pendingReservationsOpen = ref(false);
  const cleanupRulesOpen = ref(false);
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

  function togglePendingReservations(event: Event) {
    pendingReservationsOpen.value = (event.target as HTMLDetailsElement)?.open === true;
  }

  function toggleCleanupRules(event: Event) {
    cleanupRulesOpen.value = (event.target as HTMLDetailsElement)?.open === true;
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
  }));

  const overviewTelemetry = computed(() => ({
    error: options.telemetry.error.value,
    stats: options.telemetry.stats.value,
    polling: options.telemetry.polling.value,
    cpu: options.telemetry.cpu.value,
    usedMemory: options.telemetry.usedMemory.value,
    usedDisk: options.telemetry.usedDisk.value,
    diskActivity: options.telemetry.diskActivity.value,
    expanded: showHardwareSpecs.value,
    bytes: options.telemetry.bytes,
    percent: options.telemetry.percent,
  }));

  const overviewPersonalSpace = computed(() => ({
    summary: personalSpace.value,
    error: personalSpaceError.value,
    bytes: options.telemetry.bytes,
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

  return {
    showHardwareSpecs,
    isAdminDashboard,
    personalSpace,
    personalSpaceError,
    advancedUploadsOpen,
    advancedDiagnosticsOpen,
    pendingUploadsOpen,
    pendingReservationsOpen,
    cleanupRulesOpen,
    pendingMediaOpen,
    adminPendingMediaOpen,
    togglePendingMedia,
    togglePendingUploads,
    togglePendingReservations,
    toggleCleanupRules,
    toggleAdvanced,
    overviewIdentity,
    overviewSearch,
    overviewTelemetry,
    overviewPersonalSpace,
    overviewPending,
  };
}
