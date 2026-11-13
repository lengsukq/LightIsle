import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import {
  MAX_META_ENTRIES,
  classifyResourceUrl,
  clearLocalCache,
  clearRuntimeMemoryCache,
  flushLedgerNow,
  formatCacheBytes,
  getMetadata,
  inspectLocalCache,
  putMetadata,
  recordAssetHit,
} from "./useIsleCache.ts";

function createMemoryStorage() {
  const map = new Map();
  let setCalls = 0;
  return {
    get setCalls() {
      return setCalls;
    },
    get length() {
      return map.size;
    },
    key(index) {
      return Array.from(map.keys())[index] ?? null;
    },
    getItem(k) {
      return map.has(k) ? map.get(k) : null;
    },
    setItem(k, v) {
      setCalls += 1;
      map.set(k, String(v));
    },
    removeItem(k) {
      map.delete(k);
    },
    clear() {
      map.clear();
    },
  };
}

test("classifyResourceUrl maps thumbnails, posters, and map tiles to categories", () => {
  assert.equal(classifyResourceUrl("/api/v2/photos/42/thumbnail"), "thumbnails");
  assert.equal(classifyResourceUrl("/api/v2/files/thumbnail?path=a.jpg"), "thumbnails");
  assert.equal(classifyResourceUrl("/api/v2/cinema/9/poster"), "posters");
  assert.equal(classifyResourceUrl("/api/v2/map/tiles/tianditu/vec/4/12/6"), "map_tiles");
  assert.equal(classifyResourceUrl("https://tile.openstreetmap.org/5/10/12.png"), "map_tiles");
  assert.equal(classifyResourceUrl("/api/v2/system"), null);
});

test("useIsleCache tracks category usage and clears selectively", async () => {
  await clearLocalCache(["thumbnails", "posters", "map_tiles", "metadata"]);

  recordAssetHit("thumbnails", "thumb:1", 12000);
  recordAssetHit("thumbnails", "thumb:2", 18000);
  recordAssetHit("posters", "poster:1", 64000);
  recordAssetHit("map_tiles", "tile:4/12/6", 20000);
  putMetadata("photos:list:default", { assets: [{ id: 1 }], nextCursor: 0 });
  flushLedgerNow();

  const report = await inspectLocalCache();
  assert.equal(report.categories.thumbnails.entryCount, 2);
  assert.equal(report.categories.thumbnails.usedBytes, 30000);
  assert.equal(report.categories.posters.entryCount, 1);
  assert.equal(report.categories.posters.usedBytes, 64000);
  assert.equal(report.categories.map_tiles.entryCount, 1);
  assert.equal(report.categories.map_tiles.usedBytes, 20000);
  assert.equal(report.categories.metadata.entryCount, 1);
  assert.ok(report.categories.metadata.usedBytes > 0);
  assert.deepEqual(getMetadata("photos:list:default"), {
    assets: [{ id: 1 }],
    nextCursor: 0,
  });

  // Clear only map_tiles and metadata; thumbnails and posters must remain intact.
  await clearLocalCache(["map_tiles", "metadata"]);
  const afterSelective = await inspectLocalCache();
  assert.equal(afterSelective.categories.map_tiles.usedBytes, 0);
  assert.equal(afterSelective.categories.metadata.entryCount, 0);
  assert.equal(getMetadata("photos:list:default"), null);
  assert.equal(afterSelective.categories.thumbnails.usedBytes, 30000);
  assert.equal(afterSelective.categories.posters.usedBytes, 64000);
  assert.equal(formatCacheBytes(1024 * 1024), "1.0 MB");

  await clearLocalCache(["thumbnails", "posters"]);
});

