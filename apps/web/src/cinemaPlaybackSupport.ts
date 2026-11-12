import { computed, nextTick, ref, type Ref } from "vue";
import { describeRootOperationFailure } from "./rootDiscovery.ts";
import { readApiFailure } from "./apiFailure.ts";
import { createPlaybackProgressWriter, type ProgressSnapshot } from "./playbackProgressWriter.ts";
import type {
  BrowserPlayback,
  Movie,
  SubtitleTrackInfo,
  TrackInfo,
  TranscodeSession,
} from "./cinemaTypes.ts";

export type CinemaRootProps = { rootId?: string; rootGeneration?: number };

export const playbackRateOptions = [
  { value: 0.75, label: "0.75x" },
  { value: 1, label: "1x" },
  { value: 1.25, label: "1.25x" },
  { value: 1.5, label: "1.5x" },
  { value: 2, label: "2x" },
];

export function abortableDelay(ms: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) return Promise.reject(new Error("aborted"));
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timer);
      reject(new Error("aborted"));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

export function transcodeErrorMessage(e: unknown): string {
  const code = e instanceof Error ? e.message : "request_failed";
  switch (code) {
    case "transcode_unavailable":
      return "未安装 FFmpeg，仅支持直接播放或下载原片；管理员可在本机执行 brew install ffmpeg 启用在线转码。";
    case "transcode_busy":
      return "转码通道被占用，请稍后重试。";
    case "transcode_failed":
      return "转码失败：该影片可能包含不兼容的编码，请下载后用 IINA 或 VLC 播放。";
    case "transcode_insufficient_space":
      return "存储空间不足，无法创建转码缓存，请清理空间后重试。";
    case "direct_playback_available":
      return "该影片可直接播放，无需转码。";
    case "transcode_start_timeout":
      return "转码启动超时，请稍后重试；若反复出现请下载原片播放。";
    default:
      return describeRootOperationFailure(e);
  }
}

export function playbackMode(v: Movie): BrowserPlayback {
  return v.browserPlayback ?? (v.playable ? "unverified-direct" : "download-only");
}

function readRatePreference(): number {
  try {
    const rate = Number(window.localStorage.getItem("lightisle-cinema-playback-rate"));
    return [0.75, 1, 1.25, 1.5, 2].includes(rate) ? rate : 1;
  } catch {
    return 1;
  }
}

function readBoolPreference(key: string): boolean {
  try {
    return window.localStorage.getItem(key) === "yes";
  } catch {
    return false;
  }
}

function writeBoolPreference(key: string, checked: boolean) {
  try {
    if (checked) window.localStorage.setItem(key, "yes");
    else window.localStorage.removeItem(key);
  } catch {
    /* Private browsing must not prevent playing videos. */
  }
}

