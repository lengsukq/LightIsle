/**
 * Shared UI debounce, polling, feedback, and media-control timing constants (ms).
 * Centralizes recurring magic durations across Web composables and views.
 */
export const TIMINGS_MS = {
  /** Fast background poll while an active admin overview or running task is visible. */
  FAST_POLL: 5_000,
  /** Standard background poll for passive shell telemetry and root discovery. */
  SLOW_POLL: 30_000,
  /** Passive alert center refresh cadence when the tab is visible. */
  ALERTS_POLL: 60_000,
  /** Cooldown after tab wake-up before triggering another root discovery refresh. */
  VISIBILITY_COOLDOWN: 3_000,
  /** Polling cadence for active migration / duplicate-scan / metadata-scrape jobs. */
  JOB_STATUS_POLL: 1_200,
  /** Debounce delay for instant catalog search inputs (Photos / Cinema). */
  SEARCH_DEBOUNCE: 260,
  /** Transient "copied" pill/button confirmation reset duration. */
  COPIED_FEEDBACK: 1_800,
  /** Delay before revoking a temporary Blob object URL after triggering download. */
  BLOB_REVOKE_DELAY: 1_000,
  /** Stagger interval between sequential browser file downloads in a batch. */
  BATCH_DOWNLOAD_STAGGER: 180,
  /** Default photo viewer slideshow advance interval. */
  SLIDESHOW_INTERVAL: 4_000,
  /** Video transport bar / OSD auto-hide idle timeout. */
  PLAYER_HUD_HIDE: 2_600,
} as const;
