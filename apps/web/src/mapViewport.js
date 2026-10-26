// Viewport culling and marker-reuse planning for the photo map. The O(n)
// grid clustering in mapCluster.js stays untouched and still runs over the
// full point set; this module only decides which of those clusters earn a
// DOM marker (inside the padded view, capped defensively) and which markers
// survive a pan untouched. Pure and synchronous — PhotoMapView applies the
// plan with Leaflet on moveend/zoomend.

import { geoCellSize } from "./mapCluster.js";

// Widen bounds by marginRatio of their span on every side so markers just
// outside the view are already on screen when panning stops.
export function expandBounds(bounds, marginRatio) {
  if (!bounds) return null;
  const south = Number(bounds.south);
  const west = Number(bounds.west);
  const north = Number(bounds.north);
  const east = Number(bounds.east);
  if (![south, west, north, east].every(Number.isFinite)) return null;
  const ratio = Number.isFinite(marginRatio) && marginRatio > 0 ? marginRatio : 0;
  const latMargin = (north - south) * ratio;
  const lonMargin = (east - west) * ratio;
  return {
    south: south - latMargin,
    west: west - lonMargin,
    north: north + latMargin,
    east: east + lonMargin,
  };
}

// Same cell-binning identity mapCluster.js uses, so a cluster keeps a stable
// key across renders at a fixed zoom: all points of a bin share the cell
// index, hence so does their mean. Two renders of unchanged data therefore
// key every cluster identically, which is what the reuse plan relies on.
export function clusterCellKey(cluster, zoom) {
  const cellSize = geoCellSize(zoom);
  return Math.floor(Number(cluster?.lat) / cellSize) + ":" + Math.floor(Number(cluster?.lon) / cellSize);
}

function cellIntersectsBounds(key, zoom, bounds) {
  const cellSize = geoCellSize(zoom);
  const separator = key.indexOf(":");
  const latCell = Number(key.slice(0, separator));
  const lonCell = Number(key.slice(separator + 1));
  if (!Number.isFinite(latCell) || !Number.isFinite(lonCell)) return false;
  const south = latCell * cellSize;
  const north = (latCell + 1) * cellSize;
  const west = lonCell * cellSize;
  const east = (lonCell + 1) * cellSize;
  // The cluster owns its whole cell, so intersect by the cell rectangle —
  // culling by mean position alone would pop markers at the viewport edge.
  // ±360° shifts keep world-copy panning across the antimeridian covered.
  for (const shift of [-360, 0, 360]) {
    if (west + shift < bounds.east && east + shift > bounds.west && south < bounds.north && north > bounds.south) {
      return true;
    }
  }
  return false;
}

// Pick the clusters worth a marker: those whose cell meets the (padded)
// bounds, at most maxMarkers of them — clusters arrive biggest-first, so the
// cap keeps the prominent places. overflow reports that the cap bit and the
// view should ask the user to zoom in.
export function selectVisibleClusters(clusters, zoom, bounds, maxMarkers) {
  const visible = [];
  let overflow = false;
  if (Array.isArray(clusters) && bounds) {
    const limit = Number.isFinite(maxMarkers) && maxMarkers > 0 ? maxMarkers : Infinity;
    for (const cluster of clusters) {
      if (!cellIntersectsBounds(clusterCellKey(cluster, zoom), zoom, bounds)) continue;
      if (visible.length >= limit) {
        overflow = true;
        break;
      }
      visible.push(cluster);
    }
  }
  return { visible, overflow };
}

// Marker reuse plan for an unchanged zoom (pan): add markers for clusters
// that entered the view, remove the ones that left, keep the rest. A zoom
// change alters cluster granularity, so the component rebuilds instead of
// calling this.
export function planMarkerChanges(existingKeys, visibleClusters, zoom) {
  const targetKeys = new Set();
  const add = [];
  if (Array.isArray(visibleClusters)) {
    for (const cluster of visibleClusters) {
      const key = clusterCellKey(cluster, zoom);
      targetKeys.add(key);
      if (!existingKeys.has(key)) add.push({ key, cluster });
    }
  }
  const remove = [];
  for (const key of existingKeys) {
    if (!targetKeys.has(key)) remove.push(key);
  }
  return { add, remove };
}
