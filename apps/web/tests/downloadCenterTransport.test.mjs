import assert from 'node:assert/strict';
import test from 'node:test';
import { readDownloadCenter } from '../src/downloadCenterTransport.js';
import { createMediaStatusPoller } from '../src/mediaStatusPoller.js';

test('unavailable optional component still exposes owned historical tasks', async () => {
  const calls = [];
  const value = await readDownloadCenter(async path => {
    calls.push(path);
    if (path.endsWith('/status')) return { available: false, reason: 'aria2_not_installed' };
    return { tasks: [{ id: 'old', status: 'failed', phase: 'publishing', partialPublish: true }] };
  });
  assert.equal(value.status.available, false);
  assert.equal(value.tasks[0].partialPublish, true);
  assert.deepEqual(calls, ['/api/v2/downloads/status', '/api/v2/downloads']);
});

test('only the expected old-core unavailable response becomes an empty history', async () => {
  const unavailable = async path => {
    if (path.endsWith('/status')) return { available: false };
    throw new Error('download_unavailable');
  };
  assert.deepEqual((await readDownloadCenter(unavailable)).tasks, []);
  await assert.rejects(readDownloadCenter(async path => {
    if (path.endsWith('/status')) return { available: false };
    throw new Error('network_error');
  }), /network_error/);
});

test('malformed replies cannot masquerade as no tasks or no component', async () => {
  await assert.rejects(readDownloadCenter(async () => ({})), /invalid_download_status/);
  await assert.rejects(readDownloadCenter(async path => path.endsWith('/status')
    ? { available: true } : { tasks: [{ status: 'failed' }] }), /invalid_download_tasks/);
});

test('the download refresh is single-flight and old results cannot undo a mutation refresh', async () => {
  let release;
  let statusReads = 0;
  const values = [];
  const old = new Promise(resolve => { release = resolve; });
  const api = async path => {
    if (path.endsWith('/status')) {
      statusReads++;
      return statusReads === 1 ? old : { available: false };
    }
    return { tasks: [] };
  };
  const poller = createMediaStatusPoller(signal => readDownloadCenter(api, signal), { onValue: value => values.push(value) });
  const first = poller.refresh();
  assert.equal(poller.refresh(), first);
  await Promise.resolve();
  poller.invalidate();
  await poller.refresh();
  release({ available: true });
  await first;
  assert.equal(statusReads, 2);
  assert.equal(values.length, 1);
  assert.equal(values[0].status.available, false);
  poller.dispose();
});
