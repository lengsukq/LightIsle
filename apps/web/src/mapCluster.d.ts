export interface GeoCluster {
  lat: number;
  lon: number;
  count: number;
  items: Array<{ id: number; lat: number; lon: number }>;
}
export function geoCellSize(zoom: number): number;
export function clusterGeoPoints(points: Array<{ id: number; lat: number; lon: number }>, zoom: number): GeoCluster[];
export function geoPointsBounds(points: Array<{ lat: number; lon: number }>): [[number, number], [number, number]] | null;
