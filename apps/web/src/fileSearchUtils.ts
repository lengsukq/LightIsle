export type FileSearchKind = "" | "image" | "video" | "audio" | "document" | "archive" | "folder";
export type FileSearchScope = "all" | "folder";

export const FILE_SEARCH_KIND_OPTIONS: ReadonlyArray<{ value: FileSearchKind; label: string }> = [
  { value: "", label: "全部" },
  { value: "image", label: "图片" },
  { value: "video", label: "视频" },
  { value: "audio", label: "音频" },
  { value: "document", label: "文档" },
  { value: "archive", label: "压缩包" },
  { value: "folder", label: "文件夹" },
];

export const FILE_SEARCH_HISTORY_MAX = 8;

export type SearchHighlightSegment = {
  text: string;
  match: boolean;
};

/**
 * Splits a user query into unique non-empty case-folded search tokens (1+ chars).
 */
export function tokenizeSearchQuery(raw: string): string[] {
  const trimmed = raw.trim();
  if (!trimmed) return [];
  const seen = new Set<string>();
  const tokens: string[] = [];
  for (const part of trimmed.split(/\s+/)) {
    if (!part) continue;
    const lowered = part.toLowerCase();
    if (seen.has(lowered)) continue;
    seen.add(lowered);
    tokens.push(part);
  }
  return tokens;
}

/**
 * Splits text into plain and matched highlight slices for safe template rendering.
 */
export function highlightSearchSegments(text: string, rawQuery: string): SearchHighlightSegment[] {
  if (!text) return [];
  const tokens = tokenizeSearchQuery(rawQuery)
    .map((item) => item.toLowerCase())
    .sort((a, b) => b.length - a.length);
  if (!tokens.length) return [{ text, match: false }];

  const lower = text.toLowerCase();
  const ranges: Array<[number, number]> = [];
  for (const token of tokens) {
    let cursor = 0;
    while (cursor <= lower.length - token.length) {
      const idx = lower.indexOf(token, cursor);
      if (idx === -1) break;
      ranges.push([idx, idx + token.length]);
      cursor = idx + Math.max(1, token.length);
    }
  }
  if (!ranges.length) return [{ text, match: false }];

  ranges.sort((a, b) => a[0] - b[0] || b[1] - a[1]);
  const merged: Array<[number, number]> = [];
  for (const [start, end] of ranges) {
    const prev = merged[merged.length - 1];
    if (!prev || start > prev[1]) {
      merged.push([start, end]);
    } else if (end > prev[1]) {
      prev[1] = end;
    }
  }

  const result: SearchHighlightSegment[] = [];
  let offset = 0;
  for (const [start, end] of merged) {
    if (start > offset) result.push({ text: text.slice(offset, start), match: false });
    result.push({ text: text.slice(start, end), match: true });
    offset = end;
  }
  if (offset < text.length) result.push({ text: text.slice(offset), match: false });
  return result;
}

/**
 * Returns the relative parent directory for a file entry path, or "." for root.
 */
export function parentDirOfPath(entryPath: string): string {
  const trimmed = entryPath.replace(/^\/+|\/+$/g, "");
  const slash = trimmed.lastIndexOf("/");
  return slash > 0 ? trimmed.slice(0, slash) : ".";
}

/**
 * Formats a concise human-readable label for a directory path.
 */
export function folderLabelOfPath(dirPath: string, rootName = "共享根目录"): string {
  const clean = (dirPath || ".").replace(/^\/+|\/+$/g, "");
  if (!clean || clean === ".") return rootName;
  const parts = clean.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? clean;
}

function fileSearchScore(entry: { name: string; path: string }, rawQuery: string, tokens: string[]): number {
  const q = rawQuery.trim().toLowerCase();
  const nameLower = entry.name.toLowerCase();
  const pathLower = entry.path.toLowerCase();
  const dot = nameLower.lastIndexOf(".");
  const stemLower = dot > 0 ? nameLower.slice(0, dot) : nameLower;

  if (nameLower === q || stemLower === q) return 0;
  if (nameLower.startsWith(q)) return 1;
  if (tokens.length > 0 && tokens.every((t) => nameLower.includes(t)) && nameLower.startsWith(tokens[0])) return 2;
  if (tokens.length > 0 && tokens.every((t) => nameLower.includes(t))) return 3;
  if (tokens.length > 0 && tokens.every((t) => pathLower.includes(t))) return 4;
  if (tokens.some((t) => nameLower.includes(t))) return 5;
  if (tokens.some((t) => pathLower.includes(t))) return 6;
  return 7;
}

