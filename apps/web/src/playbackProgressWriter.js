// Serialize progress updates so an older in-flight pause/tick can never
// overwrite a newer position. Failed snapshots remain retryable, including
// after the player dialog has closed. A failed key is attempted once per
// flush, so an unavailable root cannot block saves for other roots.
export function createPlaybackProgressWriter(write, {onSaved = () => {}, onError = () => {}} = {}) {
  const pending = new Map();
  let running;

  function flush() {
    if (running) return running;
    if (!pending.size) return Promise.resolve();
    let flight;
    flight = (async () => {
      const attempted = new Set();
      while (true) {
        const entry = [...pending.values()].find(value => !attempted.has(value));
        if (!entry) break;
        const {key, snapshot} = entry;
        if (pending.get(key) === entry) pending.delete(key);
        try {
          await write(snapshot);
          onSaved(snapshot);
        } catch (error) {
          // A newer snapshot for the same film supersedes the failed one.
          if (!pending.has(key)) pending.set(key, entry);
          onError(error, snapshot);
          attempted.add(entry);
        }
      }
    })().finally(() => { if (running === flight) running = undefined; });
    running = flight;
    return flight;
  }

  return {
    save(snapshot) { pending.set(snapshot.key, {key:snapshot.key,snapshot}); return flush(); },
    retry: flush,
    hasPending() { return pending.size > 0; },
  };
}
