import test from 'node:test';
import assert from 'node:assert/strict';
import { useTaskCenter } from '../src/useTaskCenter.ts';

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

function createTaskCenter(getJson) {
  return useTaskCenter({
    role: () => 'admin',
    ready: () => true,
    activePage: () => 'settings',
    getJson,
    rootFetch: async () => ({ ok: true }),
    scopedApiPath: path => path,
    isAbortError: e => e?.name === 'AbortError',
  });
}

test('root switch invalidates late task status and history responses', async () => {
  const status = deferred();
  const history = deferred();
  const tc = createTaskCenter(url =>
    url.startsWith('/api/v2/tasks/history') ? history.promise : status.promise);
  const statusPromise = tc.reloadTasks();
  const historyPromise = tc.reloadTaskHistory();
  tc.reset();
  status.resolve({ tasks: [{kind:'gallery',running:true,progress:20}] });
  history.resolve({ runs: [{id:1,kind:'gallery'}], nextCursor:'cursor' });
  await Promise.all([statusPromise, historyPromise]);
  assert.deepEqual(tc.tasks.value, []);
  assert.equal(tc.taskLoaded.value, false);
  assert.equal(tc.taskLoading.value, false);
  assert.deepEqual(tc.taskHistory.value, []);
  assert.equal(tc.taskHistoryNextCursor.value, '');
  assert.equal(tc.taskHistoryLoading.value, false);
});

test('latest task overview wins and an error keeps it marked incomplete', async () => {
  const first = deferred();
  const second = deferred();
  let calls = 0;
  const tc = createTaskCenter(() => ++calls === 1 ? first.promise : second.promise);
  const oldRequest = tc.reloadTasks();
  const newRequest = tc.reloadTasks();
  second.resolve({tasks:[{kind:'cinema',running:false,progress:0,lastError:'scan_directory_changed'}]});
  await newRequest;
  first.resolve({tasks:[]});
  await oldRequest;
  assert.equal(tc.tasks.value[0].kind, 'cinema');
  assert.equal(tc.taskLoaded.value, true);
  assert.equal(tc.taskLoading.value, false);

  const failing = createTaskCenter(async () => {throw new Error('network_error');});
  await failing.reloadTasks();
  assert.equal(failing.taskLoaded.value, false);
  assert.match(failing.taskError.value, /读取任务状态失败/);
});

test('task center does not request admin-only data for a member', async () => {
  let calls=0;
  const tc=useTaskCenter({
    role: () => 'member',
    ready: () => true,
    activePage: () => 'settings',
    getJson: async () => { calls++; return {}; },
    rootFetch: async () => { calls++; return { ok: true }; },
    scopedApiPath: path => path,
    isAbortError: () => false,
  });
  await tc.refreshTaskCenter();
  assert.equal(calls,0);
});
