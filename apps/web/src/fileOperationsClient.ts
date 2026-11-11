export type FileOperation = "move" | "copy";
export type ConflictPolicy = "" | "skip" | "rename";

// File operations intentionally bind to the current caller-supplied root.
// The root transport independently rejects stale generations and switches.
export function createFileOperationsClient({
  apiPath,
  get,
  write,
  getEpoch,
}: {
  apiPath: (path: string) => string;
  get: <T>(endpoint: string) => Promise<T>;
  write: <T>(endpoint: string, method: "POST", body: object) => Promise<T>;
  getEpoch: () => number;
}): {
  listFolders<T>(path: string, cursor: string): Promise<T>;
  commit<T>(operation: {
    action: FileOperation;
    from: string;
    to: string;
    conflict: ConflictPolicy;
  }): Promise<T>;
} {
  function assertEpoch(epoch: number) {
    if (epoch !== getEpoch()) {
      const error = new Error("root_context_changed");
      error.name = "AbortError";
      throw error;
    }
  }

  async function listFolders<T>(path: string, cursor: string): Promise<T> {
    const epoch = getEpoch();
    const query = new URLSearchParams({ path, limit: "100", cursor });
    const result = await get<T>(apiPath("/api/v2/files") + "?" + query.toString());
    assertEpoch(epoch);
    return result;
  }

  async function commit<T>({
    action,
    from,
    to,
    conflict,
  }: {
    action: FileOperation;
    from: string;
    to: string;
    conflict: ConflictPolicy;
  }): Promise<T> {
    if (action !== "move" && action !== "copy") {
      throw new TypeError("invalid_file_operation");
    }
    const epoch = getEpoch();
    const result = await write<T>(apiPath("/api/v2/files/operations"), "POST", {
      action,
      from,
      to,
      conflict,
    });
    assertEpoch(epoch);
    return result;
  }

  return { listFolders, commit };
}
