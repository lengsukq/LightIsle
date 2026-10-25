import assert from "node:assert/strict";
import test from "node:test";
import { createRootRequestTransport, rootContextKey } from "../src/rootRequestTransport.js";

function harness(fetcher = async () => new Response("{}", { status: 200 })) {
  const controller = new AbortController();
  let changes = 0;
  const scope = { rootID: "root-a", generation: 3, epoch: 1, multiRoot: true,
    legacySelected: false, discoveryState: "multi", switching: false, signal: controller.signal };
  const transport = createRootRequestTransport({
    getContext: () => scope, fetcher, onGenerationChanged: () => { changes++; },
  });
  return { transport, scope, controller, get changes() { return changes; } };
}

test("v2 transport sets generation header and rejects cross-root or v1 access", async () => {
  const calls = [];
  const h = harness(async (path, init) => {
    calls.push({ path, generation: init.headers.get("X-LightIsle-Root-Generation") });
    return new Response("{}", { status: 200 });
  });
  await h.transport.request("/api/v2/roots/root-a/files");
  assert.deepEqual(calls, [{ path: "/api/v2/roots/root-a/files", generation: "3" }]);
  await assert.rejects(h.transport.request("/api/v2/roots/root-b/files"), { name: "AbortError" });
  await assert.rejects(h.transport.request("/api/v1/files"), { name: "AbortError" });
  assert.equal(calls.length, 1);
});

test("legacy mode accepts v1 requests while retaining unauthenticated health requests", async () => {
  const calls = [];
  const h = harness(async (path, init) => {
    calls.push([path, init.headers.get("X-LightIsle-Root-Generation")]);
    return new Response("{}", { status: 200 });
  });
  h.scope.legacySelected = true;
  await h.transport.request("/api/v1/files");
  assert.equal(rootContextKey(h.scope), "v1:compatibility");
  await h.transport.request("/api/v1/auth/status");
  assert.deepEqual(calls, [["/api/v1/files", null], ["/api/v1/auth/status", null]]);
});

test("stale root response never reaches a newer view", async () => {
  let deliver;
  const h = harness(() => new Promise(resolve => { deliver = resolve; }));
  const request = h.transport.request("/api/v2/roots/root-a/files");
  h.scope.epoch++;
  h.scope.generation++;
  deliver(new Response("{}", { status: 200 }));
  await assert.rejects(request, { name: "AbortError" });
});

test("generation mismatch notifies once and preserves the actionable message", async () => {
  const h = harness(async () => new Response('{"error":"root_generation_changed"}',
    { status: 409, headers: { "content-type": "application/json" } }));
  await assert.rejects(h.transport.request("/api/v2/roots/root-a/files"), /共享目录已变化/);
  assert.equal(h.changes, 1);
});

test("switch in progress blocks new requests except explicit allowed calls", async () => {
  let calls = 0;
  const h = harness(async () => { calls++; return new Response("{}", { status: 200 }); });
  h.scope.switching = true;
  await assert.rejects(h.transport.request("/api/v2/roots/root-a/files"), { name: "AbortError" });
  await h.transport.request("/api/v2/roots/root-a/files", {}, true);
  assert.equal(calls, 1);
});

test("both root switch and caller cancellation abort the fetch signal", async () => {
  for (const cancelRoot of [true, false]) {
    const requestAbort = new AbortController();
    const h = harness((_path, init) => new Promise((_resolve, reject) => {
      init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true });
    }));
    const request = h.transport.request("/api/v2/roots/root-a/files", { signal: requestAbort.signal });
    const reason = new Error("cancelled");
    if (cancelRoot) h.controller.abort(reason);
    else requestAbort.abort(reason);
    await assert.rejects(request, /cancelled/);
  }
});
