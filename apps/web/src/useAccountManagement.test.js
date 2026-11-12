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
  const state = { admin: true };
  const calls = { writes: [], logout: 0, notice: 0 };
  const dependencies = {
    isAdmin: () => state.admin,
    read: async () => ({ users: [{ id: 1, username: "admin", role: "admin", enabled: true }] }),
    write: async (path, method, body) => {
      calls.writes.push({ path, method, body });
      return { ok: true };
    },
    logout: async () => { calls.logout++; accounts.resetAccountState(); },
    onOwnPasswordChanged: () => { calls.notice++; },
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

test("loads read-only member accounts when admin is active", async t => {
  const { app, accounts } = mountAccounts({
    read: async () => ({
      users: [
        { id: 1, username: "admin", role: "admin", enabled: true },
        { id: 2, username: "alice", role: "member", enabled: true },
      ],
    }),
  });
  t.after(() => app.unmount());
  await accounts.loadAccounts();
  assert.equal(accounts.accounts.value.length, 2);
  assert.equal(accounts.accounts.value[1]?.username, "alice");
});

test("validates own password length and confirmation before calling API", async t => {
  const { app, accounts, calls } = mountAccounts();
  t.after(() => app.unmount());
  accounts.currentPassword.value = "old-secret-value";
  accounts.nextPassword.value = "short";
  accounts.repeatPassword.value = "short";
  await accounts.changeOwnPassword();
  assert.match(accounts.passwordError.value, /12–256/);
  assert.equal(calls.writes.length, 0);

  accounts.nextPassword.value = "new-password-with-length";
  accounts.repeatPassword.value = "mismatched-password-length";
  await accounts.changeOwnPassword();
  assert.match(accounts.passwordError.value, /不一致/);
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

test("creates member account, toggles enabled state, and resets member password", async t => {
  const { app, accounts, calls } = mountAccounts({
    read: async () => ({
      users: [
        { id: 1, username: "admin", role: "admin", enabled: true },
        { id: 2, username: "alice", role: "member", enabled: true },
      ],
    }),
  });
  t.after(() => app.unmount());

  accounts.newUsername.value = "alice";
  accounts.newPassword.value = "initial-password-123";
  await accounts.createMemberAccount();
  assert.equal(calls.writes[0]?.path, "/api/v2/users");
  assert.equal(calls.writes[0]?.method, "POST");
  assert.deepEqual(calls.writes[0]?.body, {
    username: "alice",
    password: "initial-password-123",
    role: "member",
  });
  assert.equal(accounts.newUsername.value, "");
  assert.equal(accounts.newPassword.value, "");

  await accounts.toggleMemberEnabled({
    id: 2,
    username: "alice",
    role: "member",
    enabled: true,
    createdAt: 1,
  });
  assert.equal(calls.writes[1]?.path, "/api/v2/users/2");
  assert.equal(calls.writes[1]?.method, "PATCH");
  assert.deepEqual(calls.writes[1]?.body, { enabled: false });

  accounts.openResetMemberPassword({
    id: 2,
    username: "alice",
    role: "member",
    enabled: true,
    createdAt: 1,
  });
  accounts.resetMemberNewPassword.value = "reset-password-456";
  accounts.resetMemberRepeatPassword.value = "reset-password-456";
  await accounts.submitResetMemberPassword();
  assert.equal(calls.writes[2]?.path, "/api/v2/users/2/password");
  assert.equal(calls.writes[2]?.method, "POST");
  assert.deepEqual(calls.writes[2]?.body, { password: "reset-password-456" });
  assert.equal(accounts.resetTargetUser.value, null);
});

test("computer grants reject stale member loads and require a successful read", async t => {
  const pending = new Map();
  const { app, accounts, calls } = mountAccounts({
    read: path => new Promise((resolve, reject) => pending.set(path, { resolve, reject })),
  });
  t.after(() => app.unmount());
  const alice = { id: 2, username: "alice", role: "member", enabled: true, createdAt: 1 };
  const bob = { id: 3, username: "bob", role: "member", enabled: true, createdAt: 1 };
  const aliceLoad = accounts.editComputerGrants(alice);
  const bobLoad = accounts.editComputerGrants(bob);
  pending.get("/api/v2/computer-files/grants/3").resolve({ mode: "none", folders: [] });
  await bobLoad;
  pending.get("/api/v2/computer-files/grants/2").resolve({ mode: "all", folders: [] });
  await aliceLoad;
  assert.equal(accounts.computerGrantUser.value.id, 3);
  assert.equal(accounts.computerGrantMode.value, "none");
  await accounts.saveComputerGrants();
  assert.deepEqual(calls.writes[0], { path: "/api/v2/computer-files/grants/3", method: "PUT", body: { mode: "none", paths: [] } });

  const failedLoad = accounts.editComputerGrants(alice);
  pending.get("/api/v2/computer-files/grants/2").reject(new Error("offline"));
  await failedLoad;
  assert.equal(accounts.computerGrantReady.value, false);
  await accounts.saveComputerGrants();
  assert.equal(calls.writes.length, 1);
});

test("computer grant confirmation cannot be applied to a newly selected member", async t => {
  let approve;
  const { app, accounts, calls } = mountAccounts({
    read: async () => ({ mode: "all", folders: [] }),
    confirm: () => new Promise(resolve => { approve = resolve; }),
  });
  t.after(() => app.unmount());
  const alice = { id: 2, username: "alice", role: "member", enabled: true, createdAt: 1 };
  const bob = { id: 3, username: "bob", role: "member", enabled: true, createdAt: 1 };
  await accounts.editComputerGrants(alice);
  const save = accounts.saveComputerGrants();
  await accounts.editComputerGrants(bob);
  approve(true);
  await save;
  assert.equal(calls.writes.length, 0);
});

test("reselecting the same member cannot restore an older grant response", async t => {
  const pending = [];
  const { app, accounts } = mountAccounts({ read: () => new Promise(resolve => pending.push(resolve)) });
  t.after(() => app.unmount());
  const alice = { id: 2, username: "alice", role: "member", enabled: true, createdAt: 1 };
  const first = accounts.editComputerGrants(alice);
  const second = accounts.editComputerGrants(alice);
  pending[1]({ mode: "none", folders: [] });
  await second;
  pending[0]({ mode: "all", folders: [] });
  await first;
  assert.equal(accounts.computerGrantMode.value, "none");
  assert.equal(accounts.computerGrantReady.value, true);
});
