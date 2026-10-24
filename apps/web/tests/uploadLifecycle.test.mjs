import assert from "node:assert/strict";
import test from "node:test";
import { adoptUploadTask, refreshAfterPublishedUpload } from "../src/uploadLifecycle.js";

test("new upload task ID is retained before a cancellation check can throw", () => {
  let taskID = "";
  const state = { id: "upload-1", offset: 0, size: 8 };

  assert.throws(() => adoptUploadTask(
    state,
    (id) => { taskID = id; },
    () => { throw new DOMException("cancelled", "AbortError"); },
  ), { name: "AbortError" });
  assert.equal(taskID, "upload-1");
});

test("a cancelled or failed batch with no published files does not reload the file list", async () => {
  let reloads = 0;
  await refreshAfterPublishedUpload(0, () => { reloads += 1; });
  assert.equal(reloads, 0);
});

test("a batch that published at least one file reloads the file list", async () => {
  let reloads = 0;
  await refreshAfterPublishedUpload(1, () => { reloads += 1; });
  assert.equal(reloads, 1);
});
