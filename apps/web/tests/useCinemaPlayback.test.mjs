import assert from "node:assert/strict";
import test from "node:test";
import { ref } from "vue";
import { useCinemaPlayback } from "../src/useCinemaPlayback.ts";

const movie = {
  id: 7,
  title: "Example",
  path: "Example.mp4",
  kind: "movie",
  series: "",
  season: 0,
  episode: 0,
  year: 2026,
  size: 1,
  position: 0,
  duration: 0,
  completed: false,
};

function deferred() {
  let resolve;
  const promise = new Promise((yes) => { resolve = yes; });
  return { promise, resolve };
}

function setup(api) {
  const selected = ref(movie);
  const movies = ref([movie]);
  const props = { rootId: "root-a", rootGeneration: 1 };
  const playback = useCinemaPlayback({
    selected,
    movies,
    props,
    api,
    apiPath: (path) => path,
    mediaPath: (path) => path,
  });
  return { selected, movies, props, playback };
}

for (const scenario of ["root switch", "close"]) {
  test(`a late transcode session response is ignored after ${scenario}`, async () => {
    const gate = deferred();
    const state = setup(() => gate.promise);
    const opening = state.playback.startTranscode(movie);

    if (scenario === "root switch") {
      state.props.rootId = "root-b";
      state.props.rootGeneration = 2;
    }
    state.playback.destroyHls();
    state.selected.value = null;

    gate.resolve({
      sessionId: "late-session",
      start: 0,
      profile: "transcode",
      audioTrack: 0,
      quality: "source",
      ready: false,
    });
    await opening;

    assert.equal(state.playback.hlsSession.value, null);
    assert.equal(state.playback.hlsStarting.value, false);
    assert.equal(state.playback.playError.value, "");
  });
}

test("an old same-id request cannot replace or clear the reopened player's session", async () => {
  const oldRequest = deferred();
  const newRequest = deferred();
  let sessionIndex = 0;
  const state = setup((url) => {
    if (url.endsWith("/tracks")) return Promise.resolve({ tracks: { audio: [], subtitles: [] } });
    return [oldRequest.promise, newRequest.promise][sessionIndex++];
  });
  state.playback.hlsPlayer.value = {
    canPlayType: () => "probably",
    src: "",
    playbackRate: 1,
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 200 });

  try {
    const oldOpening = state.playback.startTranscode(movie);
    state.playback.destroyHls();
    state.selected.value = null;
    state.selected.value = movie;
    const newOpening = state.playback.startTranscode(movie);

    oldRequest.resolve({
      sessionId: "old-session",
      start: 0,
      profile: "transcode",
      audioTrack: 0,
      quality: "source",
      ready: false,
    });
    await oldOpening;
    assert.equal(state.playback.hlsSession.value, null);
    assert.equal(state.playback.hlsStarting.value, true);

    const currentSession = {
      sessionId: "new-session",
      start: 0,
      profile: "transcode",
      audioTrack: 0,
      quality: "source",
      ready: false,
    };
    newRequest.resolve(currentSession);
    await newOpening;

    assert.deepEqual(state.playback.hlsSession.value, currentSession);
    assert.equal(state.playback.hlsStarting.value, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("a failed old-root save stays visible after the current root saves successfully",async()=>{
  const state=setup(async()=>{});
  state.playback.player.value={currentTime:12,duration:100,playbackRate:1};
  const calls=[];
  let oldRootOnline=false;
  const originalFetch=globalThis.fetch;
  globalThis.fetch=async(_url,options)=>{
    const generation=new Headers(options.headers).get("X-LightIsle-Root-Generation");
    calls.push(generation);
    if(generation==="1"&&!oldRootOnline)return {ok:false,status:503};
    return {ok:true,status:200};
  };

  try{
    await state.playback.save();
    assert.match(state.playback.progressSaveError.value,/播放进度尚未保存/);

    state.props.rootId="root-b";
    state.props.rootGeneration=2;
    state.playback.refreshProgressSaveError();
    assert.match(state.playback.progressSaveError.value,/其他存储目录/);

    await state.playback.save();
    assert.deepEqual(calls,["1","1","2"]);
    assert.match(state.playback.progressSaveError.value,/其他存储目录/);

    oldRootOnline=true;
    await state.playback.retryProgress();
    assert.deepEqual(calls,["1","1","2","1"]);
    assert.equal(state.playback.progressSaveError.value,"");
  }finally{
    globalThis.fetch=originalFetch;
  }
});
