<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import {
  Play,
  Pause,
  RotateCcw,
  RotateCw,
  Volume2,
  VolumeX,
  Maximize2,
  Minimize2,
  PictureInPicture2,
  ChevronLeft,
  ChevronRight,
  Loader2,
  Check,
} from "lucide-vue-next";

const props = withDefaults(
  defineProps<{
    src: string;
    title?: string;
    autoplay?: boolean;
    hasPrev?: boolean;
    hasNext?: boolean;
  }>(),
  {
    title: "",
    autoplay: true,
    hasPrev: false,
    hasNext: false,
  }
);

const emit = defineEmits<{
  (e: "ended"): void;
  (e: "prev"): void;
  (e: "next"): void;
  (e: "timeupdate", currentTime: number, duration: number): void;
}>();

const videoRef = ref<HTMLVideoElement | null>(null);
const containerRef = ref<HTMLElement | null>(null);

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

function formatClock(seconds: number): string {
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

const progressPercent = computed(() => {
  if (duration.value <= 0) return 0;
  return Math.min(100, Math.max(0, (currentTime.value / duration.value) * 100));
});

const bufferedPercent = computed(() => {
  if (duration.value <= 0) return 0;
  return Math.min(100, Math.max(0, (bufferedEnd.value / duration.value) * 100));
});

function wakeControls() {
  controlsVisible.value = true;
  if (hideTimer) {
    clearTimeout(hideTimer);
  }
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
  const ratio = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
  el.currentTime = ratio * duration.value;
  wakeControls();
}

function handleTrackHover(event: MouseEvent) {
  if (duration.value <= 0) return;
  const target = event.currentTarget as HTMLElement;
  const rect = target.getBoundingClientRect();
  const ratio = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
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

function handleVolumeChange(event: Event) {
  const el = videoRef.value;
  if (!el) return;
  const val = Number((event.target as HTMLInputElement).value);
  volume.value = val;
  el.volume = val;
  if (val > 0 && el.muted) {
    el.muted = false;
    isMuted.value = false;
  }
  wakeControls();
}

const playbackRateOptions = [0.5, 0.75, 1, 1.25, 1.5, 2];

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
    // Ignore PiP error
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
    // Fallback: Webkit fullscreen on iOS
    const el = videoRef.value as any;
    if (el?.webkitEnterFullscreen) {
      el.webkitEnterFullscreen();
    }
  }
}

// Media Event Handlers
function onLoadedMetadata() {
  const el = videoRef.value;
  if (!el) return;
  duration.value = el.duration;
  isLoading.value = false;
  if (props.autoplay) {
    void el.play().catch(() => {
      // Autoplay with sound might be blocked, retry muted
      el.muted = true;
      isMuted.value = true;
      void el.play().catch(() => {});
    });
  }
}

function onTimeUpdate() {
  const el = videoRef.value;
  if (!el) return;
  currentTime.value = el.currentTime;
  updateBuffered();
  emit("timeupdate", el.currentTime, el.duration);
}

function updateBuffered() {
  const el = videoRef.value;
  if (!el || el.buffered.length === 0) return;
  try {
    bufferedEnd.value = el.buffered.end(el.buffered.length - 1);
  } catch {
    // Ignore buffer range query exception
  }
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
  emit("ended");
}

function onError() {
  isLoading.value = false;
  hasError.value = true;
}

function handleKeydown(event: KeyboardEvent) {
  // Only handle shortcuts when viewer is in focus or container is fullscreen
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
    const el = videoRef.value;
    if (el) {
      const v = Math.min(1, el.volume + 0.1);
      volume.value = v;
      el.volume = v;
    }
  } else if (event.key === "ArrowDown") {
    event.preventDefault();
    const el = videoRef.value;
    if (el) {
      const v = Math.max(0, el.volume - 0.1);
      volume.value = v;
      el.volume = v;
    }
  } else if (event.key === "f" || event.key === "F") {
    event.preventDefault();
    void toggleFullscreen();
  } else if (event.key === "m" || event.key === "M") {
    event.preventDefault();
    toggleMute();
  }
}

watch(
  () => props.src,
  () => {
    currentTime.value = 0;
    bufferedEnd.value = 0;
    isLoading.value = true;
    hasError.value = false;
  }
);

