<script setup lang="ts">
import { computed, useId } from "vue";
import {
  buildDonutSegments,
  buildSegmentedSegments,
  buildSparklinePaths,
  ISLE_CHART_COLORS,
  type ChartSegmentInput,
} from "./isleChartsMath.ts";

const props = withDefaults(
  defineProps<{
    kind: "donut" | "segmented" | "sparkline";
    segments?: ChartSegmentInput[];
    percent?: number | null;
    total?: number;
    color?: string;
    trackColor?: string;
    size?: number;
    strokeWidth?: number;
    centerLabel?: string;
    centerSublabel?: string;
    points?: number[];
    minBound?: number;
    maxBound?: number;
    sparkHeight?: number;
    barHeight?: number;
    showLegend?: boolean;
    compactLegend?: boolean;
    hidePercentInLegend?: boolean;
    ariaLabel?: string;
  }>(),
  {
    segments: () => [],
    percent: null,
    total: 0,
    color: ISLE_CHART_COLORS.blue,
    trackColor: "",
    size: 68,
    strokeWidth: 7,
    centerLabel: "",
    centerSublabel: "",
    points: () => [],
    minBound: undefined,
    maxBound: undefined,
    sparkHeight: 34,
    barHeight: 10,
    showLegend: true,
    compactLegend: false,
    hidePercentInLegend: false,
    ariaLabel: "",
  },
);

