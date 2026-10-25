// Pure gesture math for the photo viewer: anchored wheel zoom, two-finger
// pinch scaling, single-finger swipe detection and pan normalization. The
// component owns the pointer bookkeeping; everything here stays testable.

export const viewerMinScale = 1;
export const viewerMaxScale = 5;
const swipeThreshold = 48;

function clampScale(value) {
  if (!Number.isFinite(value)) return viewerMinScale;
  return Math.min(viewerMaxScale, Math.max(viewerMinScale, value));
}

// Scales around an anchor point (coordinates relative to the pan origin, i.e.
// the untransformed image center) so the pixel under the cursor or pinch
// center stays put, matching native image viewers.
export function zoomAtAnchor(state, factor, anchor = { x: 0, y: 0 }) {
  const scale = clampScale(state.scale * factor);
  const ratio = scale / state.scale;
  return {
    scale,
    x: anchor.x - (anchor.x - state.x) * ratio,
    y: anchor.y - (anchor.y - state.y) * ratio,
  };
}

export function pinchScale(startScale, startDistance, currentDistance) {
  if (startDistance <= 0 || !Number.isFinite(currentDistance)) return startScale;
  return clampScale((startScale * currentDistance) / startDistance);
}

export function pinchDistance(first, second) {
  const dx = second.x - first.x;
  const dy = second.y - first.y;
  return Math.hypot(dx, dy);
}

// A swipe only counts when it is predominantly horizontal and clearly longer
// than a tap's jitter; vertical intent goes to page scrolling instead.
export function swipeDirection(start, end) {
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  if (Math.abs(dx) < swipeThreshold) return null;
  if (Math.abs(dx) < Math.abs(dy) * 1.5) return null;
  return dx < 0 ? "left" : "right";
}

// At or below unity the image snaps home: no offset, no residual scale.
export function normalizeViewerTransform(state) {
  if (state.scale <= viewerMinScale + 0.01) return { scale: viewerMinScale, x: 0, y: 0 };
  return { scale: clampScale(state.scale), x: state.x, y: state.y };
}

export function wheelZoomFactor(deltaY) {
  if (!Number.isFinite(deltaY) || deltaY === 0) return 1;
  const magnitude = Math.min(240, Math.abs(deltaY));
  return Math.exp((-Math.sign(deltaY) * magnitude) / 480);
}
