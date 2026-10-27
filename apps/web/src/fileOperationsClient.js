// File operations intentionally bind to the current caller-supplied root.
// The root transport independently rejects stale generations and switches.
export function createFileOperationsClient({ apiPath, get, write, getEpoch }) {
  function assertEpoch(epoch) {
    if (epoch !== getEpoch()) {
      const error = new Error("root_context_changed");
      error.name = "AbortError";
      throw error;
    }
  }

  async function listFolders(path, cursor) {
    const epoch = getEpoch();
    const query = new URLSearchParams({ path, limit: "100", cursor });
    const result = await get(apiPath("/api/v2/files") + "?" + query.toString());
    assertEpoch(epoch);
    return result;
  }

  async function commit({ action, from, to, conflict }) {
    if (action !== "move" && action !== "copy") throw new TypeError("invalid_file_operation");
    const epoch = getEpoch();
    const result = await write(apiPath("/api/v2/files/operations"), "POST",
      { action, from, to, conflict });
    assertEpoch(epoch);
    return result;
  }

  return { listFolders, commit };
}
