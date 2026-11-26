import { ISLE_CHART_COLORS } from "../../components/ui/isleChartsMath.ts";
import { formatBytes } from "../photos/photoPresentation.ts";
import type { DuplicateFileGroup } from "../photos/usePhotoAISearchAndPeople.ts";

export interface RootOption {
  rootID: string;
  name: string;
  generation: number;
  online: boolean;
  isDefault?: boolean;
}

export interface DuplicateScanProgress {
  phase: string;
  scannedFiles: number;
  candidateFiles?: number;
  hashedFiles?: number;
  currentPath?: string;
}

export interface DuplicateScanResponse {
  running: boolean;
  progress?: DuplicateScanProgress;
  lastDone?: number;
  lastError?: string;
  quotaReleaseNote?: string;
  result?: {
    minSizeBytes: number;
    scannedFiles: number;
    totalGroups: number;
    totalReclaimableBytes: number;
    totalReclaimablePhysicalBytes: number;
    truncated?: boolean;
    groups: DuplicateFileGroup[];
  };
}

export const DUPLICATE_MIN_SIZE_OPTIONS = [
  { value: 1, label: "大于等于 1 MB" },
  { value: 10, label: "大于等于 10 MB" },
  { value: 100, label: "大于等于 100 MB" },
];

export function buildDedupeSavingsChart(result: DuplicateScanResponse["result"] | undefined) {
  if (!result || !result.groups.length) return null;
  const keepBytes = result.groups.reduce((sum, g) => sum + Math.max(0, g.size), 0);
  const reclaimableBytes = Math.max(0, result.totalReclaimableBytes);
  const totalBytes = keepBytes + reclaimableBytes;
  if (totalBytes <= 0) return null;
  const savedPercent = Math.round((reclaimableBytes / totalBytes) * 100);
  return {
    totalBytes,
    savedPercent,
    segments: [
      { key: "keep", label: "保留原件体积", value: keepBytes, color: ISLE_CHART_COLORS.blue, displayValue: formatBytes(keepBytes) },
      { key: "reclaim", label: "可释放冗余空间", value: reclaimableBytes, color: ISLE_CHART_COLORS.green, displayValue: formatBytes(reclaimableBytes) },
    ],
  };
}

export function formatDuplicateScanProgress(progress: DuplicateScanProgress | undefined): string {
  if (!progress) return "正在准备扫描授权目录…";
  switch (progress.phase) {
    case "walking":
      return `正在遍历目录 · 已发现 ${progress.scannedFiles} 个候选文件`;
    case "sampling":
      return `正在比对首尾采样指纹 · 候选 ${progress.candidateFiles ?? 0} 个文件`;
    case "hashing":
      return `正在核验完整 SHA-256 指纹 · 已完成 ${progress.hashedFiles ?? 0}/${progress.candidateFiles ?? 0}`;
    default:
      return `正在核对重复文件指纹（已扫描 ${progress.scannedFiles} 项）…`;
  }
}

export function calculateSelectedTrashBytes(
  groups: DuplicateFileGroup[],
  checkedByGroup: Record<string, Set<string>>,
): number {
  let total = 0;
  for (const g of groups) {
    const set = checkedByGroup[g.groupId];
    if (!set?.size) continue;
    for (const item of g.items) {
      if (set.has(item.path) && item.canTrash) total += item.size;
    }
  }
  return total;
}

export function splitDuplicatePath(fullPath: string): { fileName: string; parentFolder: string } {
  const normalized = fullPath.replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
  if (!normalized) return { fileName: fullPath, parentFolder: "根目录" };
  const slash = normalized.lastIndexOf("/");
  if (slash < 0) return { fileName: normalized, parentFolder: "根目录" };
  return {
    fileName: normalized.slice(slash + 1) || normalized,
    parentFolder: normalized.slice(0, slash) || "根目录",
  };
}

export function isDuplicateThumbnailEligible(name: string): boolean {
  return /\.(jpe?g|png|gif|webp|avif|heic|heif|mp4|mov|m4v)$/i.test(name);
}

export type DuplicateFileKind = "image" | "video" | "audio" | "archive" | "doc";

export function getDuplicateFileKind(name: string): DuplicateFileKind {
  if (/\.(jpe?g|png|gif|webp|avif|bmp|heic|heif)$/i.test(name)) return "image";
  if (/\.(mp4|webm|m4v|mov|mkv|avi|mpe?g|m2?ts|3gp|wmv|flv)$/i.test(name)) return "video";
  if (/\.(mp3|m4a|flac|wav|ogg|aac|opus)$/i.test(name)) return "audio";
  if (/\.(zip|tar|gz|tgz|bz2|xz|7z|rar|dmg|pkg|iso)$/i.test(name)) return "archive";
  return "doc";
}
