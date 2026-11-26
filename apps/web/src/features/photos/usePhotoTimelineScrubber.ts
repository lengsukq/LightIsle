import { computed, getCurrentScope, nextTick, onScopeDispose, ref, watch, type ComputedRef, type Ref } from "vue";
import { describeRootOperationFailure } from "../../api/rootDiscovery.ts";
import {
  buildTimelineYears,
  timelineJumpIndex,
  timelineScrubIndexAt,
  timelineYearsFromMonths,
} from "./photoTimelineJump.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";

export type TimelineMonthEntry = {
  year: number;
  month: number;
  count: number;
  firstIndex: number;
};

export function usePhotoTimelineScrubber<TAsset extends BatchAsset>(options: {
  assets: Ref<TAsset[]>;
  nextCursor: Ref<number>;
  loading: Ref<boolean>;
  loadError: Ref<string>;
  galleryLoaded: Ref<boolean>;
  focusedIndex: Ref<number>;
  gridElement: Ref<HTMLElement | null>;
  scrubberInView: Ref<boolean>;
  timelineLayout: ComputedRef<{
    groups: Array<{ startIndex: number; top: number; title: string; count: number }>;
  }>;
  virtualWindow: ComputedRef<{
    startIndex: number;
    endIndex: number;
    headers: Array<{ startIndex: number; top: number; title: string; count: number }>;
  }>;
  isFullTimelineView: () => boolean;
  beginListRequest: () => { signal: AbortSignal; isCurrent: () => boolean };
  getRootEpoch: () => number;
  isDisposed: () => boolean;
  api: <T>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  load: (reset?: boolean) => Promise<void>;
  updateViewport: () => void;
  measureViewport: () => void;
}) {
  const timelineCursorStart = ref(0);
  const fullTimelineMonths = ref<TimelineMonthEntry[]>([]);
  const jumpYear = ref(0);
  const jumpMonth = ref(0);
  const scrubbing = ref(false);
  const scrubPreview = ref(0);
  const scrollSyncedIndex = ref<number | null>(null);
  const scrubScrolling = ref(false);
  const scrolledPastHeader = ref(false);
  const activeStickyGroup = ref<{ startIndex: number; top: number; title: string; count: number } | null>(null);
  let scrubPointerId: number | null = null;
  let scrollSyncRafId: number | null = null;
  let scrollIdleTimer: number | undefined;
  let scrollListenerAttached = false;

  async function refreshTimelineIndex() {
    const root = options.getRootEpoch();
    try {
      const result = await options.api<{ months: TimelineMonthEntry[] }>(
        options.apiPath("/api/v2/photos/timeline"),
      );
      if (!options.isDisposed() && root === options.getRootEpoch()) {
        fullTimelineMonths.value = result.months;
      }
    } catch {
      if (!options.isDisposed() && root === options.getRootEpoch()) {
        fullTimelineMonths.value = [];
      }
    }
  }

  const timelineYears = computed(() => {
    if (options.isFullTimelineView() && fullTimelineMonths.value.length) {
      return timelineYearsFromMonths(fullTimelineMonths.value);
    }
    return buildTimelineYears(options.assets.value.map((asset) => asset.takenAt));
  });

  const jumpMonths = computed(
    () => timelineYears.value.find((entry) => entry.year === jumpYear.value)?.months ?? [],
  );

  const yearOptions = computed(() =>
    timelineYears.value.map((entry) => ({
      value: entry.year,
      label: `${entry.year} 年`,
      hint: `${entry.count} 项`,
    })),
  );

  const monthOptions = computed(() =>
    jumpMonths.value.map((entry) => ({
      value: entry.month,
      label: entry.title,
      hint: `${entry.count} 项`,
    })),
  );

  const browseTitle = computed(() => options.virtualWindow.value.headers[0]?.title ?? "");

  function scrollToTimelineIndex(index: number) {
    const grid = options.gridElement.value;
    const targetGroup = options.timelineLayout.value.groups.find((item) => item.startIndex === index);
    if (!grid || !targetGroup) return;
    const targetTop = grid.getBoundingClientRect().top + window.scrollY + targetGroup.top;
    window.scrollTo({ top: Math.max(0, targetTop - 120), behavior: "auto" });
    options.measureViewport();
  }

  async function loadAtTimelineCursor(cursor: number) {
    if (options.loading.value || !options.isFullTimelineView()) return false;
    const request = options.beginListRequest();
    options.loading.value = true;
    options.loadError.value = "";
    try {
      const query = new URLSearchParams({ limit: "48", cursor: String(cursor) });
      const result = await options.api<{ assets: TAsset[]; nextCursor: number }>(
        options.apiPath("/api/v2/photos") + "?" + query.toString(),
        "GET",
        undefined,
        request.signal,
      );
      if (!request.isCurrent()) return false;
      options.assets.value = result.assets;
      options.nextCursor.value = result.nextCursor;
      timelineCursorStart.value = cursor;
      options.focusedIndex.value = 0;
      options.galleryLoaded.value = true;
      await nextTick();
      options.updateViewport();
      return true;
    } catch (error) {
      if (request.isCurrent() && !(error instanceof Error && error.name === "AbortError")) {
        options.loadError.value = "跳转年月失败：" + describeRootOperationFailure(error);
      }
      return false;
    } finally {
      if (request.isCurrent()) options.loading.value = false;
    }
  }

  async function jumpToTimeline() {
    const index = timelineJumpIndex(timelineYears.value, jumpYear.value, jumpMonth.value);
    if (index < 0) return;
    if (options.isFullTimelineView() && fullTimelineMonths.value.length) {
      const relative = index - timelineCursorStart.value;
      if (relative < 0 || relative >= options.assets.value.length) {
        if (await loadAtTimelineCursor(index)) {
          scrollToTimelineIndex(0);
        }
        return;
      }
      scrollToTimelineIndex(relative);
    } else {
      scrollToTimelineIndex(index);
    }
  }

  function onJumpYearChange() {
    jumpMonth.value = jumpMonths.value.length ? jumpMonths.value[jumpMonths.value.length - 1].month : 0;
    void jumpToTimeline();
  }

  const scrubMonths = computed(() =>
    timelineYears.value.flatMap((year) =>
      year.months.map((month) => ({
        year: year.year,
        month: month.month,
        title: month.title,
        firstIndex: month.firstIndex,
      })),
    ),
  );

  const scrubCurrentIndex = computed(() => {
    if (scrubbing.value) return scrubPreview.value;
    if (
      scrollSyncedIndex.value !== null &&
      scrollSyncedIndex.value >= 0 &&
      scrollSyncedIndex.value < scrubMonths.value.length
    ) {
      return scrollSyncedIndex.value;
    }
    const firstHeader = options.virtualWindow.value.headers[0];
    const anchorAsset = options.assets.value[
      firstHeader
        ? Math.min(options.assets.value.length - 1, firstHeader.startIndex)
        : Math.min(options.assets.value.length - 1, options.virtualWindow.value.startIndex)
    ];
    if (anchorAsset && anchorAsset.takenAt > 0) {
      const taken = new Date(anchorAsset.takenAt * 1000);
      const found = scrubMonths.value.findIndex(
        (entry) => entry.year === taken.getFullYear() && entry.month === taken.getMonth() + 1,
      );
      if (found >= 0) return found;
    }
    const fallback = scrubMonths.value.findIndex((entry) => entry.firstIndex >= timelineCursorStart.value);
    return Math.max(0, fallback);
  });

  function findActiveGroupAtGridY(
    groups: Array<{ startIndex: number; top: number; title: string; count: number }>,
    gridY: number,
  ) {
    if (!groups.length) return null;
    let low = 0;
    let high = groups.length - 1;
    let chosen = 0;
    while (low <= high) {
      const mid = (low + high) >>> 1;
      if (groups[mid].top <= gridY) {
        chosen = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return groups[chosen] ?? groups[0];
  }

  function syncActiveMonthFromScroll(markScrolling = true) {
    const grid = options.gridElement.value;
    const groups = options.timelineLayout.value.groups;
    if (!grid || !groups.length) {
      scrolledPastHeader.value = false;
      activeStickyGroup.value = null;
      scrollSyncedIndex.value = null;
      return;
    }
    const rect = grid.getBoundingClientRect();
    const gridOffsetY = Math.max(0, 96 - rect.top);
    scrolledPastHeader.value = rect.top < 54 && rect.bottom > 180;
    const group = findActiveGroupAtGridY(groups, gridOffsetY);
    activeStickyGroup.value = group;
    if (group) {
      const anchor = options.assets.value[Math.min(options.assets.value.length - 1, group.startIndex)];
      if (anchor && anchor.takenAt > 0) {
        const taken = new Date(anchor.takenAt * 1000);
        const found = scrubMonths.value.findIndex(
          (entry) => entry.year === taken.getFullYear() && entry.month === taken.getMonth() + 1,
        );
        if (found >= 0) {
          scrollSyncedIndex.value = found;
        }
      }
    }
    if (markScrolling && options.scrubberInView.value && !options.isDisposed()) {
      scrubScrolling.value = true;
      if (scrollIdleTimer !== undefined) window.clearTimeout(scrollIdleTimer);
      scrollIdleTimer = window.setTimeout(() => {
        scrollIdleTimer = undefined;
        scrubScrolling.value = false;
      }, 1150);
    }
  }

  function scheduleScrollSync() {
    if (typeof window === "undefined" || typeof window.requestAnimationFrame !== "function") return;
    if (scrollSyncRafId !== null) return;
    scrollSyncRafId = window.requestAnimationFrame(() => {
      scrollSyncRafId = null;
      if (!options.isDisposed()) syncActiveMonthFromScroll(true);
    });
  }

  function cancelScrollSync() {
    if (scrollSyncRafId !== null && typeof window !== "undefined" && typeof window.cancelAnimationFrame === "function") {
      window.cancelAnimationFrame(scrollSyncRafId);
    }
    scrollSyncRafId = null;
    if (scrollIdleTimer !== undefined && typeof window !== "undefined") {
      window.clearTimeout(scrollIdleTimer);
      scrollIdleTimer = undefined;
    }
    scrubScrolling.value = false;
  }

  function attachScrollSync() {
    if (scrollListenerAttached || typeof window === "undefined") return;
    scrollListenerAttached = true;
    window.addEventListener("scroll", scheduleScrollSync, { passive: true });
    window.addEventListener("resize", scheduleScrollSync, { passive: true });
  }

  function detachScrollSync() {
    cancelScrollSync();
    if (!scrollListenerAttached || typeof window === "undefined") return;
    scrollListenerAttached = false;
    window.removeEventListener("scroll", scheduleScrollSync);
    window.removeEventListener("resize", scheduleScrollSync);
  }

  watch(
    () => options.gridElement.value,
    (grid) => {
      if (grid) {
        attachScrollSync();
        syncActiveMonthFromScroll(false);
      } else {
        detachScrollSync();
        scrolledPastHeader.value = false;
        activeStickyGroup.value = null;
        scrollSyncedIndex.value = null;
      }
    },
  );

  watch(
    () => [options.timelineLayout.value.groups.length, scrubMonths.value.length],
    () => {
      if (options.gridElement.value) syncActiveMonthFromScroll(false);
    },
  );

  if (getCurrentScope()) {
    onScopeDispose(() => {
      detachScrollSync();
    });
  }

  let scrubRailRect: DOMRect | null = null;
  let scrubRafId: number | null = null;
  let pendingScrubY: number | null = null;

  function cancelScrubFrame() {
    if (scrubRafId !== null && typeof window !== "undefined" && typeof window.cancelAnimationFrame === "function") {
      window.cancelAnimationFrame(scrubRafId);
    }
    scrubRafId = null;
    pendingScrubY = null;
  }

  function applyScrubClientY(clientY: number, rail?: HTMLElement) {
    const rect = scrubRailRect ?? rail?.getBoundingClientRect() ?? null;
    if (!rect) return;
    scrubRailRect = rect;
    const index = timelineScrubIndexAt(clientY - rect.top, rect.height, scrubMonths.value.length);
    if (index >= 0) scrubPreview.value = index;
  }

  function startScrub(event: PointerEvent) {
    if (event.button !== 0 || options.loading.value || !scrubMonths.value.length) return;
    const rail = event.currentTarget as HTMLElement;
    scrubRailRect = rail.getBoundingClientRect();
    scrubbing.value = true;
    scrubPointerId = event.pointerId;
    applyScrubClientY(event.clientY, rail);
    rail.setPointerCapture(event.pointerId);
    event.preventDefault();
  }

  function moveScrub(event: PointerEvent) {
    if (!scrubbing.value || scrubPointerId !== event.pointerId) return;
    const rail = event.currentTarget as HTMLElement;
    pendingScrubY = event.clientY;
    if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
      if (scrubRafId === null) {
        scrubRafId = window.requestAnimationFrame(() => {
          scrubRafId = null;
          if (!scrubbing.value || pendingScrubY === null) return;
          const clientY = pendingScrubY;
          pendingScrubY = null;
          applyScrubClientY(clientY, rail);
        });
      }
    } else {
      pendingScrubY = null;
      applyScrubClientY(event.clientY, rail);
    }
  }

  function stopScrub(event: PointerEvent, commit = true) {
    if (!scrubbing.value || scrubPointerId !== event.pointerId) return;
    const rail = event.currentTarget as HTMLElement;
    if (commit && pendingScrubY !== null) {
      applyScrubClientY(pendingScrubY, rail);
    }
    cancelScrubFrame();
    scrubRailRect = null;
    if (rail.hasPointerCapture(event.pointerId)) rail.releasePointerCapture(event.pointerId);
    const selectedIndex = scrubPreview.value;
    scrubbing.value = false;
    scrubPointerId = null;
    if (!commit) return;
    const month = scrubMonths.value[selectedIndex];
    if (!month) return;
    jumpYear.value = month.year;
    jumpMonth.value = month.month;
    void jumpToTimeline();
  }

  function scrubKeydown(event: KeyboardEvent) {
    if (options.loading.value || !scrubMonths.value.length) return;
    let index = scrubCurrentIndex.value;
    if (event.key === "ArrowDown") index += 1;
    else if (event.key === "ArrowUp") index -= 1;
    else if (event.key === "PageDown") index += 6;
    else if (event.key === "PageUp") index -= 6;
    else if (event.key === "Home") index = 0;
    else if (event.key === "End") index = scrubMonths.value.length - 1;
    else return;
    event.preventDefault();
    const month = scrubMonths.value[Math.max(0, Math.min(scrubMonths.value.length - 1, index))];
    jumpYear.value = month.year;
    jumpMonth.value = month.month;
    void jumpToTimeline();
  }

  function scrollToTop() {
    if (timelineCursorStart.value > 0) {
      void options.load(true);
      return;
    }
    window.scrollTo({ top: 0, behavior: "auto" });
  }

  function resetScrubberForRootChange() {
    cancelScrubFrame();
    cancelScrollSync();
    scrubRailRect = null;
    timelineCursorStart.value = 0;
    fullTimelineMonths.value = [];
    scrubbing.value = false;
    scrubPointerId = null;
    scrollSyncedIndex.value = null;
    scrolledPastHeader.value = false;
    activeStickyGroup.value = null;
    options.scrubberInView.value = false;
    jumpYear.value = 0;
    jumpMonth.value = 0;
  }

  return {
    timelineCursorStart,
    fullTimelineMonths,
    timelineYears,
    jumpYear,
    jumpMonth,
    jumpMonths,
    yearOptions,
    monthOptions,
    browseTitle,
    scrubMonths,
    scrubbing,
    scrubPreview,
    scrubCurrentIndex,
    scrubScrolling,
    scrolledPastHeader,
    activeStickyGroup,
    refreshTimelineIndex,
    jumpToTimeline,
    onJumpYearChange,
    startScrub,
    moveScrub,
    stopScrub,
    scrubKeydown,
    scrollToTop,
    resetScrubberForRootChange,
  };
}
