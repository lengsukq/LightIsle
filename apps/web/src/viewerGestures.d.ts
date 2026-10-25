export interface ViewerTransform {
  scale: number;
  x: number;
  y: number;
}
export interface ViewerPoint {
  x: number;
  y: number;
}
export const viewerMinScale: number;
export const viewerMaxScale: number;
export function zoomAtAnchor(state: ViewerTransform, factor: number, anchor?: ViewerPoint): ViewerTransform;
export function pinchScale(startScale: number, startDistance: number, currentDistance: number): number;
export function pinchDistance(first: ViewerPoint, second: ViewerPoint): number;
export function swipeDirection(start: ViewerPoint, end: ViewerPoint): "left" | "right" | null;
export function normalizeViewerTransform(state: ViewerTransform): ViewerTransform;
export function wheelZoomFactor(deltaY: number): number;
