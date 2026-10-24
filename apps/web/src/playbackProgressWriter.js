// Serialize progress updates so an older in-flight pause/tick can never
// overwrite a newer position. Failed snapshots remain retryable, including
// after the player dialog has closed.
export function createPlaybackProgressWriter(write, {onSaved = () => {}, onError = () => {}} = {}) {
  const pending = new Map();
  let running;

  function flush() {
    if (running) return running;
    if (!pending.size) return Promise.resolve();
    let flight;
    flight = (async () => {
      while (pending.size) {
        const [key, snapshot] = pending.entries().next().value;
        pending.delete(key);
        try {
          await write(snapshot);
          onSaved(snapshot);
        } catch (error) {
          // A newer snapshot for the same film supersedes the failed one.
          if (!pending.has(key)) pending.set(key, snapshot);
          onError(error, snapshot);
          break;
        }
      }
    })().finally(() => { if (running === flight) running = undefined; });
    running = flight;
    return flight;
  }

  return {
    save(snapshot) { pending.set(snapshot.key, snapshot); return flush(); },
    retry: flush,
    hasPending() { return pending.size > 0; },
  };
}
