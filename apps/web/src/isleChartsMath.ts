export interface ChartSegmentInput {
  key?: string;
  label: string;
  value: number;
  color?: string;
  displayValue?: string;
  hint?: string;
}

export interface DonutArcSegment {
  key: string;
  label: string;
  value: number;
  share: number;
  percentLabel: string;
  color: string;
  dashArray: string;
  dashOffset: number;
  displayValue?: string;
  hint?: string;
}

export interface SegmentedBarPart {
  key: string;
  label: string;
  value: number;
  share: number;
  percent: number;
  widthPercent: number;
  percentLabel: string;
  color: string;
  displayValue?: string;
  hint?: string;
}

export interface SparklineGeometry {
  linePath: string;
  areaPath: string;
  lastX: number;
  lastY: number;
  min: number;
  max: number;
  validCount: number;
}

export const ISLE_CHART_COLORS = {
  blue: "#0071e3",
  green: "#34c759",
  amber: "#ff9f0a",
  purple: "#8c6eef",
  teal: "#10b981",
  cyan: "#32ade6",
  rose: "#ff3b30",
  slate: "rgba(142, 142, 147, 0.42)",
} as const;

export const ISLE_CHART_PALETTE = [
  ISLE_CHART_COLORS.blue,
  ISLE_CHART_COLORS.green,
  ISLE_CHART_COLORS.amber,
  ISLE_CHART_COLORS.purple,
  ISLE_CHART_COLORS.cyan,
  ISLE_CHART_COLORS.rose,
] as const;

function finiteNonNegative(value: number): number {
  return Number.isFinite(value) && value > 0 ? value : 0;
}

/**
 * Computes a bounded [0, 1] ratio, returning 0 for invalid or zero denominators.
 */
export function clampRatio(numerator: number, denominator: number): number {
  if (!Number.isFinite(numerator) || !Number.isFinite(denominator) || denominator <= 0) return 0;
  return Math.min(1, Math.max(0, numerator / denominator));
}

/**
 * Formats a normalized [0, 1] share into a concise human percentage badge.
 */
export function formatSharePercent(share: number): string {
  if (!Number.isFinite(share) || share <= 0) return "0%";
  if (share < 0.005) return "<1%";
  return `${Math.min(100, Math.round(share * 100))}%`;
}

/**
 * Computes SVG stroke-dasharray / stroke-dashoffset geometry for donut charts.
 */
export function buildDonutSegments(
  items: readonly ChartSegmentInput[],
  opts: { total?: number; radius?: number } = {},
): { segments: DonutArcSegment[]; total: number; sumValue: number; usedPercent: number } {
  const radius = Math.max(4, opts.radius ?? 28);
  const circumference = 2 * Math.PI * radius;
  const clean = items.map((item, idx) => ({
    ...item,
    key: item.key ?? `${idx}:${item.label}`,
    cleanValue: finiteNonNegative(item.value),
    resolvedColor: item.color || ISLE_CHART_PALETTE[idx % ISLE_CHART_PALETTE.length],
  }));

  const sumValue = clean.reduce((sum, item) => sum + item.cleanValue, 0);
  const requestedTotal = finiteNonNegative(opts.total ?? 0);
  const total = requestedTotal > 0 ? Math.max(requestedTotal, sumValue) : sumValue;

  if (total <= 0) {
    return {
      segments: clean.map((item) => ({
        key: item.key,
        label: item.label,
        value: item.cleanValue,
        share: 0,
        percentLabel: "0%",
        color: item.resolvedColor,
        dashArray: `0 ${circumference.toFixed(2)}`,
        dashOffset: 0,
        displayValue: item.displayValue,
        hint: item.hint,
      })),
      total: 0,
      sumValue: 0,
      usedPercent: 0,
    };
  }

  let offsetAcc = 0;
  const segments: DonutArcSegment[] = clean.map((item) => {
    const share = clampRatio(item.cleanValue, total);
    const arcLen = share * circumference;
    const segment: DonutArcSegment = {
      key: item.key,
      label: item.label,
      value: item.cleanValue,
      share,
      percentLabel: formatSharePercent(share),
      color: item.resolvedColor,
      dashArray: `${arcLen.toFixed(2)} ${circumference.toFixed(2)}`,
      dashOffset: offsetAcc === 0 ? 0 : Number((-offsetAcc).toFixed(2)),
      displayValue: item.displayValue,
      hint: item.hint,
    };
    offsetAcc += arcLen;
    return segment;
  });

  return {
    segments,
    total,
    sumValue,
    usedPercent: Math.round(clampRatio(sumValue, total) * 100),
  };
}

/**
 * Computes proportional widths and honest shares for Apple-style multi-color segmented bars.
 */
