import { nextTick, onMounted, onUnmounted, ref, watch, type Ref, type WatchSource } from "vue";

export interface SlidingIndicatorOptions {
  containerRef: Ref<HTMLElement | null>;
  activeSelector?: string;
  watchSources?: WatchSource<unknown>[];
}

/**
 * Measures the active element inside a navigation bar or segmented control and outputs
 * GPU-friendly positioning styles for a single gliding pill indicator.
 */
export function useSlidingIndicator(options: SlidingIndicatorOptions) {
  const {
    containerRef,
    activeSelector = "button.active, button.chosen, .is-selected",
    watchSources = [],
  } = options;

  const indicatorStyle = ref<Record<string, string | number>>({
    opacity: 0,
    transform: "translate3d(0, 0, 0)",
    width: "0px",
    height: "0px",
  });
  const indicatorReady = ref(false);

  let resizeObserver: ResizeObserver | null = null;
  let rafId = 0;

  function measureNow() {
    const container = containerRef.value;
    if (!container) {
      indicatorStyle.value = { ...indicatorStyle.value, opacity: 0 };
      return;
    }
    const active = container.querySelector<HTMLElement>(activeSelector);
    if (!active || active.offsetWidth <= 0 || active.offsetHeight <= 0) {
      indicatorStyle.value = { ...indicatorStyle.value, opacity: 0 };
      return;
    }

    const x = active.offsetLeft;
    const y = active.offsetTop;
    indicatorStyle.value = {
      opacity: 1,
      transform: `translate3d(${Math.round(x)}px, ${Math.round(y)}px, 0)`,
      width: `${Math.round(active.offsetWidth)}px`,
      height: `${Math.round(active.offsetHeight)}px`,
    };
    if (!indicatorReady.value) {
      requestAnimationFrame(() => {
        indicatorReady.value = true;
      });
    }
  }

  function scheduleMeasure() {
    if (typeof window === "undefined") return;
    if (rafId) cancelAnimationFrame(rafId);
    rafId = requestAnimationFrame(() => {
      rafId = 0;
      void nextTick(measureNow);
    });
  }

  watch(
    containerRef,
    (el, _prev, onCleanup) => {
      resizeObserver?.disconnect();
      resizeObserver = null;
      if (!el) return;
      scheduleMeasure();
      if (typeof ResizeObserver !== "undefined") {
        resizeObserver = new ResizeObserver(scheduleMeasure);
        resizeObserver.observe(el);
      }
      onCleanup(() => {
        resizeObserver?.disconnect();
        resizeObserver = null;
      });
    },
    { flush: "post", immediate: true },
  );

  if (watchSources.length) {
    watch(watchSources, scheduleMeasure, { flush: "post" });
  }

  onMounted(() => {
    scheduleMeasure();
    if (typeof window !== "undefined") {
      window.addEventListener("resize", scheduleMeasure, { passive: true });
    }
  });

  onUnmounted(() => {
    if (rafId) cancelAnimationFrame(rafId);
    resizeObserver?.disconnect();
    resizeObserver = null;
    if (typeof window !== "undefined") {
      window.removeEventListener("resize", scheduleMeasure);
    }
  });

  return {
    indicatorStyle,
    indicatorReady,
    refreshIndicator: scheduleMeasure,
  };
}
