import assert from "node:assert/strict";
import test from "node:test";
import { createRenderer, h } from "vue";
import { useFileBrowser } from "./useFileBrowser.ts";

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

test("directory read failure never masquerades as read-only or retain write authorization", async t => {
  let failed = false;
  const {app,browser} = mountBrowser({
    read: async path => {
      if(path === "/api/v2/files/root")return {name:"家庭盘"};
      if(!failed)return {entries:[{path:"Docs/a",name:"a",type:"file",canWrite:true}],nextCursor:"",canWrite:true};
      throw new Error("HTTP 503");
    },
  });
  t.after(()=>app.unmount());
  await browser.loadFiles("Docs");
  assert.equal(browser.fileDirectoryLoaded.value,true);
  assert.equal(browser.currentFolderCanWrite.value,true);
  failed=true;
  await browser.loadFiles("Docs");
  assert.equal(browser.fileDirectoryLoaded.value,false);
  assert.equal(browser.currentFolderCanWrite.value,false);
  assert.equal(browser.fileEntries.value.length,1,"stale content may remain visible with explicit error");
  assert.match(browser.filesError.value,/读取目录失败/);
  failed=false;
  await browser.loadFiles("Docs");
  assert.equal(browser.fileDirectoryLoaded.value,true);
  assert.equal(browser.currentFolderCanWrite.value,true);
  assert.equal(browser.filesError.value,"");
});

function mountBrowser(overrides = {}) {
  const state = { epoch: 1, authenticated: true, available: true };
  const calls = { paths: [], leaves: 0, pageOpens: 0 };
  const deps = {
    authenticated: () => state.authenticated,
    rootAvailable: () => state.available,
    rootError: () => "目录不可用",
    rootEpoch: () => state.epoch,
    apiPath: path => path,
    read: async path => {
      calls.paths.push(path);
      if (path === "/api/v2/files/root") return { name: "家庭盘" };
      if (path.startsWith("/api/v2/files/search")) return { entries: [], truncated: false, canWrite: false };
      return { entries: [{ path: "Docs/a", name: "a", type: "file", size: 1 }], nextCursor: "next", canWrite: false };
    },
    isAbort: error => error instanceof Error && error.name === "AbortError",
    onOpenFiles: () => { calls.pageOpens++; },
    onDirectoryLeave: () => { calls.leaves++; },
    ...overrides,
  };
  let browser;
  const app = renderer.createApp({
    setup() {
      browser = useFileBrowser(deps);
      return () => h("div");
    },
  });
  app.mount({ children: [] });
  return { app, browser, state, calls };
}

test("directory paging retains cursor, read-only permission, and selected path", async t => {
  const { app, browser, calls } = mountBrowser();
  t.after(() => app.unmount());
  await browser.loadFiles("Docs");
  assert.equal(browser.sharedRootName.value, "家庭盘");
  assert.equal(browser.fileEntries.value.length, 1);
  assert.equal(browser.currentFolderCanWrite.value, false);
  browser.checkedFiles.value = ["Docs/a"];
  await browser.loadFiles("Docs", true);
  assert.equal(browser.fileEntries.value.length, 2);
  assert.deepEqual(browser.checkedFiles.value, ["Docs/a"]);
  assert.match(calls.paths.at(-1), /cursor=next/);
});

test("stale directory response cannot repopulate a different physical root", async t => {
  let finish;
  const { app, browser, state } = mountBrowser({
    read: path => path === "/api/v2/files/root"
      ? Promise.resolve({ name: "旧硬盘" })
      : new Promise(resolve => { finish = resolve; }),
  });
  t.after(() => app.unmount());
  const pending = browser.loadFiles("Docs");
  await new Promise(resolve => setImmediate(resolve));
  state.epoch++;
  browser.reset();
  finish({ entries: [{ path: "old.txt" }], canWrite: true });
  await pending;
  assert.deepEqual(browser.fileEntries.value, []);
  assert.equal(browser.currentFolderCanWrite.value, false);
});

test("search response cannot overwrite a newer directory navigation", async t => {
  let finish;
  const { app, browser } = mountBrowser({
    read: path => {
      if (path === "/api/v2/files/root") return Promise.resolve({ name: "家庭盘" });
      if (path.includes("/search")) return new Promise(resolve => { finish = resolve; });
      return Promise.resolve({ entries: [{ path: "new.txt", name: "new.txt" }], nextCursor: "", canWrite: false });
    },
  });
  t.after(() => app.unmount());
  browser.fileSearch.value = "previous";
  const searching = browser.runFileSearch();
  await new Promise(resolve => setImmediate(resolve));
  await browser.loadFiles("New");
  finish({ entries: [{ path: "old.txt" }], truncated: true, canWrite: true });
  await searching;
  assert.deepEqual(browser.fileEntries.value.map(x => x.path), ["new.txt"]);
  assert.equal(browser.currentFolderCanWrite.value, false);
  assert.equal(browser.searchTruncated.value, false);
});

test("unavailable roots never display or grant permissions to old files", async t => {
  const { app, browser, state } = mountBrowser();
  t.after(() => app.unmount());
  await browser.loadFiles("Docs");
  state.available = false;
  await browser.loadFiles("Other");
  assert.equal(browser.fileEntries.value.length, 0);
  assert.equal(browser.currentFolderCanWrite.value, false);
  assert.match(browser.filesError.value, /目录不可用/);
});

test("clearFileSearch returns to pre-search folder and ignores blank queries while supporting 1-char search", async t => {
  const { app, browser, calls } = mountBrowser();
  t.after(() => app.unmount());
  await browser.loadFiles("Docs/2026");
  assert.equal(browser.filesPath.value, "Docs/2026");
  browser.fileSearch.value = "  ";
  await browser.runFileSearch();
  assert.equal(browser.searchingFiles.value, false);
  assert.equal(browser.filesError.value, "");
  browser.fileSearch.value = "周";
  await browser.runFileSearch();
  assert.equal(browser.searchingFiles.value, true);
  browser.fileSearch.value = "report";
  await browser.runFileSearch();
  assert.equal(browser.searchingFiles.value, true);
  assert.equal(browser.filesPath.value, ".");
  await browser.clearFileSearch();
  assert.equal(browser.searchingFiles.value, false);
  assert.equal(browser.fileSearch.value, "");
  assert.equal(browser.filesPath.value, "Docs/2026");
  assert.match(calls.paths.at(-1), /path=Docs%2F2026/);
});