onMounted(() => {
  window.addEventListener("keydown", handleKeydown);
  document.addEventListener("fullscreenchange", () => {
    isFullscreen.value = Boolean(document.fullscreenElement);
  });
});

onUnmounted(() => {
  window.removeEventListener("keydown", handleKeydown);
  if (hideTimer) clearTimeout(hideTimer);
});
</script>

<template>
  <div
    ref="containerRef"
    class="isle-video-player"
    :class="{
      'controls-hidden': !controlsVisible && isPlaying,
      'is-fullscreen': isFullscreen,
    }"
    tabindex="0"
    @mousemove="wakeControls"
    @pointerdown="wakeControls"
    @click.self="togglePlay"
  >
    <!-- Video Element -->
    <video
      ref="videoRef"
      :src="src"
      class="video-element"
      playsinline
      @loadedmetadata="onLoadedMetadata"
      @timeupdate="onTimeUpdate"
      @play="onPlay"
      @pause="onPause"
      @waiting="onWaiting"
      @canplay="onCanPlay"
      @progress="updateBuffered"
      @ended="onEnded"
      @error="onError"
      @click="togglePlay"
    />

    <!-- Big Center Indicator (when loading or paused) -->
    <div
      v-if="isLoading"
      class="player-center-status"
      aria-label="加载中"
    >
      <Loader2 :size="48" class="spin-icon" />
    </div>
    <div
      v-else-if="!isPlaying"
      class="player-center-status center-play-btn"
      title="播放 (空格)"
      @click="togglePlay"
    >
      <Play :size="40" fill="currentColor" />
    </div>

    <!-- Error Overlay -->
    <div v-if="hasError" class="player-error-overlay">
      <p>视频格式暂不可在浏览器直接播放，建议下载后使用本地播放器打开。</p>
    </div>

    <!-- Transport Controls Bar -->
    <div
      class="player-transport-bar"
      role="toolbar"
      aria-label="视频播放控制栏"
      @click.stop
    >
      <!-- Timeline Slider -->
      <div
        class="player-timeline"
        role="slider"
        :aria-valuenow="progressPercent"
        aria-valuemin="0"
        aria-valuemax="100"
        aria-label="播放进度"
        @click="seekTo"
        @mousemove="handleTrackHover"
        @mouseleave="handleTrackLeave"
      >
        <div class="timeline-rail">
          <div class="timeline-buffered" :style="{ width: `${bufferedPercent}%` }" />
          <div class="timeline-played" :style="{ width: `${progressPercent}%` }">
            <span class="timeline-thumb" />
          </div>
        </div>

        <!-- Hover Preview Tooltip -->
        <div
          v-if="hoverTime !== null"
          class="timeline-hover-time"
          :style="{ left: `${hoverPercent}%` }"
        >
          {{ formatClock(hoverTime) }}
        </div>
      </div>

      <!-- Controls Row -->
      <div class="player-controls-row">
        <div class="controls-left">
          <!-- Previous Video (if playlist) -->
          <button
            v-if="hasPrev"
            type="button"
            class="control-btn"
            title="上一部"
            @click="emit('prev')"
          >
            <ChevronLeft :size="20" />
          </button>

          <!-- Play / Pause -->
          <button
            type="button"
            class="control-btn play-btn"
            :title="isPlaying ? '暂停 (空格)' : '播放 (空格)'"
            @click="togglePlay"
          >
            <Pause v-if="isPlaying" :size="20" />
            <Play v-else :size="20" fill="currentColor" />
          </button>

          <!-- Next Video (if playlist) -->
          <button
            v-if="hasNext"
            type="button"
            class="control-btn"
            title="下一部"
            @click="emit('next')"
          >
            <ChevronRight :size="20" />
          </button>

          <!-- Jump -10s -->
          <button
            type="button"
            class="control-btn jump-btn"
            title="后退 10 秒 (←)"
            @click="jump(-10)"
          >
            <RotateCcw :size="17" />
            <span class="jump-text">10</span>
          </button>

          <!-- Jump +10s -->
          <button
            type="button"
            class="control-btn jump-btn"
            title="快进 10 秒 (→)"
            @click="jump(10)"
          >
            <RotateCw :size="17" />
            <span class="jump-text">10</span>
          </button>

          <!-- Volume -->
          <div class="volume-group">
            <button
              type="button"
              class="control-btn"
              :title="isMuted ? '取消静音 (M)' : '静音 (M)'"
              @click="toggleMute"
            >
              <VolumeX v-if="isMuted || volume === 0" :size="19" />
              <Volume2 v-else :size="19" />
            </button>
            <input
              type="range"
              min="0"
              max="1"
              step="0.05"
              :value="isMuted ? 0 : volume"
              class="volume-slider"
              aria-label="音量调节"
              @input="handleVolumeChange"
            />
          </div>

          <!-- Time Display -->
          <span class="time-readout">
            <span class="current-time">{{ formatClock(currentTime) }}</span>
            <span class="time-sep">/</span>
            <span class="total-time">{{ formatClock(duration) }}</span>
          </span>
        </div>

        <div class="controls-right">
          <!-- Playback Speed -->
          <div class="rate-menu-anchor">
            <button
              type="button"
              class="control-btn rate-btn"
              title="倍速播放"
              @click="showRateMenu = !showRateMenu"
            >
              {{ playbackRate === 1 ? "倍速" : `${playbackRate}x` }}
            </button>
            <div v-if="showRateMenu" class="rate-menu" role="menu">
              <button
                v-for="r in playbackRateOptions"
                :key="r"
                type="button"
                class="rate-menu-item"
                :class="{ active: playbackRate === r }"
                @click="setRate(r)"
              >
                <span>{{ r }}x</span>
                <Check v-if="playbackRate === r" :size="14" />
              </button>
            </div>
          </div>

          <!-- Picture in Picture -->
          <button
            type="button"
            class="control-btn"
            title="画中画模式"
            @click="togglePip"
          >
            <PictureInPicture2 :size="18" />
          </button>

          <!-- Fullscreen -->
          <button
            type="button"
            class="control-btn"
            :title="isFullscreen ? '退出全屏 (F)' : '全屏 (F)'"
            @click="toggleFullscreen"
          >
            <Minimize2 v-if="isFullscreen" :size="18" />
            <Maximize2 v-else :size="18" />
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.isle-video-player {
  position: relative;
  width: 100%;
  height: 100%;
  min-height: 380px;
  max-height: 82vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #000;
  border-radius: var(--radius-lg);
  overflow: hidden;
  user-select: none;
  -webkit-user-select: none;
  outline: none;
}

