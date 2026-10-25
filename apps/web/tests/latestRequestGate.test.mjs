import assert from "node:assert/strict";
import test from "node:test";
import { createLatestRequestGate } from "../src/latestRequestGate.js";

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
