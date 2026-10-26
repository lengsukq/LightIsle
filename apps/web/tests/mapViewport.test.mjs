import test from "node:test";
import assert from "node:assert/strict";
import { clusterGeoPoints } from "../src/mapCluster.js";
import { clusterCellKey, expandBounds, planMarkerChanges, selectVisibleClusters } from "../src/mapViewport.js";

test("expandBounds pads each side by the ratio of the span and rejects malformed input", () => {
  assert.deepEqual(expandBounds({ south: 0, west: 0, north: 10, east: 20 }, 0.25), {
    south: -2.5, west: -5, north: 12.5, east: 25,
  });
  assert.deepEqual(expandBounds({ south: 10, west: 116, north: 10, east: 116 }, 0.25), {
    south: 10, west: 116, north: 10, east: 116,
  });
  // Negative or non-numeric margins mean "no padding", not inflation.
  assert.deepEqual(expandBounds({ south: 0, west: 0, north: 10, east: 20 }, -1), {
    south: 0, west: 0, north: 10, east: 20,
  });
  assert.equal(expandBounds(null, 0.25), null);
  assert.equal(expandBounds({ south: 0, west: Number.NaN, north: 10, east: 20 }, 0.25), null);
});

test("clusterCellKey matches the grid bin mapCluster.js used for the cluster", () => {
  // Zoom 8 → 1° cells: both Shanghai points share cell 31:121.
  const [shanghai] = clusterGeoPoints([
    { id: 1, lat: 31.2, lon: 121.4 },
    { id: 2, lat: 31.3, lon: 121.4 },
  ], 8);
  assert.equal(clusterCellKey(shanghai, 8), "31:121");
  // Re-clustering unchanged data keys every cluster identically — the
  // property the pan-reuse plan depends on.
  const again = clusterGeoPoints([
    { id: 1, lat: 31.2, lon: 121.4 },
    { id: 2, lat: 31.3, lon: 121.4 },
  ], 8);
  assert.equal(clusterCellKey(again[0], 8), clusterCellKey(shanghai, 8));
});

test("selectVisibleClusters keeps clusters whose cell meets the bounds, even if the mean sits outside", () => {
  // Zoom 8 → 1° cells. The mean (20.5, 20.95) is north of the view, but the
  // cell [20,21)×[20,21) overlaps it, so the bubble must not pop out.
  const clusters = clusterGeoPoints([{ id: 1, lat: 20.5, lon: 20.95 }], 8);
  const { visible, overflow } = selectVisibleClusters(
    clusters, 8, { south: 20, west: 20, north: 20.9, east: 20.9 }, 2000,
  );
  assert.equal(visible.length, 1);
  assert.equal(overflow, false);
  // A distant cluster is dropped.
  const far = clusterGeoPoints([{ id: 2, lat: 50.5, lon: 50.5 }], 8);
  const onlyNear = [...clusters, ...far];
  assert.deepEqual(selectVisibleClusters(onlyNear, 8, { south: 20, west: 20, north: 20.9, east: 20.9 }, 2000).visible, [clusters[0]]);
});

test("selectVisibleClusters spans the antimeridian via ±360° cell shifts", () => {
  const east = clusterGeoPoints([{ id: 1, lat: 11, lon: 175.5 }], 8);
  const west = clusterGeoPoints([{ id: 2, lat: 11, lon: -170.5 }], 8);
  // View 170…191.5 crosses the dateline; both sides must be visible.
  const bounds = { south: 10, west: 170, north: 12, east: 191.5 };
  const picked = selectVisibleClusters([...east, ...west], 8, bounds, 2000);
  assert.deepEqual(picked.visible.map(c => c.items[0].id).sort(), [1, 2]);
});

test("selectVisibleClusters caps markers, keeps biggest first and flags overflow", () => {
  const clusters = [
    clusterGeoPoints([{ id: 1, lat: 1.5, lon: 1.5 }], 8)[0],
    clusterGeoPoints([{ id: 2, lat: 2.5, lon: 2.5 }], 8)[0],
    clusterGeoPoints([{ id: 3, lat: 3.5, lon: 3.5 }], 8)[0],
  ];
  const under = selectVisibleClusters(clusters, 8, { south: 0, west: 0, north: 10, east: 10 }, 3);
  assert.equal(under.visible.length, 3);
  assert.equal(under.overflow, false);
  const over = selectVisibleClusters(clusters, 8, { south: 0, west: 0, north: 10, east: 10 }, 2);
  assert.equal(over.visible.length, 2);
  assert.equal(over.overflow, true);
});

test("selectVisibleClusters tolerates empty clusters and missing bounds", () => {
  assert.deepEqual(selectVisibleClusters([], 8, { south: 0, west: 0, north: 1, east: 1 }, 2000), { visible: [], overflow: false });
  assert.deepEqual(selectVisibleClusters(null, 8, { south: 0, west: 0, north: 1, east: 1 }, 2000), { visible: [], overflow: false });
  const clusters = clusterGeoPoints([{ id: 1, lat: 0.5, lon: 0.5 }], 8);
  assert.deepEqual(selectVisibleClusters(clusters, 8, null, 2000), { visible: [], overflow: false });
});

test("planMarkerChanges adds arrivals, removes departures and keeps shared markers", () => {
  const zoom = 8;
  const shanghai = clusterGeoPoints([{ id: 1, lat: 31.2, lon: 121.4 }], zoom)[0];
  const beijing = clusterGeoPoints([{ id: 2, lat: 40.2, lon: 116.4 }], zoom)[0];
  const chengdu = clusterGeoPoints([{ id: 3, lat: 30.6, lon: 104.1 }], zoom)[0];
  const existing = new Set([clusterCellKey(shanghai, zoom), clusterCellKey(beijing, zoom)]);
  const plan = planMarkerChanges(existing, [shanghai, chengdu], zoom);
  // Pan: Shanghai stayed in view, Beijing left, Chengdu arrived.
  assert.deepEqual(plan.remove, [clusterCellKey(beijing, zoom)]);
  assert.equal(plan.add.length, 1);
  assert.equal(plan.add[0].key, clusterCellKey(chengdu, zoom));
  assert.equal(plan.add[0].cluster, chengdu);
});

test("planMarkerChanges seeds a fresh layer with every visible cluster and tolerates null input", () => {
  const zoom = 8;
  const [a, b] = clusterGeoPoints([
    { id: 1, lat: 1.2, lon: 1.4 },
    { id: 2, lat: 9.2, lon: 9.4 },
  ], zoom);
  const seed = planMarkerChanges(new Set(), [a, b], zoom);
  assert.equal(seed.remove.length, 0);
  assert.deepEqual(seed.add.map(item => item.key), [clusterCellKey(a, zoom), clusterCellKey(b, zoom)]);
  assert.deepEqual(planMarkerChanges(new Set(), null, zoom), { add: [], remove: [] });
});
