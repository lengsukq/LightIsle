import test from "node:test";
import assert from "node:assert/strict";
import { clusterGeoPoints, geoCellSize, geoPointsBounds } from "../src/mapCluster.js";

test("geoCellSize halves with each zoom level and clamps input", () => {
  assert.equal(geoCellSize(0), 256);
  assert.equal(geoCellSize(8), 1);
  assert.equal(geoCellSize(10), 0.25);
  assert.equal(geoCellSize(-3), 256);
  assert.equal(geoCellSize(Number.NaN), 256);
});

test("clusterGeoPoints merges nearby points and keeps singles apart", () => {
  const points = [
    { id: 1, lat: 31.2304, lon: 121.4737 },
    { id: 2, lat: 31.2311, lon: 121.4740 },
    { id: 3, lat: 31.2320, lon: 121.4730 },
    { id: 4, lat: 39.9042, lon: 116.4074 },
  ];
  // At zoom 10 each cell is 0.25°: the three Shanghai photos share a cell,
  // Beijing stays alone.
  const clusters = clusterGeoPoints(points, 10);
  assert.equal(clusters.length, 2);
  const big = clusters[0];
  assert.equal(big.count, 3);
  assert.ok(Math.abs(big.lat - 31.2312) < 0.001);
  assert.deepEqual(big.items.map(item => item.id).sort(), [1, 2, 3]);
  assert.equal(clusters[1].count, 1);
  // Zooming in splits the Shanghai cluster once cells shrink below the
  // photo spread is exceeded.
  const fine = clusterGeoPoints(points, 16);
  assert.ok(fine.length > 2);
});

test("clusterGeoPoints tolerates empty and malformed input", () => {
  assert.deepEqual(clusterGeoPoints([], 8), []);
  assert.deepEqual(clusterGeoPoints(null, 8), []);
  const clusters = clusterGeoPoints([{ id: 1, lat: Number.NaN, lon: 1 }, { id: 2, lat: 1, lon: 2 }], 8);
  assert.equal(clusters.length, 1);
  assert.equal(clusters[0].items[0].id, 2);
});

test("geoPointsBounds spans located points and rejects nothing-found", () => {
  assert.deepEqual(geoPointsBounds([{ lat: 31, lon: 121 }, { lat: 40, lon: 116 }]), [[31, 116], [40, 121]]);
  assert.equal(geoPointsBounds([]), null);
  assert.equal(geoPointsBounds([{ lat: Number.NaN, lon: 1 }]), null);
});
