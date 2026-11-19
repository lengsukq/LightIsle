<script setup lang="ts">
import { ref } from "vue";
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
import {
  playbackRateOptions,
  formatVideoClock,
  useHtmlVideoTransport,
} from "./composables/useHtmlVideoTransport";

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

const {
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
} = useHtmlVideoTransport({
  videoRef,
  containerRef,
  src: () => props.src,
  autoplay: () => props.autoplay,
  onEnded: () => emit("ended"),
  onTimeUpdate: (time, total) => emit("timeupdate", time, total),
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

    <div
      v-if="isLoading"
      class="player-center-status"
      aria-label="加载中"
    >
      <Loader2 :size="36" class="spin-icon" />
    </div>
    <div
      v-else-if="!isPlaying"
      class="player-center-status center-play-btn"
      title="播放 (空格)"
      @click="togglePlay"
    >
      <Play :size="30" fill="currentColor" />
    </div>

    <div v-if="hasError" class="player-error-overlay">
      <p>视频格式暂不可在浏览器直接播放，建议下载后使用本地播放器打开。</p>
    </div>

    <div
      class="player-transport-bar"
      role="toolbar"
      aria-label="视频播放控制栏"
      @click.stop
    >
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

        <div
          v-if="hoverTime !== null"
          class="timeline-hover-time"
          :style="{ left: `${hoverPercent}%` }"
        >
          {{ formatVideoClock(hoverTime) }}
        </div>
      </div>

      <div class="player-controls-row">
        <div class="controls-left">
          <button
            v-if="hasPrev"
            type="button"
            class="control-btn"
            title="上一部"
            @click="emit('prev')"
          >
            <ChevronLeft :size="18" />
          </button>

          <button
            type="button"
            class="control-btn play-btn"
            :title="isPlaying ? '暂停 (空格)' : '播放 (空格)'"
            @click="togglePlay"
          >
            <Pause v-if="isPlaying" :size="18" />
            <Play v-else :size="18" fill="currentColor" />
          </button>

          <button
            v-if="hasNext"
            type="button"
            class="control-btn"
            title="下一部"
            @click="emit('next')"
          >
            <ChevronRight :size="18" />
          </button>

          <button
            type="button"
            class="control-btn jump-btn"
            title="后退 10 秒 (←)"
            @click="jump(-10)"
          >
            <RotateCcw :size="16" />
            <span class="jump-text">10</span>
          </button>

          <button
            type="button"
            class="control-btn jump-btn"
            title="快进 10 秒 (→)"
            @click="jump(10)"
          >
            <RotateCw :size="16" />
            <span class="jump-text">10</span>
          </button>

          <div class="volume-group">
            <button
              type="button"
              class="control-btn"
              :title="isMuted ? '取消静音 (M)' : '静音 (M)'"
              @click="toggleMute"
            >
              <VolumeX v-if="isMuted || volume === 0" :size="17" />
              <Volume2 v-else :size="17" />
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

          <span class="time-readout">
            <span class="current-time">{{ formatVideoClock(currentTime) }}</span>
            <span class="time-sep">/</span>
            <span class="total-time">{{ formatVideoClock(duration) }}</span>
          </span>
        </div>

        <div class="controls-right">
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
                <Check v-if="playbackRate === r" :size="13" />
              </button>
            </div>
          </div>

          <button
            type="button"
            class="control-btn"
            title="画中画模式"
            @click="togglePip"
          >
            <PictureInPicture2 :size="17" />
          </button>

          <button
            type="button"
            class="control-btn"
            :title="isFullscreen ? '退出全屏 (F)' : '全屏 (F)'"
            @click="toggleFullscreen"
          >
            <Minimize2 v-if="isFullscreen" :size="17" />
            <Maximize2 v-else :size="17" />
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
  min-height: 340px;
  max-height: 82vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #000;
  border-radius: 14px;
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

.player-center-status {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: 60px;
  height: 60px;
  border-radius: 50%;
  background: rgba(18, 22, 30, 0.72);
  border: 1px solid rgba(255, 255, 255, 0.2);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  backdrop-filter: blur(14px);
  -webkit-backdrop-filter: blur(14px);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45);
  pointer-events: none;
  transition: transform 0.15s ease, opacity 0.15s ease;
  z-index: 5;
}

.center-play-btn {
  pointer-events: auto;
  cursor: pointer;
}

.center-play-btn:hover {
  transform: translate(-50%, -50%) scale(1.06);
  background: rgba(30, 36, 48, 0.88);
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
  padding: 20px;
  color: #f87171;
  text-align: center;
  font-size: 13px;
  z-index: 6;
}

.player-transport-bar {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 10px 14px 9px;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.86) 0%, rgba(0, 0, 0, 0.42) 70%, transparent 100%);
  display: flex;
  flex-direction: column;
  gap: 7px;
  transition: opacity 0.22s ease, transform 0.22s ease;
  z-index: 10;
}

