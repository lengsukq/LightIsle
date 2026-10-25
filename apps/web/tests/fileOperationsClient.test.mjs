import assert from "node:assert/strict";
import test from "node:test";
import { createFileOperationsClient } from "../src/fileOperationsClient.js";

test("file operation lists destination folders from the current root", async () => {
  const calls = [];
  const client = createFileOperationsClient({
    apiPath: path => "/root-a" + path,
    get: async endpoint => { calls.push(endpoint); return { entries: [], nextCursor: "", canWrite: true }; },
    write: async () => { throw Error("unexpected write"); },
    getEpoch: () => 4,
  });
  assert.deepEqual(await client.listFolders("相册/2026", "next-id"),
    { entries: [], nextCursor: "", canWrite: true });
  assert.equal(calls.length, 1);
  const request = new URL(calls[0], "https://local.test");
  assert.equal(request.pathname, "/root-a/api/v1/files");
  assert.equal(request.searchParams.get("path"), "相册/2026");
  assert.equal(request.searchParams.get("limit"), "100");
  assert.equal(request.searchParams.get("cursor"), "next-id");
});

test("copy and move only send recognized file-operation payloads", async () => {
  const submitted = [];
  const client = createFileOperationsClient({
    apiPath: path => path, get: async () => ({}),
    write: async (...args) => { submitted.push(args); return { done: true }; },
    getEpoch: () => 1,
  });
  await client.commit({ action: "copy", from: "a", to: "b", conflict: "rename" });
  await client.commit({ action: "move", from: "b", to: "c", conflict: "" });
  assert.deepEqual(submitted.map(args => args[2].action), ["copy", "move"]);
  assert.deepEqual(submitted[0], ["/api/v1/files/operations", "POST",
    { action: "copy", from: "a", to: "b", conflict: "rename" }]);
  await assert.rejects(client.commit({ action: "delete", from: "a", to: "b", conflict: "" }),
    /invalid_file_operation/);
  assert.equal(submitted.length, 2);
});

test("a root switch rejects stale operation responses", async () => {
  let epoch = 1;
  let answer;
  const client = createFileOperationsClient({
    apiPath: path => path,
    get: () => new Promise(resolve => { answer = resolve; }),
    write: () => new Promise(resolve => { answer = resolve; }),
    getEpoch: () => epoch,
  });
  const listing = client.listFolders(".", "");
  epoch++;
  answer({ entries: [] });
  await assert.rejects(listing, { name: "AbortError" });
  const operation = client.commit({ action: "move", from: "a", to: "b", conflict: "" });
  epoch++;
  answer({ done: true });
  await assert.rejects(operation, { name: "AbortError" });
});