export function useCinemaMediaControls({
  player,
  hlsPlayer,
  activeVideo,
  playError,
}: {
  player: Ref<HTMLVideoElement | null>;
  hlsPlayer: Ref<HTMLVideoElement | null>;
  activeVideo: () => HTMLVideoElement | null;
  playError: Ref<string>;
}) {
  const isPlaying = ref(false);
  const volume = ref(1);
  const isMuted = ref(false);
  const fillScreen = ref(false);
  const isFullscreen = ref(false);
  const playbackRate = ref(readRatePreference());
  const autoplayNext = ref(readBoolPreference("lightisle-cinema-autoplay-next"));
  const preferLocalDecode = ref(readBoolPreference("lightisle-cinema-prefer-local-decode"));
  const directLocalOverride = ref(preferLocalDecode.value);
  const canPictureInPicture = typeof document !== "undefined" && document.pictureInPictureEnabled;
  let lastNonZeroVolume = 1;

  function applyPlaybackRate() {
    const p = activeVideo();
    if (p) p.playbackRate = playbackRate.value;
  }

  function setPlaybackRate(rate: number) {
    if (![0.75, 1, 1.25, 1.5, 2].includes(rate)) return;
    playbackRate.value = rate;
    applyPlaybackRate();
    try {
      window.localStorage.setItem("lightisle-cinema-playback-rate", String(rate));
    } catch {
      /* Private browsing or storage quota limits must not interrupt playback rate changes. */
    }
  }

  function setAutoplayNext(checked: boolean) {
    autoplayNext.value = checked;
    writeBoolPreference("lightisle-cinema-autoplay-next", checked);
  }

  function syncVideoMediaState() {
    const p = activeVideo();
    if (!p) return;
    isPlaying.value = !p.paused && !p.ended;
    isMuted.value = p.muted || p.volume === 0;
    volume.value = p.muted ? 0 : p.volume;
    if (p.volume > 0 && !p.muted) lastNonZeroVolume = p.volume;
  }

  function setVolume(next: number) {
    const clamped = Math.max(0, Math.min(1, Number.isFinite(next) ? next : 1));
    if (clamped > 0) lastNonZeroVolume = clamped;
    volume.value = clamped;
    isMuted.value = clamped === 0;
    for (const v of [player.value, hlsPlayer.value]) {
      if (!v) continue;
      v.muted = clamped === 0;
      if (clamped > 0) v.volume = clamped;
    }
  }

  function toggleMute() {
    if (isMuted.value || volume.value === 0) {
      setVolume(lastNonZeroVolume > 0 ? lastNonZeroVolume : 1);
    } else {
      setVolume(0);
    }
  }

  function toggleFillScreen() {
    fillScreen.value = !fillScreen.value;
  }

  function syncFullscreenState() {
    isFullscreen.value = Boolean(document.fullscreenElement);
  }

  async function toggleCinemaFullscreen(container?: HTMLElement | null) {
    const video = activeVideo() as (HTMLVideoElement & { webkitEnterFullscreen?: () => void }) | null;
    const target = container ?? video;
    if (!target) return;
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else if (typeof target.requestFullscreen === "function") await target.requestFullscreen();
      else if (video && typeof video.webkitEnterFullscreen === "function") video.webkitEnterFullscreen();
      isFullscreen.value = Boolean(document.fullscreenElement);
    } catch {
      if (video && typeof video.webkitEnterFullscreen === "function") {
        try {
          video.webkitEnterFullscreen();
          return;
        } catch {
          /* Fall through to surface user-facing fullscreen fallback guidance below. */
        }
      }
      playError.value = "当前浏览器不支持此播放模式，请尝试系统全屏快捷键。";
    }
  }

  async function toggleCinemaPictureInPicture() {
    const video = activeVideo();
    if (!video || !document.pictureInPictureEnabled) return;
    try {
      if (document.pictureInPictureElement) await document.exitPictureInPicture();
      else await video.requestPictureInPicture();
    } catch {
      playError.value = "当前设备无法开启画中画。";
    }
  }

  return {
    isPlaying,
    volume,
    isMuted,
    fillScreen,
    isFullscreen,
    playbackRate,
    autoplayNext,
    preferLocalDecode,
    directLocalOverride,
    canPictureInPicture,
    writeBoolPreference,
    applyPlaybackRate,
    setPlaybackRate,
    setAutoplayNext,
    syncVideoMediaState,
    setVolume,
    toggleMute,
    toggleFillScreen,
    syncFullscreenState,
    toggleCinemaFullscreen,
    toggleCinemaPictureInPicture,
  };
}

