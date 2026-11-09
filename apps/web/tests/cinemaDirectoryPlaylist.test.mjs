import test from "node:test";
import assert from "node:assert/strict";
import { ref } from "vue";
import { useCinemaDirectoryPlaylist } from "../src/useCinemaDirectoryPlaylist.ts";

const film = (id, path) => ({ id, path, title: String(id), season: 0, episode: 0 });
function playlist(selected, api, getEpoch = () => 0) {
  return useCinemaDirectoryPlaylist({
    selected,
    sources: () => [[]],
    rootEpoch: getEpoch,
    disposed: () => false,
    api,
    apiPath: path => path,
    describeError: error => String(error),
  });
}
function deferred() {
  let resolve;
  const promise = new Promise(yes => { resolve = yes; });
  return { promise, resolve };
}

test("directory playlist respects API limit and retries a failed request", async () => {
  const current = film(1, "videos/one.mp4");
  const selected = ref(current);
  let calls = 0;
  const p = playlist(selected, async url => {
    const u = new URL(url, "http://localhost");
    assert.equal(u.searchParams.get("dir"), "videos");
    assert.equal(u.searchParams.get("limit"), "120");
    calls++;
    if (calls === 1) throw new Error("offline");
    return { films: [current, film(2, "videos/two.mp4")], nextCursor: 0 };
  });
  await p.load(current);
  assert.equal(p.loadedKey.value, "");
  assert.match(p.error.value, /offline/);
  await p.load(current);
  assert.equal(calls, 2);
  assert.equal(p.error.value, "");
  assert.equal(p.sameDirectoryFilms.value.length, 2);
});

test("an old directory response cannot replace a new selection", async () => {
  const a = film(1, "dir-a/one.mp4");
  const b = film(2, "dir-b/two.mp4");
  const selected = ref(a);
  const oldResponse = deferred();
  const newResponse = deferred();
  const p = playlist(selected, url =>
    url.includes("dir-a") ? oldResponse.promise : newResponse.promise,
  );
  const oldRequest = p.load(a);
  selected.value = b;
  const newRequest = p.load(b);
  newResponse.resolve({ films: [b], nextCursor: 0 });
  await newRequest;
  oldResponse.resolve({ films: [a], nextCursor: 0 });
  await oldRequest;
  assert.deepEqual(p.sameDirectoryFilms.value.map(item => item.id), [2]);
  assert.equal(p.loadedKey.value, "0:dir-b");
});

test("automatic continuation discovers a next film on another page", async () => {
  const first = film(5, "series/one.mp4");
  const second = film(6, "series/two.mp4");
  const selected = ref(first);
  const cursors = [];
  const p = playlist(selected, async url => {
    const cursor = Number(new URL(url, "http://localhost").searchParams.get("cursor"));
    cursors.push(cursor);
    return cursor === 0
      ? { films: [first], nextCursor: 120 }
      : { films: [second], nextCursor: 0 };
  });
  assert.equal((await p.findNext(first))?.id, 6);
  assert.deepEqual(cursors, [0, 120]);
  assert.equal(p.nextCursor.value, 0);
});

test("reset invalidates pending responses from an old root", async () => {
  const current = film(1, "videos/old.mp4");
  const selected = ref(current);
  const response = deferred();
  let epoch = 1;
  const p = playlist(selected, () => response.promise, () => epoch);
  const pending = p.load(current);
  epoch = 2;
  p.reset();
  response.resolve({ films: [current], nextCursor: 0 });
  await pending;
  assert.equal(p.loadedKey.value, "");
  assert.equal(p.sameDirectoryFilms.value.length, 1);
});
