// Browser storage is an optional hint; the NAS remains authoritative about
// upload identity and progress. Keep browser storage failures non-fatal.
export function createUploadResumeStorage(storageProvider) {
  // Accessing window.sessionStorage can itself throw SecurityError.
  const currentStorage = () => typeof storageProvider === "function" ? storageProvider() : storageProvider;
  function collectStaleIDs({ legacyKey, prefix, key }) {
    const ids = [];
    try {
      const storage = currentStorage();
      const legacyID = legacyKey ? storage.getItem(legacyKey) : null;
      if (legacyID) {
        ids.push(legacyID);
        storage.removeItem(legacyKey);
      }
      if (prefix) {
        for (let index = 0; index < storage.length;) {
          const candidate = storage.key(index);
          if (candidate?.startsWith(prefix) && candidate !== key) {
            const id = storage.getItem(candidate);
            if (id) ids.push(id);
            storage.removeItem(candidate);
            continue;
          }
          index++;
        }
      }
    } catch {
      // Private browsing or a restricted origin may block sessionStorage.
    }
    return ids;
  }

  function read(key) {
    try { return { saved: currentStorage().getItem(key), resumable: true }; }
    catch { return { saved: null, resumable: false }; }
  }

  function save(key, id) {
    try { currentStorage().setItem(key, id); return true; }
    catch { return false; }
  }

  function remove(key) {
    try { currentStorage().removeItem(key); }
    catch { /* Server-side cleanup and completion still take precedence. */ }
  }
  return { collectStaleIDs, read, save, remove };
}
