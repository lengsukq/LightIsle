import { computed, ref } from "vue";
import { apiFetch } from "../apiClient.ts";
import { rootApiPath, rootMediaPath } from "../rootApi.ts";
import { createRootRequestTransport, rootContextKey } from "../rootRequestTransport.ts";
import {
  chooseDiscoveredRoot,
  describeRootContext,
  describeRootOperationFailure,
  readRootDiscoveryResponse,
  rootDiscoveryNetworkError,
} from "../rootDiscovery.ts";
import { routePersonalCategory } from "../personalStorageRouting.ts";
import { createRootContextLifecycle } from "../rootContextLifecycle.ts";

export interface SharedRoot {
  rootID: string;
  name: string;
  generation: number;
  online: boolean;
  isDefault?: boolean;
}

export type RootDiscoveryState = "unknown" | "multi" | "error";

export interface MyLocation {
  category: string;
  rootID: string;
  rootGeneration: number;
  relativePath: string;
}

const ROOT_SELECTION_STORAGE_KEY = "lightisle_root_choice_v2";

export interface RootContextControllerHooks {
  isAuthenticated: () => boolean;
  isAdmin: () => boolean;
  activeSection: () => string;
  isFileDirectoryLoaded: () => boolean;
  isUploadBusy: () => boolean;
  hasActiveUpload: () => boolean;
  cancelAndWaitForUpload: () => Promise<void>;
  resetRootScopedFeatures: () => void;
  loadFiles: (path?: string) => Promise<unknown> | void;
  refreshTaskCenter: () => Promise<unknown> | void;
  loadMyShares: () => Promise<unknown> | void;
  clearClientSessionState: (expiredMessage?: string) => void;
  isAbortError: (error: unknown) => boolean;
}

/**
 * Manages multi-root discovery, selection persistence, generation epochs,
 * and personal storage auto-routing outside `App.vue`.
 */
