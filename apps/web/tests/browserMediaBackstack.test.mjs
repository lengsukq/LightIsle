import assert from "node:assert/strict";
import test from "node:test";
import {createBrowserMediaBackstack} from "../src/browserMediaBackstack.ts";

function fakeHost(){
  const states=[{page:"cinema"}];
  let index=0,listener;
  const host={
    location:{href:"https://nas.test/?page=cinema"},
    history:{
      get state(){return states[index]},
      pushState(state){states.splice(++index);states.push(state)},
      replaceState(state){states[index]=state},
      go(n){index+=n;if(index<0||index>=states.length)throw Error("invalid history");listener?.({state:states[index]})},
    },
    addEventListener(name,fn){if(name==="popstate")listener=fn},
    removeEventListener(name,fn){if(name==="popstate"&&listener===fn)listener=null},
  };
  return host;
}
const settled=()=>new Promise(resolve=>setImmediate(resolve));
test("browser Back walks film player -> detail -> page",async()=>{
  const host=fakeHost(),levels=[];
  const stack=createBrowserMediaBackstack(host,"cinema",async(old,target)=>{
    levels.push([old,target]);return true;
  });
  stack.push();stack.push();
  assert.equal(stack.depth,2);
  stack.back();await settled();assert.equal(stack.depth,1);
  stack.back();await settled();assert.equal(stack.depth,0);
  assert.deepEqual(levels,[[2,1],[1,0]]);
  stack.dispose();
});
test("failed progress save restores browser history and does not dismiss player",async()=>{
  const host=fakeHost();
  let attempts=0;
  const stack=createBrowserMediaBackstack(host,"cinema",async()=>++attempts>1);
  stack.push();stack.push();stack.back();await settled();
  assert.equal(stack.depth,2);
  assert.equal(host.history.state.__lightisleMediaLayer.level,2);
  stack.back();await settled();assert.equal(stack.depth,1);
  stack.dispose();
});
test("dispose discards current layer marker before changing root or page",()=>{
  const host=fakeHost();
  const stack=createBrowserMediaBackstack(host,"photos",async()=>true);
  stack.push();stack.dispose();
  assert.equal(host.history.state.__lightisleMediaLayer,undefined);
});
