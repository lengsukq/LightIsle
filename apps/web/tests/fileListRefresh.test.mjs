import assert from "node:assert/strict";
import test from "node:test";
import { performFileOperationAndRefresh } from "../src/fileListRefresh.js";

test("a successful copy or move action refreshes the file list", async () => {
  const events = [];
  await performFileOperationAndRefresh(
    async () => { events.push("operation"); },
    async () => { events.push("refresh"); },
  );
  assert.deepEqual(events, ["operation", "refresh"]);
});

test("a failed copy or move action does not refresh the file list", async () => {
  let refreshes = 0;
  await assert.rejects(
    performFileOperationAndRefresh(
      async () => { throw new Error("operation_failed"); },
      async () => { refreshes += 1; },
    ),
    /operation_failed/,
  );
  assert.equal(refreshes, 0);
});
