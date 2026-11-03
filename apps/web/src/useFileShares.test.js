import assert from "node:assert/strict";
import test from "node:test";
import { createRenderer, h } from "vue";
import { useFileShares } from "./useFileShares.ts";

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

const item = { name: "notes.txt", path: "Docs/notes.txt", type: "file", size: 4, modified: "" };
function mountShares(overrides = {}) {
  let shares;
  const calls = { created: [], revoked: [], lists: 0 };
  const state = { currentRoot: "disk-A", authenticated: true };
  const api = {
    canList: () => state.authenticated,
    context: () => state.currentRoot,
    apiPath: path => "/api/v2/roots/" + state.currentRoot + path.slice("/api/v2".length),
    mediaPath: path => "/api/v2/roots/" + state.currentRoot + path.slice("/api/v2".length),
    read: async path => { calls.lists++; return { shares: [] }; },
    write: async (path, body) => { calls.created.push({ path, body }); return { token: "private-token", share: {} }; },
    remove: async path => { calls.revoked.push(path); },
    confirm: () => true,
    origin: () => "https://nas.example",
    ...overrides,
  };
  const app = renderer.createApp({
    setup() {
      shares = useFileShares(api);
      return () => h("div");
    },
  });
  app.mount({ children: [] });
  return { app, shares, calls, state };
}

test("creates root-bound shares, lists results, and restores submit button", async t => {
  const { app, shares, calls } = mountShares();
  t.after(() => app.unmount());
  shares.openShareDialog(item);
  await shares.createFileShare();
  assert.equal(calls.created.length, 1);
  assert.equal(calls.created[0].path, "/api/v2/roots/disk-A/file-shares");
  assert.equal(
    shares.shareCreatedLink.value,
    "https://nas.example/api/v2/roots/disk-A/public/file/private-token",
  );
  assert.equal(shares.shareCreating.value, false);
  assert.equal(shares.sharesLoaded.value, true);
});

test("share response from prior root is discarded after a storage switch", async t => {
  let finish;
  const { app, shares, state } = mountShares({
    write: () => new Promise(resolve => { finish = resolve; }),
  });
  t.after(() => app.unmount());
  shares.openShareDialog(item);
  const pending = shares.createFileShare();
  state.currentRoot = "disk-B";
  shares.reset();
  finish({ token: "old-root-token" });
  await pending;
  assert.equal(shares.shareCreatedLink.value, "");
  assert.equal(shares.shareCreating.value, false);
});

test("modal switches invalidate earlier create responses", async t => {
  let finish;
  const { app, shares } = mountShares({
    write: () => new Promise(resolve => { finish = resolve; }),
  });
  t.after(() => app.unmount());
  shares.openShareDialog(item);
  const pending = shares.createFileShare();
  shares.openShareDialog({ ...item, name: "other.txt", path: "other.txt" });
  finish({ token: "old-item-token" });
  await pending;
  assert.equal(shares.shareCreatedLink.value, "");
});

test("rejects unsafe share options before calling the API", async t => {
  const { app, shares, calls } = mountShares();
  t.after(() => app.unmount());
  shares.openShareDialog(item);
  shares.sharePassword.value = "123";
  await shares.createFileShare();
  assert.match(shares.shareError.value, /密码/);
  shares.sharePassword.value = "";
  shares.shareMaxDownloads.value = 100001;
  await shares.createFileShare();
  assert.match(shares.shareError.value, /100000/);
  assert.equal(calls.created.length, 0);
});

test("revoke confirmation cannot send old path into newly selected physical root", async t => {
  const { app, shares, calls, state } = mountShares({
    confirm: () => { state.currentRoot = "disk-B"; return true; },
  });
  t.after(() => app.unmount());
  await shares.revokeFileShare({ id: "share-one", path: "notes.txt", createdAt: 1, expiresAt: 2 });
  assert.deepEqual(calls.revoked, []);
});
