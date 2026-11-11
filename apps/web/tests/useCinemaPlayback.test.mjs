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

test("HLS seek keeps full film duration instead of collapsing to seek point and seeks locally inside buffered window", async () => {
  const mkvFilm = { ...movie, id: 88, path: "Wakanda.mkv", durationSeconds: 0, duration: 0, browserPlayback: "download-only" };
  const requestedUrls = [];
  const state = setup(async (url) => {
    requestedUrls.push(url);
    if (url.endsWith("/tracks")) {
      return { tracks: { durationSeconds: 9660, height: 2160, audio: [], subtitles: [] } };
    }
    if (url.includes("start=0.000")) {
      return { sessionId: "sess-0", start: 0, durationSeconds: 9660, profile: "remux", audioTrack: 0, quality: "source", ready: true };
    }
    return { sessionId: "sess-1800", start: 1800, durationSeconds: 9660, profile: "remux", audioTrack: 0, quality: "source", ready: true };
  });
  state.selected.value = mkvFilm;
  state.movies.value = [mkvFilm];
  const seekableRanges = [[0, 120]];
  state.playback.hlsPlayer.value = {
    canPlayType: () => "probably",
    src: "",
    currentTime: 0,
    duration: 20,
    playbackRate: 1,
    muted: false,
    volume: 1,
    paused: false,
    ended: false,
    play: async () => {},
    pause: () => {},
    buffered: { length: 1, start: () => 0, end: () => 120 },
    seekable: { length: 1, start: (i) => seekableRanges[i][0], end: (i) => seekableRanges[i][1] },
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 200 });

  try {
    state.playback.resetPlaybackForFilm(mkvFilm);
    await state.playback.startTranscode(mkvFilm, 0, 0);
    state.playback.loaded();
    assert.equal(state.playback.playbackDuration.value, 9660);
    assert.equal(state.selected.value.durationSeconds, 9660);

    // 1) Seeking within already-muxed [0, 120] window updates currentTime locally with ZERO new /hls/session call!
    const countBeforeLocalSeek = requestedUrls.filter((u) => u.includes("/hls/session")).length;
    state.playback.seekAbsolute(45);
    assert.equal(state.playback.hlsPlayer.value.currentTime, 45);
    assert.equal(state.playback.playbackPosition.value, 45);
    assert.equal(state.playback.playbackDuration.value, 9660);
    assert.equal(requestedUrls.filter((u) => u.includes("/hls/session")).length, countBeforeLocalSeek);

    // 2) Seeking outside [0, 120] to 1800s passes ?replace=sess-0 and keeps duration at 9660 even when playlist has only 4s!
    state.playback.seekAbsolute(1800);
    assert.equal(state.playback.playbackPosition.value, 1800);
    assert.equal(state.playback.playbackDuration.value, 9660);
    await new Promise((r) => setTimeout(r, 20));
    assert.ok(requestedUrls.some((u) => u.includes("start=1800.000") && u.includes("replace=sess-0")));

    // Simulate freshly restarted HLS playlist with only 1 segment (4s) muxed so far:
    state.playback.hlsPlayer.value.currentTime = 1;
    state.playback.hlsPlayer.value.duration = 4;
    seekableRanges[0] = [0, 4];
    state.playback.loaded();
    state.playback.tick();
    assert.equal(state.playback.playbackPosition.value, 1801);
    assert.equal(state.playback.playbackDuration.value, 9660);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("seeking again while hlsStarting supersedes the in-flight transcode request", async () => {
  const firstGate = deferred();
  const secondGate = deferred();
  const requestedUrls = [];
  const state = setup((url) => {
    requestedUrls.push(url);
    if (url.endsWith("/tracks")) return Promise.resolve({ tracks: { durationSeconds: 3600, audio: [], subtitles: [] } });
    if (url.includes("start=600.000")) return firstGate.promise;
    return secondGate.promise;
  });
  const mkvFilm = { ...movie, id: 99, durationSeconds: 3600, browserPlayback: "download-only" };
  state.selected.value = mkvFilm;
  state.playback.hlsPlayer.value = {
    canPlayType: () => "probably",
    src: "",
    currentTime: 0,
    duration: 8,
    playbackRate: 1,
    play: async () => {},
    pause: () => {},
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, status: 200 });

  try {
    const firstSeek = state.playback.startTranscode(mkvFilm, 600, 0);
    assert.equal(state.playback.hlsStarting.value, true);

    // User drags slider again to 2400s before 600s finishes starting:
    state.playback.seekAbsolute(2400);
    assert.equal(state.playback.playbackPosition.value, 2400);

    firstGate.resolve({ sessionId: "stale-600", start: 600, durationSeconds: 3600, profile: "remux", audioTrack: 0, quality: "source", ready: true });
    await firstSeek;
    assert.equal(state.playback.hlsStarting.value, true);

    secondGate.resolve({ sessionId: "fresh-2400", start: 2400, durationSeconds: 3600, profile: "remux", audioTrack: 0, quality: "source", ready: true });
    await new Promise((r) => setTimeout(r, 20));
    assert.equal(state.playback.hlsSession.value?.sessionId, "fresh-2400");
    assert.equal(state.playback.hlsStarting.value, false);
    assert.equal(state.playback.playbackDuration.value, 3600);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
