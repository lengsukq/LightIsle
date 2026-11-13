import { onMounted, onUnmounted, watch, type Ref } from "vue";
import { installImageResourceObserver } from "../useIsleCache.ts";
import { resolvePermittedPage, resolvePermittedSettingsGroup } from "../shellRouteGuard.ts";

const FAST_POLL_INTERVAL_MS = 5_000;
const SLOW_POLL_INTERVAL_MS = 30_000;
const VISIBILITY_ROOT_REFRESH_COOLDOWN_MS = 3_000;

export interface AppBrowserLifecycleOptions<TPage extends string, TGroup extends string> {
  active: Ref<TPage>;
  validPages: ReadonlySet<TPage>;
  visitedPages: Ref<Record<TPage, boolean>>;
  settingsGroup: Ref<TGroup>;
  moreMenuOpen: Ref<boolean>;
  manualRootSection: Ref<string>;
  personalRouteError: Ref<string>;
  hasMyStoragePolicy: () => boolean;
  multiRootMode: () => boolean;
  searchingFiles: () => boolean;
  fileDirectoryLoaded: () => boolean;
  isAuthenticated: () => boolean;
  isAdmin: () => boolean;
  computerFilesAllowed?: () => boolean;
  computerFilesResolved?: () => boolean;
  rootFeatureContextReady: () => boolean;
  rootDiscoveryLoading: () => boolean;
  getLastRootDiscoveryAt: () => number;
  taskLoading: () => boolean;
  hasRunningTasks: () => boolean;
  rootViewKey: () => string;
  checkAuth: () => Promise<void>;
  updateHostTelemetry: () => Promise<unknown> | void;
  reloadTasks: () => Promise<unknown> | void;
  refreshTaskCenter: () => Promise<unknown> | void;
  refreshRootDiscovery: () => Promise<void>;
  autoRouteSection: (page: TPage) => Promise<void>;
  loadFiles: () => Promise<unknown> | void;
  onShareOutcomeUncertain: () => void;
  onPhotoBatchOutcomeUncertain: () => void;
}

/**
 * Coordinates URL query/history navigation (`?page=`, `?group=`), visibility
 * wake-up checks, custom outcome-warning events, and adaptive 5s/30s polling.
 */
