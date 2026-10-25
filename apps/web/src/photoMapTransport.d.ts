export interface GeoPointDTO {
  id: number;
  lat: number;
  lon: number;
  takenAt: number;
  type: string;
}
export interface MapStripAsset {
  id: number;
  name: string;
  path: string;
  type: "photo" | "video";
  takenAt: number;
  size?: number;
}
export interface MapTransport {
  loadGeo: () => Promise<{ points: GeoPointDTO[]; total: number; truncated: boolean }>;
  loadAssetsByIds: (ids: number[]) => Promise<MapStripAsset[]>;
  thumbnail: (id: number) => string;
}
