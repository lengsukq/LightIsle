import test from 'node:test';
import assert from 'node:assert/strict';
import { createRootContextLifecycle } from '../src/rootContextLifecycle.ts';

test('each physical root generation closes previous request signal', () => {
 const life=createRootContextLifecycle();
 const first=life.signal;
 assert.equal(life.epoch,0);
 assert.equal(first.aborted,false);
 const firstEpoch=life.epoch;
 assert.equal(life.invalidate(),1);
 assert.equal(first.aborted,true);
 assert.equal(life.isCurrentEpoch(firstEpoch),false);
 const second=life.signal;
 assert.notEqual(first,second);
 assert.equal(second.aborted,false);
 assert.equal(life.invalidate(),2);
 assert.equal(second.aborted,true);
 assert.equal(life.signal.aborted,false);
});

test('old discovery cannot overwrite a later root choice', () => {
 const life=createRootContextLifecycle();
 const one=life.beginDiscovery();
 assert.equal(life.isCurrentDiscovery(one),true);
 const two=life.beginDiscovery();
 assert.equal(life.isCurrentDiscovery(one),false);
 assert.equal(life.isCurrentDiscovery(two),true);
 life.invalidateDiscovery();
 assert.equal(life.isCurrentDiscovery(two),false);
});
