export interface PhotoVirtualWindow {
  columns: number;
  tileSize: number;
  gap: number;
  rowPitch: number;
  rowCount: number;
  totalHeight: number;
  startRow: number;
  endRow: number;
  startIndex: number;
  endIndex: number;
  topSpacer: number;
  bottomSpacer: number;
}

export function getPhotoVirtualWindow(options: {
  itemCount: number;
  containerWidth: number;
  viewportTop?: number;
  viewportHeight?: number;
  minTileWidth?: number;
  gap?: number;
  overscanRows?: number;
}): PhotoVirtualWindow;
