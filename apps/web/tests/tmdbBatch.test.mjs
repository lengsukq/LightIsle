import test from 'node:test';
import assert from 'node:assert/strict';
import {isTMDBAuthenticationFailure, runSequentialTMDBBatch} from '../src/tmdbBatch.js';

test('authentication rejection stops sequential TMDB searches immediately', async () => {
  const calls = [];
  const results = [];
  const outcome = await runSequentialTMDBBatch([1, 2, 3], async (filmId) => {
    calls.push(filmId);
    if (filmId === 2) throw new Error('tmdb_auth_failed');
    return `candidate-${filmId}`;
  }, {onResult: (_filmId, candidate) => results.push(candidate)});

  assert.deepEqual(calls, [1, 2]);
  assert.deepEqual(results, ['candidate-1']);
  assert.equal(outcome.status, 'auth-rejected');
});

test('other search failures remain retryable for later batch items', async () => {
  const calls = [];
  const outcome = await runSequentialTMDBBatch([1, 2, 3], async (filmId) => {
    calls.push(filmId);
    if (filmId === 1) throw new Error('tmdb_upstream_failed');
    return filmId;
  });

  assert.deepEqual(calls, [1, 2, 3]);
  assert.equal(outcome.status, 'completed');
  assert.equal(outcome.hadFailures, true);
});

test('only stable authentication error codes trigger credential handling', () => {
  assert.equal(isTMDBAuthenticationFailure(new Error('tmdb_auth_failed')), true);
  assert.equal(isTMDBAuthenticationFailure(new Error('tmdb_access_denied')), true);
  assert.equal(isTMDBAuthenticationFailure(new Error('tmdb_upstream_failed')), false);
});
