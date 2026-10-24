import assert from "node:assert/strict";
import test from "node:test";
import { createMediaStatusPoller } from "../src/mediaStatusPoller.js";

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

test("status polling is single-flight and a failed read keeps the last known status retryable", async () => {
  const first = deferred();
  const second = deferred();
  const requests = [first, second];
  const values = [];
  const errors = [];
  let calls = 0;
  const poller = createMediaStatusPoller(
    async () => requests[calls++].promise,
    { onValue: value => values.push(value), onError: error => errors.push(error.message) },
  );

  const polling = poller.refresh();
  const overlappingPoll = poller.refresh();
  await Promise.resolve();
  assert.equal(calls, 1, "a timer tick must not start a competing status read");
  assert.equal(overlappingPoll, polling);
  first.resolve({ running: true, found: 4 });
  await polling;

  const retry = poller.refresh();
  await Promise.resolve();
  second.reject(new Error("temporary offline"));
  await retry;
  assert.deepEqual(values, [{ running: true, found: 4 }]);
  assert.deepEqual(errors, ["temporary offline"]);

  const recovered = deferred();
  requests.push(recovered);
  const manualRetry = poller.refresh();
  await Promise.resolve();
  recovered.resolve({ running: false, found: 6 });
  await manualRetry;
  assert.deepEqual(values, [{ running: true, found: 4 }, { running: false, found: 6 }]);
  poller.dispose();
});

test("root invalidation and disposal prevent older status responses from replacing current state", async () => {
  const oldRoot = deferred();
  const newRoot = deferred();
  const values = [];
  let calls = 0;
  const poller = createMediaStatusPoller(
    () => [oldRoot, newRoot][calls++].promise,
    { onValue: value => values.push(value) },
  );

  const oldRequest = poller.refresh();
  await Promise.resolve();
  poller.invalidate();
  const currentRequest = poller.refresh();
  await Promise.resolve();
  newRoot.resolve({ root: "new", running: false });
  await currentRequest;
  oldRoot.resolve({ root: "old", running: true });
  await oldRequest;
  assert.deepEqual(values, [{ root: "new", running: false }]);

  const afterDispose = deferred();
  const disposedPoller = createMediaStatusPoller(
    () => afterDispose.promise,
    { onValue: value => values.push(value) },
  );
  const disposedRequest = disposedPoller.refresh();
  await Promise.resolve();
  disposedPoller.dispose();
  afterDispose.resolve({ root: "disposed", running: true });
  await disposedRequest;
  assert.deepEqual(values, [{ root: "new", running: false }]);
});
