import assert from "node:assert/strict";
import test from "node:test";
import { createRenderer, h } from "vue";
import { useAccountSessions } from "./useAccountSessions.ts";

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

function mountSessions(overrides = {}) {
  let sessions;
  const auth = { value: true };
  const calls = { revoked: [], loggedOut: 0, notices: 0 };
  const app = renderer.createApp({
    setup() {
      sessions = useAccountSessions({
        authenticated: () => auth.value,
        read: async () => ({ sessions: [{ id: "device-1", current: true }], truncated: false }),
        logoutCurrent: async () => { calls.loggedOut++; auth.value = false; sessions.reset(); },
        onCurrentLogout: () => { calls.notices++; },
        confirm: () => true,
        revoke: async path => { calls.revoked.push(path); },
        ...overrides,
      });
      return () => h("div");
    },
  });
  app.mount({ children: [] });
  return { sessions, app, auth, calls };
}

test("loads session list only for signed-in users", async t => {
  const { sessions, app, auth } = mountSessions();
  t.after(() => app.unmount());
  await sessions.loadLoginSessions();
  assert.equal(sessions.loginSessions.value.length, 1);
  assert.equal(sessions.sessionsLoaded.value, true);
  auth.value = false;
  sessions.reset();
  await sessions.loadLoginSessions();
  assert.deepEqual(sessions.loginSessions.value, []);
  assert.equal(sessions.sessionsLoaded.value, false);
});

test("late session response cannot repopulate logout state", async t => {
  let resolveRequest;
  const { sessions, app, auth } = mountSessions({
    read: () => new Promise(resolve => { resolveRequest = resolve; }),
  });
  t.after(() => app.unmount());
  const inflight = sessions.loadLoginSessions();
  auth.value = false;
  sessions.reset();
  resolveRequest({ sessions: [{ id: "old-admin-device", current: true }], truncated: false });
  await inflight;
  assert.deepEqual(sessions.loginSessions.value, []);
  assert.equal(sessions.sessionsLoaded.value, false);
  assert.equal(sessions.sessionsLoading.value, false);
});

test("revoking other devices posts the precise API path and reloads", async t => {
  const { sessions, app, calls } = mountSessions();
  t.after(() => app.unmount());
  await sessions.revokeLoginSession("others");
  assert.deepEqual(calls.revoked, ["/api/v2/auth/sessions/others"]);
  assert.equal(sessions.sessionsLoaded.value, true);
  assert.match(sessions.sessionsMessage.value, /已撤销/);
});

test("revoking current device logs out instead of reloading its old sessions", async t => {
  const { sessions, app, calls } = mountSessions();
  t.after(() => app.unmount());
  await sessions.revokeLoginSession({ id: "current/123", current: true });
  assert.deepEqual(calls.revoked, ["/api/v2/auth/sessions/current%2F123"]);
  assert.equal(calls.loggedOut, 1);
  assert.equal(calls.notices, 1);
  assert.equal(sessions.sessionsLoaded.value, false);
});

test("declining confirmation does not revoke a session", async t => {
  const { sessions, app, calls } = mountSessions({ confirm: () => false });
  t.after(() => app.unmount());
  await sessions.revokeLoginSession("others");
  assert.deepEqual(calls.revoked, []);
});