export function useAppBrowserLifecycle<TPage extends string, TGroup extends string>(
  opts: AppBrowserLifecycleOptions<TPage, TGroup>,
) {
  let applyingBrowserNavigation = false;
  let interval: number | undefined;
  let lastHostCheck = 0;
  let lastOverviewTaskRefresh = 0;

  function clampActivePageAndGroup() {
    if (!opts.isAuthenticated()) return;
    const isAdmin = opts.isAdmin();
    const computerFilesAllowed = opts.computerFilesAllowed ? opts.computerFilesAllowed() : true;
    const computerFilesResolved = opts.computerFilesResolved ? opts.computerFilesResolved() : false;
    const permittedPage = resolvePermittedPage(opts.active.value, {
      isAdmin,
      computerFilesAllowed,
      computerFilesResolved,
    });
    if (permittedPage !== opts.active.value) {
      applyingBrowserNavigation = true;
      opts.active.value = permittedPage;
      const url = new URL(window.location.href);
      url.searchParams.set("page", permittedPage);
      window.history.replaceState({ ...window.history.state, page: permittedPage }, "", url.toString());
      queueMicrotask(() => {
        applyingBrowserNavigation = false;
      });
    }
    const permittedGroup = resolvePermittedSettingsGroup(opts.settingsGroup.value, isAdmin);
    if (permittedGroup !== opts.settingsGroup.value) {
      opts.settingsGroup.value = permittedGroup;
    }
  }

  function handleBrowserPageNavigation() {
    const page = new URL(window.location.href).searchParams.get("page") ?? "overview";
    const candidate = (opts.validPages.has(page as TPage) ? page : "overview") as TPage;
    const next = opts.isAuthenticated()
      ? resolvePermittedPage(candidate, {
          isAdmin: opts.isAdmin(),
          computerFilesAllowed: opts.computerFilesAllowed ? opts.computerFilesAllowed() : true,
          computerFilesResolved: opts.computerFilesResolved ? opts.computerFilesResolved() : false,
        })
      : candidate;
    if (next !== candidate) {
      const url = new URL(window.location.href);
      url.searchParams.set("page", next);
      window.history.replaceState({ ...window.history.state, page: next }, "", url.toString());
    }
    if (next === opts.active.value) return;
    applyingBrowserNavigation = true;
    opts.active.value = next;
    queueMicrotask(() => {
      applyingBrowserNavigation = false;
    });
  }

  function handleRootGenerationChangedEvent() {
    void opts.refreshRootDiscovery();
  }

  function handleVisibilityRefresh() {
    if (
      !document.hidden &&
      opts.isAuthenticated() &&
      !opts.rootDiscoveryLoading() &&
      Date.now() - opts.getLastRootDiscoveryAt() > VISIBILITY_ROOT_REFRESH_COOLDOWN_MS
    ) {
      void opts.refreshRootDiscovery();
    }
  }

  function pollVisiblePage() {
    if (document.hidden || !opts.isAuthenticated()) return;
    const now = Date.now();
    const admin = opts.isAdmin();
    const overview = opts.active.value === "overview";
    const taskSettings =
      opts.active.value === "settings" && opts.settingsGroup.value === "ops";

    if (now - lastHostCheck >= (admin && overview ? FAST_POLL_INTERVAL_MS : SLOW_POLL_INTERVAL_MS)) {
      lastHostCheck = now;
      void opts.updateHostTelemetry();
    }
    if (
      admin &&
      (overview || taskSettings) &&
      opts.rootFeatureContextReady() &&
      !opts.taskLoading() &&
      now - lastOverviewTaskRefresh >=
        (taskSettings && opts.hasRunningTasks() ? FAST_POLL_INTERVAL_MS : SLOW_POLL_INTERVAL_MS)
    ) {
      lastOverviewTaskRefresh = now;
      void opts.reloadTasks();
    }
    if (
      !opts.rootDiscoveryLoading() &&
      now - opts.getLastRootDiscoveryAt() >= SLOW_POLL_INTERVAL_MS
    ) {
      void opts.refreshRootDiscovery();
    }
  }

  function resetPollingTimers() {
    lastHostCheck = 0;
    lastOverviewTaskRefresh = 0;
  }

  watch(opts.settingsGroup, (group) => {
    const safeGroup = opts.isAuthenticated()
      ? resolvePermittedSettingsGroup(group, opts.isAdmin())
      : group;
    if (safeGroup !== group) {
      opts.settingsGroup.value = safeGroup;
      return;
    }
    if (opts.active.value !== "settings") return;
    const url = new URL(window.location.href);
    url.searchParams.set("group", safeGroup);
    window.history.replaceState(null, "", url.toString());
  });

  watch(
    [
      opts.isAuthenticated,
      opts.isAdmin,
      () => (opts.computerFilesAllowed ? opts.computerFilesAllowed() : true),
      () => (opts.computerFilesResolved ? opts.computerFilesResolved() : false),
      opts.active,
    ],
    () => {
      clampActivePageAndGroup();
    },
    { immediate: true },
  );

  watch(
    [opts.active, opts.isAdmin, opts.rootViewKey, opts.rootFeatureContextReady],
    () => {
      if (
        opts.active.value === "overview" &&
        opts.isAdmin() &&
        opts.rootFeatureContextReady()
      ) {
        lastOverviewTaskRefresh = Date.now();
        void opts.reloadTasks();
      }
    },
    { immediate: true },
  );

  watch(opts.active, (next) => {
    opts.moreMenuOpen.value = false;
    opts.visitedPages.value[next] = true;
    if (!applyingBrowserNavigation) {
      const current = new URL(window.location.href);
      current.searchParams.set("page", next);
      const previous = { ...window.history.state };
      delete previous.__lightisleMediaLayer;
      window.history.replaceState(previous, "", window.location.href);
      window.history.pushState({ page: next }, "", current.toString());
    }
    opts.manualRootSection.value = "";
    if (["files", "photos", "cinema"].includes(next) && opts.isAuthenticated()) {
      if (opts.personalRouteError.value || !opts.hasMyStoragePolicy()) {
        void opts.refreshRootDiscovery();
      } else if (opts.multiRootMode()) {
        void opts.autoRouteSection(next);
      } else if (
        next === "files" &&
        !opts.searchingFiles() &&
        !opts.fileDirectoryLoaded()
      ) {
        void opts.loadFiles();
      }
    } else {
      opts.personalRouteError.value = "";
    }
    if (next === "settings" && opts.isAdmin()) {
      void opts.refreshTaskCenter();
    }
  });

  onMounted(() => {
    installImageResourceObserver();
    window.history.replaceState(
      { ...window.history.state, page: opts.active.value },
      "",
      window.location.href,
    );
    window.addEventListener("popstate", handleBrowserPageNavigation);
    void opts.checkAuth();
    window.addEventListener("lightisle-root-generation-changed", handleRootGenerationChangedEvent);
    document.addEventListener("visibilitychange", handleVisibilityRefresh);
    window.addEventListener("lightisle-share-outcome-uncertain", opts.onShareOutcomeUncertain);
    window.addEventListener(
      "lightisle-photo-batch-outcome-uncertain",
      opts.onPhotoBatchOutcomeUncertain,
    );
    interval = window.setInterval(pollVisiblePage, FAST_POLL_INTERVAL_MS);
  });

  onUnmounted(() => {
    window.removeEventListener("popstate", handleBrowserPageNavigation);
    if (interval) clearInterval(interval);
    window.removeEventListener(
      "lightisle-root-generation-changed",
      handleRootGenerationChangedEvent,
    );
    document.removeEventListener("visibilitychange", handleVisibilityRefresh);
    window.removeEventListener(
      "lightisle-share-outcome-uncertain",
      opts.onShareOutcomeUncertain,
    );
    window.removeEventListener(
      "lightisle-photo-batch-outcome-uncertain",
      opts.onPhotoBatchOutcomeUncertain,
    );
  });

  return { resetPollingTimers };
}
