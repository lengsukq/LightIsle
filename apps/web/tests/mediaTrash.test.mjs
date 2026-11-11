import test from "node:test";
import assert from "node:assert/strict";
import { trashMediaOriginals } from "../src/mediaTrash.ts";

test("media trash sends one bounded batch and reports partial failures", async () => {
  const requests = [];
  const outcome = await trashMediaOriginals(["a.jpg", "b.mov"], async paths => {
    requests.push(paths);
    return {results:[{path:"a.jpg",success:true},{path:"b.mov",success:false}]};
  }, () => true);
  assert.deepEqual(requests, [["a.jpg", "b.mov"]]);
  assert.deepEqual(outcome, {completed:1,cancelled:false,failed:["b.mov"],needsRootCheck:false});
});

test("media trash reports uncertain results after a disk disconnect", async () => {
  const outcome = await trashMediaOriginals(["a.jpg", "b.mov"], async () => ({results:[
    {path:"a.jpg",success:false,error:"storage_operation_uncertain"},
    {path:"b.mov",success:false,error:"root_unavailable"},
  ]}), () => true);
  assert.equal(outcome.completed, 0);
  assert.equal(outcome.needsRootCheck, true);
  assert.deepEqual(outcome.failed, ["a.jpg", "b.mov"]);
});

test("media trash refuses changed root and duplicate paths", async () => {
  let sent = false;
  const stopped = await trashMediaOriginals(["a.jpg"], async () => {
    sent = true;
    return {results:[]};
  }, () => false);
  assert.equal(sent, false);
  assert.equal(stopped.cancelled, true);
  await assert.rejects(trashMediaOriginals(["a.jpg","a.jpg"], async () => ({results:[]}), () => true));
});
