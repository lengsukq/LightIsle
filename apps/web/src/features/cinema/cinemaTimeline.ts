export interface CinemaTimeline {
  position: number;
  duration: number;
  nearEnd: boolean;
}

export interface TimeRangesLike {
  readonly length: number;
  start(index: number): number;
  end(index: number): number;
}

// Native video time is relative to a transcoded HLS session; persist and
// display the original media timeline instead of comparing incompatible clocks.
export function cinemaTimeline(
  current: number,
  duration: number,
  sessionStart = 0,
  originalDuration = 0,
  ongoingHls = false,
): CinemaTimeline {
  const offset = Number.isFinite(sessionStart) ? Math.max(0, sessionStart) : 0;
  const local = Number.isFinite(current) ? Math.max(0, current) : 0;
  const length = Number.isFinite(duration) ? Math.max(0, duration) : 0;
  const known = Number.isFinite(originalDuration) ? Math.max(0, originalDuration) : 0;
  const position = offset + local;
  const observed = offset + length;
  // Ongoing HLS playlists only expose their *current* buffered length until
  // ENDLIST is written; never shrink below known full duration or infer end.
  const total = known > 0 ? Math.max(known, position, ongoingHls ? 0 : observed) : observed;
  const canInferEnd = known > 0 || (!ongoingHls && offset === 0);
  return { position, duration: total, nearEnd: canInferEnd && total > 0 && total - position < 8 };
}

export function cinemaSeekTarget(current: number, seconds: number, total: number): number {
  const max = Number.isFinite(total) && total > 0 ? Math.max(0, total - 0.25) : Infinity;
  return Math.max(0, Math.min(max, (Number.isFinite(current) ? current : 0) + seconds));
}

export function resolveKnownFilmDuration(sources: {
  sessionDuration?: number;
  tracksDuration?: number;
  mediaDuration?: number;
  progressDuration?: number;
}): number {
  const probed = Math.max(
    Number.isFinite(sources.sessionDuration) ? (sources.sessionDuration ?? 0) : 0,
    Number.isFinite(sources.tracksDuration) ? (sources.tracksDuration ?? 0) : 0,
    Number.isFinite(sources.mediaDuration) ? (sources.mediaDuration ?? 0) : 0,
  );
  if (probed > 0) return probed;
  return Number.isFinite(sources.progressDuration) && (sources.progressDuration ?? 0) > 0
    ? (sources.progressDuration ?? 0)
    : 0;
}

export function canSeekWithinHlsRanges(
  ranges: TimeRangesLike | null | undefined,
  targetSeconds: number,
  sessionStart: number,
  knownDuration: number,
): boolean {
  const offset = Number.isFinite(sessionStart) ? Math.max(0, sessionStart) : 0;
  const localTarget = targetSeconds - offset;
  if (!Number.isFinite(localTarget) || localTarget < 0 || !ranges || ranges.length <= 0) {
    return false;
  }
  for (let i = 0; i < ranges.length; i++) {
    const start = ranges.start(i);
    const end = ranges.end(i);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) continue;
    const reachedFilmEnd = knownDuration > 0 && offset + end >= knownDuration - 2;
    const safeEnd = reachedFilmEnd ? end : Math.max(start, end - 1.0);
    if (localTarget >= start - 0.05 && localTarget <= safeEnd) {
      return true;
    }
  }
  return false;
}

export function resolveBufferedFilmEnd(
  ranges: TimeRangesLike | null | undefined,
  localCurrent: number,
  sessionStart = 0,
): number {
  if (!ranges || ranges.length <= 0) return 0;
  const offset = Number.isFinite(sessionStart) ? Math.max(0, sessionStart) : 0;
  const local = Number.isFinite(localCurrent) ? Math.max(0, localCurrent) : 0;
  let best = 0;
  for (let i = 0; i < ranges.length; i++) {
    const s = ranges.start(i);
    const e = ranges.end(i);
    if (!Number.isFinite(s) || !Number.isFinite(e) || e <= s) continue;
    if (local >= s - 1 && local <= e + 1) {
      best = Math.max(best, offset + e);
    } else if (best === 0) {
      best = offset + e;
    }
  }
  return best;
}
