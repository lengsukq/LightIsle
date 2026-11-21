import { formatDateTime } from "./dateTimeFormat.ts";

const STANDARD_UNITS = ["B", "KB", "MB", "GB", "TB", "PB"] as const;
const BINARY_UNITS = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"] as const;

export interface FormatBytesOptions {
  /** Use IEC binary unit labels (KiB/MiB/GiB/TiB) instead of KB/MB/GB/TB. */
  binary?: boolean;
  /** Value returned when input is NaN, Infinity, or negative/zero (when emptyOnZero is set). */
  invalidFallback?: string;
  /** Return empty string for 0 or missing values (used in optional badges). */
  emptyOnZero?: boolean;
  /** Minimum unit index to start formatting from (e.g. 2 for MB/MiB). */
  minUnitIndex?: number;
  /** Compact large numbers (>=100 or >=10 GB) without unnecessary decimal places. */
  compact?: boolean;
  /** Number of decimals for GB/TB when not compact (defaults to 2 for GB+, 1 for MB, 0/1 for KB). */
  kbDecimals?: number;
  gbDecimals?: number;
}

/** Single source of truth for formatting byte sizes across Web views and telemetry. */
export function formatBytes(value: number | null | undefined, options: FormatBytesOptions = {}): string {
  const {
    binary = false,
    invalidFallback = "0 B",
    emptyOnZero = false,
    minUnitIndex = 0,
    compact = false,
    kbDecimals = 1,
    gbDecimals = 2,
  } = options;

  if (value === null || value === undefined || !Number.isFinite(value)) {
    return emptyOnZero ? "" : invalidFallback;
  }
  if (value <= 0) {
    return emptyOnZero ? "" : "0 B";
  }

  const units = binary ? BINARY_UNITS : STANDARD_UNITS;
  let scaled = value;
  let unitIdx = 0;

  while (unitIdx < minUnitIndex && unitIdx < units.length - 1) {
    scaled /= 1024;
    unitIdx += 1;
  }
  while (scaled >= 1024 && unitIdx < units.length - 1) {
    scaled /= 1024;
    unitIdx += 1;
  }

  if (unitIdx === 0) return `${Math.round(scaled)} ${units[0]}`;

  if (compact) {
    const decimals = unitIdx <= 1 ? 0 : unitIdx === 2 ? (scaled >= 100 ? 0 : 1) : (scaled >= 10 ? 0 : 1);
    return `${scaled.toFixed(decimals)} ${units[unitIdx]}`;
  }

  const decimals = unitIdx === 1 ? kbDecimals : unitIdx === 2 ? 1 : gbDecimals;
  return `${scaled.toFixed(decimals)} ${units[unitIdx]}`;
}

/** Format byte sizes using explicit IEC binary units (B / KiB / MiB / GiB / TiB). */
export function formatBinaryBytes(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value) || value <= 0) return "0 B";
  return formatBytes(value, { binary: true, kbDecimals: 0, gbDecimals: 1 });
}

/** Format byte size strictly in MB for resumable upload offset/size comparisons. */
export function formatMegabytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "0 MB";
  return `${new Intl.NumberFormat("zh-CN", { maximumFractionDigits: 1 }).format(value / (1024 * 1024))} MB`;
}

/** Format Unix epoch seconds into a localized date-time string via shared Intl formatter. */
export function formatUnixDateTime(seconds?: number | null, fallback = ""): string {
  if (seconds === null || seconds === undefined || !Number.isFinite(seconds) || seconds <= 0) {
    return fallback;
  }
  return formatDateTime(seconds * 1000) || fallback;
}
