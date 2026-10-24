export function createMediaStatusPoller(readStatus, { onValue, onError } = {}) {
  let generation = 0;
  let controller;
  let pending;
  let disposed = false;

  function invalidate() {
    generation += 1;
    controller?.abort();
    controller = undefined;
    pending = undefined;
  }

  function refresh() {
    if (disposed) return Promise.resolve();
    if (pending) return pending;

    const currentGeneration = ++generation;
    const currentController = new AbortController();
    controller = currentController;
    const isCurrent = () => !disposed && currentGeneration === generation && !currentController.signal.aborted;
    let request;
    request = Promise.resolve()
      .then(() => {
        if (!isCurrent()) {
          const error = new Error("status_request_cancelled");
          error.name = "AbortError";
          throw error;
        }
        return readStatus(currentController.signal);
      })
      .then(value => {
        if (isCurrent()) onValue?.(value);
      })
      .catch(error => {
        if (isCurrent() && !(error instanceof Error && error.name === "AbortError")) onError?.(error);
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
