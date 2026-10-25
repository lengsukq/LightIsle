import test from "node:test";
import assert from "node:assert/strict";
import { buildTimelineYears, timelineJumpIndex } from "../src/photoTimelineJump.js";
import { createPhotoTimelineLayout } from "../src/photoTimelineLayout.js";

// Local-time helpers keep the fixtures deterministic regardless of the
// machine's timezone, matching how the viewer formats its month headers.
function localTimestamp(year, month, day, hour = 12) {
  return Math.floor(new Date(year, month - 1, day, hour).getTime() / 1000);
}

test("buildTimelineYears aggregates descending years and months with firstIndex", () => {
  const timestamps = [
    localTimestamp(2026, 10, 2),
    localTimestamp(2026, 10, 1),
    localTimestamp(2026, 3, 8),
    localTimestamp(2025, 10, 25),
    localTimestamp(2025, 1, 1),
  ];
  const years = buildTimelineYears(timestamps);
  assert.deepEqual(years.map(entry => entry.year), [2026, 2025]);
  assert.equal(years[0].count, 3);
  assert.deepEqual(years[0].months.map(entry => entry.month), [10, 3]);
  assert.equal(years[0].months[0].firstIndex, 0);
  assert.equal(years[0].months[1].firstIndex, 2);
  assert.equal(years[1].months[0].month, 10);
  assert.equal(years[1].months[0].firstIndex, 3);
  // Titles must equal what the timeline layout renders, so a jump lands on a
  // real group header.
  const layout = createPhotoTimelineLayout(timestamps, 900);
  for (const yearEntry of years) {
    for (const monthEntry of yearEntry.months) {
      assert.ok(
        layout.groups.some(group => group.title === monthEntry.title),
        `missing layout group for ${monthEntry.title}`,
      );
    }
  }
});

test("buildTimelineYears skips unknown dates and tolerates garbage", () => {
  const years = buildTimelineYears([0, -5, Number.NaN, localTimestamp(2024, 5, 1)]);
  assert.equal(years.length, 1);
  assert.equal(years[0].year, 2024);
  assert.equal(years[0].count, 1);
});

test("timelineJumpIndex resolves pairs and whole years", () => {
  const timestamps = [
    localTimestamp(2026, 12, 1),
    localTimestamp(2026, 5, 2),
    localTimestamp(2026, 1, 3),
    localTimestamp(2024, 2, 4),
  ];
  const years = buildTimelineYears(timestamps);
  assert.equal(timelineJumpIndex(years, 2026, 5), 1);
  assert.equal(timelineJumpIndex(years, 2024, 2), 3);
  // Year-only jumps land on the oldest month of that year.
  assert.equal(timelineJumpIndex(years, 2026, 0), 2);
  assert.equal(timelineJumpIndex(years, 2030, 1), -1);
  assert.equal(timelineJumpIndex(years, 2026, 7), -1);
});
