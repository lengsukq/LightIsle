import test from "node:test";
import assert from "node:assert/strict";
import { timelineMonth, createPhotoTimelineLayout, getPhotoTimelineWindow } from "../src/photoTimelineLayout.js";

const stamp = (day) => Date.parse(day + "T12:00:00Z") / 1000;

test("photo timeline creates non-overlapping monthly headers and keeps each month in its own grid", () => {
  const stamps = ["2026-10-19", "2026-10-18", "2026-09-29", "2025-12-09"].map(stamp);
  const layout = createPhotoTimelineLayout(stamps, 600);
  assert.equal(layout.groups.length, 3);
  assert.equal(layout.groups[0].startIndex, 0);
  assert.equal(layout.groups[1].startIndex, 2);
  assert.equal(layout.groups[2].startIndex, 3);
  assert.ok(layout.groups[1].top > layout.positions[1].top);
  assert.ok(layout.positions[2].top > layout.groups[1].top);
  assert.ok(layout.positions[3].top > layout.groups[2].top);
  assert.ok(layout.totalHeight >= layout.positions[3].top + layout.tileSize);
});

test("photo timeline windows stay bounded for 100k photos across years", () => {
  const stamps = Array.from({ length: 100_000 }, (_, i) => stamp("2026-10-19") - i * 86400);
  const layout = createPhotoTimelineLayout(stamps, 1000);
  const middle = layout.positions[50_000].top;
  const window = getPhotoTimelineWindow(layout, middle, 850);
  assert.ok(window.startIndex > 49_900);
  assert.ok(window.endIndex < 50_100);
  assert.ok(window.endIndex - window.startIndex < 60);
  assert.ok(window.headers.length <= 3);
});

test("photo timeline handles unknown dates and responsive single-column layout", () => {
  assert.equal(timelineMonth(0), "日期未知");
  const layout = createPhotoTimelineLayout([stamp("2026-05-01"), 0], 180);
  assert.equal(layout.columns, 1);
  assert.equal(layout.groups.length, 2);
  const far = getPhotoTimelineWindow(layout, layout.totalHeight + 1000, 600);
  assert.equal(far.startIndex, 2);
  assert.equal(far.endIndex, 2);
});