export function buildSegmentedSegments(
  items: readonly ChartSegmentInput[],
  opts: { total?: number; minVisiblePercent?: number } = {},
): { parts: SegmentedBarPart[]; total: number; sumValue: number } {
  const minFloor = Math.min(4, Math.max(0, opts.minVisiblePercent ?? 1.5));
  const clean = items.map((item, idx) => ({
    ...item,
    key: item.key ?? `${idx}:${item.label}`,
    cleanValue: finiteNonNegative(item.value),
    resolvedColor: item.color || ISLE_CHART_PALETTE[idx % ISLE_CHART_PALETTE.length],
  }));

  const sumValue = clean.reduce((sum, item) => sum + item.cleanValue, 0);
  const requestedTotal = finiteNonNegative(opts.total ?? 0);
  const total = requestedTotal > 0 ? Math.max(requestedTotal, sumValue) : sumValue;

  if (total <= 0) {
    return {
      parts: clean.map((item) => ({
        key: item.key,
        label: item.label,
        value: item.cleanValue,
        share: 0,
        percent: 0,
        widthPercent: 0,
        percentLabel: "0%",
        color: item.resolvedColor,
        displayValue: item.displayValue,
        hint: item.hint,
      })),
      total: 0,
      sumValue: 0,
    };
  }

  const totalNaturalWidth = clampRatio(sumValue, total) * 100;
  const rawWidths = clean.map((item) => clampRatio(item.cleanValue, total) * 100);
  const tinyFlags = rawWidths.map((w, idx) => clean[idx].cleanValue > 0 && w < minFloor);
  const floorCount = tinyFlags.filter(Boolean).length;
  const effectiveFloor = floorCount > 0 && totalNaturalWidth > 0 ? Math.min(minFloor, totalNaturalWidth / Math.max(1, floorCount + 1)) : 0;
  const reservedForTiny = floorCount * effectiveFloor;
  const remainingTarget = Math.max(0, totalNaturalWidth - reservedForTiny);
  const remainingNatural = rawWidths.reduce((sum, w, idx) => (tinyFlags[idx] ? sum : sum + w), 0);

  const parts: SegmentedBarPart[] = clean.map((item, idx) => {
    const share = clampRatio(item.cleanValue, total);
    let widthPercent = 0;
    if (item.cleanValue > 0) {
      if (tinyFlags[idx]) {
        widthPercent = effectiveFloor;
      } else if (remainingNatural > 0) {
        widthPercent = (rawWidths[idx] / remainingNatural) * remainingTarget;
      }
    }
    return {
      key: item.key,
      label: item.label,
      value: item.cleanValue,
      share,
      percent: Math.round(share * 100),
      widthPercent: Number(widthPercent.toFixed(2)),
      percentLabel: formatSharePercent(share),
      color: item.resolvedColor,
      displayValue: item.displayValue,
      hint: item.hint,
    };
  });

  return { parts, total, sumValue };
}

/**
 * Builds smooth SVG stroke & gradient area paths for compact trend sparklines.
 */
export function buildSparklinePaths(
  points: readonly number[],
  opts: { width?: number; height?: number; padding?: number; minBound?: number; maxBound?: number } = {},
): SparklineGeometry {
  const width = Math.max(32, opts.width ?? 160);
  const height = Math.max(16, opts.height ?? 36);
  const padding = Math.min(height / 3, Math.max(2, opts.padding ?? 4));
  const clean = points.filter((v) => Number.isFinite(v));

  if (!clean.length) {
    return { linePath: "", areaPath: "", lastX: 0, lastY: height - padding, min: 0, max: 0, validCount: 0 };
  }

  const dataMin = Math.min(...clean);
  const dataMax = Math.max(...clean);
  const low = opts.minBound !== undefined && Number.isFinite(opts.minBound) ? Math.min(opts.minBound, dataMin) : dataMin;
  const high = opts.maxBound !== undefined && Number.isFinite(opts.maxBound) ? Math.max(opts.maxBound, dataMax) : dataMax;
  const span = high - low;
  const innerW = Math.max(1, width - padding * 2);
  const innerH = Math.max(1, height - padding * 2);
  const baselineY = height - padding;

  const toY = (val: number) => {
    if (span <= 0) return padding + innerH / 2;
    const norm = Math.min(1, Math.max(0, (val - low) / span));
    return Number((baselineY - norm * innerH).toFixed(2));
  };

  if (clean.length === 1) {
    const y = toY(clean[0]);
    const x1 = Number(padding.toFixed(2));
    const x2 = Number((width - padding).toFixed(2));
    return {
      linePath: `M ${x1} ${y} L ${x2} ${y}`,
      areaPath: `M ${x1} ${baselineY} L ${x1} ${y} L ${x2} ${y} L ${x2} ${baselineY} Z`,
      lastX: x2,
      lastY: y,
      min: dataMin,
      max: dataMax,
      validCount: 1,
    };
  }

  const coords = clean.map((val, idx) => ({
    x: Number((padding + (idx / (clean.length - 1)) * innerW).toFixed(2)),
    y: toY(val),
  }));

  let linePath = `M ${coords[0].x} ${coords[0].y}`;
  for (let i = 1; i < coords.length; i += 1) {
    const prev = coords[i - 1];
    const curr = coords[i];
    if (i === coords.length - 1) {
      linePath += ` L ${curr.x} ${curr.y}`;
    } else {
      const midX = Number(((prev.x + curr.x) / 2).toFixed(2));
      const midY = Number(((prev.y + curr.y) / 2).toFixed(2));
      linePath += ` Q ${prev.x} ${prev.y} ${midX} ${midY}`;
    }
  }

  const first = coords[0];
  const last = coords[coords.length - 1];
  const areaPath = `${linePath} L ${last.x} ${baselineY} L ${first.x} ${baselineY} Z`;

  return {
    linePath,
    areaPath,
    lastX: last.x,
    lastY: last.y,
    min: dataMin,
    max: dataMax,
    validCount: clean.length,
  };
}
