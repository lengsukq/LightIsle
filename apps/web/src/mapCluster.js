// Grid clustering for map points: bins located assets into cells whose size
// follows the zoom level, so a dense city of photos renders as one bubble
// until the user zooms in. Pure and synchronous — the component re-clusters
// on zoomend.

export function geoCellSize(zoom) {
  const level = Math.max(0, Math.min(22, Math.floor(Number(zoom) || 0)));
  return 256 / 2 ** level;
}

export function clusterGeoPoints(points, zoom) {
  if (!Array.isArray(points) || points.length === 0) return [];
  const cellSize = geoCellSize(zoom);
  const bins = new Map();
  for (const point of points) {
    const latitude = Number(point.lat);
    const longitude = Number(point.lon);
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) continue;
    const key = Math.floor(latitude / cellSize) + ":" + Math.floor(longitude / cellSize);
    let bin = bins.get(key);
    if (!bin) {
      bin = { latSum: 0, lonSum: 0, count: 0, items: [] };
      bins.set(key, bin);
    }
    bin.latSum += latitude;
    bin.lonSum += longitude;
    bin.count++;
    bin.items.push(point);
  }
  const clusters = [];
  for (const bin of bins.values()) {
    clusters.push({
      lat: bin.latSum / bin.count,
      lon: bin.lonSum / bin.count,
      count: bin.count,
      items: bin.items,
    });
  }
  // Deterministic order: biggest clusters first so prominent places anchor
  // the visual hierarchy.
  clusters.sort((a, b) => b.count - a.count || b.lat - a.lat);
  return clusters;
}

// Leaflet-fitBounds input for the located points.
export function geoPointsBounds(points) {
  let minLat = 90;
  let maxLat = -90;
  let minLon = 180;
  let maxLon = -180;
  let found = 0;
  for (const point of points) {
    const latitude = Number(point.lat);
    const longitude = Number(point.lon);
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) continue;
    found++;
    minLat = Math.min(minLat, latitude);
    maxLat = Math.max(maxLat, latitude);
    minLon = Math.min(minLon, longitude);
    maxLon = Math.max(maxLon, longitude);
  }
  if (!found) return null;
  return [
    [minLat, minLon],
    [maxLat, maxLon],
  ];
}
