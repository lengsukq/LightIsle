import test from "node:test";
import assert from "node:assert/strict";
import {recoverUploadOffset} from "../src/uploadChunkRecovery.ts";
import {describeUserFacingError} from "../src/userFacingError.ts";

function failure(status,code){
 return new Response(JSON.stringify({error:code}),{status});
}
test("only exact offset_mismatch may refresh the same upload task",async()=>{
 let reads=0;
 const state=await recoverUploadOffset(failure(409,"offset_mismatch"),async()=>{
  reads++;return {id:"upload-a",offset:4096};
 });
 assert.deepEqual(state,{id:"upload-a",offset:4096});
 assert.equal(reads,1);
});
test("all other 409 and 507 errors stop rather than fetching or retrying old upload",async()=>{
 for(const [status,code] of [
  [409,"root_generation_changed"],[409,"storage_accounting_conflict"],
  [409,"file_permission_denied"],[409,"not_found"],[507,"insufficient_storage_space"],
 ]) {
  let reads=0;
  await assert.rejects(
   recoverUploadOffset(failure(status,code),async()=>{reads++;return {}}),
   error=>{
    assert.equal(error.code,code);
    assert.equal(error.status,status);
    assert.match(describeUserFacingError(error),new RegExp(`HTTP ${status}`));
    return true;
   },
  );
  assert.equal(reads,0,`${code} must not resume or change disk`);
 }
});
test("non-JSON 409 never qualifies as a resumable offset conflict",async()=>{
 let reads=0;
 await assert.rejects(
  recoverUploadOffset(new Response("<html>Bad gateway</html>",{status:409}),
   async()=>{reads++;return {}}),
  /HTTP 409/,
 );
 assert.equal(reads,0);
});
