// Root-scoped HTTP transport. UI state belongs to the caller; this module
// enforces root identity, generation and cancellation across async requests.
const ROOT_SCOPED_GLOBAL_PATH =
  /^\/api\/v2\/(?:files(?:[/?]|$)|uploads(?:[/?]|$)|file-shares(?:[/?]|$)|photos(?:[/?]|$)|cinema(?:[/?]|$)|tasks(?:[/?]|$)|alerts(?:[/?]|$)|admin\/uploads(?:[/?]|$)|users\/[^/]+\/file-grants(?:[/?]|$))/;

export type RootRequestScope = {
  rootID: string;
  generation: number;
  epoch: number;
  multiRoot: boolean;
  legacySelected: boolean;
  discoveryState: "unknown" | "multi" | "error";
  switching: boolean;
  signal: AbortSignal;
};

export type RootRequestSnapshot = {
  rootID: string;
  generation: number;
  epoch: number;
  contextKey: string;
  version: "shared" | "root";
};

export function makeRootAbortError(): Error {
  const error = new Error("root_context_changed");
  error.name = "AbortError";
  return error;
}

export function rootContextKey(scope: RootRequestScope): string {
  if (scope.multiRoot && !scope.legacySelected) {
    return scope.rootID ? `v2:${scope.rootID}:${scope.generation}` : "v2:unselected";
  }
  if (scope.multiRoot && scope.legacySelected) {
    return "v2:shared";
  }
  return `unavailable:${scope.discoveryState}`;
}

export function createRootRequestTransport({
  getContext,
  onGenerationChanged,
  fetcher = fetch,
}: {
  getContext: () => RootRequestScope;
  onGenerationChanged: () => void;
  fetcher?: typeof fetch;
}): {
  snapshot(endpoint: string): RootRequestSnapshot | null;
  assertCurrent(snapshot: RootRequestSnapshot | null): void;
  request(endpoint: string, init?: RequestInit, allowDuringRootSwitch?: boolean): Promise<Response>;
} {
  function snapshot(endpoint: string): RootRequestSnapshot | null {
    const scope = getContext();
    if (endpoint === "/api/v1" || endpoint.startsWith("/api/v1/")) {
      throw makeRootAbortError();
    }
    if (endpoint.startsWith("/api/v2/roots/")) {
      const prefix = `/api/v2/roots/${encodeURIComponent(scope.rootID)}/`;
      if (!scope.rootID || !endpoint.startsWith(prefix)) throw makeRootAbortError();
      return {
        rootID: scope.rootID,
        generation: scope.generation,
        epoch: scope.epoch,
        contextKey: rootContextKey(scope),
        version: "root",
      };
    }
    if (ROOT_SCOPED_GLOBAL_PATH.test(endpoint)) {
      if (scope.multiRoot && !scope.legacySelected) throw makeRootAbortError();
      return {
        rootID: "",
        generation: 0,
        epoch: scope.epoch,
        contextKey: rootContextKey(scope),
        version: "shared",
      };
    }
    return null;
  }

  function assertCurrent(requestSnapshot: RootRequestSnapshot | null): void {
    if (requestSnapshot === null) return;
    const scope = getContext();
    if (
      requestSnapshot.epoch !== scope.epoch ||
      requestSnapshot.contextKey !== rootContextKey(scope) ||
      (requestSnapshot.version === "root" &&
        (requestSnapshot.rootID !== scope.rootID || requestSnapshot.generation !== scope.generation))
    ) {
      throw makeRootAbortError();
    }
  }

  async function request(
    endpoint: string,
    init: RequestInit = {},
    allowDuringRootSwitch = false,
  ): Promise<Response> {
    if (!endpoint) throw new Error("root_scope_unavailable");
    const captured = snapshot(endpoint);
    const scope = getContext();
    if (captured && scope.switching && !allowDuringRootSwitch) throw makeRootAbortError();
    const headers = new Headers(init.headers);
    if (captured?.version === "root") {
      headers.set("X-LightIsle-Root-Generation", String(captured.generation));
    }

    let signal = init.signal;
    const cleanup: Array<() => void> = [];
    if (captured) {
      const rootSignal = scope.signal;
      if (signal) {
        const requestSignal = signal;
        const combined = new AbortController();
        for (const source of [rootSignal, requestSignal]) {
          const cancel = () => {
            if (!combined.signal.aborted) combined.abort(source.reason);
          };
          if (source.aborted) cancel();
          else {
            source.addEventListener("abort", cancel, { once: true });
            cleanup.push(() => source.removeEventListener("abort", cancel));
          }
        }
        signal = combined.signal;
      } else {
        signal = rootSignal;
      }
    }

    let response: Response;
    try {
      response = await fetcher(endpoint, { ...init, headers, signal });
    } finally {
      for (const remove of cleanup) remove();
    }
    assertCurrent(captured);
    if (captured?.version === "root" && response.status === 409) {
      const result = (await response
        .clone()
        .json()
        .catch(() => ({}))) as { error?: unknown };
      assertCurrent(captured);
      if (result.error === "root_generation_changed") {
        onGenerationChanged();
        throw new Error("共享目录已变化，请刷新根列表后重新选择。");
      }
    }
    return response;
  }

  return { snapshot, assertCurrent, request };
}