export function useCinemaProgressPersistence({
  selected,
  movies,
  props,
  filmScopeKey,
}: {
  selected: Ref<Movie | null>;
  movies: Ref<Movie[]>;
  props: CinemaRootProps;
  filmScopeKey: (filmId: number) => string;
}) {
  const progressSaveError = ref("");
  const failedProgressSnapshots = new Map<string, ProgressSnapshot>();

  function refreshProgressSaveError() {
    const rootId = props.rootId ?? "";
    const rootGeneration = props.rootGeneration ?? 0;
    let currentRootFailures = 0;
    let otherRootFailures = 0;
    for (const snapshot of failedProgressSnapshots.values()) {
      if (snapshot.rootId === rootId && snapshot.rootGeneration === rootGeneration) currentRootFailures += 1;
      else otherRootFailures += 1;
    }
    if (currentRootFailures && otherRootFailures) {
      progressSaveError.value = `当前播放进度尚未保存，另有 ${otherRootFailures} 项其他目录进度未保存；请点击重试。离开影院页面或刷新后仍未保存的进度将无法恢复。`;
    } else if (currentRootFailures) {
      progressSaveError.value = "播放进度尚未保存，网络恢复后请点击重试。离开影院页面或刷新后仍未保存的进度将无法恢复。";
    } else if (otherRootFailures) {
      progressSaveError.value = `另有 ${otherRootFailures} 项其他存储目录的播放进度尚未保存；可在当前影院页面点击重试。离开影院页面或刷新后仍未保存的进度将无法恢复。`;
    } else {
      progressSaveError.value = "";
    }
  }

  const progressWriter = createPlaybackProgressWriter(
    async (snapshot) => {
      const headers = new Headers({ "Content-Type": "application/json", "X-LightIsle-Request": "1" });
      if (snapshot.rootId) headers.set("X-LightIsle-Root-Generation", String(snapshot.rootGeneration));
      const response = await fetch(snapshot.url, {
        method: "PUT",
        credentials: "same-origin",
        cache: "no-store",
        keepalive: true,
        headers,
        body: JSON.stringify({
          position: snapshot.position,
          duration: snapshot.duration,
          completed: snapshot.completed,
        }),
      });
      if (!response.ok) throw await readApiFailure(response);
    },
    {
      onSaved: (snapshot: ProgressSnapshot) => {
        failedProgressSnapshots.delete(snapshot.key);
        refreshProgressSaveError();
        if (snapshot.rootId !== (props.rootId ?? "") || snapshot.rootGeneration !== (props.rootGeneration ?? 0)) {
          return;
        }
        movies.value = movies.value.map((item) =>
          item.id === snapshot.id
            ? { ...item, position: snapshot.position, duration: snapshot.duration, completed: snapshot.completed }
            : item,
        );
        if (selected.value?.id === snapshot.id) {
          selected.value.position = snapshot.position;
          selected.value.duration = snapshot.duration;
          selected.value.completed = snapshot.completed;
        }
      },
      onError: (_error: unknown, snapshot: ProgressSnapshot) => {
        failedProgressSnapshots.set(snapshot.key, snapshot);
        refreshProgressSaveError();
      },
    },
  );

  function retryProgress() {
    return progressWriter.retry();
  }

  function currentFilmProgressUnsaved() {
    const film = selected.value;
    if (!film) return false;
    return failedProgressSnapshots.has(filmScopeKey(film.id));
  }

  return {
    progressSaveError,
    refreshProgressSaveError,
    progressWriter,
    retryProgress,
    currentFilmProgressUnsaved,
  };
}

function captionLabel(v: SubtitleTrackInfo): string {
  const language =
    v.language === "chi" || v.language === "zh"
      ? "中文"
      : v.language === "eng" || v.language === "en"
        ? "英文"
        : v.language || "内嵌";
  return `内嵌 ${language}（${v.codec || "?"}，样式简化）`;
}

