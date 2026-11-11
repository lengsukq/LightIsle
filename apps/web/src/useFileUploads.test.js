import assert from "node:assert/strict";
import test from "node:test";
import { createRenderer, h, ref } from "vue";
import { useFileUploads } from "./useFileUploads.ts";

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

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function mountUploads(state, createReply, fetchReply) {
  let uploads;
  const calls = { writes: [], fetches: [] };
  const app = renderer.createApp({
    setup() {
      uploads = useFileUploads({
        username: () => "member",
        selectedRootID: () => state.rootID,
        selectedRootGeneration: () => state.generation,
        rootEpoch: () => state.epoch,
        multiRoot: () => true,
        filesPath: () => ".",
        currentFolderCanWrite: () => true,
        filesLoading: () => false,
        showingTrash: () => false,
        searchingFiles: () => false,
        filesError: ref(""),
        rootFetch: async (path, init = {}) => {
          calls.fetches.push({ path, method: init.method ?? "GET" });
          if (!path.startsWith(`/api/v2/roots/${encodeURIComponent(state.rootID)}/`)) {
            const error = new Error("root_context_changed");
            error.name = "AbortError";
            throw error;
          }
          return fetchReply ? fetchReply(path, init) : new Response(null, { status: 204 });
        },
        read: async path => { throw new Error("unexpected read: " + path); },
        // Deliberately let this simulated response arrive after its signal is
        // aborted, matching a transport or server reply that finishes late.
        write: (path, method) => {
          calls.writes.push({ path, method });
          return typeof createReply === "function" ? createReply(path, method) : createReply.promise;
        },
        loadFiles: async () => {},
        describeError: error => String(error),
      });
      return () => h("div");
    },
  });
  app.mount({ children: [] });
  return { app, uploads, calls };
}

test("late upload creation reply cannot write into the newly selected physical root", async t => {
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, "sessionStorage");
  Object.defineProperty(globalThis, "sessionStorage", {
    configurable: true,
    value: {
      length: 0,
      key: () => null,
      getItem: () => null,
      setItem: () => {},
      removeItem: () => {},
    },
  });
  t.after(() => {
    if (previousStorage) Object.defineProperty(globalThis, "sessionStorage", previousStorage);
    else delete globalThis.sessionStorage;
  });

  const state = { rootID: "disk-A", generation: 9, epoch: 1 };
  const createReply = deferred();
  const hashRead = deferred();
  const hashStarted = deferred();
  const { app, uploads, calls } = mountUploads(state, createReply);
  t.after(() => app.unmount());

  const file = {
    name: "archive.bin",
    size: 3,
    lastModified: 123,
    slice: () => ({
      arrayBuffer: () => {
        hashStarted.resolve();
        return hashRead.promise;
      },
    }),
  };
  uploads.enqueueUploads([file]);
  await hashStarted.promise;
  hashRead.resolve(new Uint8Array([1, 2, 3]).buffer);
  for (let attempt = 0; attempt < 200 && !calls.writes.length; attempt++) {
    await new Promise(resolve => (attempt < 20 ? setImmediate(resolve) : setTimeout(resolve, 2)));
  }
  assert.deepEqual(calls.writes, [{
    path: "/api/v2/roots/disk-A/uploads",
    method: "POST",
  }]);

  // This is the root transition order in App.vue: invalidate the identity,
  // clear root-owned UI state, then cancel and await the active upload.
  state.rootID = "disk-B";
  state.generation = 10;
  state.epoch++;
  uploads.resetUploadsForRoot();
  const cancelled = uploads.cancelAndWaitForUpload();
  createReply.resolve({ id: "upload-created-on-A", offset: 0, size: 3 });
  await cancelled;
  await new Promise(resolve => setImmediate(resolve));

  assert.ok(calls.writes.every(call => call.path.includes("/roots/disk-A/")));
  assert.ok(calls.fetches.every(call => call.path.includes("/roots/disk-A/")));
  assert.equal(calls.fetches.some(call => call.method === "PATCH" || call.path.endsWith("/complete")), false);
  assert.equal(uploads.uploadBusy.value, false);
  assert.equal(uploads.hasActiveUpload(), false);
});

