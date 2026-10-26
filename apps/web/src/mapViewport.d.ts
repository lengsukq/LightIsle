import type { GeoCluster } from "./mapCluster.js";

export interface ViewportBounds {
  south: number;
  west: number;
  north: number;
  east: number;
}
export interface VisibleClusterSelection {
  visible: GeoCluster[];
  overflow: boolean;
}
export interface MarkerChangePlan {
  add: Array<{ key: string; cluster: GeoCluster }>;
  remove: string[];
}
export function expandBounds(bounds: ViewportBounds | null | undefined, marginRatio: number): ViewportBounds | null;
export function clusterCellKey(cluster: { lat: number; lon: number }, zoom: number): string;
export function selectVisibleClusters(
  clusters: GeoCluster[] | null | undefined,
  zoom: number,
  bounds: ViewportBounds | null | undefined,
  maxMarkers: number,
): VisibleClusterSelection;
export function planMarkerChanges(
  existingKeys: ReadonlySet<string>,
  visibleClusters: GeoCluster[] | null | undefined,
  zoom: number,
): MarkerChangePlan;
