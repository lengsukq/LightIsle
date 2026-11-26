import { computed, getCurrentInstance, onUnmounted, ref, watch, type Ref } from "vue";

export interface DockOffset {
  x: number;
  y: number;
}

export interface UseCinemaDockDragOptions {
  stageRef?: Ref<HTMLElement | null>;
  dockRef?: Ref<HTMLElement | null>;
}

export function clampDockOffset(
  offset: DockOffset,
  stageRect: { width: number; height: number },
  dockRect: { width: number; height: number },
  baseBottomMargin = 16,
): DockOffset {
  if (stageRect.width <= 0 || stageRect.height <= 0 || dockRect.width <= 0 || dockRect.height <= 0) {
    return { x: offset.x, y: offset.y };
  }
  const maxX = Math.max(0, (stageRect.width - dockRect.width) / 2 - 8);
  const minY = -(stageRect.height - dockRect.height - baseBottomMargin - 12);
  const maxY = Math.max(0, baseBottomMargin - 6);
  return {
    x: Math.round(Math.max(-maxX, Math.min(maxX, offset.x))),
    y: Math.round(Math.max(minY, Math.min(maxY, offset.y))),
  };
}

function isInteractiveDockTarget(target: EventTarget | null): boolean {
  if (!target || typeof (target as Element).closest !== "function") return false;
  return Boolean(
    (target as Element).closest(
      "button, input, select, textarea, a, label, .cinema-menu-anchor, .cinema-unified-seek",
    ),
  );
}

