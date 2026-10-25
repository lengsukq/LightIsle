import assert from "node:assert/strict";
import test from "node:test";
import { createUploadResumeStorage } from "../src/uploadResumeStorage.js";

function fakeSessionStorage(initial = {}) {
  const store = new Map(Object.entries(initial));
  return {
    get length() { return store.size; },
    key(index) { return [...store.keys()][index] ?? null; },
    getItem(key) { return store.get(key) ?? null; },
    setItem(key, value) { store.set(key, value); },
    removeItem(key) { store.delete(key); },
  };
}

test("stale upload hints are cleared but current matching upload is preserved", () => {
  const storage = fakeSessionStorage({
    "lightisle_upload_old": "legacy-id", "upload:path:old": "stale-id",
    "upload:path:current": "current-id", "unrelated": "keep",
  });
  const resume = createUploadResumeStorage(storage);
  const obsolete = resume.collectStaleIDs({
    legacyKey: "lightisle_upload_old", prefix: "upload:path:", key: "upload:path:current",
  });
  assert.deepEqual(obsolete, ["legacy-id", "stale-id"]);
  assert.deepEqual(resume.read("upload:path:current"), { saved: "current-id", resumable: true });
  assert.equal(storage.getItem("unrelated"), "keep");
  resume.save("upload:path:current", "new-id");
  assert.equal(resume.read("upload:path:current").saved, "new-id");
  resume.remove("upload:path:current");
  assert.equal(resume.read("upload:path:current").saved, null);
});

test("restricted session storage disables resume without blocking uploads", () => {
  const blocked = {
    get length() { throw Error("blocked"); },
    key() { throw Error("blocked"); },
    getItem() { throw Error("blocked"); },
    setItem() { throw Error("blocked"); },
    removeItem() { throw Error("blocked"); },
  };
  const resume = createUploadResumeStorage(blocked);
  assert.deepEqual(resume.collectStaleIDs({ legacyKey: "legacy", prefix: "upload:", key: "current" }), []);
  assert.deepEqual(resume.read("current"), { saved: null, resumable: false });
  assert.equal(resume.save("current", "id"), false);
  assert.doesNotThrow(() => resume.remove("current"));
});

test("sessionStorage accessor throwing SecurityError does not stop page initialization or uploads", () => {
  const resume = createUploadResumeStorage(() => { throw new DOMException("blocked", "SecurityError"); });
  assert.deepEqual(resume.collectStaleIDs({ legacyKey: "old", prefix: "upload:", key: "current" }), []);
  assert.deepEqual(resume.read("current"), { saved: null, resumable: false });
  assert.equal(resume.save("current", "id"), false);
  assert.doesNotThrow(() => resume.remove("current"));
});
