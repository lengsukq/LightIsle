import assert from "node:assert/strict";
import test from "node:test";
import { createRenderer, h } from "vue";
import { bytes, percent, useHostTelemetry } from "./useHostTelemetry.ts";

const renderer = createRenderer({
  createElement: name => ({ name, children: [] }),
  createText: text => ({ text }),
  createComment: text => ({ text }),
  insert: (child, parent) => { parent.children.push(child); child.parent = parent; },
  remove: () => {},
  patchProp: () => {},
  setText: (node, text) => { node.text = text; },
  setElementText: (node, text) => { node.text = text; },
  parentNode: node => node.parent,
  nextSibling: () => null,
});

function mountTelemetry(role) {
  let telemetry;
  const app = renderer.createApp({
    setup() {
      telemetry = useHostTelemetry(() => role.value);
      return () => h("div");
    },
  });
  app.mount({ children: [] });
  return { telemetry, app };
}

const reading = {
  memoryTotal: 200, memoryUsed: 50,
  diskTotal: 100, diskFree: 25,
  cpuPercent: 37,
  diskIo: [{ device: "disk0", readBps: 20, writeBps: 10 }],
};

test("metrics expose bounded values and format nonfinite bytes safely", () => {
  assert.equal(percent(-10), 0);
  assert.equal(percent(125), 100);
  assert.equal(bytes(Number.NaN), "—");
});

test("member health checks never retain admin metrics after logout", async t => {
  const role = { value: "admin" };
  const { telemetry, app } = mountTelemetry(role);
  t.after(() => app.unmount());
  const requested = [];
  t.mock.method(globalThis, "fetch", async path => {
    requested.push(path);
    return { ok: true, json: async () => reading };
  });
  await telemetry.update();
  assert.equal(telemetry.usedMemory.value, 25);
  assert.equal(telemetry.usedDisk.value, 75);
  assert.equal(telemetry.cpu.value, 37);
  assert.match(telemetry.diskActivity.value, /读/);

  telemetry.clear();
  role.value = "member";
  await telemetry.update();
  assert.deepEqual(requested, ["/api/v2/system", "/api/v2/health"]);
  assert.equal(telemetry.stats.value, null);
  assert.equal(telemetry.usedMemory.value, null);
});

test("logout invalidates even a late response that ignored abort", async t => {
  const role = { value: "admin" };
  const { telemetry, app } = mountTelemetry(role);
  t.after(() => app.unmount());
  let deliver;
  t.mock.method(globalThis, "fetch", () => new Promise(resolve => { deliver = resolve; }));
  const pending = telemetry.update();
  telemetry.clear();
  role.value = "member";
  deliver({ ok: true, json: async () => reading });
  await pending;
  assert.equal(telemetry.stats.value, null);
  assert.equal(telemetry.error.value, null);
  assert.equal(telemetry.polling.value, false);
});

test("failed admin request leaves no potentially stale diagnostic data", async t => {
  const role = { value: "admin" };
  const { telemetry, app } = mountTelemetry(role);
  t.after(() => app.unmount());
  let fail = false;
  t.mock.method(globalThis, "fetch", async () => {
    if (fail) return { ok: false, status: 503 };
    return { ok: true, json: async () => reading };
  });
  await telemetry.update();
  assert.ok(telemetry.stats.value);
  fail = true;
  await telemetry.update();
  assert.equal(telemetry.stats.value, null);
  assert.ok(telemetry.error.value);
});