export function useCinemaDockDrag(options?: UseCinemaDockDragOptions) {
  const dockOffset = ref<DockOffset>({ x: 0, y: 0 });
  const draggingDock = ref(false);
  const dockHovered = ref(false);
  const manuallyCollapsed = ref(false);

  let startPointer: DockOffset = { x: 0, y: 0 };
  let startOffset: DockOffset = { x: 0, y: 0 };
  let activePointerId: number | null = null;
  let reclampRafId: number | null = null;

  const isDockMoved = computed(() => Math.abs(dockOffset.value.x) > 2 || Math.abs(dockOffset.value.y) > 2);
  const isDockNearBottom = computed(() => dockOffset.value.y > -56);

  function resetDockPosition() {
    dockOffset.value = { x: 0, y: 0 };
  }

  function reclampDockOffset(stageEl: HTMLElement | null, dockEl: HTMLElement | null) {
    if (draggingDock.value || !stageEl || !dockEl) return;
    if (dockOffset.value.x === 0 && dockOffset.value.y === 0) return;
    const stageRect = stageEl.getBoundingClientRect();
    const dockRect = dockEl.getBoundingClientRect();
    const clamped = clampDockOffset(dockOffset.value, stageRect, dockRect);
    if (clamped.x !== dockOffset.value.x || clamped.y !== dockOffset.value.y) {
      dockOffset.value = clamped;
    }
  }

  function scheduleReclamp(stageEl: HTMLElement | null, dockEl: HTMLElement | null) {
    if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
      if (reclampRafId !== null) window.cancelAnimationFrame(reclampRafId);
      reclampRafId = window.requestAnimationFrame(() => {
        reclampRafId = null;
        reclampDockOffset(stageEl, dockEl);
      });
    } else {
      reclampDockOffset(stageEl, dockEl);
    }
  }

  if (options?.stageRef && getCurrentInstance()) {
    const stageRef = options.stageRef;
    const dockRef = options.dockRef;
    const stopWatch = watch(
      () => [stageRef.value, dockRef?.value ?? null] as const,
      ([stageEl, dockEl], _prev, onCleanup) => {
        if (!stageEl) return;
        const onBoundsChange = () => scheduleReclamp(stageEl, dockEl);
        let resizeObserver: ResizeObserver | null = null;
        if (typeof ResizeObserver !== "undefined") {
          resizeObserver = new ResizeObserver(onBoundsChange);
          resizeObserver.observe(stageEl);
          if (dockEl) resizeObserver.observe(dockEl);
        }
        if (typeof window !== "undefined" && typeof window.addEventListener === "function") {
          window.addEventListener("resize", onBoundsChange, { passive: true });
          window.addEventListener("orientationchange", onBoundsChange, { passive: true });
        }
        if (typeof document !== "undefined" && typeof document.addEventListener === "function") {
          document.addEventListener("fullscreenchange", onBoundsChange);
        }
        onCleanup(() => {
          resizeObserver?.disconnect();
          if (typeof window !== "undefined" && typeof window.removeEventListener === "function") {
            window.removeEventListener("resize", onBoundsChange);
            window.removeEventListener("orientationchange", onBoundsChange);
          }
          if (typeof document !== "undefined" && typeof document.removeEventListener === "function") {
            document.removeEventListener("fullscreenchange", onBoundsChange);
          }
        });
      },
      { flush: "post", immediate: true },
    );

    onUnmounted(() => {
      stopWatch();
      if (reclampRafId !== null && typeof window !== "undefined" && typeof window.cancelAnimationFrame === "function") {
        window.cancelAnimationFrame(reclampRafId);
        reclampRafId = null;
      }
    });
  }

  function startDockDrag(
    event: PointerEvent,
    stageEl: HTMLElement | null,
    dockEl: HTMLElement | null,
  ): boolean {
    if (event.button !== 0 || isInteractiveDockTarget(event.target)) return false;
    activePointerId = event.pointerId;
    draggingDock.value = true;
    startPointer = { x: event.clientX, y: event.clientY };
    startOffset = { ...dockOffset.value };
    dockEl?.setPointerCapture?.(event.pointerId);

    // Measure stage and dock bounds once per gesture to avoid per-frame forced reflows.
    let cachedStageRect: DOMRect | null = stageEl?.getBoundingClientRect() ?? null;
    let cachedDockRect: DOMRect | null = dockEl?.getBoundingClientRect() ?? null;
    let pendingOffset: DockOffset | null = null;
    let dragRafId: number | null = null;

    const applyOffset = (raw: DockOffset) => {
      if (stageEl && dockEl) {
        cachedStageRect ??= stageEl.getBoundingClientRect();
        cachedDockRect ??= dockEl.getBoundingClientRect();
        dockOffset.value = clampDockOffset(raw, cachedStageRect, cachedDockRect);
      } else {
        dockOffset.value = raw;
      }
    };

    const onMove = (moveEvent: PointerEvent) => {
      if (activePointerId !== null && moveEvent.pointerId !== activePointerId) return;
      const raw: DockOffset = {
        x: startOffset.x + (moveEvent.clientX - startPointer.x),
        y: startOffset.y + (moveEvent.clientY - startPointer.y),
      };
      pendingOffset = raw;
      if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
        if (dragRafId === null) {
          dragRafId = window.requestAnimationFrame(() => {
            dragRafId = null;
            if (pendingOffset !== null) {
              const next = pendingOffset;
              pendingOffset = null;
              applyOffset(next);
            }
          });
        }
      } else {
        pendingOffset = null;
        applyOffset(raw);
      }
    };

    const onEnd = (endEvent: PointerEvent) => {
      if (activePointerId !== null && endEvent.pointerId !== activePointerId) return;
      if (dragRafId !== null && typeof window !== "undefined" && typeof window.cancelAnimationFrame === "function") {
        window.cancelAnimationFrame(dragRafId);
        dragRafId = null;
      }
      if (pendingOffset !== null) {
        const finalOffset = pendingOffset;
        pendingOffset = null;
        applyOffset(finalOffset);
      }
      draggingDock.value = false;
      activePointerId = null;
      dockEl?.releasePointerCapture?.(endEvent.pointerId);
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onEnd);
      window.removeEventListener("pointercancel", onEnd);
    };

    window.addEventListener("pointermove", onMove, { passive: true });
    window.addEventListener("pointerup", onEnd);
    window.addEventListener("pointercancel", onEnd);
    return true;
  }

  return {
    dockOffset,
    draggingDock,
    dockHovered,
    manuallyCollapsed,
    isDockMoved,
    isDockNearBottom,
    resetDockPosition,
    startDockDrag,
  };
}
