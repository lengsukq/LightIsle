export function rootApiPath(rootID: string | undefined, apiPath: string): string {
  if (
    typeof apiPath !== "string" ||
    !apiPath.startsWith("/api/v2/") ||
    apiPath.startsWith("/api/v2/roots/")
  ) {
    throw new TypeError("root_api_path_must_be_v2_global_path");
  }
  if (!rootID) return apiPath;
  return `/api/v2/roots/${encodeURIComponent(rootID)}${apiPath.slice("/api/v2".length)}`;
}

export function rootMediaPath(
  rootID: string | undefined,
  rootGeneration: number,
  apiPath: string,
): string {
  const path = rootApiPath(rootID, apiPath);
  if (!rootID) return path;
  const separator = path.includes("?") ? "&" : "?";
  return `${path}${separator}rootGeneration=${encodeURIComponent(String(rootGeneration))}`;
}