test("debounces ledger persistence and coalesces burst asset hits until flushed", async (t) => {
  const prevWindow = globalThis.window;
  const mockStorage = createMemoryStorage();
  globalThis.window = {
    localStorage: mockStorage,
    addEventListener() {},
    removeEventListener() {},
  };
  t.after(async () => {
    await clearLocalCache(["thumbnails", "posters", "map_tiles", "metadata"]);
    globalThis.window = prevWindow;
  });

  await clearLocalCache(["thumbnails", "posters", "map_tiles", "metadata"]);
  const baselineWrites = mockStorage.setCalls;

  for (let i = 0; i < 80; i++) {
    recordAssetHit("thumbnails", `thumb:burst:${i}`, 14000);
  }
  putMetadata("photos:burst", { count: 80 });

  // No synchronous localStorage.setItem writes during the burst!
  assert.equal(mockStorage.setCalls, baselineWrites);

  flushLedgerNow();
  // Coalesced into 1 thumbnails ledger write + 1 metadata key write = 2 setItem calls total!
  assert.equal(mockStorage.setCalls - baselineWrites, 2);
});

test("enforces LRU cap, clone isolation, and clearRuntimeMemoryCache on logout", async () => {
  await clearLocalCache(["metadata"]);

  const mutableInput = { items: ["alpha"] };
  putMetadata("isolated:key", mutableInput);
  mutableInput.items.push("mutated-caller");
  const firstRead = getMetadata("isolated:key");
  assert.deepEqual(firstRead, { items: ["alpha"] });
  firstRead.items.push("mutated-reader");
  assert.deepEqual(getMetadata("isolated:key"), { items: ["alpha"] });

  await clearLocalCache(["metadata"]);

  // Insert MAX_META_ENTRIES entries, promote entry 0 via getMetadata, then add 5 more.
  for (let i = 0; i < MAX_META_ENTRIES; i++) {
    putMetadata(`lru:${i}`, { index: i });
  }
  // Touch lru:0 so it moves to MRU; lru:1..lru:5 become the oldest entries.
  assert.deepEqual(getMetadata("lru:0"), { index: 0 });

  for (let extra = 0; extra < 5; extra++) {
    putMetadata(`lru:extra:${extra}`, { extra });
  }

  const report = await inspectLocalCache();
  assert.equal(report.categories.metadata.entryCount, MAX_META_ENTRIES);
  assert.deepEqual(getMetadata("lru:0"), { index: 0 });
  assert.equal(getMetadata("lru:1"), null);
  assert.equal(getMetadata("lru:5"), null);
  assert.deepEqual(getMetadata("lru:6"), { index: 6 });

  clearRuntimeMemoryCache();
  assert.equal(getMetadata("lru:0"), null);
  assert.equal((await inspectLocalCache()).categories.metadata.entryCount, 0);
});

test("AppShell preserves core user views with v-show and unmounts admin/utility views with v-if", () => {
  const html = readFileSync(new URL("./AppShell.html", import.meta.url), "utf8");
  assert.doesNotMatch(html, /<div v-if="!rootSwitching" :key="active">/);
  assert.match(html, /<div v-show="active === 'photos'[\s\S]*?<PhotosView v-if="visitedPages\.photos" v-show="active === 'photos'/);
  assert.match(html, /<div v-show="active === 'cinema'[\s\S]*?<CinemaView v-if="visitedPages\.cinema" v-show="active === 'cinema'/);
  assert.match(html, /<div v-if="active === 'downloads'"/);
  assert.match(html, /<div v-if="active === 'apps'"/);
  assert.match(html, /<div v-if="active === 'automation' && user\.role === 'admin'"/);
  assert.match(html, /<div v-if="active === 'settings'"/);
  assert.match(html, /<CacheManagementPanel/);

  const photosSfc = readFileSync(new URL("./PhotosView.vue", import.meta.url), "utf8");
  const photoViewerSfc = readFileSync(new URL("./PhotoViewerModal.vue", import.meta.url), "utf8");
  const cinemaSfc = readFileSync(new URL("./CinemaView.vue", import.meta.url), "utf8");
  assert.match(photosSfc, /<PhotoViewerModal[\s\S]*\/>\s*<\/div>\s*<\/template>/);
  assert.match(photoViewerSfc, /<\/Teleport>\s*<\/template>/);
  assert.match(cinemaSfc, /<\/Teleport>\s*<\/div>\s*<\/template>/);
});
