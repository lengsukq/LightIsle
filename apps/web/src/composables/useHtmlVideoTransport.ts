import { computed, onMounted, onUnmounted, ref, watch, type Ref } from "vue";

export const playbackRateOptions = [0.5, 0.75, 1, 1.25, 1.5, 2] as const;

export function formatVideoClock(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const sec = Math.floor(seconds % 60);
  const min = Math.floor((seconds / 60) % 60);
  const hr = Math.floor(seconds / 3600);
  const pad = (n: number) => String(n).padStart(2, "0");
  if (hr > 0) {
    return `${hr}:${pad(min)}:${pad(sec)}`;
  }
  return `${pad(min)}:${pad(sec)}`;
}

export function clampUnitRatio(clientX: number, rectLeft: number, rectWidth: number): number {
  if (!Number.isFinite(rectWidth) || rectWidth <= 0) return 0;
  return Math.max(0, Math.min(1, (clientX - rectLeft) / rectWidth));
}

export interface UseHtmlVideoTransportOptions {
  videoRef: Ref<HTMLVideoElement | null>;
  containerRef: Ref<HTMLElement | null>;
  src: () => string;
  autoplay: () => boolean;
  onEnded: () => void;
  onTimeUpdate: (currentTime: number, duration: number) => void;
}

export function useHtmlVideoTransport(options: UseHtmlVideoTransportOptions) {
  const { videoRef, containerRef } = options;

  const isPlaying = ref(false);
  const isLoading = ref(true);
  const hasError = ref(false);
  const currentTime = ref(0);
  const duration = ref(0);
  const bufferedEnd = ref(0);
  const volume = ref(1);
  const isMuted = ref(false);
  const isFullscreen = ref(false);
  const controlsVisible = ref(true);
  const playbackRate = ref(1);
  const showRateMenu = ref(false);
  const hoverTime = ref<number | null>(null);
  const hoverPercent = ref(0);

  let hideTimer: number | undefined;

  const progressPercent = computed(() => {
    if (duration.value <= 0) return 0;
    return Math.min(100, Math.max(0, (currentTime.value / duration.value) * 100));
  });

  const bufferedPercent = computed(() => {
    if (duration.value <= 0) return 0;
    return Math.min(100, Math.max(0, (bufferedEnd.value / duration.value) * 100));
  });

  function clearHideTimer() {
    if (hideTimer !== undefined) {
      window.clearTimeout(hideTimer);
      hideTimer = undefined;
    }
  }

  function wakeControls() {
    controlsVisible.value = true;
    clearHideTimer();
    if (isPlaying.value) {
      hideTimer = window.setTimeout(() => {
        controlsVisible.value = false;
        showRateMenu.value = false;
      }, 2800);
    }
  }

  function togglePlay() {
    const el = videoRef.value;
    if (!el) return;
    if (el.paused) {
      void el.play();
    } else {
      el.pause();
    }
  }

  function jump(seconds: number) {
    const el = videoRef.value;
    if (!el) return;
    el.currentTime = Math.max(0, Math.min(duration.value, el.currentTime + seconds));
    wakeControls();
  }

  function seekTo(event: MouseEvent) {
    const el = videoRef.value;
    if (!el || duration.value <= 0) return;
    const target = event.currentTarget as HTMLElement;
    const rect = target.getBoundingClientRect();
    el.currentTime = clampUnitRatio(event.clientX, rect.left, rect.width) * duration.value;
    wakeControls();
  }

  function handleTrackHover(event: MouseEvent) {
    if (duration.value <= 0) return;
    const target = event.currentTarget as HTMLElement;
    const rect = target.getBoundingClientRect();
    const ratio = clampUnitRatio(event.clientX, rect.left, rect.width);
    hoverPercent.value = ratio * 100;
    hoverTime.value = ratio * duration.value;
  }

  function handleTrackLeave() {
    hoverTime.value = null;
  }

  function toggleMute() {
    const el = videoRef.value;
    if (!el) return;
    el.muted = !el.muted;
    isMuted.value = el.muted;
    wakeControls();
  }

  function setClampedVolume(nextVolume: number) {
    const el = videoRef.value;
    if (!el) return;
    const clamped = Math.max(0, Math.min(1, nextVolume));
    volume.value = clamped;
    el.volume = clamped;
    if (clamped > 0 && el.muted) {
      el.muted = false;
      isMuted.value = false;
    }
  }

  function handleVolumeChange(event: Event) {
    setClampedVolume(Number((event.target as HTMLInputElement).value));
    wakeControls();
  }

  function setRate(rate: number) {
    const el = videoRef.value;
    if (!el) return;
    playbackRate.value = rate;
    el.playbackRate = rate;
    showRateMenu.value = false;
    wakeControls();
  }

  async function togglePip() {
    const el = videoRef.value;
    if (!el) return;
    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture();
      } else if (document.pictureInPictureEnabled) {
        await el.requestPictureInPicture();
      }
    } catch {
      // Browser Picture-in-Picture rejection is non-fatal.
    }
  }

  async function toggleFullscreen() {
    const container = containerRef.value;
    if (!container) return;
    try {
      if (!document.fullscreenElement) {
        await container.requestFullscreen();
        isFullscreen.value = true;
      } else {
        await document.exitFullscreen();
        isFullscreen.value = false;
      }
    } catch {
      const el = videoRef.value as (HTMLVideoElement & { webkitEnterFullscreen?: () => void }) | null;
      el?.webkitEnterFullscreen?.();
    }
  }

  function updateBuffered() {
    const el = videoRef.value;
    if (!el || el.buffered.length === 0) return;
    try {
      bufferedEnd.value = el.buffered.end(el.buffered.length - 1);
    } catch {
      // Buffered TimeRanges can transiently shift during stream seek.
    }
  }

  function onLoadedMetadata() {
    const el = videoRef.value;
    if (!el) return;
    duration.value = el.duration;
    isLoading.value = false;
    if (options.autoplay()) {
      void el.play().catch(() => {
        el.muted = true;
        isMuted.value = true;
        void el.play().catch(() => {
          // User gesture will be required if muted autoplay is also blocked.
        });
      });
    }
  }

  function onTimeUpdate() {
    const el = videoRef.value;
    if (!el) return;
    currentTime.value = el.currentTime;
    updateBuffered();
    options.onTimeUpdate(el.currentTime, el.duration);
  }

  function onPlay() {
    isPlaying.value = true;
    isLoading.value = false;
    wakeControls();
  }

  function onPause() {
    isPlaying.value = false;
    wakeControls();
  }

  function onWaiting() {
    isLoading.value = true;
  }

  function onCanPlay() {
    isLoading.value = false;
  }

  function onEnded() {
    isPlaying.value = false;
    wakeControls();
    options.onEnded();
  }

  function onError() {
    isLoading.value = false;
    hasError.value = true;
  }

  function handleKeydown(event: KeyboardEvent) {
    const active = document.activeElement;
    if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA")) return;

    if (event.key === " " || event.code === "Space") {
      event.preventDefault();
      togglePlay();
    } else if (event.key === "ArrowLeft") {
      event.preventDefault();
      jump(event.shiftKey ? -10 : -5);
    } else if (event.key === "ArrowRight") {
      event.preventDefault();
      jump(event.shiftKey ? 10 : 5);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      if (videoRef.value) setClampedVolume(videoRef.value.volume + 0.1);
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      if (videoRef.value) setClampedVolume(videoRef.value.volume - 0.1);
    } else if (event.key === "f" || event.key === "F") {
      event.preventDefault();
      void toggleFullscreen();
    } else if (event.key === "m" || event.key === "M") {
      event.preventDefault();
      toggleMute();
    }
  }

  function handleFullscreenChange() {
    isFullscreen.value = Boolean(document.fullscreenElement);
  }

  watch(options.src, () => {
    currentTime.value = 0;
    bufferedEnd.value = 0;
    isLoading.value = true;
    hasError.value = false;
  });

  onMounted(() => {
    window.addEventListener("keydown", handleKeydown);
    document.addEventListener("fullscreenchange", handleFullscreenChange);
  });

  onUnmounted(() => {
    window.removeEventListener("keydown", handleKeydown);
    document.removeEventListener("fullscreenchange", handleFullscreenChange);
    clearHideTimer();
  });

  return {
    isPlaying,
    isLoading,
    hasError,
    currentTime,
    duration,
    volume,
    isMuted,
    isFullscreen,
    controlsVisible,
    playbackRate,
    showRateMenu,
    hoverTime,
    hoverPercent,
    progressPercent,
    bufferedPercent,
    wakeControls,
    togglePlay,
    jump,
    seekTo,
    handleTrackHover,
    handleTrackLeave,
    toggleMute,
    handleVolumeChange,
    setRate,
    togglePip,
    toggleFullscreen,
    updateBuffered,
    onLoadedMetadata,
    onTimeUpdate,
    onPlay,
    onPause,
    onWaiting,
    onCanPlay,
    onEnded,
    onError,
  };
}
