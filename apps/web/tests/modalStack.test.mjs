import assert from "node:assert/strict";
import test from "node:test";
import { hasActiveModalLayer, pushModalLayer } from "../src/modalStack.ts";

test("modalStack dispatches Escape strictly to the topmost active layer and restores body scroll", (t) => {
  const prevWindow = globalThis.window;
  const prevDocument = globalThis.document;
  const listeners = new Map();
  const bodyStyle = { overflow: "auto" };

  globalThis.window = {
    addEventListener(name, fn) {
      listeners.set(name, fn);
    },
    removeEventListener(name) {
      listeners.delete(name);
    },
  };
  globalThis.document = { body: { style: bodyStyle } };

  t.after(() => {
    globalThis.window = prevWindow;
    globalThis.document = prevDocument;
  });

  const closed = [];
  const baseLayer = pushModalLayer({
    onEsc: () => closed.push("base"),
    lockScroll: true,
  });
  assert.equal(hasActiveModalLayer(), true);
  assert.equal(baseLayer.isTop(), true);
  assert.equal(bodyStyle.overflow, "hidden");

  const confirmLayer = pushModalLayer({
    onEsc: () => closed.push("confirm"),
    lockScroll: true,
  });
  assert.equal(baseLayer.isTop(), false);
  assert.equal(confirmLayer.isTop(), true);

  const keyHandler = listeners.get("keydown");
  assert.equal(typeof keyHandler, "function");

  // Pressing Escape while confirmLayer is on top must ONLY invoke confirmLayer
  let prevented = false;
  keyHandler({
    key: "Escape",
    defaultPrevented: false,
    preventDefault() {
      prevented = true;
    },
    stopPropagation() {},
  });
  assert.equal(prevented, true);
  assert.deepEqual(closed, ["confirm"]);

  // Disposing confirmLayer promotes baseLayer back to top while keeping scroll locked
  confirmLayer.dispose();
  assert.equal(baseLayer.isTop(), true);
  assert.equal(bodyStyle.overflow, "hidden");

  keyHandler({
    key: "Escape",
    defaultPrevented: false,
    preventDefault() {},
    stopPropagation() {},
  });
  assert.deepEqual(closed, ["confirm", "base"]);

  // Disposing the last layer restores original body overflow and detaches listener
  baseLayer.dispose();
  assert.equal(hasActiveModalLayer(), false);
  assert.equal(bodyStyle.overflow, "auto");
  assert.equal(listeners.has("keydown"), false);
});