.isle-video-player.is-fullscreen {
  border-radius: 0;
  max-height: 100vh;
}

.video-element {
  width: 100%;
  height: 100%;
  max-height: 82vh;
  object-fit: contain;
  background: #000;
}

.isle-video-player.is-fullscreen .video-element {
  max-height: 100vh;
}

/* Center status / big play */
.player-center-status {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: 72px;
  height: 72px;
  border-radius: 50%;
  background: rgba(20, 20, 25, 0.7);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  backdrop-filter: blur(16px);
  -webkit-backdrop-filter: blur(16px);
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  pointer-events: none;
  transition: transform 0.15s ease, opacity 0.15s ease;
  z-index: 5;
}

.center-play-btn {
  pointer-events: auto;
  cursor: pointer;
}

.center-play-btn:hover {
  transform: translate(-50%, -50%) scale(1.08);
  background: rgba(35, 35, 45, 0.88);
}

.center-play-btn:active {
  transform: translate(-50%, -50%) scale(0.95);
}

.spin-icon {
  animation: spin 1s linear infinite;
  color: var(--accent-primary);
}

@keyframes spin {
  from {
    transform: rotate(0deg);
  }
  to {
    transform: rotate(360deg);
  }
}

.player-error-overlay {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.8);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 24px;
  color: #ff6b6b;
  text-align: center;
  font-size: 14px;
  z-index: 6;
}

/* Transport Bar */
.player-transport-bar {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 14px 18px 12px;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.88) 0%, rgba(0, 0, 0, 0.45) 70%, transparent 100%);
  display: flex;
  flex-direction: column;
  gap: 10px;
  transition: opacity 0.25s ease, transform 0.25s ease;
  z-index: 10;
}

