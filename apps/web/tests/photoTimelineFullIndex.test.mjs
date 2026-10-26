import test from "node:test";
import assert from "node:assert/strict";
import {timelineYearsFromMonths,timelineJumpIndex} from "../src/photoTimelineJump.js";

test("the full NAS month index can jump beyond loaded browser pages", () => {
  const index = timelineYearsFromMonths([
    {year:2026,month:10,count:20,firstIndex:0},
    {year:2026,month:9,count:100,firstIndex:20},
    {year:2019,month:2,count:15,firstIndex:1500},
  ]);
  assert.equal(index.length, 2);
  assert.equal(index[0].count,120);
  assert.equal(timelineJumpIndex(index,2019,2),1500);
  assert.equal(timelineJumpIndex(index,2026,9),20);
});
test("invalid month summaries do not become jump links", () => {
  assert.deepEqual(timelineYearsFromMonths([{year:2026,month:13,count:2,firstIndex:0}]),[]);
});
