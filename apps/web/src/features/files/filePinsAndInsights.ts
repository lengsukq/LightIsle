import { computed, ref } from "vue";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import type { SharedFileEntry } from "./useFileShares.ts";

export interface FilePin {
  rootId: string;
  rootGeneration: number;
  path: string;
  kind: "file" | "folder";
  label: string;
  pinnedAt: number;
  exists: boolean;
  size?: number;
  modified?: string;
  canWrite: boolean;
}

export type FileInsightMode = "large" | "recent";

export interface FileInsightItem {
  name: string;
  path: string;
  parentDir: string;
  size: number;
  modified: string;
  modifiedAt: number;
  ext?: string;
  canWrite: boolean;
}

export interface FileInsightResult {
  mode: FileInsightMode;
  minBytes?: number;
  days?: number;
  scannedFiles: number;
  matchedFiles: number;
  totalBytes: number;
  truncated: boolean;
  timedOut?: boolean;
  items: FileInsightItem[];
}

export interface FilePinsDependencies {
  canList: () => boolean;
  context: () => string;
  apiPath: (path: string) => string;
  read: <T>(path: string) => Promise<T>;
  write: <T>(path: string, body: object) => Promise<T>;
  remove: (path: string) => Promise<void>;
  isAbort?: (error: unknown) => boolean;
}

export interface FileInsightsDependencies {
  canList: () => boolean;
  context: () => string;
  apiPath: (path: string) => string;
  read: <T>(path: string) => Promise<T>;
  trashFile: (path: string) => Promise<void>;
  confirm: (opts: {
    title?: string;
    message: string;
    confirmText?: string;
    variant?: "default" | "danger";
  }) => boolean | Promise<boolean>;
  onFileTrashed?: () => Promise<unknown> | void;
  isAbort?: (error: unknown) => boolean;
}

export const LARGE_FILE_MIN_OPTIONS = [
  { value: 10 * 1024 * 1024, label: "≥ 10 MiB" },
  { value: 50 * 1024 * 1024, label: "≥ 50 MiB" },
  { value: 200 * 1024 * 1024, label: "≥ 200 MiB" },
  { value: 500 * 1024 * 1024, label: "≥ 500 MiB" },
  { value: 1024 * 1024 * 1024, label: "≥ 1 GiB" },
];

export const RECENT_DAYS_OPTIONS = [
  { value: 1, label: "最近 1 天" },
  { value: 3, label: "最近 3 天" },
  { value: 7, label: "最近 7 天" },
  { value: 30, label: "最近 30 天" },
  { value: 90, label: "最近 90 天" },
];

export function buildInsightsQueryParams(opts: {
  mode: FileInsightMode;
  path?: string;
  minBytes?: number;
  days?: number;
  limit?: number;
}): string {
  const params = new URLSearchParams();
  params.set("mode", opts.mode);
  params.set("path", opts.path && opts.path.trim() ? opts.path.trim() : ".");
  if (opts.mode === "large" && typeof opts.minBytes === "number" && opts.minBytes >= 0) {
    params.set("minBytes", String(Math.trunc(opts.minBytes)));
  }
  if (opts.mode === "recent" && typeof opts.days === "number" && opts.days >= 1) {
    params.set("days", String(Math.min(365, Math.max(1, Math.trunc(opts.days)))));
  }
  if (typeof opts.limit === "number" && opts.limit >= 1) {
    params.set("limit", String(Math.min(200, Math.trunc(opts.limit))));
  }
  return params.toString();
}

export function pinDisplayLabel(pin: Pick<FilePin, "label" | "path">): string {
  const trimmed = pin.label?.trim();
  if (trimmed) return trimmed;
  const parts = pin.path.split("/").filter(Boolean);
  return parts[parts.length - 1] || pin.path;
}

export function describePinError(error: unknown, fallbackPrefix = "置顶操作失败："): string {
  return fallbackPrefix + describeUserFacingError(error);
}