test("cancellation reports an unconfirmed server cleanup instead of success", async t => {
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, "sessionStorage");
  Object.defineProperty(globalThis, "sessionStorage", { configurable:true, value:{length:0,key:()=>null,getItem:()=>null,setItem:()=>{},removeItem:()=>{}} });
  t.after(() => previousStorage ? Object.defineProperty(globalThis, "sessionStorage", previousStorage) : delete globalThis.sessionStorage);
  const state = { rootID:"disk-A", generation:9, epoch:1 };
  const creation = deferred();
  const {app,uploads,calls} = mountUploads(state, creation, () => new Response(null, {status:503}));
  t.after(() => app.unmount());
  uploads.enqueueUploads([{name:"empty.bin",size:0,lastModified:123}]);
  for(let attempt=0;attempt<100&&!calls.writes.length;attempt++) await new Promise(resolve=>setImmediate(resolve));
  assert.equal(calls.writes.length,1);
  const cancelled = uploads.cancelAndWaitForUpload();
  creation.resolve({id:"uncertain-upload",offset:0,size:0});
  await cancelled;
  assert.equal(uploads.uploadStage.value,"cancelled");
  assert.match(uploads.uploadFailure.value,/未能确认服务端清理结果/);
});

test("a lost creation response can cancel by the chosen ID and reports uncertain cleanup", async t => {
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, "sessionStorage");
  Object.defineProperty(globalThis, "sessionStorage", { configurable:true, value:{length:0,key:()=>null,getItem:()=>null,setItem:()=>{},removeItem:()=>{}} });
  t.after(() => previousStorage ? Object.defineProperty(globalThis, "sessionStorage", previousStorage) : delete globalThis.sessionStorage);
  const state = { rootID:"disk-A", generation:9, epoch:1 };
  let rejectCreation;
  const creation = {promise:new Promise((_,reject)=>{rejectCreation=reject;})};
  const {app,uploads,calls} = mountUploads(state, creation, () => new Response(null, {status:503}));
  t.after(() => app.unmount());
  uploads.enqueueUploads([{name:"empty.bin",size:0,lastModified:123}]);
  for(let attempt=0;attempt<100&&!calls.writes.length;attempt++) await new Promise(resolve=>setImmediate(resolve));
  assert.equal(calls.writes.length,1);
  const cancelled = uploads.cancelAndWaitForUpload();
  rejectCreation(new Error("connection_lost"));
  await cancelled;
  assert.match(uploads.uploadFailure.value,/未能确认服务端清理结果/);
  const abort = calls.fetches.find(call=>call.method==="DELETE");
  assert.match(abort?.path ?? "", /\/uploads\/[a-f0-9]{32}$/);
});

test("cancelling and waiting on the current root clears busy so another upload can start", async t => {
  const previousStorage = Object.getOwnPropertyDescriptor(globalThis, "sessionStorage");
  Object.defineProperty(globalThis, "sessionStorage", {
    configurable: true,
    value: {
      length: 0,
      key: () => null,
      getItem: () => null,
      setItem: () => {},
      removeItem: () => {},
    },
  });
  t.after(() => {
    if (previousStorage) Object.defineProperty(globalThis, "sessionStorage", previousStorage);
    else delete globalThis.sessionStorage;
  });

  const state = { rootID: "disk-A", generation: 9, epoch: 1 };
  const firstReply = deferred();
  const secondReply = deferred();
  let createCount = 0;
  const { app, uploads, calls } = mountUploads(state, (path, method) => {
    if (method === "POST" && path.endsWith("/uploads")) {
      createCount += 1;
      return createCount === 1 ? firstReply.promise : secondReply.promise;
    }
    return Promise.resolve({});
  });
  t.after(() => app.unmount());

  const file = { name: "empty.bin", size: 0, lastModified: 123 };
  const waitUntil = async condition => {
    for (let attempt = 0; attempt < 100 && !condition(); attempt++) {
      await new Promise(resolve => setImmediate(resolve));
    }
    assert.ok(condition(), "expected upload state was not reached");
  };

  uploads.enqueueUploads([file]);
  await waitUntil(() => createCount === 1);
  assert.equal(uploads.uploadBusy.value, true);

  const cancelled = uploads.cancelAndWaitForUpload();
  firstReply.resolve({ id: "cancelled-upload", offset: 0, size: 0 });
  await cancelled;
  assert.equal(uploads.uploadBusy.value, false);
  assert.equal(uploads.uploadStage.value, "cancelled");
  assert.equal(uploads.hasActiveUpload(), false);

  uploads.enqueueUploads([file]);
  await waitUntil(() => createCount === 2);
  assert.equal(uploads.uploadBusy.value, true);
  secondReply.resolve({ id: "retry-upload", offset: 0, size: 0 });
  await waitUntil(() => !uploads.hasActiveUpload());

  assert.ok(calls.writes.some(call => call.path.endsWith("/retry-upload/complete")));
  assert.equal(uploads.uploadBusy.value, false);
  assert.equal(uploads.uploadStage.value, "done");
});
