import { ISLE_CHART_COLORS } from "../../components/ui/isleChartsMath.ts";

export type Disk = {
  id: string;
  name: string;
  parent: string;
  mount: string;
  filesystem: string;
  protocol: string;
  smart: string;
  total: number;
  free: number;
  readOnly: boolean;
  mounted: boolean;
  external: boolean;
  identity: string;
};

export type HealthSample = {
  timestamp: number;
  source: string;
  reason?: string;
  temperature?: number;
  passed: boolean | null;
  lifeUsed?: number;
  powerOnHours?: number;
  risk: string;
};

export type SmartReport = {
  device: string;
  source: string;
  reason?: string;
  model?: string;
  serial?: string;
  firmware?: string;
  temperature?: number;
  passed?: boolean;
  powerOnHours?: number;
  lifeUsed?: number;
};

export type Volume = {
  name: string;
  mount: string;
  device: string;
  filesystem: string;
  total: number;
  free: number;
  readOnly: boolean;
};

export function formatDiskSize(size: number): string {
  if (!Number.isFinite(size) || size < 0) return "未知";
  if (size === 0) return "0 B";
  if (size < 1024 ** 2) return (size / 1024).toFixed(0) + " KB";
  if (size < 1024 ** 3) return (size / 1024 ** 2).toFixed(1) + " MB";
  const gib = size / 1024 ** 3;
  if (gib >= 1000) return (size / 1024 ** 4).toFixed(2) + " TB";
  return gib.toFixed(1) + " GB";
}

export function diskUsedPercent(d: Disk): number {
  return Math.min(100, Math.max(0, Math.round(((d.total - d.free) / Math.max(1, d.total)) * 100)));
}

export function isSystemDiskPartition(d: Disk): boolean {
  const fs = (d.filesystem ?? "").toUpperCase();
  const name = (d.name ?? "").trim();
  const proto = (d.protocol ?? "").trim();
  const isEfi = /^efi$/i.test(name) && fs.includes("FAT") && d.total > 0 && d.total < 2 * 1024 ** 3;
  const isDiskImage = /disk\s*image/i.test(proto) || /disk\s*image/i.test(name);
  return isEfi || isDiskImage;
}

export function isSystemVolume(v: Volume, systemDiskMounts?: ReadonlySet<string>): boolean {
  const mount = (v.mount ?? "").trim();
  const name = (v.name ?? "").trim();
  if (!mount) return false;
  if (mount === "/Volumes/Recovery" || mount.startsWith("/Volumes/Recovery/")) return true;
  if (mount === "/System/Volumes" || mount.startsWith("/System/Volumes/")) return true;
  if (name === "Recovery" && (mount === "/Volumes/Recovery" || mount.startsWith("/System/"))) return true;
  if (systemDiskMounts?.has(mount)) return true;
  if (mount.startsWith("/Volumes/")) {
    if (/^Gemini(\s|$|-)/i.test(name) || /\.dmg$/i.test(name) || /disk\s*image/i.test(name)) {
      return true;
    }
  }
  return false;
}

export function healthRiskLabel(risk?: string): string {
  switch (risk) {
    case "critical": return "严重：SMART 自检明确失败";
    case "warning": return "注意：温度或寿命达到提示阈值";
    case "ok": return "当前已读取指标未触发预设阈值";
    default: return "未知：无法证明磁盘健康";
  }
}

export function diskUsageSegments(total: number, free: number) {
  const safeTotal = Math.max(0, total);
  const safeFree = Math.min(safeTotal, Math.max(0, free));
  const used = Math.max(0, safeTotal - safeFree);
  return [
    { key: "used", label: "已用空间", value: used, color: ISLE_CHART_COLORS.blue, displayValue: formatDiskSize(used) },
    { key: "free", label: "可用空间", value: safeFree, color: ISLE_CHART_COLORS.green, displayValue: formatDiskSize(safeFree) },
  ];
}
