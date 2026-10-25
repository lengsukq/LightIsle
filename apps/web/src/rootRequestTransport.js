// Root-scoped HTTP transport. UI state belongs to the caller; this module
// enforces root identity, generation and cancellation across async requests.
const ROOT_SCOPED_V1_PATH = /^\/api\/v1\/(?:files(?:[/?]|$)|uploads(?:[/?]|$)|file-shares(?:[/?]|$)|photos(?:[/?]|$)|cinema(?:[/?]|$)|tasks(?:[/?]|$)|alerts(?:[/?]|$)|admin\/uploads(?:[/?]|$)|users\/[^/]+\/file-grants(?:[/?]|$))/;

export function makeRootAbortError() {
  const error = new Error("root_context_changed");
  error.name = "AbortError";
  return error;
}

export function rootContextKey(scope) {
  if (scope.multiRoot && !scope.legacySelected) {
    return scope.rootID ? `v2:${scope.rootID}:${scope.generation}` : "v2:unselected";
  }
  if (scope.discoveryState === "legacy" || (scope.multiRoot && scope.legacySelected)) {
    return "v1:compatibility";
  }
  return `unavailable:${scope.discoveryState}`;
}

export function createRootRequestTransport({ getContext, onGenerationChanged, fetcher = fetch }) {
  function snapshot(endpoint) {
    const scope = getContext();
    if (endpoint.startsWith("/api/v2/roots/")) {
      const prefix = `/api/v2/roots/${encodeURIComponent(scope.rootID)}/`;
      if (!scope.rootID || !endpoint.startsWith(prefix)) throw makeRootAbortError();
      return { rootID: scope.rootID, generation: scope.generation, epoch: scope.epoch,
        contextKey: rootContextKey(scope), version: "v2" };
    }
    if (ROOT_SCOPED_V1_PATH.test(endpoint)) {
      if (scope.multiRoot && !scope.legacySelected) throw makeRootAbortError();
      return { rootID: "", generation: 0, epoch: scope.epoch,
        contextKey: rootContextKey(scope), version: "v1" };
    }
    return null;
  }

  function assertCurrent(request) {
    if (request === null) return;
    const scope = getContext();
    if (request.epoch !== scope.epoch || request.contextKey !== rootContextKey(scope) ||
        (request.version === "v2" &&
          (request.rootID !== scope.rootID || request.generation !== scope.generation))) {
      throw makeRootAbortError();
    }
  }

  async function request(endpoint, init = {}, allowDuringRootSwitch = false) {
    if (!endpoint) throw new Error("root_scope_unavailable");
    const captured = snapshot(endpoint);
    const scope = getContext();
    if (captured && scope.switching && !allowDuringRootSwitch) throw makeRootAbortError();
    const headers = new Headers(init.headers);
    if (captured?.version === "v2") {
      headers.set("X-LightIsle-Root-Generation", String(captured.generation));
    }

    let signal = init.signal;
    const cleanup = [];
    if (captured) {
      const rootSignal = scope.signal;
      if (signal) {
        const requestSignal = signal;
        const combined = new AbortController();
        for (const source of [rootSignal, requestSignal]) {
          const cancel = () => { if (!combined.signal.aborted) combined.abort(source.reason); };
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

    let response;
    try {
      response = await fetcher(endpoint, { ...init, headers, signal });
    } finally {
      for (const remove of cleanup) remove();
    }
    assertCurrent(captured);
    if (captured?.version === "v2" && response.status === 409) {
      const result = await response.clone().json().catch(() => ({}));
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
