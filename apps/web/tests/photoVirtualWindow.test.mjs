import assert from "node:assert/strict";
import test from "node:test";
import { createLatestRequestGate } from "../src/latestRequestGate.js";
import { getPhotoVirtualWindow } from "../src/photoVirtualWindow.js";

test("virtual columns adapt to narrow and wide gallery containers", () => {
  const narrow = getPhotoVirtualWindow({ itemCount: 80, containerWidth: 320 });
  const wide = getPhotoVirtualWindow({ itemCount: 80, containerWidth: 1040 });

  assert.equal(narrow.columns, 1);
  assert.equal(wide.columns, 6);
  assert.ok(narrow.tileSize >= 160);
  assert.ok(wide.tileSize >= 160);
  assert.equal(wide.totalHeight, wide.rowCount * wide.tileSize + (wide.rowCount - 1) * 12);
});

test("large galleries expose a bounded slice with stable item indices", () => {
  const window = getPhotoVirtualWindow({
    itemCount: 100_000,
    containerWidth: 1200,
    viewportTop: 120_000,
    viewportHeight: 900,
  });

  assert.ok(window.endIndex - window.startIndex <= window.columns * 10);
  assert.ok(window.startIndex > 0);
  assert.ok(window.endIndex < 100_000);
  assert.equal(window.topSpacer + (window.endIndex - window.startIndex) / window.columns * window.rowPitch + window.bottomSpacer, window.totalHeight);
});

test("empty and out-of-range windows stay within item bounds", () => {
  const empty = getPhotoVirtualWindow({ itemCount: 0, containerWidth: 0 });
  const pastEnd = getPhotoVirtualWindow({
    itemCount: 3,
    containerWidth: 700,
    viewportTop: 10_000,
    viewportHeight: 400,
  });

  assert.equal(empty.startIndex, 0);
  assert.equal(empty.endIndex, 0);
  assert.equal(empty.totalHeight, 0);
  assert.equal(pastEnd.startIndex, 3);
  assert.equal(pastEnd.endIndex, 3);
});

test("starting a reset aborts the old request and invalidates late results", () => {
  const gate = createLatestRequestGate();
  const oldRequest = gate.begin();
  const currentRequest = gate.begin();

  assert.equal(oldRequest.signal.aborted, true);
  assert.equal(oldRequest.isCurrent(), false);
  assert.equal(currentRequest.signal.aborted, false);
  assert.equal(currentRequest.isCurrent(), true);

  gate.cancel();
  assert.equal(currentRequest.signal.aborted, true);
  assert.equal(currentRequest.isCurrent(), false);
});

test("a response arriving after a reset cannot replace the newer page", async () => {
  const gate = createLatestRequestGate();
  const rows = [];
  let releaseOld;
  const oldResponse = new Promise((resolve) => { releaseOld = resolve; });
  const oldRequest = gate.begin();
  const oldApply = oldResponse.then((value) => {
    if (oldRequest.isCurrent()) rows.splice(0, rows.length, ...value);
  });

  const newRequest = gate.begin();
  if (newRequest.isCurrent()) rows.splice(0, rows.length, "new page");
  releaseOld(["stale page"]);
  await oldApply;

  assert.deepEqual(rows, ["new page"]);
  assert.equal(oldRequest.signal.aborted, true);
});