export function useFilePins(deps: FilePinsDependencies) {
  const pins = ref<FilePin[]>([]);
  const pinsLoading = ref(false);
  const pinsLoaded = ref(false);
  const pinsError = ref("");
  const togglingPinPath = ref("");

  let contextGeneration = 0;
  let loadGeneration = 0;

  const pinnedPathSet = computed(() => new Set(pins.value.map((p) => p.path)));

  function isPinned(path: string): boolean {
    return pinnedPathSet.value.has(path);
  }

  function reset() {
    contextGeneration += 1;
    loadGeneration += 1;
    pins.value = [];
    pinsLoading.value = false;
    pinsLoaded.value = false;
    pinsError.value = "";
    togglingPinPath.value = "";
  }

  async function loadPins(force = false) {
    if (!deps.canList()) return;
    if (pinsLoading.value && !force) return;
    const req = ++loadGeneration;
    const scope = contextGeneration;
    const ctx = deps.context();
    pinsLoading.value = true;
    pinsError.value = "";
    try {
      const res = await deps.read<{ pins: FilePin[] }>(deps.apiPath("/api/v2/files/pins"));
      if (req !== loadGeneration || scope !== contextGeneration || ctx !== deps.context() || !deps.canList()) {
        return;
      }
      pins.value = Array.isArray(res?.pins) ? res.pins : [];
      pinsLoaded.value = true;
    } catch (error) {
      if (req === loadGeneration && scope === contextGeneration && ctx === deps.context() && !deps.isAbort?.(error)) {
        pinsError.value = describePinError(error, "读取常用置顶失败：");
      }
    } finally {
      if (req === loadGeneration && scope === contextGeneration) {
        pinsLoading.value = false;
      }
    }
  }

  async function addPin(path: string, label?: string): Promise<boolean> {
    if (!deps.canList() || !path || path === "." || togglingPinPath.value) return false;
    const scope = contextGeneration;
    const ctx = deps.context();
    togglingPinPath.value = path;
    pinsError.value = "";
    try {
      const body: Record<string, string> = { path };
      if (label?.trim()) body.label = label.trim();
      const res = await deps.write<{ pin: FilePin }>(deps.apiPath("/api/v2/files/pins"), body);
      if (scope !== contextGeneration || ctx !== deps.context() || !deps.canList()) return false;
      const next = pins.value.filter((p) => p.path !== res.pin.path);
      pins.value = [res.pin, ...next];
      pinsLoaded.value = true;
      return true;
    } catch (error) {
      if (scope === contextGeneration && ctx === deps.context() && !deps.isAbort?.(error)) {
        pinsError.value = describePinError(error, "置顶失败：");
      }
      return false;
    } finally {
      if (togglingPinPath.value === path) togglingPinPath.value = "";
    }
  }

  async function removePin(path: string): Promise<boolean> {
    if (!deps.canList() || !path || togglingPinPath.value) return false;
    const scope = contextGeneration;
    const ctx = deps.context();
    togglingPinPath.value = path;
    pinsError.value = "";
    try {
      await deps.remove(deps.apiPath("/api/v2/files/pins") + "?path=" + encodeURIComponent(path));
      if (scope !== contextGeneration || ctx !== deps.context() || !deps.canList()) return false;
      pins.value = pins.value.filter((p) => p.path !== path);
      return true;
    } catch (error) {
      if (scope === contextGeneration && ctx === deps.context() && !deps.isAbort?.(error)) {
        pinsError.value = describePinError(error, "取消置顶失败：");
      }
      return false;
    } finally {
      if (togglingPinPath.value === path) togglingPinPath.value = "";
    }
  }

  async function togglePin(entry: Pick<SharedFileEntry, "path" | "name">): Promise<boolean> {
    if (isPinned(entry.path)) {
      return removePin(entry.path);
    }
    return addPin(entry.path, entry.name);
  }

  return {
    pins,
    pinsLoading,
    pinsLoaded,
    pinsError,
    togglingPinPath,
    isPinned,
    loadPins,
    addPin,
    removePin,
    togglePin,
    reset,
  };
}

