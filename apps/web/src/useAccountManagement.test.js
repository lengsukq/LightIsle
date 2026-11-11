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
