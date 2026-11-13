import { ISLE_CHART_COLORS } from "./isleChartsMath.ts";

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

export const DISK_ERROR_MESSAGES: Record<string, string> = {
  invalid_drive_request: "磁盘标识或名称无效，请检查输入。",
  drive_identity_changed_refresh_required: "设备身份已变化，请刷新列表后再操作。",
  drive_in_use_or_protected: "该硬盘仍被 NAS 或备份占用，不能执行此操作。先切换存储目录并停止相关任务。",
  drive_operation_busy: "后台正在处理存储任务，请稍后重试。",
  drive_operation_not_supported: "此磁盘或控制器不支持受控操作。可以使用 macOS 磁盘工具。",
  drive_discovery_unavailable: "暂时无法读取 macOS 硬盘列表。",
  diskutil_operation_failed: "macOS 拒绝此操作：磁盘可能正被系统或其他应用使用。",
  admin_only: "仅管理员能够管理硬盘。",
};

const SMART_REASONS: Record<string, string> = {
  smartctl_not_installed: "未安装 smartmontools，无法读取详细健康信息。可执行 brew install smartmontools 后重试；当前仅显示 macOS 基础 SMART 状态。",
  smartctl_permission_required: "macOS 限制普通权限进程直读设备 SMART，详细数据需要管理员权限；当前仅显示 macOS 基础 SMART 状态。",
  smartctl_device_unsupported: "该磁盘的桥接芯片或控制器不支持通过 smartctl 读取 SMART；当前仅显示 macOS 基础 SMART 状态。",
  smartctl_query_failed: "SMART 查询失败，请稍后重试。",
};

export function describeSmartReason(report?: SmartReport): string {
  if (!report) return "正在读取健康信息…";
  return SMART_REASONS[report.reason ?? ""] ?? "暂时无法读取该磁盘的健康详情。";
}

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