export function useFileInsights(deps: FileInsightsDependencies) {
  const mode = ref<FileInsightMode>("large");
  const scopePath = ref(".");
  const minBytes = ref(50 * 1024 * 1024);
  const recentDays = ref(7);
  const limit = ref(100);
  const result = ref<FileInsightResult | null>(null);
  const loading = ref(false);
  const error = ref("");
  const trashingPath = ref("");

  let contextGeneration = 0;
  let scanGeneration = 0;

  function reset() {
    contextGeneration += 1;
    scanGeneration += 1;
    result.value = null;
    loading.value = false;
    error.value = "";
    trashingPath.value = "";
  }

  async function loadInsights(override?: {
    mode?: FileInsightMode;
    path?: string;
    minBytes?: number;
    days?: number;
  }) {
    if (!deps.canList()) return;
    if (override?.mode) mode.value = override.mode;
    if (override?.path !== undefined) scopePath.value = override.path || ".";
    if (override?.minBytes !== undefined) minBytes.value = override.minBytes;
    if (override?.days !== undefined) recentDays.value = override.days;

    const req = ++scanGeneration;
    const scope = contextGeneration;
    const ctx = deps.context();
    loading.value = true;
    error.value = "";
    try {
      const qs = buildInsightsQueryParams({
        mode: mode.value,
        path: scopePath.value,
        minBytes: minBytes.value,
        days: recentDays.value,
        limit: limit.value,
      });
      const res = await deps.read<FileInsightResult>(deps.apiPath("/api/v2/files/insights") + "?" + qs);
      if (req !== scanGeneration || scope !== contextGeneration || ctx !== deps.context() || !deps.canList()) {
        return;
      }
      result.value = res;
    } catch (err) {
      if (req === scanGeneration && scope === contextGeneration && ctx === deps.context() && !deps.isAbort?.(err)) {
        error.value = "扫描文件失败：" + describeUserFacingError(err);
      }
    } finally {
      if (req === scanGeneration && scope === contextGeneration) {
        loading.value = false;
      }
    }
  }

  async function trashInsightItem(item: FileInsightItem): Promise<boolean> {
    if (!deps.canList() || !item.canWrite || trashingPath.value) return false;
    const scope = contextGeneration;
    const ctx = deps.context();
    const ok = await deps.confirm({
      title: "移到回收站？",
      message: `“${item.name}”将从「${item.parentDir === "." ? "根目录" : item.parentDir}」移入内部回收站，暂不会永久删除。`,
      confirmText: "确认移入",
      variant: "danger",
    });
    if (!ok || scope !== contextGeneration || ctx !== deps.context() || !deps.canList()) {
      return false;
    }
    trashingPath.value = item.path;
    error.value = "";
    try {
      await deps.trashFile(item.path);
      if (scope !== contextGeneration || ctx !== deps.context()) return false;
      if (result.value) {
        const remaining = result.value.items.filter((it) => it.path !== item.path);
        result.value = {
          ...result.value,
          items: remaining,
          matchedFiles: Math.max(0, result.value.matchedFiles - 1),
          totalBytes: Math.max(0, result.value.totalBytes - item.size),
        };
      }
      await deps.onFileTrashed?.();
      return true;
    } catch (err) {
      if (scope === contextGeneration && ctx === deps.context() && !deps.isAbort?.(err)) {
        error.value = "移入回收站失败：" + describeUserFacingError(err);
      }
      return false;
    } finally {
      if (trashingPath.value === item.path) trashingPath.value = "";
    }
  }

  return {
    mode,
    scopePath,
    minBytes,
    recentDays,
    limit,
    result,
    loading,
    error,
    trashingPath,
    loadInsights,
    trashInsightItem,
    reset,
  };
}