.isle-video-player.controls-hidden .player-transport-bar {
  opacity: 0;
  transform: translateY(8px);
  pointer-events: none;
}

.player-timeline {
  position: relative;
  width: 100%;
  height: 18px;
  display: flex;
  align-items: center;
  cursor: pointer;
}

.timeline-rail {
  position: relative;
  width: 100%;
  height: 4px;
  border-radius: var(--radius-full, 9999px);
  background: rgba(255, 255, 255, 0.25);
  overflow: visible;
  transition: height 0.15s ease;
}

.player-timeline:hover .timeline-rail {
  height: 6px;
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
  background: var(--accent-primary, #3b82f6);
  display: flex;
  align-items: center;
  justify-content: flex-end;
}

.timeline-thumb {
  width: 12px;
  height: 12px;
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
  bottom: 22px;
  transform: translateX(-50%);
  padding: 2px 6px;
  border-radius: 5px;
  background: rgba(18, 22, 30, 0.92);
  color: #fff;
  font-size: 11px;
  font-family: ui-monospace, monospace;
  pointer-events: none;
  white-space: nowrap;
}

.player-controls-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}

.controls-left,
.controls-right {
  display: flex;
  align-items: center;
  gap: 6px;
}

.control-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 32px;
  height: 32px;
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
  font-size: 8.5px;
  font-weight: 700;
  font-family: ui-monospace, monospace;
  margin-top: 1px;
}

.volume-group {
  display: flex;
  align-items: center;
  gap: 2px;
}

.volume-slider {
  width: 64px;
  height: 4px;
  accent-color: var(--accent-primary, #3b82f6);
  cursor: pointer;
  opacity: 0.85;
  transition: opacity 0.15s ease, width 0.15s ease;
}

.volume-slider:hover {
  opacity: 1;
}

.time-readout {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 11.5px;
  font-family: ui-monospace, SFMono-Regular, monospace;
  color: rgba(255, 255, 255, 0.85);
  margin-left: 4px;
}

.time-sep {
  opacity: 0.45;
}

.rate-menu-anchor {
  position: relative;
}

.rate-btn {
  width: auto;
  padding: 0 9px;
  border-radius: var(--radius-full, 9999px);
  font-size: 11.5px;
  font-weight: 600;
}

.rate-menu {
  position: absolute;
  bottom: 38px;
  right: 0;
  display: flex;
  flex-direction: column;
  background: rgba(20, 24, 34, 0.95);
  border: 1px solid rgba(255, 255, 255, 0.16);
  border-radius: 10px;
  padding: 4px;
  backdrop-filter: blur(18px);
  -webkit-backdrop-filter: blur(18px);
  box-shadow: 0 8px 22px rgba(0, 0, 0, 0.42);
  z-index: 20;
}

.rate-menu-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 5px 12px;
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.86);
  font-size: 12px;
  font-weight: 500;
  border-radius: 7px;
  cursor: pointer;
}

.rate-menu-item:hover {
  background: rgba(255, 255, 255, 0.12);
  color: #fff;
}

.rate-menu-item.active {
  color: var(--accent-primary, #60a5fa);
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

@media (prefers-reduced-motion: reduce) {
  .player-center-status,
  .player-transport-bar,
  .timeline-rail,
  .timeline-buffered,
  .timeline-thumb,
  .control-btn,
  .volume-slider {
    transition: none;
  }
  .spin-icon {
    animation: none;
  }
}
</style>
