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
  size: number;
  favorite: boolean;
  personalFavorite?: boolean;
  canWrite?: boolean;
  capturedAt?: string;
  latitude?: number;
  longitude?: number;
  cameraMake?: string;
  cameraModel?: string;
  lensModel?: string;
  iso?: number;
  fNumber?: number;
  exposureSeconds?: number;
  focalLength?: number;
  width?: number;
  height?: number;
  durationSeconds?: number;
}
export interface MapTransport {
  loadGeo: () => Promise<{ points: GeoPointDTO[]; total: number; truncated: boolean }>;
  loadAssetsByIds: (ids: number[]) => Promise<MapStripAsset[]>;
  thumbnail: (id: number) => string;
}
