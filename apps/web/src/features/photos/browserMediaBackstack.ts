export type MediaBackstack = {
  readonly depth: number;
  push(): void;
  back(steps?: number): boolean;
  reset(): void;
  dispose(): void;
};

type BackstackHost = Pick<Window, "history" | "location" | "addEventListener" | "removeEventListener">;

// Browser Back should close the innermost media layer first. Each layer is a
// same-URL history entry, preserving ordinary page navigation. A failed
// progress save may reject Back and restore the layer entry.
export function createBrowserMediaBackstack(
  host: BackstackHost,
  owner: string,
  onBack: (oldDepth: number, targetDepth: number) => Promise<boolean>,
): MediaBackstack {
  let depth = 0;
  let busy = false;
  const key = "__lightisleMediaLayer";
  const current = (): { owner?: string; level?: number } | undefined =>
    (host.history.state as Record<string, { owner?: string; level?: number }> | null)?.[key];
  const stateFor = (level: number) => ({
    ...(host.history.state as Record<string, unknown> | null),
    [key]: { owner, level },
  });

  function push() {
    if (busy) return;
    const next = depth + 1;
    host.history.pushState(stateFor(next), "", host.location.href);
    depth = next;
  }

  async function pop(rawEvent: Event) {
    const event = rawEvent as PopStateEvent;
    if (!depth || busy) return;
    const marker = (event.state as Record<string, { owner?: string; level?: number }> | null)?.[key];
    const target =
      marker?.owner === owner && typeof marker.level === "number" && Number.isInteger(marker.level)
        ? Math.max(0, marker.level)
        : 0;
    if (target >= depth) return;
    const old = depth;
    busy = true;
    try {
      const success = await onBack(old, target);
      if (success) depth = target;
      else host.history.pushState(stateFor(old), "", host.location.href);
    } catch {
      host.history.pushState(stateFor(old), "", host.location.href);
    } finally {
      busy = false;
    }
  }

  const onPopState: EventListener = (event) => {
    void pop(event);
  };

  host.addEventListener("popstate", onPopState);
  return {
    push,
    get depth() {
      return depth;
    },
    back(steps = 1) {
      if (depth && !busy) host.history.go(-Math.min(depth, Math.max(1, steps)));
      return depth > 0;
    },
    reset() {
      if (current()?.owner === owner) {
        const state = { ...(host.history.state as Record<string, unknown> | null) };
        delete state[key];
        host.history.replaceState(state, "", host.location.href);
      }
      depth = 0;
    },
    dispose() {
      host.removeEventListener("popstate", onPopState);
      this.reset();
    },
  };
}
