import test from "node:test";
import assert from "node:assert/strict";
import {
  canSeekWithinHlsRanges,
  cinemaSeekTarget,
  cinemaTimeline,
  resolveBufferedFilmEnd,
  resolveKnownFilmDuration,
} from "../src/cinemaTimeline.ts";

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

test("ongoing HLS at offset 0 does not mark 20s partial mux as completed", () => {
  assert.deepEqual(cinemaTimeline(15, 20, 0, 0, true), {
    position: 15,
    duration: 20,
    nearEnd: false,
  });
});

test("ongoing HLS after seeking preserves full movie duration instead of seekTarget + partial segment", () => {
  assert.deepEqual(cinemaTimeline(1, 4, 1800, 9660, true), {
    position: 1801,
    duration: 9660,
    nearEnd: false,
  });
});

test("resolveKnownFilmDuration picks authoritative full length across sources", () => {
  assert.equal(
    resolveKnownFilmDuration({
      sessionDuration: 9660,
      tracksDuration: 0,
      mediaDuration: 0,
      progressDuration: 0,
    }),
    9660,
  );
  assert.equal(
    resolveKnownFilmDuration({
      sessionDuration: 0,
      tracksDuration: 5400,
      mediaDuration: 0,
      progressDuration: 5399,
    }),
    5400,
  );
});

function makeRanges(pairs) {
  return {
    length: pairs.length,
    start: (i) => pairs[i][0],
    end: (i) => pairs[i][1],
  };
}

test("canSeekWithinHlsRanges allows instant local seeks inside muxed window and rejects out-of-window seeks", () => {
  const ranges = makeRanges([[0, 120]]);
  assert.equal(canSeekWithinHlsRanges(ranges, 650, 600, 9660), true);
  assert.equal(canSeekWithinHlsRanges(ranges, 719.2, 600, 9660), false);
  assert.equal(canSeekWithinHlsRanges(ranges, 590, 600, 9660), false);
  assert.equal(canSeekWithinHlsRanges(ranges, 1500, 600, 9660), false);
  // Near actual film end, allow seeking up to the final second.
  const tailRanges = makeRanges([[0, 60]]);
  assert.equal(canSeekWithinHlsRanges(tailRanges, 9659.4, 9600, 9660), true);
});

test("resolveBufferedFilmEnd maps local buffered ranges onto original film timeline", () => {
  const ranges = makeRanges([[0, 48.5]]);
  assert.equal(resolveBufferedFilmEnd(ranges, 12, 1800), 1848.5);
});