const gradId = `isle-spark-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;

const normalizedPercent = computed<number | null>(() => {
  if (props.percent === null || props.percent === undefined || !Number.isFinite(props.percent)) return null;
  return Math.min(100, Math.max(0, Math.round(props.percent)));
});

const donutGeom = computed(() => {
  const half = props.size / 2;
  const radius = Math.max(6, (props.size - props.strokeWidth) / 2);
  const circumference = 2 * Math.PI * radius;
  const singleMode = !props.segments.length;

  if (singleMode) {
    const pct = normalizedPercent.value;
    const len = pct === null ? 0 : (pct / 100) * circumference;
    return {
      half,
      radius,
      circumference,
      singleMode: true,
      singleDashArray: `${len.toFixed(2)} ${circumference.toFixed(2)}`,
      segments: [] as ReturnType<typeof buildDonutSegments>["segments"],
      usedPercent: pct ?? 0,
    };
  }

  const built = buildDonutSegments(props.segments, {
    total: props.total,
    radius,
  });
  return {
    half,
    radius,
    circumference,
    singleMode: false,
    singleDashArray: `0 ${circumference.toFixed(2)}`,
    segments: built.segments,
    usedPercent: built.usedPercent,
  };
});

const resolvedCenterLabel = computed(() => {
  if (props.centerLabel) return props.centerLabel;
  if (!props.segments.length && normalizedPercent.value === null) return "—";
  return `${donutGeom.value.usedPercent}%`;
});

const segmentedBuilt = computed(() =>
  buildSegmentedSegments(props.segments, {
    total: props.total,
    minVisiblePercent: 1.5,
  }),
);

const sparkBuilt = computed(() =>
  buildSparklinePaths(props.points, {
    width: 168,
    height: props.sparkHeight,
    padding: 4,
    minBound: props.minBound,
    maxBound: props.maxBound,
  }),
);
</script>

<template>
  <div
    v-if="kind === 'donut'"
    class="isle-chart-donut"
    :class="{ 'isle-chart-donut--with-legend': showLegend && segments.length > 0 }"
  >
    <div
      class="isle-donut-ring"
      :style="{ width: `${size}px`, height: `${size}px` }"
      role="img"
      :aria-label="ariaLabel || `占比图表 ${resolvedCenterLabel}`"
    >
      <svg :viewBox="`0 0 ${size} ${size}`" :width="size" :height="size" aria-hidden="true">
        <circle
          class="isle-donut-track"
          :cx="donutGeom.half"
          :cy="donutGeom.half"
          :r="donutGeom.radius"
          :stroke="trackColor || undefined"
          :stroke-width="strokeWidth"
        />
        <circle
          v-if="donutGeom.singleMode && normalizedPercent !== null && normalizedPercent > 0"
          class="isle-donut-arc"
          :cx="donutGeom.half"
          :cy="donutGeom.half"
          :r="donutGeom.radius"
          :stroke="color"
          :stroke-width="strokeWidth"
          stroke-linecap="round"
          :stroke-dasharray="donutGeom.singleDashArray"
          :transform="`rotate(-90 ${donutGeom.half} ${donutGeom.half})`"
        />
        <template v-else-if="!donutGeom.singleMode">
          <circle
            v-for="seg in donutGeom.segments"
            :key="seg.key"
            class="isle-donut-arc"
            :cx="donutGeom.half"
            :cy="donutGeom.half"
            :r="donutGeom.radius"
            :stroke="seg.color"
            :stroke-width="strokeWidth"
            stroke-linecap="butt"
            :stroke-dasharray="seg.dashArray"
            :stroke-dashoffset="seg.dashOffset"
            :transform="`rotate(-90 ${donutGeom.half} ${donutGeom.half})`"
          />
        </template>
      </svg>
      <div class="isle-donut-center" :class="{ 'is-mini': size < 48 }">
        <strong
          class="isle-donut-val"
          :style="{ fontSize: size <= 44 ? '10px' : size <= 64 ? '12px' : size < 84 ? '13px' : '15px' }"
        >
          {{ resolvedCenterLabel }}
        </strong>
        <small v-if="centerSublabel && size >= 84" class="isle-donut-sub">{{ centerSublabel }}</small>
      </div>
    </div>

    <div v-if="showLegend && donutGeom.segments.length" class="isle-chart-legend" :class="{ 'is-compact': compactLegend }">
      <div v-for="seg in donutGeom.segments" :key="seg.key" class="isle-legend-item" :title="seg.hint || seg.label">
        <i class="isle-legend-dot" :style="{ background: seg.color }" />
        <span class="isle-legend-label">{{ seg.label }}</span>
        <strong class="isle-legend-val">{{ seg.displayValue ?? seg.percentLabel }}</strong>
        <span v-if="seg.displayValue && !hidePercentInLegend" class="isle-legend-pct">{{ seg.percentLabel }}</span>
      </div>
    </div>
  </div>

  <div v-else-if="kind === 'segmented'" class="isle-chart-segmented">
    <div
      class="isle-seg-track"
      :style="{ height: `${barHeight}px` }"
      role="img"
      :aria-label="ariaLabel || '容量与占比分布条'"
    >
      <template v-for="part in segmentedBuilt.parts" :key="part.key">
        <span
          v-if="part.widthPercent > 0"
          class="isle-seg-slice"
          :style="{ width: `${part.widthPercent}%`, background: part.color }"
          :title="`${part.label}：${part.displayValue ? part.displayValue + ' · ' : ''}${part.percentLabel}`"
        />
      </template>
    </div>

    <div v-if="showLegend && segmentedBuilt.parts.length" class="isle-chart-legend" :class="{ 'is-compact': compactLegend }">
      <div v-for="part in segmentedBuilt.parts" :key="part.key" class="isle-legend-item" :title="part.hint || part.label">
        <i class="isle-legend-dot" :style="{ background: part.color }" />
        <span class="isle-legend-label">{{ part.label }}</span>
        <strong v-if="part.displayValue" class="isle-legend-val">{{ part.displayValue }}</strong>
        <span v-if="!hidePercentInLegend && (segmentedBuilt.total > 0 || !part.displayValue)" class="isle-legend-pct">
          {{ part.percentLabel }}
        </span>
      </div>
    </div>
  </div>

  <div v-else class="isle-chart-sparkline" :style="{ height: `${sparkHeight}px` }">
    <svg
      v-if="sparkBuilt.validCount > 0"
      :viewBox="`0 0 168 ${sparkHeight}`"
      preserveAspectRatio="none"
      role="img"
      :aria-label="ariaLabel || '最近采样趋势图'"
    >
      <defs>
        <linearGradient :id="gradId" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" :stop-color="color" stop-opacity="0.28" />
          <stop offset="100%" :stop-color="color" stop-opacity="0.02" />
        </linearGradient>
      </defs>
      <line
        x1="4"
        :y1="sparkHeight / 2"
        x2="164"
        :y2="sparkHeight / 2"
        stroke="currentColor"
        stroke-opacity="0.1"
        stroke-dasharray="3 3"
        vector-effect="non-scaling-stroke"
      />
      <path :d="sparkBuilt.areaPath" :fill="`url(#${gradId})`" />
      <path
        :d="sparkBuilt.linePath"
        fill="none"
        :stroke="color"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
        vector-effect="non-scaling-stroke"
      />
      <circle
        :cx="sparkBuilt.lastX"
        :cy="sparkBuilt.lastY"
        r="2.8"
        :fill="color"
      />
    </svg>
    <div v-else class="isle-sparkline-empty" aria-hidden="true" />
  </div>
</template>

<style scoped>
.isle-chart-donut {
  display: inline-flex;
  align-items: center;
  gap: 12px;
  min-width: 0;
}
.isle-chart-donut--with-legend {
  display: flex;
  flex-wrap: wrap;
}
.isle-donut-ring {
  position: relative;
  display: inline-grid;
  place-items: center;
  flex-shrink: 0;
}
.isle-donut-ring svg {
  display: block;
}
.isle-donut-track {
  fill: none;
  stroke: var(--isle-chart-track, rgba(142, 142, 147, 0.18));
}
.isle-donut-arc {
  fill: none;
  transition: stroke-dasharray 0.32s var(--ease-fluid, ease-out), stroke-dashoffset 0.32s var(--ease-fluid, ease-out);
}
.isle-donut-center {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  pointer-events: none;
  text-align: center;
  line-height: 1.08;
}
.isle-donut-val {
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  color: var(--text-primary);
  white-space: nowrap;
  max-width: calc(100% - 10px);
  overflow: hidden;
  text-overflow: ellipsis;
}
.isle-donut-sub {
  font-size: 9.5px;
  color: var(--text-tertiary);
  margin-top: 1px;
}

.isle-chart-segmented {
  display: flex;
  flex-direction: column;
  gap: 8px;
  width: 100%;
  min-width: 0;
}
.isle-seg-track {
  width: 100%;
  display: flex;
  gap: 2px;
  padding: 1px;
  border-radius: 999px;
  overflow: hidden;
  background: var(--isle-chart-track, rgba(142, 142, 147, 0.16));
  border: 1px solid color-mix(in srgb, var(--border-subtle, rgba(142, 142, 147, 0.25)) 68%, transparent);
}
.isle-seg-slice {
  height: 100%;
  border-radius: 4px;
  min-width: 0;
  transition: width 0.32s var(--ease-fluid, ease-out);
}
.isle-seg-slice:first-child {
  border-top-left-radius: 999px;
  border-bottom-left-radius: 999px;
}
.isle-seg-slice:last-child {
  border-top-right-radius: 999px;
  border-bottom-right-radius: 999px;
}

.isle-chart-legend {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 14px;
  min-width: 0;
}
.isle-chart-legend.is-compact {
  gap: 4px 10px;
}
.isle-legend-item {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 12px;
  color: var(--text-secondary);
  min-width: 0;
  font-variant-numeric: tabular-nums;
}
.isle-chart-legend.is-compact .isle-legend-item {
  font-size: 11px;
}
.isle-legend-dot {
  width: 8px;
  height: 8px;
  border-radius: 999px;
  flex-shrink: 0;
}
.isle-legend-label {
  white-space: nowrap;
}
.isle-legend-val {
  color: var(--text-primary);
  font-weight: 600;
}
.isle-legend-pct {
  color: var(--text-tertiary);
}

.isle-chart-sparkline {
  width: 100%;
  color: var(--text-tertiary);
}
.isle-chart-sparkline svg {
  width: 100%;
  height: 100%;
  display: block;
  overflow: visible;
}
.isle-sparkline-empty {
  width: 100%;
  height: 100%;
  border-bottom: 1px dashed rgba(142, 142, 147, 0.24);
}

:global([data-theme="dark"]) .isle-seg-track,
:global([data-theme="dark"]) .isle-donut-track {
  --isle-chart-track: rgba(255, 255, 255, 0.11);
}

@media (prefers-reduced-motion: reduce) {
  .isle-donut-arc,
  .isle-seg-slice {
    transition: none;
  }
}
</style>
