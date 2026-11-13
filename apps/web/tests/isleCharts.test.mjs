import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import {
  buildDonutSegments,
  buildSegmentedSegments,
  buildSparklinePaths,
  clampRatio,
  formatSharePercent,
  ISLE_CHART_COLORS,
} from "../src/isleChartsMath.ts";
import {
  buildHostDiskSegments,
  buildHostMemorySegments,
  buildQuotaSegments,
} from "../src/overviewPageModels.ts";

test("clampRatio and formatSharePercent handle boundaries honestly", () => {
  assert.equal(clampRatio(5, 0), 0);
  assert.equal(clampRatio(Number.NaN, 10), 0);
  assert.equal(clampRatio(150, 100), 1);
  assert.equal(clampRatio(-5, 100), 0);

  assert.equal(formatSharePercent(0), "0%");
  assert.equal(formatSharePercent(0.002), "<1%");
  assert.equal(formatSharePercent(0.456), "46%");
});

test("buildDonutSegments accumulates offsets sequentially and tolerates empty inputs", () => {
  const empty = buildDonutSegments([{ label: "空", value: 0 }], { total: 0, radius: 20 });
  assert.equal(empty.total, 0);
  assert.equal(empty.usedPercent, 0);
  assert.equal(empty.segments[0].percentLabel, "0%");

  const multi = buildDonutSegments(
    [
      { key: "a", label: "已入账", value: 25, displayValue: "25 GB" },
      { key: "b", label: "预占", value: 25, displayValue: "25 GB" },
      { key: "c", label: "剩余", value: 50, displayValue: "50 GB" },
    ],
    { total: 100, radius: 20 },
  );
  assert.equal(multi.total, 100);
  assert.equal(multi.usedPercent, 100);
  assert.equal(multi.segments[0].dashOffset, 0);
  assert.ok(multi.segments[1].dashOffset < 0);
  assert.ok(multi.segments[2].dashOffset < multi.segments[1].dashOffset);
  assert.equal(multi.segments[0].percentLabel, "25%");
  assert.equal(multi.segments[2].percentLabel, "50%");
});

test("buildSegmentedSegments preserves tiny non-zero slice visibility while keeping honest percentage labels", () => {
  const built = buildSegmentedSegments(
    [
      { key: "big", label: "已用", value: 999, color: ISLE_CHART_COLORS.blue },
      { key: "tiny", label: "预占", value: 1, color: ISLE_CHART_COLORS.amber },
    ],
    { total: 1000, minVisiblePercent: 2 },
  );
  assert.equal(built.parts[0].percentLabel, "100%");
  assert.equal(built.parts[1].percentLabel, "<1%");
  assert.ok(built.parts[1].widthPercent >= 1.9);
  assert.ok(built.parts[0].widthPercent + built.parts[1].widthPercent <= 100.05);
});

test("buildSparklinePaths generates valid paths for empty, single, constant, and noisy series", () => {
  const zero = buildSparklinePaths([]);
  assert.equal(zero.validCount, 0);
  assert.equal(zero.linePath, "");

  const single = buildSparklinePaths([42], { width: 160, height: 36, minBound: 0, maxBound: 100 });
  assert.equal(single.validCount, 1);
  assert.match(single.linePath, /^M /);
  assert.match(single.areaPath, /Z$/);

  const constant = buildSparklinePaths([50, 50, 50]);
  assert.equal(constant.validCount, 3);
  assert.ok(!constant.linePath.includes("NaN"));

  const multi = buildSparklinePaths([10, Number.NaN, 35, 22, 80], { minBound: 0, maxBound: 100 });
  assert.equal(multi.validCount, 4);
  assert.equal(multi.min, 10);
  assert.equal(multi.max, 80);
  assert.match(multi.linePath, /Q /);
});

test("overview model chart builders accurately partition memory, disk, and pending quota space", () => {
  const fmt = (n) => `${n}B`;
  const quota = buildQuotaSegments(30, 10, 100, fmt);
  assert.deepEqual(
    quota.map((s) => [s.key, s.value]),
    [
      ["accounted", 30],
      ["reserved", 10],
      ["available", 60],
    ],
  );

  const memWithCore = buildHostMemorySegments(
    {
      timestamp: "",
      hostname: "mac",
      architecture: "arm64",
      cpuCount: 8,
      cpuPercent: 12,
      memoryTotal: 1000,
      memoryUsed: 600,
      diskTotal: 2000,
      diskFree: 500,
      coreRssBytes: 120,
    },
    fmt,
  );
  assert.deepEqual(
    memWithCore.map((s) => [s.key, s.value]),
    [
      ["core", 120],
      ["other", 480],
      ["free", 400],
    ],
  );

  const disk = buildHostDiskSegments(
    {
      timestamp: "",
      hostname: "mac",
      architecture: "arm64",
      cpuCount: 8,
      cpuPercent: 12,
      memoryTotal: 1000,
      memoryUsed: 600,
      diskTotal: 2000,
      diskFree: 500,
    },
    fmt,
  );
  assert.deepEqual(
    disk.map((s) => [s.key, s.value]),
    [
      ["used", 1500],
      ["free", 500],
    ],
  );
});

test("IsleCharts enforces zero transition: all, prefers-reduced-motion, and aria-labels", () => {
  const sfc = readFileSync(new URL("../src/IsleCharts.vue", import.meta.url), "utf8");
  assert.doesNotMatch(sfc, /transition:\s*all/);
  assert.match(sfc, /@media\s*\(prefers-reduced-motion:\s*reduce\)/);
  assert.match(sfc, /role="img"/);
});
