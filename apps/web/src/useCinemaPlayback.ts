import { nextTick, ref, type Ref } from "vue";
import type Hls from "hls.js";
import type { ProgressSnapshot } from "./playbackProgressWriter.ts";
import {
  canSeekWithinHlsRanges,
  cinemaSeekTarget,
  cinemaTimeline,
  resolveBufferedFilmEnd,
  resolveKnownFilmDuration,
} from "./cinemaTimeline.ts";
import {
  abortableDelay,
  buildCinemaPlaybackOptions,
  playbackMode,
  playbackRateOptions,
  transcodeErrorMessage,
  useCinemaMediaControls,
  useCinemaProgressPersistence,
  type CinemaRootProps,
} from "./cinemaPlaybackSupport.ts";
import type { Movie, TrackInfo, TranscodeSession } from "./cinemaTypes.ts";

type CinemaApi = <T>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;

export function useCinemaPlayback({
  selected,
  movies,
  props,
  api,
  apiPath,
  mediaPath,
}: {
  selected: Ref<Movie | null>;
  movies: Ref<Movie[]>;
  props: CinemaRootProps;
  api: CinemaApi;
  apiPath: (path: string) => string;
  mediaPath: (path: string) => string;
}) {
  const player = ref<HTMLVideoElement | null>(null);
  const hlsPlayer = ref<HTMLVideoElement | null>(null);
  const caption = ref("off");
  const playError = ref("");
  const hlsSession = ref<TranscodeSession | null>(null);
  const hlsTracks = ref<TrackInfo | null>(null);
  const hlsStarting = ref(false);
  const hlsQuality = ref("source");
  const playbackPosition = ref(0);
  const playbackDuration = ref(0);
  const playbackBuffered = ref(0);
  const seekPreview = ref<number | null>(null);
  const pendingSeekTarget = ref<number | null>(null);

  let hls: Hls | null = null;
  let transcodeRequestGeneration = 0;
  let activeTranscodeAbort: AbortController | null = null;
  let startingTargetKey = "";
  let tracksScopeKey = "";
  let activeSessionFilmId = 0;
  let activeSessionScopeKey = "";
  let observedDurationScopeKey = "";
  let maxObservedDuration = 0;
  let desiredHlsStart: number | null = null;
  let pendingDirectSeek: number | null = null;
  let hlsSeekDebounceTimer: ReturnType<typeof setTimeout> | null = null;

  function filmScopeKey(filmId: number): string {
    return `${props.rootId ?? ""}:${props.rootGeneration ?? 0}:${filmId}`;
  }

  function activeVideo() {
    return hlsSession.value || hlsStarting.value ? hlsPlayer.value : player.value;
  }

  const controls = useCinemaMediaControls({ player, hlsPlayer, activeVideo, playError });
  const persistence = useCinemaProgressPersistence({ selected, movies, props, filmScopeKey });
  const options = buildCinemaPlaybackOptions({
    selected,
    player,
    hlsPlayer,
    caption,
    hlsSession,
    hlsTracks,
    hlsStarting,
    hlsQuality,
    preferLocalDecode: controls.preferLocalDecode,
    directLocalOverride: controls.directLocalOverride,
    mediaPath,
  });

  function clearSeekDebounce() {
    if (hlsSeekDebounceTimer !== null) {
      clearTimeout(hlsSeekDebounceTimer);
      hlsSeekDebounceTimer = null;
    }
  }

  function recordObservedDuration(filmId: number, durationSeconds: number) {
    if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) return;
    const scope = filmScopeKey(filmId);
    if (observedDurationScopeKey !== scope) {
      observedDurationScopeKey = scope;
      maxObservedDuration = durationSeconds;
    } else if (durationSeconds > maxObservedDuration) {
      maxObservedDuration = durationSeconds;
    }
  }

  function knownDurationFor(film: Movie, session: TranscodeSession | null = hlsSession.value): number {
    const scope = filmScopeKey(film.id);
    const resolved = resolveKnownFilmDuration({
      sessionDuration: session?.durationSeconds,
      tracksDuration: tracksScopeKey === scope ? hlsTracks.value?.durationSeconds : 0,
      mediaDuration: film.durationSeconds,
      progressDuration: film.duration,
    });
    const observed = observedDurationScopeKey === scope ? maxObservedDuration : 0;
    return Math.max(resolved, observed);
  }

  function hydrateFilmDuration(filmId: number, scopeKey: string, durationSeconds?: number) {
    if (!durationSeconds || !Number.isFinite(durationSeconds) || durationSeconds <= 0) return;
    if (scopeKey !== filmScopeKey(filmId)) return;
    recordObservedDuration(filmId, durationSeconds);
    if (selected.value?.id === filmId && (selected.value.durationSeconds ?? 0) <= 0) {
      selected.value.durationSeconds = durationSeconds;
    }
    const existing = movies.value.find((item) => item.id === filmId);
    if (existing && (existing.durationSeconds ?? 0) <= 0) {
      movies.value = movies.value.map((item) =>
        item.id === filmId ? { ...item, durationSeconds } : item,
      );
    }
    if (selected.value?.id === filmId && durationSeconds > playbackDuration.value) {
      playbackDuration.value = durationSeconds;
    }
  }

  function playbackClock() {
    const film = selected.value;
    if (!film) return null;
    const session = hlsSession.value;
    const known = knownDurationFor(film, session);
    const video = activeVideo();
    if (!video) {
      const fallbackPos = pendingSeekTarget.value ?? playbackPosition.value;
      return cinemaTimeline(fallbackPos, 0, 0, known, Boolean(session || hlsStarting.value));
    }
    const clock = cinemaTimeline(
      video.currentTime,
      video.duration,
      session?.start ?? 0,
      known,
      Boolean(session),
    );
    if (clock.duration > 0) recordObservedDuration(film.id, clock.duration);
    return clock;
  }

  function refreshBufferedProgress() {
    const video = activeVideo();
    const session = hlsSession.value;
    if (!video) {
      playbackBuffered.value = 0;
      return;
    }
    const offset = session?.start ?? 0;
    const fromBuffered = resolveBufferedFilmEnd(video.buffered, video.currentTime, offset);
    const fromSeekable = session ? resolveBufferedFilmEnd(video.seekable, video.currentTime, offset) : 0;
    playbackBuffered.value = Math.max(fromBuffered, fromSeekable);
  }

  function refreshPlaybackClock() {
    const clock = playbackClock();
    if (!clock) return;
    playbackPosition.value = pendingSeekTarget.value !== null ? pendingSeekTarget.value : clock.position;
    playbackDuration.value = clock.duration;
    refreshBufferedProgress();
  }

  function resetPlaybackForFilm(film: Movie | null) {
    clearSeekDebounce();
    seekPreview.value = null;
    pendingSeekTarget.value = null;
    desiredHlsStart = null;
    pendingDirectSeek = null;
    playbackBuffered.value = 0;
    if (!film) {
      observedDurationScopeKey = "";
      maxObservedDuration = 0;
      playbackPosition.value = 0;
      playbackDuration.value = 0;
      return;
    }
    const scope = filmScopeKey(film.id);
    if (observedDurationScopeKey !== scope) {
      observedDurationScopeKey = scope;
      maxObservedDuration = 0;
    }
    playbackPosition.value = film.position > 5 && !film.completed ? film.position : 0;
    const known = knownDurationFor(film, null);
    recordObservedDuration(film.id, known);
    playbackDuration.value = known;
  }

  function stopServerHlsSession(filmId: number, sessionId: string) {
    if (!filmId || !sessionId || typeof fetch !== "function") return;
    const headers = new Headers({ "X-LightIsle-Request": "1" });
    if (props.rootId) headers.set("X-LightIsle-Root-Generation", String(props.rootGeneration ?? 0));
    const url = apiPath(`/api/v2/cinema/${filmId}/hls/session?session=${encodeURIComponent(sessionId)}`);
    try {
      void Promise.resolve(
        fetch(url, { method: "DELETE", credentials: "same-origin", cache: "no-store", keepalive: true, headers }),
      ).catch(() => {});
    } catch {}
  }

  function performSeek(targetPosition: number, debounceHlsMs = 0) {
    const film = selected.value;
    if (!film || !Number.isFinite(targetPosition)) return;
    const clock = playbackClock();
    const total = clock?.duration || knownDurationFor(film);
    const target = cinemaSeekTarget(targetPosition, 0, total);
    const session = hlsSession.value;
    const video = activeVideo();
    seekPreview.value = null;

    if (!session && !hlsStarting.value) {
      clearSeekDebounce();
      playbackPosition.value = target;
      if (video) {
        if ((video.readyState ?? 1) >= 1) {
          pendingSeekTarget.value = null;
          video.currentTime = target;
          refreshPlaybackClock();
        } else {
          pendingSeekTarget.value = target;
          pendingDirectSeek = target;
        }
        void save();
      }
      return;
    }

    const known = knownDurationFor(film, session);
    if (
      !hlsStarting.value &&
      session &&
      video &&
      canSeekWithinHlsRanges(video.seekable, target, session.start, known)
    ) {
      clearSeekDebounce();
      pendingSeekTarget.value = null;
      video.currentTime = Math.max(0, target - session.start);
      refreshPlaybackClock();
      void save();
      return;
    }

    const wasStarting = hlsStarting.value;
    pendingSeekTarget.value = target;
    playbackPosition.value = target;
    if (known > playbackDuration.value) playbackDuration.value = known;
    if (!wasStarting) void save();

    const audio = session?.audioTrack ?? 0;
    const quality = session?.quality ?? hlsQuality.value;
    clearSeekDebounce();
    if (debounceHlsMs > 0) {
      hlsSeekDebounceTimer = setTimeout(() => {
        hlsSeekDebounceTimer = null;
        if (selected.value?.id === film.id) void startTranscode(film, target, audio, quality);
      }, debounceHlsMs);
    } else {
      void startTranscode(film, target, audio, quality);
    }
  }

  async function jumpPlayback(seconds: number) {
    const film = selected.value;
    if (!film || !Number.isFinite(seconds)) return;
    const clock = playbackClock();
    const base = pendingSeekTarget.value ?? clock?.position ?? playbackPosition.value;
    const total = clock?.duration || knownDurationFor(film);
    const target = cinemaSeekTarget(base, seconds, total);
    performSeek(target, hlsSession.value || hlsStarting.value ? 150 : 0);
  }

  function seekAbsolute(position: number) {
    if (Number.isFinite(position)) performSeek(position, 0);
  }

  async function togglePlayPause() {
    const p = activeVideo();
    if (!p || hlsStarting.value) return;
    if (p.paused || p.ended) {
      try {
        await p.play();
      } catch {}
    } else {
      p.pause?.();
      void save();
    }
    controls.syncVideoMediaState();
  }

  function setPreferLocalDecode(checked: boolean) {
    controls.preferLocalDecode.value = checked;
    controls.directLocalOverride.value = checked;
    controls.writeBoolPreference("lightisle-cinema-prefer-local-decode", checked);
    if (selected.value) {
      if (checked) void switchQuality("local");
      else if (playbackMode(selected.value) === "download-only") void switchQuality("source");
    }
  }

  function detachHlsEngine() {
    if (hls) {
      hls.destroy();
      hls = null;
    }
  }

  function destroyHls() {
    clearSeekDebounce();
    transcodeRequestGeneration += 1;
    startingTargetKey = "";
    if (activeTranscodeAbort) {
      activeTranscodeAbort.abort();
      activeTranscodeAbort = null;
    }
    const priorSession = hlsSession.value;
    const priorFilmId = activeSessionFilmId;
    const priorScope = activeSessionScopeKey;
    detachHlsEngine();
    hlsSession.value = null;
    hlsTracks.value = null;
    tracksScopeKey = "";
    activeSessionFilmId = 0;
    activeSessionScopeKey = "";
    desiredHlsStart = null;
    pendingSeekTarget.value = null;
    hlsStarting.value = false;
    controls.isPlaying.value = false;
    if (priorSession && priorFilmId && priorScope === filmScopeKey(priorFilmId)) {
      stopServerHlsSession(priorFilmId, priorSession.sessionId);
    }
  }

  async function waitForPlaylist(
    v: Movie,
    session: TranscodeSession,
    isCurrent: () => boolean,
    signal?: AbortSignal,
  ) {
    const url = mediaPath(`/api/v2/cinema/${v.id}/hls/${session.sessionId}/index.m3u8`);
    if (session.ready) return url;
    for (let attempt = 0; attempt < 115; attempt++) {
      if (!isCurrent() || signal?.aborted) throw new Error("aborted");
      const response = await fetch(url, { method: "GET", credentials: "same-origin", cache: "no-store", signal });
      if (!isCurrent() || signal?.aborted) throw new Error("aborted");
      if (response.ok) return url;
      if (response.status === 502) throw new Error("transcode_failed");
      const delay = attempt === 0 ? 80 : attempt < 5 ? 110 : attempt < 15 ? 170 : 250;
      await abortableDelay(delay, signal);
    }
    throw new Error("transcode_start_timeout");
  }

  async function startTranscode(v: Movie, startSeconds = 0, audio = 0, quality = "source") {
    const normalizedStart = Math.max(0, Number.isFinite(startSeconds) ? startSeconds : 0);
    const targetKey = `${v.id}:${Math.round(normalizedStart * 10)}:${audio}:${quality}`;
    if (hlsStarting.value && startingTargetKey === targetKey) return;

    clearSeekDebounce();
    if (activeTranscodeAbort) {
      activeTranscodeAbort.abort();
      activeTranscodeAbort = null;
    }

    const scopeKey = filmScopeKey(v.id);
    const sameFilmSession =
      activeSessionScopeKey === scopeKey && hlsSession.value ? hlsSession.value.sessionId : "";
    if (tracksScopeKey !== scopeKey) {
      hlsTracks.value = null;
      tracksScopeKey = "";
    }

    detachHlsEngine();
    hlsPlayer.value?.pause?.();
    transcodeRequestGeneration += 1;
    const requestGeneration = transcodeRequestGeneration;
    const requestRoot = props.rootId;
    const requestRootGeneration = props.rootGeneration ?? 0;
    const abortController = new AbortController();
    activeTranscodeAbort = abortController;
    startingTargetKey = targetKey;
    hlsStarting.value = true;
    controls.isPlaying.value = false;
    playError.value = "";
    hlsQuality.value = quality;
    desiredHlsStart = normalizedStart;
    pendingSeekTarget.value = normalizedStart;
    playbackPosition.value = normalizedStart;
    const initialKnown = knownDurationFor(v);
    if (initialKnown > playbackDuration.value) playbackDuration.value = initialKnown;

    const isCurrent = () =>
      requestGeneration === transcodeRequestGeneration &&
      selected.value?.id === v.id &&
      props.rootId === requestRoot &&
      (props.rootGeneration ?? 0) === requestRootGeneration;

    try {
      const query =
        `/api/v2/cinema/${v.id}/hls/session?start=${encodeURIComponent(normalizedStart.toFixed(3))}&audio=${audio}` +
        (quality && quality !== "source" ? `&quality=${encodeURIComponent(quality)}` : "") +
        (sameFilmSession ? `&replace=${encodeURIComponent(sameFilmSession)}` : "");
      const session = await api<TranscodeSession>(apiPath(query), undefined, undefined, abortController.signal);
      if (!isCurrent()) {
        if (session?.sessionId && session.sessionId !== hlsSession.value?.sessionId) {
          stopServerHlsSession(v.id, session.sessionId);
        }
        return;
      }
      hlsSession.value = session;
      activeSessionFilmId = v.id;
      activeSessionScopeKey = scopeKey;
      hydrateFilmDuration(v.id, scopeKey, session.durationSeconds);

      await nextTick();
      if (!isCurrent()) return;
      const video = hlsPlayer.value;
      if (!video) throw new Error("transcode_failed");
      const url = await waitForPlaylist(v, session, isCurrent, abortController.signal);
      if (!isCurrent()) return;

      if (video.canPlayType("application/vnd.apple.mpegurl")) {
        video.src = url;
        video.load?.();
      } else {
        const { default: Hls } = await import("hls.js");
        if (!isCurrent()) return;
        if (!Hls.isSupported()) {
          playError.value = "当前浏览器不支持所需的媒体能力，请下载原片后使用本地播放器。";
          return;
        }
        hls = new Hls({ enableWorker: false, startPosition: 0, backBufferLength: 90 });
        hls.loadSource(url);
        hls.attachMedia(video);
        hls.on(Hls.Events.ERROR, (_event, data) => {
          if (data.fatal && isCurrent()) {
            playError.value = `转码播放中断（${data.details || "media_error"}）。可重新点击转码播放，或下载原片用 IINA/VLC 播放。`;
          }
        });
      }

      if (!hlsTracks.value || tracksScopeKey !== scopeKey) {
        void api<{ tracks: TrackInfo }>(
          apiPath(`/api/v2/cinema/${v.id}/tracks`),
          undefined,
          undefined,
          abortController.signal,
        )
          .then((result) => {
            if (selected.value?.id === v.id && filmScopeKey(v.id) === scopeKey) {
              hlsTracks.value = result.tracks;
              tracksScopeKey = scopeKey;
              hydrateFilmDuration(v.id, scopeKey, result.tracks.durationSeconds);
            }
          })
          .catch(() => {});
      }

      if (!isCurrent()) return;
      controls.applyPlaybackRate();
    } catch (e) {
      const aborted = e instanceof Error && (e.message === "aborted" || e.name === "AbortError");
      if (isCurrent() && !aborted) {
        destroyHls();
        if (e instanceof Error && e.message === "transcode_unavailable") {
          controls.directLocalOverride.value = true;
          pendingDirectSeek = normalizedStart > 0 ? normalizedStart : null;
          playError.value = "服务器未安装 FFmpeg，已自动启用原片直传（本地解码）。";
        } else {
          playError.value = transcodeErrorMessage(e);
        }
      }
    } finally {
      if (isCurrent()) {
        hlsStarting.value = false;
        startingTargetKey = "";
        if (activeTranscodeAbort === abortController) activeTranscodeAbort = null;
      }
    }
  }

  async function switchAudioTrack(audioIndex: number) {
    const v = selected.value;
    const session = hlsSession.value;
    const p = hlsPlayer.value;
    if (!v || !session) return;
    const realPosition =
      pendingSeekTarget.value ??
      (p && Number.isFinite(p.currentTime) ? p.currentTime + session.start : playbackPosition.value);
    void save();
    caption.value = caption.value.startsWith("emb:") ? caption.value : "off";
    await startTranscode(v, Math.max(0, realPosition), audioIndex, hlsQuality.value);
  }

  async function switchQuality(quality: string) {
    const v = selected.value;
    const session = hlsSession.value;
    const p = hlsPlayer.value;
    if (!v) return;
    const realPosition =
      pendingSeekTarget.value ??
      (session && p && Number.isFinite(p.currentTime) ? p.currentTime + session.start : v.position);
    void save();
    if (quality === "local") {
      controls.directLocalOverride.value = true;
      pendingDirectSeek = Math.max(0, realPosition);
      destroyHls();
      playbackPosition.value = Math.max(0, realPosition);
      playError.value = playbackMode(v) === "download-only" ? "原片直传（本地解码）播放中。" : "";
      await nextTick();
      return;
    }
    controls.directLocalOverride.value = false;
    if (quality === "source" && playbackMode(v) !== "download-only" && !controls.preferLocalDecode.value) {
      pendingDirectSeek = Math.max(0, realPosition);
      destroyHls();
      playbackPosition.value = Math.max(0, realPosition);
      playError.value = "";
      await nextTick();
      return;
    }
    await startTranscode(v, Math.max(0, realPosition), session ? session.audioTrack : 0, quality);
  }

  function loaded() {
    const v = selected.value;
    const p = activeVideo();
    const session = hlsSession.value;
    if (!v || !p) return;
    controls.applyPlaybackRate();
    p.muted = controls.isMuted.value;
    if (controls.volume.value > 0) p.volume = controls.volume.value;

    if (!session && pendingDirectSeek !== null) {
      const target = pendingDirectSeek;
      pendingDirectSeek = null;
      pendingSeekTarget.value = null;
      if (!Number.isFinite(p.duration) || p.duration > target) p.currentTime = target;
      refreshPlaybackClock();
      void p.play().catch(() => {});
      controls.syncVideoMediaState();
      return;
    }

    const resume = v.position > 5 && !v.completed;
    if (!session) {
      pendingSeekTarget.value = null;
      if (resume && p.duration > v.position + 5) p.currentTime = v.position;
      refreshPlaybackClock();
      void p.play().catch(() => {});
      controls.syncVideoMediaState();
      return;
    }

    const targetOffset =
      desiredHlsStart !== null
        ? Math.max(0, desiredHlsStart - session.start)
        : resume
          ? Math.max(0, v.position - session.start)
          : 0;
    desiredHlsStart = null;
    pendingSeekTarget.value = null;
    if (targetOffset > 0.25 && (!Number.isFinite(p.duration) || p.duration > targetOffset + 0.25)) {
      try {
        p.currentTime = targetOffset;
      } catch {}
    } else if (p.currentTime > 1 && targetOffset <= 0.25) {
      try {
        p.currentTime = 0;
      } catch {}
    }
    refreshPlaybackClock();
    void p.play().catch(() => {});
    controls.syncVideoMediaState();
  }

  async function save(done = false) {
    const v = selected.value;
    const p = activeVideo();
    const session = hlsSession.value;
    if (!v || !p || !Number.isFinite(p.duration) || p.duration <= 0) return;
    if (!Number.isFinite(p.currentTime) || p.currentTime < 0) return;
    const known = knownDurationFor(v, session);
    const clock = cinemaTimeline(p.currentTime, p.duration, session?.start ?? 0, known, Boolean(session));
    if (clock.duration <= 0) return;
    recordObservedDuration(v.id, clock.duration);
    const rootId = props.rootId ?? "";
    const rootGeneration = props.rootGeneration ?? 0;
    const snapshot: ProgressSnapshot = {
      key: `${rootId}:${rootGeneration}:${v.id}`,
      id: v.id,
      rootId,
      rootGeneration,
      url: apiPath(`/api/v2/cinema/${v.id}/progress`),
      position: clock.position,
      duration: clock.duration,
      completed: done || clock.nearEnd,
    };
    await persistence.progressWriter.save(snapshot);
  }

  let lastSave = 0;
  function resetProgressClock() {
    lastSave = 0;
  }

  function tick() {
    if (pendingSeekTarget.value !== null && !hlsStarting.value) {
      pendingSeekTarget.value = null;
    }
    refreshPlaybackClock();
    const now = Date.now();
    if (now - lastSave > 10000) {
      lastSave = now;
      void save();
    }
  }

  function resetPendingSeek() {
    clearSeekDebounce();
    pendingDirectSeek = null;
    pendingSeekTarget.value = null;
    desiredHlsStart = null;
  }

  return {
    player,
    hlsPlayer,
    caption,
    playError,
    hlsSession,
    hlsTracks,
    hlsStarting,
    hlsQuality,
    playbackRate: controls.playbackRate,
    autoplayNext: controls.autoplayNext,
    preferLocalDecode: controls.preferLocalDecode,
    directLocalOverride: controls.directLocalOverride,
    playbackPosition,
    playbackDuration,
    playbackBuffered,
    canPictureInPicture: controls.canPictureInPicture,
    seekPreview,
    progressSaveError: persistence.progressSaveError,
    retryProgress: persistence.retryProgress,
    currentFilmProgressUnsaved: persistence.currentFilmProgressUnsaved,
    stream: options.stream,
    track: options.track,
    download: options.download,
    playback: options.playback,
    canAttemptDirect: options.canAttemptDirect,
    destroyHls,
    refreshProgressSaveError: persistence.refreshProgressSaveError,
    refreshBufferedProgress,
    resetPlaybackForFilm,
    resetPendingSeek,
    startTranscode,
    switchAudioTrack,
    switchQuality,
    playbackRateOptions,
    captionOptions: options.captionOptions,
    audioTrackOptions: options.audioTrackOptions,
    currentQuality: options.currentQuality,
    cinemaQualityOptions: options.cinemaQualityOptions,
    setPlaybackRate: controls.setPlaybackRate,
    setAutoplayNext: controls.setAutoplayNext,
    setPreferLocalDecode,
    activeVideo,
    loaded,
    save,
    tick,
    resetProgressClock,
    changeCaption: options.changeCaption,
    captionSrclang: options.captionSrclang,
    jumpPlayback,
    seekAbsolute,
    toggleCinemaFullscreen: controls.toggleCinemaFullscreen,
    toggleCinemaPictureInPicture: controls.toggleCinemaPictureInPicture,
    transcodeErrorMessage,
    isPlaying: controls.isPlaying,
    volume: controls.volume,
    isMuted: controls.isMuted,
    fillScreen: controls.fillScreen,
    isFullscreen: controls.isFullscreen,
    syncVideoMediaState: controls.syncVideoMediaState,
    togglePlayPause,
    setVolume: controls.setVolume,
    toggleMute: controls.toggleMute,
    toggleFillScreen: controls.toggleFillScreen,
    syncFullscreenState: controls.syncFullscreenState,
  };
}
