import test from "node:test";
import assert from "node:assert/strict";
import { cinemaTimeline, cinemaSeekTarget } from "../src/cinemaTimeline.js";

test("HLS at a late offset does not prematurely complete on its short playlist", () => {
  assert.deepEqual(cinemaTimeline(12, 25, 600, 720), {position: 612, duration: 720, nearEnd: false});
});
test("completion uses original timeline rather than mixing local duration and absolute position", () => {
  assert.deepEqual(cinemaTimeline(115, 120, 600, 720), {position: 715, duration: 720, nearEnd: true});
  assert.deepEqual(cinemaTimeline(115, 120, 0, 120), {position: 115, duration: 120, nearEnd: true});
});
test("unknown HLS length cannot mark the movie watched before stream actually ends", () => {
  assert.deepEqual(cinemaTimeline(14, 15, 300), {position: 314, duration: 315, nearEnd: false});
});
test("seek respects film boundaries", () => {
  assert.equal(cinemaSeekTarget(0, -10, 120), 0);
  assert.equal(cinemaSeekTarget(119, 10, 120), 119.75);
  assert.equal(cinemaSeekTarget(41, 10, 120), 51);
});
