import test from 'node:test';
import assert from 'node:assert/strict';
import { usePendingMediaList } from '../src/usePendingMediaList.ts';

function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}
const page = items => ({items,nextCursor:'',scan:{state:'finished'}});
function fakeClock() {
  let next=0;
  const pending=new Map();
  return {
    pending,
    schedule(callback) { const id=++next;pending.set(id,callback);return id; },
    cancel(id) { pending.delete(id); },
    async tick() {
      const item=pending.entries().next().value;
      assert.ok(item,'expected a scheduled status check');
      pending.delete(item[0]);item[1]();
      await new Promise(resolve=>setImmediate(resolve));
    },
  };
}

test('a successful action refresh supersedes an older in-flight list', async () => {
  const old = deferred();
  const newer = deferred();
  let calls = 0;
  const list = usePendingMediaList({
    read: () => ++calls === 1 ? old.promise : newer.promise,
    errorLabel: error => String(error),
  });
  const first = list.load('photos');
  const refresh = list.load('photos', false, true);
  newer.resolve(page([]));
  await refresh;
  old.resolve(page([{id:7,path:'old.jpg',reason:'missing',data:[],canManage:true}]));
  await first;
  assert.deepEqual(list.groups.photos.items, []);
  assert.equal(list.groups.photos.loading, false);
  assert.equal(list.groups.photos.loaded, true);
});

test('a stale failure or disposed page cannot replace current results', async () => {
  const old = deferred();
  const newer = deferred();
  let calls = 0;
  const list = usePendingMediaList({
    read: () => ++calls === 1 ? old.promise : newer.promise,
    errorLabel: error => String(error),
  });
  const first = list.load('cinema');
  const refresh = list.load('cinema', false, true);
  old.reject(new Error('stale failure'));
  await first;
  assert.equal(list.groups.cinema.error, '');
  assert.equal(list.groups.cinema.loading, true);
  list.dispose();
  newer.resolve(page([{id:8,path:'film.mp4',reason:'missing',data:[],canManage:true}]));
  await refresh;
  assert.deepEqual(list.groups.cinema.items, []);
});

test('a resolved item stays removed when its refresh fails and an older page returns', async () => {
  const old = deferred();
  const failing = deferred();
  let calls = 0;
  const row = {id:7,path:'old.jpg',reason:'missing',data:[],canManage:true};
  const list = usePendingMediaList({
    read: () => {
      calls++;
      if(calls === 1)return Promise.resolve({items:[row],nextCursor:'7'});
      return calls === 2 ? old.promise : failing.promise;
    },
    errorLabel: error => error.message,
  });
  await list.load('photos');
  const stale = list.load('photos', true);
  const refresh = list.resolved('photos', 7);
  assert.deepEqual(list.groups.photos.items, []);
  assert.equal(list.groups.photos.next, '');
  failing.reject(new Error('network unavailable'));
  await refresh;
  old.resolve(page([row]));
  await stale;
  assert.deepEqual(list.groups.photos.items, []);
  assert.match(list.groups.photos.error, /network unavailable/);
});

test('a running check updates the list on completion and stops polling', async () => {
  const clock=fakeClock();
  const requests=[];
  const replies=[
    {items:[],nextCursor:'',scan:{state:'running'}},
    {items:[],nextCursor:'',scan:{state:'running'}},
    {items:[],nextCursor:'',scan:{state:'finished'}},
    page([{id:9,path:'photo.jpg',reason:'missing',data:[],canManage:true}]),
  ];
  const list=usePendingMediaList({
    read:async (_kind,query)=>{requests.push(query.get('limit'));return replies.shift();},
    errorLabel:error=>String(error),schedule:clock.schedule,cancel:clock.cancel,visible:()=>true,
  });
  await list.load('photos');
  assert.equal(list.groups.photos.scan,'running');
  await clock.tick();
  assert.equal(clock.pending.size,1);
  await clock.tick();
  assert.equal(list.groups.photos.scan,'finished');
  assert.equal(list.groups.photos.items[0].id,9);
  assert.deepEqual(requests,['30','1','1','30']);
  assert.equal(clock.pending.size,0);
});

test('hidden pages pause status checks and ignore their in-flight response', async () => {
  const clock=fakeClock();
  const pending=deferred();
  let visible=true, calls=0;
  const list=usePendingMediaList({
    read:()=>++calls===1?pending.promise:Promise.resolve(page([])),
    errorLabel:error=>String(error),schedule:clock.schedule,cancel:clock.cancel,visible:()=>visible,
  });
  list.trackScan('cinema');
  await clock.tick();
  visible=false;list.visibilityChanged();
  pending.resolve(page([{id:1,path:'old',reason:'missing',data:[],canManage:true}]));
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(list.groups.cinema.scan,'running');
  assert.equal(clock.pending.size,0);
  visible=true;list.visibilityChanged();
  assert.equal(clock.pending.size,1);
  list.dispose();
  assert.equal(clock.pending.size,0);
});

test('a failed progress request is shown as unknown instead of complete', async () => {
  const clock=fakeClock();
  const list=usePendingMediaList({
    read:async()=>{throw new Error('connection lost');},
    errorLabel:error=>error.message,schedule:clock.schedule,cancel:clock.cancel,visible:()=>true,
  });
  list.trackScan('photos');
  await clock.tick();
  assert.equal(list.groups.photos.scan,'not_checked');
  assert.match(list.groups.photos.error,/connection lost/);
  assert.equal(clock.pending.size,0);
});
