export function rootApiPath(rootID, legacyPath) {
  if (!rootID) return legacyPath;
  if (typeof legacyPath !== "string" || !legacyPath.startsWith("/api/v1/")) {
    throw new TypeError("root_api_path_must_be_v1_api_path");
  }
  return `/api/v2/roots/${encodeURIComponent(rootID)}${legacyPath.slice("/api/v1".length)}`;
}

export function rootMediaPath(rootID, rootGeneration, legacyPath) {
  const path = rootApiPath(rootID, legacyPath);
  if (!rootID) return path;
  const separator = path.includes("?") ? "&" : "?";
  return `${path}${separator}rootGeneration=${encodeURIComponent(String(rootGeneration))}`;
}
