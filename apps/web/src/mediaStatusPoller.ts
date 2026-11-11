export interface MediaStatusPoller<T> {
  refresh(): Promise<void>;
  invalidate(): void;
  dispose(): void;
}

export function createMediaStatusPoller<T>(
  readStatus: (signal: AbortSignal) => Promise<T>,
  { onValue, onError }: { onValue?: (value: T) => void; onError?: (error: unknown) => void } = {},
): MediaStatusPoller<T> {
  let generation = 0;
  let controller: AbortController | undefined;
  let pending: Promise<void> | undefined;
  let disposed = false;

  function invalidate() {
    generation += 1;
    controller?.abort();
    controller = undefined;
    pending = undefined;
  }

  function refresh(): Promise<void> {
    if (disposed) return Promise.resolve();
    if (pending) return pending;

    const currentGeneration = ++generation;
    const currentController = new AbortController();
    controller = currentController;
    const isCurrent = () =>
      !disposed && currentGeneration === generation && !currentController.signal.aborted;
    let request: Promise<void>;
    request = Promise.resolve()
      .then(() => {
        if (!isCurrent()) {
          const error = new Error("status_request_cancelled");
          error.name = "AbortError";
          throw error;
        }
        return readStatus(currentController.signal);
      })
      .then((value) => {
        if (isCurrent()) onValue?.(value);
      })
      .catch((error: unknown) => {
        if (isCurrent() && !(error instanceof Error && error.name === "AbortError")) {
          onError?.(error);
        }
      })
      .finally(() => {
        if (pending === request) pending = undefined;
        if (controller === currentController) controller = undefined;
      });
    pending = request;
    return request;
  }

  function dispose() {
    disposed = true;
    invalidate();
  }

  return { refresh, invalidate, dispose };
}
