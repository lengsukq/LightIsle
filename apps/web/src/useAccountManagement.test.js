import assert from "node:assert/strict";
import test from "node:test";
import { createRenderer, h } from "vue";
import { useAccountManagement } from "./useAccountManagement.ts";

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

function mountAccounts(overrides = {}) {
  let accounts;
  const state = { admin: true, root: { id: "disk-A", generation: 9 } };
  const calls = { writes: [], allocations: [], logout: 0, changed: 0, notice: 0 };
  const dependencies = {
    isAdmin: () => state.admin,
    read: async () => ({ users: [{ id: 1, username: "admin", role: "admin", enabled: true }] }),
    write: async (path, method, body) => {
      calls.writes.push({ path, method, body });
      return { id: 42, username: "member" };
    },
    confirm: () => true,
    logout: async () => { calls.logout++; accounts.resetAccountState(); },
    onOwnPasswordChanged: () => { calls.notice++; },
    storageRoot: () => state.root,
    assignStorage: async (id, category, root) => {
      calls.allocations.push({
        accountId: id, category, rootID: root.id, generation: root.generation,
      });
    },
    storageChanged: () => { calls.changed++; },
    ...overrides,
  };
  const app = renderer.createApp({
    setup() {
      accounts = useAccountManagement(dependencies);
      return () => h("div");
    },
  });
  app.mount({ children: [] });
  return { app, accounts, state, calls };
}

test("loads admin accounts and discards a response after role loss", async t => {
  let complete;
  const { app, accounts, state } = mountAccounts({
    read: () => new Promise(resolve => { complete = resolve; }),
  });
  t.after(() => app.unmount());
  const pending = accounts.loadAccounts();
  state.admin = false;
  accounts.resetAccountState();
  complete({ users: [{ id: 7, username: "old-admin" }] });
  await pending;
  assert.equal(accounts.accounts.value.length, 0);
});

test("creates a member and allocates three categories on the selected physical root", async t => {
  const { app, accounts, calls } = mountAccounts();
  t.after(() => app.unmount());
  accounts.newUsername.value = "member";
  accounts.newPassword.value = "a-long-password";
  await accounts.addAccount();
  assert.deepEqual(calls.allocations.map(a => a.category), ["files", "photos", "videos"]);
  assert.ok(calls.allocations.every(a =>
    a.accountId === 42 && a.rootID === "disk-A" && a.generation === 9));
  assert.equal(calls.changed, 1);
  assert.equal(accounts.userBusy.value, false);
});

test("stops allocating further categories when storage root changes", async t => {
  let selected = { id: "disk-A", generation: 9 };
  const assigned = [];
  const { app, accounts } = mountAccounts({
    storageRoot: () => selected,
    assignStorage: async (id, category) => {
      assigned.push(category);
      selected = { id: "disk-B", generation: 10 };
    },
  });
  t.after(() => app.unmount());
  await accounts.addAccount();
  assert.deepEqual(assigned, ["files"]);
  assert.match(accounts.userError.value, /硬盘已变化/);
});

test("rejects invalid member passwords before an API mutation", async t => {
  const { app, accounts, calls } = mountAccounts();
  t.after(() => app.unmount());
  accounts.openMemberReset({ id: 2, username: "guest", role: "member", enabled: true });
  accounts.resetPassword.value = "short";
  accounts.resetConfirm.value = "short";
  await accounts.submitMemberReset();
  assert.match(accounts.resetError.value, /12–256/);
  assert.equal(calls.writes.length, 0);
});

test("changing own password triggers logout only after server success", async t => {
  const { app, accounts, calls } = mountAccounts();
  t.after(() => app.unmount());
  accounts.currentPassword.value = "old-secret-value";
  accounts.nextPassword.value = "new-password-with-length";
  accounts.repeatPassword.value = accounts.nextPassword.value;
  await accounts.changeOwnPassword();
  assert.equal(calls.writes[0]?.path, "/api/v2/auth/password");
  assert.equal(calls.logout, 1);
  assert.equal(calls.notice, 1);
});
