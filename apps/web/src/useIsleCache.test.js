import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import {
  classifyResourceUrl,
  clearLocalCache,
  formatCacheBytes,
  getMetadata,
  inspectLocalCache,
  putMetadata,
  recordAssetHit,
} from "./useIsleCache.ts";

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
});

test("AppShell preserves visited views with v-show and mounts CacheManagementPanel", () => {
  const html = readFileSync(new URL("./AppShell.html", import.meta.url), "utf8");
  assert.doesNotMatch(html, /<div v-if="!rootSwitching" :key="active">/);
  assert.match(html, /<div v-show="active === 'photos'[\s\S]*?<PhotosView v-if="visitedPages\.photos" v-show="active === 'photos'/);
  assert.match(html, /<div v-show="active === 'cinema'[\s\S]*?<CinemaView v-if="visitedPages\.cinema" v-show="active === 'cinema'/);
  assert.match(html, /<CacheManagementPanel/);

  const photosSfc = readFileSync(new URL("./PhotosView.vue", import.meta.url), "utf8");
  const cinemaSfc = readFileSync(new URL("./CinemaView.vue", import.meta.url), "utf8");
  assert.match(photosSfc, /<\/Teleport>\s*<\/div>\s*<\/template>/);
  assert.match(cinemaSfc, /<\/Teleport>\s*<\/div>\s*<\/template>/);
});
