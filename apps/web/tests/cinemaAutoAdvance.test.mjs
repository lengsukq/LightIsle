import assert from "node:assert/strict";
import test from "node:test";
import {continueAfterPlaybackEnd} from "../src/cinemaAutoAdvance.ts";

function deferred(){
 let resolve;
 const promise=new Promise(yes=>{resolve=yes});
 return {promise,resolve};
}

test("same-id close and reopen invalidates a pending autoplay continuation",async()=>{
 const film={id:7,kind:"series"};
 const nextEpisode={id:8,kind:"series"};
 const lookup=deferred();
 const lookupStarted=deferred();
 let generation=1;
 let selected=film;
 const opened=[];
 const ended=continueAfterPlaybackEnd({
  film,
  saveFinished:async()=>{},
  shouldAdvance:()=>true,
  isCurrent:()=>generation===1&&selected?.id===film.id,
  findNext:()=>{lookupStarted.resolve();return lookup.promise},
  openNext:async episode=>{opened.push(episode)},
  onNoNext:()=>assert.fail("a next episode is available"),
 });

 await lookupStarted.promise;
 selected=null;
 generation+=1;
 selected={...film};
 lookup.resolve(nextEpisode);
 await ended;

 assert.deepEqual(opened,[]);
});

test("a current playback end still opens the next episode",async()=>{
 const film={id:7,kind:"series"};
 const nextEpisode={id:8,kind:"series"};
 const opened=[];
 await continueAfterPlaybackEnd({
  film,
  saveFinished:async()=>{},
  shouldAdvance:()=>true,
  isCurrent:()=>true,
  findNext:async()=>nextEpisode,
  openNext:async episode=>{opened.push(episode)},
  onNoNext:()=>assert.fail("a next episode is available"),
 });
 assert.deepEqual(opened,[nextEpisode]);
});
