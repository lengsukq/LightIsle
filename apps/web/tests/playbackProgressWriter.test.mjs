import assert from 'node:assert/strict';
import test from 'node:test';
import {createPlaybackProgressWriter} from '../src/playbackProgressWriter.js';

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return {promise, resolve, reject};
}

test('pause and tick updates are serialized; only the newest queued position is saved', async () => {
  const gate = deferred();
  const values = [];
  const writer = createPlaybackProgressWriter(async value => {
    values.push(value.position);
    if (value.position === 10) await gate.promise;
  });
  const first = writer.save({key:'film',position:10});
  const second = writer.save({key:'film',position:12});
  writer.save({key:'film',position:16});
  assert.deepEqual(values,[10]);
  gate.resolve();
  await Promise.all([first,second]);
  assert.deepEqual(values,[10,16]);
  assert.equal(writer.hasPending(),false);
});

test('network failure preserves latest snapshot and permits explicit retry after close', async () => {
  const calls=[];const errors=[];
  let offline=true;
  const writer=createPlaybackProgressWriter(async value=>{
    calls.push(value.position);
    if(offline)throw new Error('offline');
  },{onError:(error)=>errors.push(error.message)});
  await writer.save({key:'film',position:14});
  assert.equal(writer.hasPending(),true);
  assert.deepEqual(errors,['offline']);
  offline=false;
  await writer.retry();
  assert.deepEqual(calls,[14,14]);
  assert.equal(writer.hasPending(),false);
});

test('a failed old-root snapshot stays retryable without blocking the current root',async()=>{
  const calls=[];const errors=[];const saved=[];
  let oldRootOnline=false;
  const writer=createPlaybackProgressWriter(async snapshot=>{
    calls.push(snapshot.key);
    if(snapshot.rootId==='root-a'&&!oldRootOnline)throw new Error('offline');
  },{
    onError:(_error,snapshot)=>errors.push(snapshot.key),
    onSaved:snapshot=>saved.push(snapshot.key),
  });
  const oldRoot={key:'root-a:1:7',rootId:'root-a',rootGeneration:1,position:10};
  const currentRoot={key:'root-b:2:7',rootId:'root-b',rootGeneration:2,position:12};

  await writer.save(oldRoot);
  await writer.save(currentRoot);

  assert.deepEqual(calls,['root-a:1:7','root-a:1:7','root-b:2:7']);
  assert.deepEqual(errors,['root-a:1:7','root-a:1:7']);
  assert.deepEqual(saved,['root-b:2:7']);
  assert.equal(writer.hasPending(),true);

  oldRootOnline=true;
  await writer.retry();
  assert.deepEqual(calls,['root-a:1:7','root-a:1:7','root-b:2:7','root-a:1:7']);
  assert.deepEqual(saved,['root-b:2:7','root-a:1:7']);
  assert.equal(writer.hasPending(),false);
});

test('a newer same-key snapshot replaces an older one that fails in flight',async()=>{
  const gate=deferred();const calls=[];
  const writer=createPlaybackProgressWriter(async snapshot=>{
    calls.push(snapshot.position);
    if(snapshot.position===10){await gate.promise;throw new Error('offline')}
  });
  const first=writer.save({key:'film',position:10});
  writer.save({key:'film',position:16});
  gate.resolve();
  await first;
  assert.deepEqual(calls,[10,16]);
  assert.equal(writer.hasPending(),false);
});

test('progress from separate root generations is never merged', async () => {
  const gate=deferred();const seen=[];
  const writer=createPlaybackProgressWriter(async value=>{
    seen.push(value.key);
    if(value.key==='rootA:1:7')await gate.promise;
  });
  const running=writer.save({key:'rootA:1:7'});
  writer.save({key:'rootB:9:7'});
  gate.resolve();await running;
  assert.deepEqual(seen,['rootA:1:7','rootB:9:7']);
});
