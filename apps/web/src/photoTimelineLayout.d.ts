export interface PhotoTimelinePosition {
  left: number;
  top: number;
}
export interface PhotoTimelineGroup {
  title: string;
  top: number;
  startIndex: number;
  count: number;
}
export interface PhotoTimelineLayout {
  columns: number;
  tileSize: number;
  rowPitch: number;
  gap: number;
  totalHeight: number;
  positions: PhotoTimelinePosition[];
  groups: PhotoTimelineGroup[];
}
export interface PhotoTimelineWindow {
  startIndex: number;
  endIndex: number;
  headers: PhotoTimelineGroup[];
}
export function timelineMonth(timestamp: number): string;
export function createPhotoTimelineLayout(timestamps: number[], containerWidth: number): PhotoTimelineLayout;
export function getPhotoTimelineWindow(layout: PhotoTimelineLayout, viewportTop: number, viewportHeight: number): PhotoTimelineWindow;
