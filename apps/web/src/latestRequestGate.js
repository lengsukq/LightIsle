export function createLatestRequestGate() {
  let generation = 0;
  let controller;

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
