export type UploadResumeStorage = {
  collectStaleIDs(input: { legacyKey: string; prefix: string; key: string }): string[];
  read(key: string): { saved: string | null; resumable: boolean };
  save(key: string, uploadID: string): boolean;
  remove(key: string): void;
};

type ResumeStorageLike = Pick<Storage, "getItem" | "setItem" | "removeItem" | "key" | "length">;

// Browser storage is an optional hint; the NAS remains authoritative about
// upload identity and progress. Keep browser storage failures non-fatal.
export function createUploadResumeStorage(
  storageProvider: ResumeStorageLike | (() => ResumeStorageLike),
): UploadResumeStorage {
  // Accessing window.sessionStorage can itself throw SecurityError.
  const currentStorage = (): ResumeStorageLike =>
    typeof storageProvider === "function" ? storageProvider() : storageProvider;

  function collectStaleIDs({
    legacyKey,
    prefix,
    key,
  }: {
    legacyKey: string;
    prefix: string;
    key: string;
  }): string[] {
    const ids: string[] = [];
    try {
      const storage = currentStorage();
      const legacyID = legacyKey ? storage.getItem(legacyKey) : null;
      if (legacyID) {
        ids.push(legacyID);
        storage.removeItem(legacyKey);
      }
      if (prefix) {
        for (let index = 0; index < storage.length; ) {
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

  function read(key: string): { saved: string | null; resumable: boolean } {
    try {
      return { saved: currentStorage().getItem(key), resumable: true };
    } catch {
      return { saved: null, resumable: false };
    }
  }

  function save(key: string, id: string): boolean {
    try {
      currentStorage().setItem(key, id);
      return true;
    } catch {
      return false;
    }
  }

  function remove(key: string): void {
    try {
      currentStorage().removeItem(key);
    } catch {
      /* Server-side cleanup and completion still take precedence. */
    }
  }

  return { collectStaleIDs, read, save, remove };
}
