import { ISLE_CHART_COLORS, type ChartSegmentInput } from "./isleChartsMath.ts";
import type { ServerStats } from "./useHostTelemetry.ts";

export type PersonalSpaceSummary = {
  quotaBytes: number | null;
  rootQuotas: Array<{rootID:string;rootGeneration:number;quotaBytes:number|null;accountedBytes:number;reservedBytes:number}>;
  accountedBytes: number;
  reservedBytes: number;
  usageComplete: boolean;
  enforcement: string;
  locations: Array<{ category: string; rootID: string }>;
};

export type OverviewIdentity = { username: string; isAdmin: boolean };
export type OverviewPending = {
  offlineCount: number;
  rootsError: string;
  rootsKnown: boolean;
  rootName: string;
  tasksLoaded: boolean;
  tasksLoading: boolean;
  tasksError: string;
  failedTasks: number;
};
export type OverviewSearch = {
  query: string;
  spotlight: boolean;
  filesLoading: boolean;
  searchingFiles: boolean;
  recentQueries?: string[];
};
export type OverviewTelemetry = {
  error: string | null;
  stats: ServerStats | null;
  polling: boolean;
  cpu: number | null;
  usedMemory: number | null;
  usedDisk: number | null;
  diskActivity: string | null;
  cpuHistory?: number[];
  memoryHistory?: number[];
  expanded: boolean;
  bytes: (value: number) => string;
  percent: (value: number) => number;
};
export type OverviewPersonalSpace = {
  summary: PersonalSpaceSummary | null;
  error: string;
  bytes: (value: number) => string;
  rootNames?: Record<string, string>;
};

export function buildQuotaSegments(
  accountedBytes: number,
  reservedBytes: number,
  quotaBytes: number,
  formatBytes: (value: number) => string,
): ChartSegmentInput[] {
  const accounted = Math.max(0, accountedBytes);
  const reserved = Math.max(0, reservedBytes);
  const available = Math.max(0, quotaBytes - accounted - reserved);
  return [
    { key: "accounted", label: "已入账空间", value: accounted, color: ISLE_CHART_COLORS.blue, displayValue: formatBytes(accounted) },
    { key: "reserved", label: "传输预占", value: reserved, color: ISLE_CHART_COLORS.amber, displayValue: formatBytes(reserved) },
    { key: "available", label: "剩余额度", value: available, color: ISLE_CHART_COLORS.green, displayValue: formatBytes(available) },
  ];
}

export function buildHostMemorySegments(
  stats: ServerStats,
  formatBytes: (value: number) => string,
): ChartSegmentInput[] {
  const used = Math.max(0, stats.memoryUsed);
  const free = Math.max(0, stats.memoryTotal - used);
  if (stats.coreRssBytes != null && Number.isFinite(stats.coreRssBytes)) {
    const core = Math.min(used, Math.max(0, stats.coreRssBytes));
    const systemOther = Math.max(0, used - core);
    return [
      { key: "core", label: "轻屿服务", value: core, color: ISLE_CHART_COLORS.purple, displayValue: formatBytes(core) },
      { key: "other", label: "系统其他占用", value: systemOther, color: ISLE_CHART_COLORS.blue, displayValue: formatBytes(systemOther) },
      { key: "free", label: "可用内存", value: free, color: ISLE_CHART_COLORS.green, displayValue: formatBytes(free) },
    ];
  }
  return [
    { key: "used", label: "已用内存", value: used, color: ISLE_CHART_COLORS.blue, displayValue: formatBytes(used) },
    { key: "free", label: "可用内存", value: free, color: ISLE_CHART_COLORS.green, displayValue: formatBytes(free) },
  ];
}

export function buildHostDiskSegments(
  stats: ServerStats,
  formatBytes: (value: number) => string,
): ChartSegmentInput[] {
  const free = Math.max(0, stats.diskFree);
  const used = Math.max(0, stats.diskTotal - free);
  return [
    { key: "used", label: "磁盘已用", value: used, color: ISLE_CHART_COLORS.teal, displayValue: formatBytes(used) },
    { key: "free", label: "磁盘可用", value: free, color: ISLE_CHART_COLORS.slate, displayValue: formatBytes(free) },
  ];
}
