import test from "node:test";
import assert from "node:assert/strict";
import { clampDockOffset, useCinemaDockDrag } from "../src/useCinemaDockDrag.ts";

test("clampDockOffset keeps the floating transport dock within player stage bounds", () => {
  const stage = { width: 1200, height: 700 };
  const dock = { width: 900, height: 84 };

  assert.deepEqual(clampDockOffset({ x: 0, y: 0 }, stage, dock), { x: 0, y: 0 });
  assert.deepEqual(clampDockOffset({ x: 500, y: -900 }, stage, dock), {
    x: 142,
    y: -588,
  });
  assert.deepEqual(clampDockOffset({ x: -500, y: 80 }, stage, dock), {
    x: -142,
    y: 10,
  });
});

test("useCinemaDockDrag tracks moved state, bottom proximity, and reset", () => {
  const drag = useCinemaDockDrag();
  assert.equal(drag.isDockMoved.value, false);
  assert.equal(drag.isDockNearBottom.value, true);

  drag.dockOffset.value = { x: 24, y: -140 };
  assert.equal(drag.isDockMoved.value, true);
  assert.equal(drag.isDockNearBottom.value, false);

  drag.resetDockPosition();
  assert.deepEqual(drag.dockOffset.value, { x: 0, y: 0 });
  assert.equal(drag.isDockMoved.value, false);
  assert.equal(drag.isDockNearBottom.value, true);
});
