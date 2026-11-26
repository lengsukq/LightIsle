// Pure gesture math for the photo viewer: anchored wheel zoom, two-finger
// pinch scaling, single-finger swipe detection and pan normalization. The
// component owns the pointer bookkeeping; everything here stays testable.

export interface ViewerTransform {
  scale: number;
  x: number;
  y: number;
}

export interface ViewerPoint {
  x: number;
  y: number;
}

export const viewerMinScale = 1;
export const viewerMaxScale = 5;
const swipeThreshold = 48;

function clampScale(value: number): number {
  if (!Number.isFinite(value)) return viewerMinScale;
  return Math.min(viewerMaxScale, Math.max(viewerMinScale, value));
}

// Scales around an anchor point (coordinates relative to the pan origin, i.e.
// the untransformed image center) so the pixel under the cursor or pinch
// center stays put, matching native image viewers.
export function zoomAtAnchor(
  state: ViewerTransform,
  factor: number,
  anchor: ViewerPoint = { x: 0, y: 0 },
): ViewerTransform {
  const scale = clampScale(state.scale * factor);
  const ratio = scale / state.scale;
  return {
    scale,
    x: anchor.x - (anchor.x - state.x) * ratio,
    y: anchor.y - (anchor.y - state.y) * ratio,
  };
}

export function pinchScale(
  startScale: number,
  startDistance: number,
  currentDistance: number,
): number {
  if (startDistance <= 0 || !Number.isFinite(currentDistance)) return startScale;
  return clampScale((startScale * currentDistance) / startDistance);
}

export function pinchDistance(first: ViewerPoint, second: ViewerPoint): number {
  const dx = second.x - first.x;
  const dy = second.y - first.y;
  return Math.hypot(dx, dy);
}

// A swipe only counts when it is predominantly horizontal and clearly longer
// than a tap's jitter; vertical intent goes to page scrolling instead.
export function swipeDirection(start: ViewerPoint, end: ViewerPoint): "left" | "right" | null {
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  if (Math.abs(dx) < swipeThreshold) return null;
  if (Math.abs(dx) < Math.abs(dy) * 1.5) return null;
  return dx < 0 ? "left" : "right";
}

// At or below unity the image snaps home: no offset, no residual scale.
export function normalizeViewerTransform(state: ViewerTransform): ViewerTransform {
  if (state.scale <= viewerMinScale + 0.01) return { scale: viewerMinScale, x: 0, y: 0 };
  return { scale: clampScale(state.scale), x: state.x, y: state.y };
}

export function wheelZoomFactor(deltaY: number): number {
  if (!Number.isFinite(deltaY) || deltaY === 0) return 1;
  const magnitude = Math.min(240, Math.abs(deltaY));
  return Math.exp((-Math.sign(deltaY) * magnitude) / 480);
}

export function clampPanOffset(
  state: ViewerTransform,
  stageSize: { width: number; height: number },
  mediaSize?: { width: number; height: number } | null,
): ViewerTransform {
  const normalized = normalizeViewerTransform(state);
  if (normalized.scale <= viewerMinScale) return normalized;
  const baseW = mediaSize && mediaSize.width > 0 ? mediaSize.width : stageSize.width;
  const baseH = mediaSize && mediaSize.height > 0 ? mediaSize.height : stageSize.height;
  const maxX = Math.max(0, (baseW * normalized.scale - stageSize.width) / 2);
  const maxY = Math.max(0, (baseH * normalized.scale - stageSize.height) / 2);
  return {
    scale: normalized.scale,
    x: Math.max(-maxX, Math.min(maxX, normalized.x)),
    y: Math.max(-maxY, Math.min(maxY, normalized.y)),
  };
}

export function doubleTapZoom(
  state: ViewerTransform,
  anchor: ViewerPoint = { x: 0, y: 0 },
  targetScale = 2.5,
): ViewerTransform {
  if (state.scale > viewerMinScale + 0.01) {
    return { scale: viewerMinScale, x: 0, y: 0 };
  }
  return zoomAtAnchor({ scale: viewerMinScale, x: 0, y: 0 }, targetScale, anchor);
}

export function horizontalSwipeResistance(
  dx: number,
  canSwipePrev: boolean,
  canSwipeNext: boolean,
): number {
  if ((dx > 0 && !canSwipePrev) || (dx < 0 && !canSwipeNext)) {
    return Math.round(dx * 0.28);
  }
  return Math.round(dx);
}
