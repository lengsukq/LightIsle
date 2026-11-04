import assert from "node:assert/strict";
import test from "node:test";
import { readCinemaHomeShelves } from "../src/cinemaHomeShelves.ts";

function film(id, overrides={}) {
 return { id, title: String(id), path: "Cinema/"+id+".mp4", kind: "movie",
  series: "", season: 0, episode: 0, year: 2026, size: 1,
  position: 0, duration: 100, completed: false, ...overrides };
}
function deferred() {
 let resolve;
 const promise = new Promise(yes => { resolve=yes; });
 return { promise, resolve };
}

test("home shelves keep server ranking, remove duplicates and exclude watched/completed", async () => {
 const result = await readCinemaHomeShelves(async kind =>
  kind === "continue"
   ? { films: [film(9, { position: 60 }), film(9, { position: 70 }), film(8, { completed: true, position: 99 }), film(4, { position: 5 }), film(7, { position: 20 })] }
   : { films: [film(12), film(10), film(12)] },
  () => true,
 );
 assert.deepEqual(result.resume.map(f => f.id), [9, 7]);
 assert.deepEqual(result.recent.map(f => f.id), [12, 10]);
});

test("home shelves discard both responses if the physical root changes mid-request", async () => {
 const first = deferred(), second = deferred();
 let epoch = 7;
 const currentEpoch = epoch;
 const reading = readCinemaHomeShelves(
  kind => kind === "continue" ? first.promise : second.promise,
  () => epoch === currentEpoch,
 );
 first.resolve({ films: [film(22, { position: 40 })] });
 epoch = 8;
 second.resolve({ films: [film(23)] });
 assert.equal(await reading, null);
});

test("home shelves cap both rails and tolerate missing items without creating placeholders", async () => {
 const result = await readCinemaHomeShelves(async kind =>
  kind === "continue"
   ? { films: Array.from({ length: 20 }, (_, i) => film(i + 1, { position: 10 })) }
   : { films: [null, film(0), ...Array.from({ length: 30 }, (_, i) => film(i + 1))] },
  () => true,
 );
 assert.equal(result.resume.length, 8);
 assert.equal(result.recent.length, 8);
 assert.deepEqual(result.recent.map(f => f.id), [1,2,3,4,5,6,7,8]);
});
