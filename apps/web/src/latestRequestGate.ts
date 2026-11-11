export interface LatestRequest {
  signal: AbortSignal;
  isCurrent(): boolean;
}

export interface LatestRequestGate {
  begin(): LatestRequest;
  cancel(): void;
}

export function createLatestRequestGate(): LatestRequestGate {
  let generation = 0;
  let controller: AbortController | undefined;

  return {
    begin() {
      controller?.abort();
      controller = new AbortController();
      const currentGeneration = ++generation;
      const currentController = controller;
      return {
        signal: currentController.signal,
        isCurrent: () => currentGeneration === generation && !currentController.signal.aborted,
      };
    },
    cancel() {
      generation += 1;
      controller?.abort();
      controller = undefined;
    },
  };
}
