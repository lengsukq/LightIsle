// Native video time is relative to a transcoded HLS session; persist and
// display the original media timeline instead of comparing incompatible clocks.
export function cinemaTimeline(current, duration, sessionStart = 0, originalDuration = 0) {
  const offset = Number.isFinite(sessionStart) ? Math.max(0, sessionStart) : 0;
  const local = Number.isFinite(current) ? Math.max(0, current) : 0;
  const length = Number.isFinite(duration) ? Math.max(0, duration) : 0;
  const known = Number.isFinite(originalDuration) ? Math.max(0, originalDuration) : 0;
  const position = offset + local;
  // Some ongoing HLS playlists only expose their *current* buffered length.
  // Do not infer the end of the movie from that length.
  const total = known > 0 ? Math.max(known, position) : offset + length;
  const canInferEnd = known > 0 || offset === 0;
  return {position, duration: total, nearEnd: canInferEnd && total > 0 && total - position < 8};
}

export function cinemaSeekTarget(current, seconds, total) {
  const max = Number.isFinite(total) && total > 0 ? Math.max(0, total - 0.25) : Infinity;
  return Math.max(0, Math.min(max, (Number.isFinite(current) ? current : 0) + seconds));
}