.isle-video-player.controls-hidden .player-transport-bar {
  opacity: 0;
  transform: translateY(10px);
  pointer-events: none;
}

/* Timeline */
.player-timeline {
  position: relative;
  width: 100%;
  height: 20px;
  display: flex;
  align-items: center;
  cursor: pointer;
}

.timeline-rail {
  position: relative;
  width: 100%;
  height: 5px;
  border-radius: var(--radius-full);
  background: rgba(255, 255, 255, 0.25);
  overflow: visible;
  transition: height 0.15s ease;
}

.player-timeline:hover .timeline-rail {
  height: 7px;
}

.timeline-buffered {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  border-radius: inherit;
  background: rgba(255, 255, 255, 0.4);
  transition: width 0.2s ease;
}

.timeline-played {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  border-radius: inherit;
  background: var(--accent-primary, #6366f1);
  display: flex;
  align-items: center;
  justify-content: flex-end;
}

.timeline-thumb {
  width: 13px;
  height: 13px;
  border-radius: 50%;
  background: #fff;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.4);
  transform: scale(0);
  transition: transform 0.15s ease;
  margin-right: -6px;
}

.player-timeline:hover .timeline-thumb {
  transform: scale(1);
}

.timeline-hover-time {
  position: absolute;
  bottom: 24px;
  transform: translateX(-50%);
  padding: 3px 7px;
  border-radius: 6px;
  background: rgba(20, 20, 25, 0.9);
  color: #fff;
  font-size: 11px;
  font-family: ui-monospace, monospace;
  pointer-events: none;
  white-space: nowrap;
}

/* Controls row */
.player-controls-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.controls-left,
.controls-right {
  display: flex;
  align-items: center;
  gap: 8px;
}

.control-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 36px;
  height: 36px;
  border-radius: 50%;
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.88);
  cursor: pointer;
  transition: background-color 0.15s ease, color 0.15s ease, transform 0.1s ease;
}

.control-btn:hover {
  background: rgba(255, 255, 255, 0.16);
  color: #fff;
}

.control-btn:active {
  transform: scale(0.92);
}

.jump-btn {
  position: relative;
}

.jump-text {
  position: absolute;
  font-size: 9px;
  font-weight: 700;
  font-family: ui-monospace, monospace;
  margin-top: 1px;
}

/* Volume Slider */
.volume-group {
  display: flex;
  align-items: center;
  gap: 2px;
}

.volume-slider {
  width: 68px;
  height: 4px;
  accent-color: var(--accent-primary, #6366f1);
  cursor: pointer;
  opacity: 0.85;
  transition: opacity 0.15s ease, width 0.15s ease;
}

.volume-slider:hover {
  opacity: 1;
}

/* Time Readout */
.time-readout {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 12px;
  font-family: ui-monospace, SFMono-Regular, monospace;
  color: rgba(255, 255, 255, 0.85);
  margin-left: 6px;
}

.time-sep {
  opacity: 0.45;
}

/* Playback Speed Menu */
.rate-menu-anchor {
  position: relative;
}

.rate-btn {
  width: auto;
  padding: 0 10px;
  border-radius: var(--radius-full);
  font-size: 12px;
  font-weight: 600;
}

.rate-menu {
  position: absolute;
  bottom: 42px;
  right: 0;
  display: flex;
  flex-direction: column;
  background: rgba(24, 24, 30, 0.94);
  border: 1px solid rgba(255, 255, 255, 0.15);
  border-radius: 12px;
  padding: 4px;
  backdrop-filter: blur(18px);
  -webkit-backdrop-filter: blur(18px);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
  z-index: 20;
}

.rate-menu-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 6px 14px;
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.85);
  font-size: 12px;
  font-weight: 500;
  border-radius: 8px;
  cursor: pointer;
}

.rate-menu-item:hover {
  background: rgba(255, 255, 255, 0.12);
  color: #fff;
}

.rate-menu-item.active {
  color: var(--accent-primary, #818cf8);
  font-weight: 600;
}

@media (max-width: 640px) {
  .volume-slider {
    display: none;
  }
  .jump-btn {
    display: none;
  }
}
</style>