export function buildCinemaPlaybackOptions({
  selected,
  player,
  hlsPlayer,
  caption,
  hlsSession,
  hlsTracks,
  hlsStarting,
  hlsQuality,
  preferLocalDecode,
  directLocalOverride,
  mediaPath,
}: {
  selected: Ref<Movie | null>;
  player: Ref<HTMLVideoElement | null>;
  hlsPlayer: Ref<HTMLVideoElement | null>;
  caption: Ref<string>;
  hlsSession: Ref<TranscodeSession | null>;
  hlsTracks: Ref<TrackInfo | null>;
  hlsStarting: Ref<boolean>;
  hlsQuality: Ref<string>;
  preferLocalDecode: Ref<boolean>;
  directLocalOverride: Ref<boolean>;
  mediaPath: (path: string) => string;
}) {
  function canAttemptDirect(v: Movie) {
    return playbackMode(v) !== "download-only" || preferLocalDecode.value || directLocalOverride.value;
  }

  function stream(v: Movie) {
    const base = mediaPath(`/api/v2/cinema/${v.id}/stream`);
    const needDirect = playbackMode(v) === "download-only" || preferLocalDecode.value || directLocalOverride.value;
    return needDirect ? `${base}${base.includes("?") ? "&" : "?"}direct=1` : base;
  }

  function track(v: Movie) {
    if (caption.value.startsWith("emb:")) {
      return mediaPath(`/api/v2/cinema/${v.id}/embedded-subtitles?track=${caption.value.slice(4)}`);
    }
    return mediaPath(`/api/v2/cinema/${v.id}/subtitles${caption.value === "auto" ? "" : `?lang=${caption.value}`}`);
  }

  function download(v: Movie) {
    const a = document.createElement("a");
    a.href = mediaPath(`/api/v2/files/content?path=${encodeURIComponent(v.path)}`);
    a.download = v.path.split("/").pop() || v.title;
    a.click();
  }

  function qualityOptions(v: Movie) {
    const options = [
      { value: "source", label: "原画" },
      { value: "local", label: "本地硬解" },
    ];
    const sourceHeight = v.height || hlsTracks.value?.height || 0;
    for (const tier of [
      { value: "1080", label: "1080P", height: 1080 },
      { value: "720", label: "720P", height: 720 },
      { value: "480", label: "480P", height: 480 },
    ]) {
      if (sourceHeight > 0 && sourceHeight <= tier.height) break;
      options.push({ value: tier.value, label: tier.label });
    }
    return options;
  }

  const captionOptions = computed(() => {
    const opts = [
      { value: "off", label: "关闭" },
      { value: "auto", label: "同名字幕" },
      { value: "zh", label: "中文字幕" },
      { value: "en", label: "英文字幕" },
    ];
    for (const t of (hlsTracks.value?.subtitles ?? []).filter((s) => s.extractable)) {
      opts.push({ value: `emb:${t.streamIndex}`, label: captionLabel(t) });
    }
    return opts;
  });

  const audioTrackOptions = computed(() =>
    (hlsTracks.value?.audio ?? []).map((t) => ({
      value: t.audioIndex,
      label: `${t.title || t.language || `音轨 ${t.audioIndex + 1}`}${t.codec ? ` · ${t.codec}` : ""}${t.channels ? ` · ${t.channels}ch` : ""}`,
    })),
  );

  const currentQuality = computed(() => {
    if (hlsSession.value) return hlsSession.value.quality;
    if (hlsStarting.value) return hlsQuality.value;
    const film = selected.value;
    if (film && (directLocalOverride.value || preferLocalDecode.value) && playbackMode(film) === "download-only") {
      return "local";
    }
    return film ? (qualityOptions(film)[0]?.value ?? "source") : "source";
  });

  const cinemaQualityOptions = computed(() => {
    const film = selected.value;
    if (!film) return [];
    return qualityOptions(film).map((opt) => ({
      value: opt.value,
      label: `${opt.label}${opt.value === "source" && playbackMode(film) === "download-only" ? "（转封装）" : ""}`,
    }));
  });

  async function changeCaption() {
    await nextTick();
    for (const video of [player.value, hlsPlayer.value]) {
      if (!video) continue;
      for (const t of Array.from(video.textTracks)) t.mode = caption.value === "off" ? "disabled" : "showing";
    }
  }

  function captionSrclang() {
    if (caption.value.startsWith("emb:")) {
      const index = Number.parseInt(caption.value.slice(4), 10);
      const found = hlsTracks.value?.subtitles.find((t) => t.streamIndex === index);
      return found?.language || "zh";
    }
    return caption.value === "auto" ? "zh" : caption.value;
  }

  return {
    playback: playbackMode,
    canAttemptDirect,
    stream,
    track,
    download,
    captionOptions,
    audioTrackOptions,
    currentQuality,
    cinemaQualityOptions,
    changeCaption,
    captionSrclang,
  };
}

export function stopRemoteHlsSession(
  props: CinemaRootProps,
  apiPath: (path: string) => string,
  filmId: number,
  sessionId: string,
) {
  if (!filmId || !sessionId || typeof fetch !== "function") return;
  const headers = new Headers({ "X-LightIsle-Request": "1" });
  if (props.rootId) headers.set("X-LightIsle-Root-Generation", String(props.rootGeneration ?? 0));
  const url = apiPath(`/api/v2/cinema/${filmId}/hls/session?session=${encodeURIComponent(sessionId)}`);
  try {
    void Promise.resolve(
      fetch(url, { method: "DELETE", credentials: "same-origin", cache: "no-store", keepalive: true, headers }),
    ).catch(() => {
      /* Best-effort teardown when page or root closes; server reaps idle sessions. */
    });
  } catch {
    /* Ignore synchronous teardown URL/Abort errors during unmount. */
  }
}

export async function pollHlsPlaylistReady(
  mediaPath: (path: string) => string,
  v: Movie,
  session: TranscodeSession,
  isCurrent: () => boolean,
  signal?: AbortSignal,
): Promise<string> {
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
