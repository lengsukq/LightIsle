import { onBeforeUnmount, onMounted, onUnmounted, watch } from "vue";
import { createVisibleMediaPolling } from "../../api/visibleMediaPolling.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import { createBrowserMediaBackstack } from "../photos/browserMediaBackstack.ts";
import type { CinemaKeyBindings, createCinemaKeyboardController } from "./cinemaKeyboard.ts";
import type { ModalLayerHandle } from "../../utils/modalStack.ts";
import type { Movie } from "./cinemaTypes.ts";

export function useCinemaWindowBridge(options: {
  isActive: () => boolean;
  getLaunchRequest: () => { film: Movie; nonce: number } | null | undefined;
  emitLaunchHandled: () => void;
  getSelected: () => Movie | null;
  getSeriesDetail: () => unknown;
  getViewerPlaying: () => boolean;
  getCinemaLayerHandle: () => ModalLayerHandle | null;
  keyboardController: ReturnType<typeof createCinemaKeyboardController>;
  getBindings: () => CinemaKeyBindings;
  stopHoldSpeedBoost: () => void;
  status: () => Promise<unknown>;
  save: () => Promise<unknown>;
  leavePlayer: (destination: "overview" | "close", allowUnsaved?: boolean) => Promise<boolean>;
  finishCloseSeries: () => void;
  openLaunchFilm: (film: Movie) => Promise<void> | void;
  triggerInitialLoad: () => void;
  setMediaBackstack: (stack: ReturnType<typeof createBrowserMediaBackstack> | null) => void;
  onCleanupResources: () => void;
}) {
  let lastHandledLaunchNonce = 0;
  let initialLoadPending = false;
  const setScanPolling = createVisibleMediaPolling(options.status, TIMINGS_MS.FAST_POLL);

  function keydown(event: KeyboardEvent) {
    if (!options.isActive() || event.defaultPrevented) return;
    const layer = options.getCinemaLayerHandle();
    if (layer && !layer.isTop()) return;
    options.keyboardController.handleKeydown(event, options.getBindings());
  }

  function keyup(event: KeyboardEvent) {
    if (!options.isActive()) return;
    options.keyboardController.handleKeyup(event, options.getBindings());
  }

  function onWindowBlur() {
    options.keyboardController.reset();
    options.stopHoldSpeedBoost();
  }

  function syncCinemaActiveBindings(active: boolean) {
    setScanPolling(active);
    if (active) {
      window.addEventListener("keydown", keydown);
      window.addEventListener("keyup", keyup);
      window.addEventListener("blur", onWindowBlur);
    } else {
      options.keyboardController.reset();
      options.stopHoldSpeedBoost();
      window.removeEventListener("keydown", keydown);
      window.removeEventListener("keyup", keyup);
      window.removeEventListener("blur", onWindowBlur);
    }
  }

  function onVisibilityFlush() {
    if (document.visibilityState === "hidden" && options.getSelected() && options.getViewerPlaying()) {
      void options.save();
    }
  }

  function onPageHideFlush() {
    if (options.getSelected() && options.getViewerPlaying()) {
      void options.save();
    }
  }

  function consumeLaunchRequest(req: { film: Movie; nonce: number } | null | undefined) {
    if (!req || req.nonce === lastHandledLaunchNonce || !options.isActive()) return;
    lastHandledLaunchNonce = req.nonce;
    options.emitLaunchHandled();
    void options.openLaunchFilm(req.film);
  }

  watch(
    () => [options.isActive(), options.getLaunchRequest()] as const,
    ([activeVal, req]) => {
      if (activeVal && req) consumeLaunchRequest(req);
    },
  );

  onMounted(() => {
    document.addEventListener("visibilitychange", onVisibilityFlush);
    window.addEventListener("pagehide", onPageHideFlush);
    const stack = createBrowserMediaBackstack(window, "lightisle-cinema", async (_old, target) => {
      if (options.getSelected()) {
        const toOverview = options.getViewerPlaying() && target > 0 && !options.getSeriesDetail();
        const saved = await options.leavePlayer(toOverview ? "overview" : "close");
        if (saved && target === 0 && options.getSeriesDetail()) options.finishCloseSeries();
        return saved;
      }
      if (options.getSeriesDetail()) options.finishCloseSeries();
      return true;
    });
    options.setMediaBackstack(stack);
    if (options.isActive()) {
      initialLoadPending = false;
      options.triggerInitialLoad();
    } else {
      initialLoadPending = true;
    }
    syncCinemaActiveBindings(options.isActive());
    consumeLaunchRequest(options.getLaunchRequest());
  });

  watch(options.isActive, (isActive) => {
    syncCinemaActiveBindings(isActive);
    if (!isActive) {
      if (options.getSelected()) void options.leavePlayer("close", true);
      if (options.getSeriesDetail()) options.finishCloseSeries();
    } else if (initialLoadPending) {
      initialLoadPending = false;
      options.triggerInitialLoad();
    } else if (!document.hidden) {
      void options.status();
    }
  });

  onBeforeUnmount(() => {
    void options.save();
  });

  onUnmounted(() => {
    document.removeEventListener("visibilitychange", onVisibilityFlush);
    window.removeEventListener("pagehide", onPageHideFlush);
    syncCinemaActiveBindings(false);
    options.onCleanupResources();
  });
}