/**
 * Ranks file search results so exact and prefix filename matches appear before
 * substring, path-only, or Spotlight content matches while preserving stability.
 */
export function rankSearchEntries<T extends { name: string; path: string }>(entries: readonly T[], rawQuery: string): T[] {
  const tokens = tokenizeSearchQuery(rawQuery).map((t) => t.toLowerCase());
  if (!tokens.length || entries.length <= 1) return entries.slice();
  return entries
    .map((entry, index) => ({ entry, index, score: fileSearchScore(entry, rawQuery, tokens) }))
    .sort((a, b) => a.score - b.score || a.index - b.index)
    .map((item) => item.entry);
}

/**
 * Computes an account + root isolated localStorage key for recent file searches.
 */
export function buildFileSearchHistoryKey(username?: string | null, rootID?: string | null): string {
  const userPart = (username ?? "").trim();
  if (!userPart) return "";
  const rootPart = (rootID ?? "").trim() || "primary";
  return `lightisle:file-search-history:v1:${encodeURIComponent(userPart)}:${encodeURIComponent(rootPart)}`;
}

type StorageReader = Pick<Storage, "getItem">;
type StorageWriter = Pick<Storage, "getItem" | "setItem">;
type StorageRemover = Pick<Storage, "removeItem">;

function resolveStorage(): Storage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null;
  }
}

export function readFileSearchHistory(storageKey: string, storage: StorageReader | null = resolveStorage()): string[] {
  if (!storageKey || !storage) return [];
  try {
    const raw = storage.getItem(storageKey);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((item): item is string => typeof item === "string" && item.trim().length > 0)
      .slice(0, FILE_SEARCH_HISTORY_MAX);
  } catch {
    return [];
  }
}

export function recordFileSearchHistory(
  storageKey: string,
  query: string,
  max = FILE_SEARCH_HISTORY_MAX,
  storage: StorageWriter | null = resolveStorage(),
): string[] {
  const trimmed = query.trim();
  if (!storageKey || !trimmed) return readFileSearchHistory(storageKey, storage);
  const existing = readFileSearchHistory(storageKey, storage);
  const next = [trimmed, ...existing.filter((item) => item.toLowerCase() !== trimmed.toLowerCase())].slice(0, max);
  try {
    storage?.setItem(storageKey, JSON.stringify(next));
  } catch {
    // Private browsing or storage quota errors must never block search execution.
  }
  return next;
}

export function removeFileSearchHistory(
  storageKey: string,
  query: string,
  storage: StorageWriter | null = resolveStorage(),
): string[] {
  if (!storageKey) return [];
  const next = readFileSearchHistory(storageKey, storage).filter((item) => item !== query);
  try {
    storage?.setItem(storageKey, JSON.stringify(next));
  } catch {
    // Ignore storage persistence errors.
  }
  return next;
}

export function clearFileSearchHistory(
  storageKey: string,
  storage: StorageRemover | null = resolveStorage(),
): string[] {
  if (!storageKey || !storage) return [];
  try {
    storage.removeItem(storageKey);
  } catch {
    // Ignore storage removal errors.
  }
  return [];
}

/**
 * Scrolls a revealed file entry row into center viewport while honoring reduced motion.
 */
export function scrollRevealedFileIntoView(revealedPath: string | null) {
  if (!revealedPath || typeof document === "undefined") return;
  const escaped =
    typeof CSS !== "undefined" && typeof CSS.escape === "function"
      ? CSS.escape(revealedPath)
      : revealedPath.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  const row = document.querySelector<HTMLElement>(`.file-entry[data-file-path="${escaped}"]`);
  const reduced = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  row?.scrollIntoView({ block: "center", behavior: reduced ? "auto" : "smooth" });
}
