import {test} from 'node:test';
import {strict as assert} from 'node:assert';
import {routePersonalCategory} from '../src/personalStorageRouting.js';
const policy={locations:[{category:'files',rootID:'disk-a',rootGeneration:4,relativePath:'Users/u11/files'},
  {category:'photos',rootID:'disk-b',rootGeneration:2,relativePath:'Users/u11/photos'},
  {category:'videos',rootID:'disk-c',rootGeneration:3,relativePath:'Users/u11/videos'}]};
const roots=[{rootID:'disk-a',generation:4,online:true},{rootID:'disk-b',generation:2,online:true},
  {rootID:'disk-c',generation:3,online:true}];
test('personal sections resolve their configured physical disk and directory',()=>{
  assert.deepEqual(routePersonalCategory(policy,roots,'files'),{kind:'personal',category:'files',rootID:'disk-a',path:'Users/u11/files'});
  assert.equal(routePersonalCategory(policy,roots,'photos').rootID,'disk-b');
  assert.equal(routePersonalCategory(policy,roots,'cinema').rootID,'disk-c');
});
test('offline, replaced or malformed bindings never fall back to a different disk',()=>{
  assert.equal(routePersonalCategory(policy,[{...roots[0],generation:5},...roots.slice(1)],'files').kind,'offline');
  assert.equal(routePersonalCategory(policy,[{...roots[0],online:false},...roots.slice(1)],'files').kind,'offline');
  assert.equal(routePersonalCategory({locations:[{...policy.locations[0],relativePath:'Users/u11/files/../secret'}]},roots,'files').kind,'offline');
});
test('unassigned categories retain manual shared directory browsing',()=>{
  assert.equal(routePersonalCategory({locations:[]},roots,'files').kind,'shared');
  assert.equal(routePersonalCategory(policy,roots,'settings').kind,'shared');
});
