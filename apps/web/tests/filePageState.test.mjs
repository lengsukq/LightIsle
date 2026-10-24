import assert from "node:assert/strict";
import test from "node:test";
import {
  createUploadContinuation,
  trashPresentationState,
  uploadContinuationIsCurrent,
} from "../src/filePageState.js";

test("trash loading, failure, empty and populated states are mutually exclusive", () => {
  assert.equal(trashPresentationState({ loading: true, error: "offline", entries: [] }), "loading");
  assert.equal(trashPresentationState({ loading: false, error: "offline", entries: [{ id: "old" }] }), "error");
  assert.equal(trashPresentationState({ loading: false, error: "", entries: [] }), "empty");
  assert.equal(trashPresentationState({ loading: false, error: "", entries: [{ id: "one" }] }), "items");
});

test("upload continuation retains only the failed and later File objects", () => {
  const files = [{ name: "done.jpg" }, { name: "retry.jpg" }, { name: "later.jpg" }];
  const context = { username: "alice", rootID: "root-a", rootGeneration: 4, rootEpoch: 9, directory: "photos" };
  const continuation = createUploadContinuation(files, 1, context);

  assert.deepEqual(continuation.files, files.slice(1));
  assert.equal(continuation.files[0], files[1]);
  assert.equal(uploadContinuationIsCurrent(continuation, { ...context }), true);
  assert.equal(uploadContinuationIsCurrent(continuation, { ...context, directory: "other" }), false);
  assert.equal(uploadContinuationIsCurrent(continuation, { ...context, rootID: "root-b" }), false);
  assert.equal(uploadContinuationIsCurrent(continuation, { ...context, rootGeneration: 5 }), false);
  assert.equal(uploadContinuationIsCurrent(continuation, { ...context, rootEpoch: 10 }), false);
  assert.equal(uploadContinuationIsCurrent(continuation, { ...context, username: "bob" }), false);
  assert.equal(createUploadContinuation(files, files.length, context), null);
});
