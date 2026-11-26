import { hasWebModule } from "../apps/appsCenterApi.ts";
import { appMode, appStatus, categoryLabel } from "../../composables/useAppsCenterController.ts";
import { ISLE_CHART_COLORS, type ChartSegmentInput } from "../../components/ui/isleChartsMath.ts";
import type { PublicAppItem } from "../../types/appsCenter.ts";
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
export type OverviewApps = {
  items: PublicAppItem[];
  loading: boolean;
  error: string;
};

/** Whether a home tile app is ready to launch directly into the workbench without admin activation or repair. */
export function isHomeAppReady(app: PublicAppItem): boolean {
  return (
    !app.pendingActivation &&
    app.valid !== false &&
    !app.lastError &&
    !app.validationError &&
    !app.web?.lastError &&
    !app.diagnostic
  );
}

/** Filters `/api/v2/apps` items down to web-enabled home tiles and sorts ready apps first. */
export function filterHomeLaunchableApps(apps: PublicAppItem[]): PublicAppItem[] {
  const launchable = apps.filter(
    (app) => app.web?.enabled !== false && hasWebModule(app),
  );
  return launchable.sort((a, b) => {
    const aReady = isHomeAppReady(a);
    const bReady = isHomeAppReady(b);
    if (aReady !== bReady) return aReady ? -1 : 1;
    return a.id.localeCompare(b.id);
  });
}

const HOME_APP_CATEGORY_KEYS = new Set(["network", "media", "finance", "utility", "system", "automation"]);

/** Normalizes an app category into one of the known icon/color keys. */
export function homeAppCategoryKey(category?: string): string {
  return category && HOME_APP_CATEGORY_KEYS.has(category) ? category : "default";
}

/** Resolves role-safe badge text and tone for a home-page app tile without runtime memory noise. */
export function homeAppBadge(
  app: PublicAppItem,
  isAdmin: boolean,
): { text: string; tone: "ready" | "running" | "warn" | "neutral" } {
  if (!isAdmin) return { text: "免密即开", tone: "ready" };
  if (app.pendingActivation) return { text: "待首次激活", tone: "warn" };
  if (!isHomeAppReady(app)) return { text: "启动异常", tone: "warn" };
  const status = appStatus(app);
  const mode = appMode(app);
  if (status === "running") return { text: "运行中", tone: "running" };
  if (status === "starting") return { text: "唤醒中", tone: "running" };
  if (mode === "persistent") return { text: "未启动", tone: "neutral" };
  return { text: "就绪", tone: "ready" };
}

export { categoryLabel as homeAppCategoryLabel };

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
