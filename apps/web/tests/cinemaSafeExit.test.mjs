import assert from "node:assert/strict";
import test from "node:test";
import {confirmCinemaExit} from "../src/cinemaSafeExit.js";

test("successful progress save closes player exactly once", async () => {
  let closed=0,failed=0;
  const ok=await confirmCinemaExit({
    save:async()=>{},hasUnsaved:()=>false,
    onLeave:()=>closed++,onFailure:()=>failed++,
  });
  assert.equal(ok,true);assert.equal(closed,1);assert.equal(failed,0);
});
test("a failed progress write retains player and offers recovery", async () => {
  let closed=0,failed=0;
  const ok=await confirmCinemaExit({
    save:async()=>{},hasUnsaved:()=>true,
    onLeave:()=>closed++,onFailure:()=>failed++,
  });
  assert.equal(ok,false);assert.equal(closed,0);assert.equal(failed,1);
});
test("exception does not dismiss player; explicit discard is separate", async () => {
  let closed=0;
  const ok=await confirmCinemaExit({
    save:async()=>{throw Error("offline");},hasUnsaved:()=>false,
    onLeave:()=>closed++,onFailure:()=>{},
  });
  assert.equal(ok,false);assert.equal(closed,0);
});
