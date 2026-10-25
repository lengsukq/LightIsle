import test from "node:test";
import assert from "node:assert/strict";
import {
  zoomAtAnchor,
  pinchScale,
  pinchDistance,
  swipeDirection,
  normalizeViewerTransform,
  wheelZoomFactor,
  viewerMaxScale,
} from "../src/viewerGestures.js";

test("zoomAtAnchor keeps the anchor pixel fixed while scaling", () => {
  const state = { scale: 1, x: 0, y: 0 };
  const anchor = { x: 120, y: -40 };
  const zoomed = zoomAtAnchor(state, 2.5, anchor);
  // The image point that sat at the anchor must still map to the anchor.
  assert.equal(zoomed.scale, 2.5);
  assert.equal(zoomed.x, anchor.x - anchor.x * 2.5);
  assert.equal(zoomed.y, anchor.y - anchor.y * 2.5);
  // Re-projecting the anchor through the transform lands back on itself.
  const imageX = (anchor.x - zoomed.x) / zoomed.scale;
  assert.equal(imageX, anchor.x);
});

test("zoomAtAnchor clamps to the scale bounds", () => {
  assert.equal(zoomAtAnchor({ scale: 4.9, x: 0, y: 0 }, 4, { x: 0, y: 0 }).scale, viewerMaxScale);
  assert.equal(zoomAtAnchor({ scale: 2, x: 10, y: 10 }, 0.01, { x: 0, y: 0 }).scale, 1);
});

test("pinch math scales with finger distance and tolerates degenerate input", () => {
  assert.equal(pinchScale(2, 100, 200), 4);
  assert.equal(pinchScale(2, 100, 50), 1);
  assert.equal(pinchScale(2, 0, 100), 2);
  assert.equal(pinchScale(2, 100, Number.NaN), 2);
  assert.equal(pinchDistance({ x: 0, y: 0 }, { x: 3, y: 4 }), 5);
});

test("swipeDirection only accepts clearly horizontal intent", () => {
  assert.equal(swipeDirection({ x: 0, y: 0 }, { x: -80, y: 5 }), "left");
  assert.equal(swipeDirection({ x: 0, y: 0 }, { x: 90, y: 10 }), "right");
  assert.equal(swipeDirection({ x: 0, y: 0 }, { x: -20, y: 0 }), null);
  // Mostly vertical drags scroll the page instead of flipping photos.
  assert.equal(swipeDirection({ x: 0, y: 0 }, { x: -60, y: -120 }), null);
});

test("normalizeViewerTransform snaps home at unity", () => {
  assert.deepEqual(normalizeViewerTransform({ scale: 1.005, x: 30, y: 12 }), { scale: 1, x: 0, y: 0 });
  const kept = normalizeViewerTransform({ scale: 2, x: 30, y: 12 });
  assert.deepEqual(kept, { scale: 2, x: 30, y: 12 });
});

test("wheelZoomFactor direction and magnitude", () => {
  assert.ok(wheelZoomFactor(-100) > 1, "scroll up zooms in");
  assert.ok(wheelZoomFactor(100) < 1, "scroll down zooms out");
  assert.equal(wheelZoomFactor(0), 1);
  const capped = wheelZoomFactor(-100000);
  assert.ok(capped > 1 && capped <= Math.exp(240 / 480));
});
