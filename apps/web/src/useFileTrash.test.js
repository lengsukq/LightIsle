import assert from "node:assert/strict";
import test from "node:test";
import { createRenderer, h } from "vue";
import { useFileTrash } from "./useFileTrash.ts";

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

function mountTrash(overrides = {}) {
  let trash;
  const context = { epoch: 1 };
  const writes = [];
  let refreshes = 0;
  const deps = {
    epoch: () => context.epoch,
    path: path => path,
    read: async path => path === "/api/v2/trash/retention"
      ? { enabled: true, days: 30 }
      : { entries: [
        { id: "old", name: "old", deletedAt: "2026-10-01", originalPath: "Docs/old" },
        { id: "new", name: "new", deletedAt: "2026-11-01", originalPath: "Docs/new" },
      ] },
    write: async path => { writes.push({ method: "POST", path }); },
    remove: async path => { writes.push({ method: "DELETE", path }); },
    refreshFiles: async () => { refreshes++; },
    isAbort: error => error instanceof Error && error.name === "AbortError",
    errorLabel: error => String(error),
    confirm: () => true,
    ...overrides,
  };
  const app = renderer.createApp({
    setup() {
      trash = useFileTrash(deps);
      return () => h("div");
    },
  });
  app.mount({ children: [] });
  return { app, trash, context, writes, get refreshes() { return refreshes; } };
}

test("trash entries sort newest first and retention belongs to same root", async t => {
  const fixture = mountTrash();
  t.after(() => fixture.app.unmount());
  await fixture.trash.loadTrash();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(fixture.trash.trashItems.value.map(e => e.id), ["new", "old"]);
  assert.deepEqual(fixture.trash.trashRetention.value, { enabled: true, days: 30 });
  assert.equal(fixture.trash.trashLoading.value, false);
});

test("root switch invalidates a late trash result", async t => {
  let finish;
  const fixture = mountTrash({
    read: path => new Promise(resolve => { finish = resolve; }),
  });
  t.after(() => fixture.app.unmount());
  const request = fixture.trash.loadTrash();
  fixture.context.epoch++;
  fixture.trash.reset();
  finish({ entries: [{ id: "obsolete" }] });
  await request;
  assert.deepEqual(fixture.trash.trashItems.value, []);
  assert.equal(fixture.trash.trashLoading.value, false);
});

test("restore and purge use root-bound endpoints and refresh", async t => {
  const fixture = mountTrash();
  t.after(() => fixture.app.unmount());
  const entry = { id: "a b", name: "notes.txt", deletedAt: "", originalPath: "Docs/notes.txt" };
  await fixture.trash.restoreTrash(entry);
  assert.equal(fixture.writes[0].path, "/api/v2/files/trash/a%20b/restore");
  assert.equal(fixture.refreshes, 1);
  await fixture.trash.purgeTrashItem(entry);
  assert.deepEqual(fixture.writes[1], { method: "DELETE", path: "/api/v2/files/trash/a%20b" });
});

test("purge never deletes when user cancels or root changes during confirmation", async t => {
  const fixture = mountTrash({
    confirm: () => false,
  });
  t.after(() => fixture.app.unmount());
  const item = { id: "1", name: "notes.txt", deletedAt: "", originalPath: "notes.txt" };
  await fixture.trash.purgeTrashItem(item);
  assert.equal(fixture.writes.length, 0);
  let epoch = 1;
  const changed = mountTrash({
    epoch: () => epoch,
    confirm: () => { epoch++; return true; },
  });
  t.after(() => changed.app.unmount());
  await changed.trash.purgeTrashItem(item);
  assert.equal(changed.writes.length, 0);
});

test("closing trash invalidates pending response without old data flashing", async t => {
  let resolve;
  const fixture = mountTrash({ read: () => new Promise(done => { resolve = done; }) });
  t.after(() => fixture.app.unmount());
  const open = fixture.trash.openTrash();
  await fixture.trash.openTrash();
  resolve({ entries: [{ id: "old" }] });
  await open;
  assert.equal(fixture.trash.showingTrash.value, false);
  assert.equal(fixture.trash.trashLoading.value, false);
  assert.deepEqual(fixture.trash.trashItems.value, []);
});