export function useRootContextController(hooks: RootContextControllerHooks) {
  const rootDiscoveryState = ref<RootDiscoveryState>("unknown");
  const myStoragePolicy = ref<{ locations: MyLocation[] } | null>(null);
  const personalRouteError = ref("");
  const manualRootSection = ref("");
  const sharedRoots = ref<SharedRoot[]>([]);
  const selectedRootID = ref("");
  const selectedRootSnapshot = ref<SharedRoot | null>(null);
  const rootDiscoveryError = ref("");
  const rootDiscoveryLoading = ref(false);
  const rootSwitching = ref(false);
  const rootLifecycle = createRootContextLifecycle();
  const rootContextEpoch = ref(rootLifecycle.epoch);
  let lastRootDiscoveryAt = 0;

  const selectedRoot = computed(() => selectedRootSnapshot.value);
  const multiRootMode = computed(() => rootDiscoveryState.value === "multi");
  const selectedRootGeneration = computed(() => selectedRoot.value?.generation ?? 0);
  const rootSelectionValue = computed(() => selectedRootID.value);
  const rootSelectionOptions = computed(() =>
    sharedRoots.value.map((root) => ({
      value: root.rootID,
      label: root.name + (root.isDefault ? " · 默认" : ""),
      hint: root.online ? undefined : "离线",
    })),
  );
  const rootViewKey = computed(
    () => `${selectedRootID.value}:${selectedRootGeneration.value}`,
  );
  const rootFeatureContextReady = computed(
    () => multiRootMode.value && !!selectedRoot.value,
  );
  const rootContextPresentation = computed(() =>
    describeRootContext({
      state: rootDiscoveryState.value,
      error: rootDiscoveryError.value,
      hasContext: rootFeatureContextReady.value,
      rootCount: sharedRoots.value.length,
      selectedRoot: selectedRoot.value,
    }),
  );

  function scopedApiPath(path: string): string {
    if (rootDiscoveryState.value !== "multi" || !selectedRootID.value) return "";
    return rootApiPath(selectedRootID.value, path);
  }

  function scopedMediaPath(path: string): string {
    if (rootDiscoveryState.value !== "multi" || !selectedRootID.value) return "";
    return rootMediaPath(selectedRootID.value, selectedRootGeneration.value, path);
  }

  function rootRequestContext() {
    return {
      rootID: selectedRootID.value,
      generation: selectedRootGeneration.value,
      epoch: rootContextEpoch.value,
      multiRoot: multiRootMode.value,
      legacySelected: false,
      discoveryState: rootDiscoveryState.value,
      switching: rootSwitching.value,
      signal: rootLifecycle.signal,
    };
  }

  const rootTransport = createRootRequestTransport({
    getContext: rootRequestContext,
    onGenerationChanged: () => {
      void refreshRootDiscovery();
    },
    fetcher: (endpoint, init) => apiFetch(endpoint, init),
  });

  function currentRootContextKey(): string {
    return rootContextKey(rootRequestContext());
  }

  function getLastRootDiscoveryAt(): number {
    return lastRootDiscoveryAt;
  }

  function resetAllRootControllerState() {
    myStoragePolicy.value = null;
    personalRouteError.value = "";
    manualRootSection.value = "";
    rootLifecycle.invalidateDiscovery();
    rootSwitching.value = false;
    rootDiscoveryState.value = "unknown";
    sharedRoots.value = [];
    selectedRootID.value = "";
    selectedRootSnapshot.value = null;
    rootDiscoveryError.value = "";
    lastRootDiscoveryAt = 0;
    rootContextEpoch.value = rootLifecycle.invalidate();
  }

  async function switchRoot(
    rootID: string,
    force = false,
    skipInitialFilesLoad = false,
  ): Promise<void> {
    if (!multiRootMode.value || rootSwitching.value) return;
    const target = sharedRoots.value.find((root) => root.rootID === rootID) ?? null;
    if (!target) return;
    rootDiscoveryError.value = "";
    if (
      !force &&
      target.rootID === selectedRootID.value &&
      target.generation === selectedRoot.value?.generation
    ) {
      selectedRootSnapshot.value = target;
      return;
    }
    rootLifecycle.invalidateDiscovery();
    rootDiscoveryLoading.value = false;
    rootSwitching.value = true;
    rootContextEpoch.value = rootLifecycle.invalidate();
    hooks.resetRootScopedFeatures();
    const switchEpoch = rootContextEpoch.value;
    await hooks.cancelAndWaitForUpload();
    if (switchEpoch !== rootContextEpoch.value || !hooks.isAuthenticated()) {
      rootSwitching.value = false;
      return;
    }
    selectedRootID.value = target?.rootID ?? "";
    selectedRootSnapshot.value = target;
    try {
      sessionStorage.setItem(ROOT_SELECTION_STORAGE_KEY, target.rootID);
    } catch {
      // sessionStorage may be blocked in restricted browser modes.
    }
    rootSwitching.value = false;
    const active = hooks.activeSection();
    if (active === "files" && !skipInitialFilesLoad) void hooks.loadFiles(".");
    if (active === "settings" && hooks.isAdmin()) void hooks.refreshTaskCenter();
    if (active === "settings") void hooks.loadMyShares();
  }

  async function loadPersonalStoragePolicy(
    readJson: <T>(endpoint: string) => Promise<T>,
  ): Promise<void> {
    if (!hooks.isAuthenticated()) return;
    try {
      const data = await readJson<{ locations: MyLocation[] }>("/api/v2/me/storage");
      myStoragePolicy.value = {
        locations: Array.isArray(data.locations) ? data.locations : [],
      };
      personalRouteError.value = "";
    } catch (error) {
      myStoragePolicy.value = null;
      personalRouteError.value =
        "无法确认个人硬盘配置：" +
        describeRootOperationFailure(error) +
        "。请重试，不会自动使用其他硬盘。";
    }
  }

  async function autoRouteSection(section = hooks.activeSection()): Promise<void> {
    if (
      !hooks.isAuthenticated() ||
      !multiRootMode.value ||
      !["files", "photos", "cinema"].includes(section) ||
      manualRootSection.value === section
    ) {
      return;
    }
    if (!myStoragePolicy.value) {
      if (!personalRouteError.value) {
        personalRouteError.value = "个人存储配置尚未读取，无法自动选择硬盘。";
      }
      return;
    }
    const match = routePersonalCategory(myStoragePolicy.value, sharedRoots.value, section);
    if (match.kind === "offline") {
      personalRouteError.value =
        "该分类绑定的硬盘已离线或发生更换。请重新连接原硬盘，或在 Mac 管理端移除登记后手动重建。不会自动改写到其他盘。";
      return;
    }
    personalRouteError.value = "";
    if (match.kind === "shared") {
      const defaultRoot = sharedRoots.value.find((root) => root.isDefault && root.online);
      if (!defaultRoot) {
        personalRouteError.value = "尚未配置在线的默认 NAS 存储。请先在 Mac 上设定默认根。";
        return;
      }
      if (selectedRootID.value !== defaultRoot.rootID) {
        await switchRoot(defaultRoot.rootID);
      }
      if (
        section === "files" &&
        hooks.activeSection() === "files" &&
        !hooks.isFileDirectoryLoaded()
      ) {
        await hooks.loadFiles(".");
      }
      return;
    }
    if (hooks.isUploadBusy() || hooks.hasActiveUpload()) {
      personalRouteError.value =
        "当前上传尚未完成。请先完成或取消上传，再切换到这个个人目录。";
      return;
    }
    if (selectedRootID.value !== match.rootID) {
      await switchRoot(match.rootID, false, section === "files");
    }
    if (
      section === "files" &&
      hooks.activeSection() === "files" &&
      !rootSwitching.value &&
      selectedRootID.value === match.rootID &&
      !hooks.isFileDirectoryLoaded()
    ) {
      await hooks.loadFiles(match.path);
    }
  }

  let policyReader: (<T>(endpoint: string) => Promise<T>) | null = null;
  function bindPolicyReader(reader: <T>(endpoint: string) => Promise<T>) {
    policyReader = reader;
  }

  async function refreshRootDiscovery(skipPolicyRefresh = false): Promise<void> {
    if (rootSwitching.value) return;
    const request = rootLifecycle.beginDiscovery();
    lastRootDiscoveryAt = Date.now();
    rootDiscoveryLoading.value = true;
    try {
      const response = await apiFetch("/api/v2/roots");
      if (response.status === 401 && hooks.isAuthenticated()) {
        hooks.clearClientSessionState("登录状态已失效，请重新登录。");
        return;
      }
      if (!rootLifecycle.isCurrentDiscovery(request) || rootSwitching.value) return;
      const discovery = await readRootDiscoveryResponse(response);
      if (!rootLifecycle.isCurrentDiscovery(request) || rootSwitching.value) return;
      if (discovery.kind === "error") {
        rootDiscoveryError.value = discovery.message;
        if (rootDiscoveryState.value !== "multi") rootDiscoveryState.value = "error";
        console.warn("root discovery failed", discovery.message);
        return;
      }
      const wasMulti = multiRootMode.value;
      const previous = selectedRoot.value;
      sharedRoots.value = Array.isArray(discovery.roots)
        ? discovery.roots.filter(
            (root) =>
              typeof root.rootID === "string" &&
              Number.isSafeInteger(root.generation) &&
              root.generation > 0,
          )
        : [];
      rootDiscoveryState.value = "multi";
      rootDiscoveryError.value = "";
      let preferred = "";
      try {
        preferred = sessionStorage.getItem(ROOT_SELECTION_STORAGE_KEY) ?? "";
      } catch {
        // sessionStorage unavailable.
      }
      const choice = chooseDiscoveredRoot({
        roots: sharedRoots.value,
        selectedRootID: selectedRootID.value,
        legacySelected: false,
        preferredRootID: preferred,
        previousRoot: previous,
        wasMulti,
      });
      if (choice.kind === "root") {
        await switchRoot(choice.rootID, choice.force);
        if (!skipPolicyRefresh && hooks.isAuthenticated() && policyReader) {
          await loadPersonalStoragePolicy(policyReader);
          const active = hooks.activeSection();
          if (["files", "photos", "cinema"].includes(active)) {
            await autoRouteSection(active);
          }
        }
        return;
      }
      if (choice.kind === "missing") {
        rootDiscoveryError.value =
          "之前选择的硬盘已移除或不可见。请重新连接原硬盘，或者明确选择其他共享目录。";
        if (previous?.online !== false) {
          rootContextEpoch.value = rootLifecycle.invalidate();
          hooks.resetRootScopedFeatures();
          await hooks.cancelAndWaitForUpload();
        }
        if (!rootLifecycle.isCurrentDiscovery(request)) return;
        selectedRootSnapshot.value = previous ? { ...previous, online: false } : null;
        return;
      }
      if (choice.kind === "reset") {
        rootContextEpoch.value = rootLifecycle.invalidate();
        hooks.resetRootScopedFeatures();
      }
    } catch (error) {
      if (!rootLifecycle.isCurrentDiscovery(request)) return;
      rootDiscoveryError.value = rootDiscoveryNetworkError(error);
      if (rootDiscoveryState.value !== "multi") rootDiscoveryState.value = "error";
      if (!hooks.isAbortError(error)) console.warn("root discovery failed", error);
    } finally {
      if (rootLifecycle.isCurrentDiscovery(request)) rootDiscoveryLoading.value = false;
    }
  }

  function handleRootChange(event: Event | string) {
    manualRootSection.value = hooks.activeSection();
    personalRouteError.value = "";
    const val =
      typeof event === "string"
        ? event
        : (event?.target as HTMLSelectElement | null)?.value ?? "";
    void switchRoot(val);
  }

  return {
    rootDiscoveryState,
    myStoragePolicy,
    personalRouteError,
    manualRootSection,
    sharedRoots,
    selectedRootID,
    selectedRootSnapshot,
    rootDiscoveryError,
    rootDiscoveryLoading,
    rootSwitching,
    rootContextEpoch,
    selectedRoot,
    multiRootMode,
    selectedRootGeneration,
    rootSelectionValue,
    rootSelectionOptions,
    rootViewKey,
    rootFeatureContextReady,
    rootContextPresentation,
    scopedApiPath,
    scopedMediaPath,
    rootTransport,
    currentRootContextKey,
    getLastRootDiscoveryAt,
    resetAllRootControllerState,
    bindPolicyReader,
    switchRoot,
    loadPersonalStoragePolicy,
    autoRouteSection,
    refreshRootDiscovery,
    handleRootChange,
  };
}
