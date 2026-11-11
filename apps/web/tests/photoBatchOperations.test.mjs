import test from "node:test";
import assert from "node:assert/strict";
import {photoArchivePath,photoShareUrl,preparePhotoArchive,runPhotoBatch} from "../src/photoBatchOperations.ts";

const items=[{id:1,path:"photos/a.jpg",name:"a.jpg"},{id:2,path:"photos/b.jpg",name:"b.jpg"},{id:3,path:"photos/c.jpg",name:"c.jpg"}];

test("share links stay bound to the selected root and reject invalid tokens",()=>{
  const token="A12345678901234567890";
  assert.equal(photoShareUrl("https://example.test","disk-A",7,token),`https://example.test/api/v2/roots/disk-A/public/file/${token}?rootGeneration=7`);
  assert.throws(()=>photoShareUrl("https://example.test","disk-A",7,"bad/token"),/share_result_uncertain/);
});

test("download checks the frozen selection and does not start after switching roots",async()=>{
  assert.equal(photoArchivePath([2,7]),"/api/v2/photos/archive?ids=2%2C7");
  assert.throws(()=>photoArchivePath([2,2]),/invalid_archive_selection/);
  let current=true,downloads=0;
  const stopped=await preparePhotoArchive("/archive",()=>current,async()=>{current=false;return {ok:true,status:200}},()=>downloads++);
  assert.equal(stopped.stopped,true);
  assert.equal(downloads,0);
  current=true;
  const denied=await preparePhotoArchive("/archive",()=>current,async()=>({ok:false,status:413}),()=>downloads++);
  assert.equal(denied.status,413);
  assert.equal(downloads,0);
  const ready=await preparePhotoArchive("/archive",()=>current,async()=>({ok:true,status:200}),()=>downloads++);
  assert.equal(ready.started,true);
  assert.equal(downloads,1);
});

test("batch stops on a failure and distinguishes completed and unattempted items",async()=>{
  const sent=[];
  const result=await runPhotoBatch(items,async item=>{sent.push(item.id);if(item.id===2)throw new Error("file_already_exists")},()=>true);
  assert.deepEqual(sent,[1,2]);
  assert.deepEqual(result.completed.map(item=>item.id),[1]);
  assert.equal(result.failure.item.id,2);
  assert.deepEqual(result.remaining.map(item=>item.id),[3]);
});

test("a physical root or view switch prevents subsequent writes",async()=>{
  let current=true;
  const sent=[];
  const result=await runPhotoBatch(items,async item=>{sent.push(item.id);current=false},()=>current);
  assert.deepEqual(sent,[1]);
  assert.deepEqual(result.completed.map(item=>item.id),[1]);
  assert.equal(result.stopped,true);
  assert.deepEqual(result.remaining.map(item=>item.id),[2,3]);
});

test("selection is frozen and invalid repeated items are rejected",async()=>{
  const original=items.map(item=>({...item}));
  const sent=[];
  await runPhotoBatch(original,async item=>{sent.push(item.path);original[1].path="changed"},()=>true);
  assert.deepEqual(sent,["photos/a.jpg","photos/b.jpg","photos/c.jpg"]);
  await assert.rejects(runPhotoBatch([items[0],items[0]],async()=>{},()=>true));
});
