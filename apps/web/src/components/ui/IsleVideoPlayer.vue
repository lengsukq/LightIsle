<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import {
  Check, ChevronLeft, ChevronRight, Loader2, Maximize2, Minimize2,
  Pause, PictureInPicture2, Play, RotateCcw, RotateCw, Volume2, VolumeX,
} from "lucide-vue-next";
import { formatVideoClock, playbackRateOptions, useHtmlVideoTransport } from "../../composables/useHtmlVideoTransport";

const props = withDefaults(
  defineProps<{
    src: string;
    title?: string;
    autoplay?: boolean;
    hasPrev?: boolean;
    hasNext?: boolean;
  }>(),
  { title: "", autoplay: true, hasPrev: false, hasNext: false },
);

const emit = defineEmits<{
  (e: "ended"): void;
  (e: "prev"): void;
  (e: "next"): void;
  (e: "timeupdate", currentTime: number, duration: number): void;
}>();

const videoRef = ref<HTMLVideoElement | null>(null);
const containerRef = ref<HTMLElement | null>(null);
const rateMenuAnchorRef = ref<HTMLElement | null>(null);

const pipSupported = computed(
  () => typeof document !== "undefined" && Boolean((document as Document & { pictureInPictureEnabled?: boolean }).pictureInPictureEnabled),
);

const {
  isPlaying, isLoading, hasError, currentTime, duration, volume, isMuted, isFullscreen,
  controlsVisible, playbackRate, showRateMenu, hoverTime, hoverPercent, progressPercent, bufferedPercent,
  wakeControls, togglePlay, jump, seekTo, handleTrackHover, handleTrackLeave, toggleMute,
  handleVolumeChange, setRate, togglePip, toggleFullscreen, updateBuffered, onLoadedMetadata,
  onTimeUpdate, onPlay, onPause, onWaiting, onCanPlay, onEnded, onError,
} = useHtmlVideoTransport({
  videoRef,
  containerRef,
  src: () => props.src,
  autoplay: () => props.autoplay,
  onEnded: () => emit("ended"),
  onTimeUpdate: (time, total) => emit("timeupdate", time, total),
});

const clampedHoverPercent = computed(() => Math.max(8, Math.min(92, hoverPercent.value)));
const volumePercent = computed(() => Math.round((isMuted.value ? 0 : volume.value) * 100));

function handleOutsidePointerDown(event: PointerEvent) {
  if (!showRateMenu.value) return;
  const target = event.target as Node | null;
  if (rateMenuAnchorRef.value && target && rateMenuAnchorRef.value.contains(target)) return;
  showRateMenu.value = false;
}

onMounted(() => window.addEventListener("pointerdown", handleOutsidePointerDown, true));
onUnmounted(() => window.removeEventListener("pointerdown", handleOutsidePointerDown, true));
</script>

<template>
  <div
    ref="containerRef"
    class="isle-video-player"
    :class="{ 'controls-hidden': !controlsVisible && isPlaying, 'is-fullscreen': isFullscreen }"
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

    <Transition name="isle-cue-pop">
      <div v-if="isLoading" class="player-center-status" aria-label="加载中">
        <Loader2 :size="36" class="spin-icon" />
      </div>
      <div v-else-if="!isPlaying" class="player-center-status center-play-btn" title="播放 (空格)" @click="togglePlay">
        <Play :size="30" fill="currentColor" />
      </div>
    </Transition>

    <div v-if="hasError" class="player-error-overlay">
      <p>视频格式暂不可在浏览器直接播放，建议下载后使用本地播放器打开。</p>
    </div>

    <div class="player-transport-bar" role="toolbar" aria-label="视频播放控制栏" @click.stop>
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
        <Transition name="isle-hover-pop">
          <div v-if="hoverTime !== null" class="timeline-hover-time" :style="{ left: `${clampedHoverPercent}%` }">
            {{ formatVideoClock(hoverTime) }}
          </div>
        </Transition>
      </div>

      <div class="player-controls-row">
        <div class="controls-left">
          <button v-if="hasPrev" type="button" class="control-btn" title="上一部" @click="emit('prev')">
            <ChevronLeft :size="18" />
          </button>
          <button type="button" class="control-btn play-btn" :title="isPlaying ? '暂停 (空格)' : '播放 (空格)'" @click="togglePlay">
            <Pause v-if="isPlaying" :size="18" />
            <Play v-else :size="18" fill="currentColor" />
          </button>
          <button v-if="hasNext" type="button" class="control-btn" title="下一部" @click="emit('next')">
            <ChevronRight :size="18" />
          </button>
          <button type="button" class="control-btn jump-btn" title="后退 10 秒 (←)" @click="jump(-10)">
            <RotateCcw :size="16" />
            <span class="jump-text">10</span>
          </button>
          <button type="button" class="control-btn jump-btn" title="快进 10 秒 (→)" @click="jump(10)">
            <RotateCw :size="16" />
            <span class="jump-text">10</span>
          </button>
          <div class="volume-group">
            <button type="button" class="control-btn" :title="isMuted ? '取消静音 (M)' : '静音 (M)'" @click="toggleMute">
              <VolumeX v-if="isMuted || volume === 0" :size="17" />
              <Volume2 v-else :size="17" />
            </button>
            <input
              type="range"
              min="0"
              max="1"
              step="0.05"
              :value="isMuted ? 0 : volume"
              :style="{ '--vol-pct': `${volumePercent}%` }"
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
          <div ref="rateMenuAnchorRef" class="rate-menu-anchor">
            <button type="button" class="control-btn rate-btn" title="倍速播放" :aria-expanded="showRateMenu" @click="showRateMenu = !showRateMenu">
              {{ playbackRate === 1 ? "倍速" : `${playbackRate}x` }}
            </button>
            <Transition name="isle-pop">
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
            </Transition>
          </div>
          <button v-if="pipSupported" type="button" class="control-btn pip-btn" title="画中画模式" @click="togglePip">
            <PictureInPicture2 :size="17" />
          </button>
          <button type="button" class="control-btn" :title="isFullscreen ? '退出全屏 (F)' : '全屏 (F)'" @click="toggleFullscreen">
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
.isle-video-player.is-fullscreen { border-radius: 0; max-height: 100vh; }
.video-element { width: 100%; height: 100%; max-height: 82vh; object-fit: contain; background: #000; }
.isle-video-player.is-fullscreen .video-element { max-height: 100vh; }
.player-center-status {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: 60px;
  height: 60px;
  border-radius: 50%;
  background: rgba(16, 17, 20, 0.78);
  border: 1px solid rgba(255, 255, 255, 0.22);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  backdrop-filter: blur(16px) saturate(145%);
  -webkit-backdrop-filter: blur(16px) saturate(145%);
  box-shadow: 0 10px 28px rgba(0, 0, 0, 0.48);
  pointer-events: none;
  transition: transform 0.16s var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)), background-color 0.16s ease, opacity 0.15s ease;
  z-index: 5;
}
.center-play-btn { pointer-events: auto; cursor: pointer; }
.center-play-btn:hover {
  transform: translate(-50%, -50%) scale(1.06);
  background: color-mix(in srgb, var(--accent-primary-solid, #1a8e9a) 84%, #0c0e12);
  border-color: rgba(103, 212, 224, 0.56);
}
.center-play-btn:active { transform: translate(-50%, -50%) scale(0.95); }
.spin-icon { animation: spin 1s linear infinite; color: var(--accent-primary, #67d4e0); }
@keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
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
  padding: 12px 14px 10px;
  background: linear-gradient(to top, rgba(12, 13, 16, 0.9) 0%, rgba(16, 17, 20, 0.54) 70%, transparent 100%);
  display: flex;
  flex-direction: column;
  gap: 7px;
  transition: opacity 0.22s ease, transform 0.22s ease;
  z-index: 10;
}
.isle-video-player.controls-hidden .player-transport-bar { opacity: 0; transform: translateY(8px); pointer-events: none; }
.player-timeline { position: relative; width: 100%; height: 18px; display: flex; align-items: center; cursor: pointer; }
.timeline-rail {
  position: relative;
  width: 100%;
  height: 4px;
  border-radius: var(--radius-full, 9999px);
  background: rgba(255, 255, 255, 0.22);
  overflow: visible;
  transition: height 0.15s ease;
}
.player-timeline:hover .timeline-rail { height: 6px; }
.timeline-buffered {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  border-radius: inherit;
  background: rgba(255, 255, 255, 0.36);
  transition: width 0.2s ease;
}
.timeline-played {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  border-radius: inherit;
  background: linear-gradient(90deg, var(--accent-primary, #0e6b74) 0%, color-mix(in srgb, var(--accent-primary, #67d4e0) 62%, #f4b942) 100%);
  display: flex;
  align-items: center;
  justify-content: flex-end;
}
.timeline-thumb {
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: #fffdf9;
  box-shadow: 0 0 0 2px rgba(244, 185, 66, 0.36), 0 1px 6px rgba(0, 0, 0, 0.52);
  transform: scale(0);
  transition: transform 0.15s ease;
  margin-right: -6px;
}
.player-timeline:hover .timeline-thumb { transform: scale(1); }
.timeline-hover-time {
  position: absolute;
  bottom: 22px;
  transform: translateX(-50%);
  padding: 2px 7px;
  border-radius: 6px;
  background: rgba(16, 17, 20, 0.94);
  border: 1px solid rgba(255, 255, 255, 0.16);
  color: #fff;
  font-size: 11px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  pointer-events: none;
  white-space: nowrap;
}
.player-controls-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: nowrap; }
.controls-left, .controls-right { display: flex; align-items: center; gap: 5px; min-width: 0; }
.controls-right { margin-left: auto; flex-shrink: 0; }
.control-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  white-space: nowrap;
  width: 31px;
  height: 31px;
  border-radius: 50%;
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.9);
  cursor: pointer;
  transition: background-color 0.15s ease, color 0.15s ease, transform 0.1s ease;
}
.control-btn:hover { background: rgba(255, 255, 255, 0.16); color: #fff; }
.control-btn:active { transform: scale(0.92); }
.jump-btn { position: relative; }
.jump-text { position: absolute; font-size: 8.5px; font-weight: 700; font-variant-numeric: tabular-nums; margin-top: 1px; }
.volume-group { display: flex; align-items: center; gap: 3px; }
.volume-slider {
  -webkit-appearance: none;
  appearance: none;
  width: 58px;
  height: 3px;
  border-radius: 999px;
  background: linear-gradient(90deg, var(--accent-primary, #67d4e0) 0%, #fff var(--vol-pct, 100%), rgba(255, 255, 255, 0.24) var(--vol-pct, 100%), rgba(255, 255, 255, 0.24) 100%);
  outline: none;
  cursor: pointer;
  opacity: 0.9;
  transition: opacity 0.15s ease;
}
.volume-slider::-webkit-slider-thumb { -webkit-appearance: none; appearance: none; width: 10px; height: 10px; border-radius: 50%; background: #fff; cursor: pointer; }
.volume-slider::-moz-range-thumb { width: 10px; height: 10px; border: 0; border-radius: 50%; background: #fff; cursor: pointer; }
.volume-slider:hover { opacity: 1; }
.time-readout {
  display: inline-flex;
  align-items: center;
  flex-shrink: 0;
  white-space: nowrap;
  gap: 4px;
  font-size: 11.5px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  color: rgba(255, 255, 255, 0.88);
  margin-left: 4px;
}
.time-sep { opacity: 0.45; }
.rate-menu-anchor { position: relative; }
.rate-btn { width: auto; flex-shrink: 0; white-space: nowrap; padding: 0 10px; border-radius: var(--radius-full, 9999px); font-size: 11.5px; font-weight: 600; font-variant-numeric: tabular-nums; }
.rate-menu {
  position: absolute;
  bottom: 38px;
  right: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
  background: rgba(18, 19, 22, 0.94);
  border: 1px solid rgba(255, 255, 255, 0.16);
  border-radius: 12px;
  padding: 5px;
  backdrop-filter: blur(22px) saturate(155%);
  -webkit-backdrop-filter: blur(22px) saturate(155%);
  box-shadow: 0 14px 32px rgba(0, 0, 0, 0.56);
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
  font-variant-numeric: tabular-nums;
  border-radius: 8px;
  cursor: pointer;
}
.rate-menu-item:hover { background: rgba(255, 255, 255, 0.12); color: #fff; }
.rate-menu-item.active { color: var(--accent-primary, #67d4e0); background: color-mix(in srgb, var(--accent-primary, #67d4e0) 14%, transparent); font-weight: 600; }
.isle-pop-enter-active,.isle-cue-pop-enter-active,.isle-hover-pop-enter-active {
  transition: opacity 0.16s cubic-bezier(0.22, 1, 0.36, 1), transform 0.2s var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1));
}
.isle-pop-leave-active,.isle-cue-pop-leave-active,.isle-hover-pop-leave-active { transition: opacity 0.12s ease, transform 0.12s ease; }
.isle-pop-enter-from,.isle-pop-leave-to { opacity: 0; transform: translate3d(0, 5px, 0) scale(0.95); }
.isle-cue-pop-enter-from,.isle-cue-pop-leave-to { opacity: 0; transform: translate(-50%, -50%) scale(0.92); }
.isle-hover-pop-enter-from,.isle-hover-pop-leave-to { opacity: 0; transform: translateX(-50%) translateY(4px) scale(0.95); }
@media (max-width: 780px), (max-height: 540px) { .isle-video-player { min-height: 180px; } }
@media (max-width: 640px) { .volume-slider, .jump-btn { display: none; } }
@media (max-width: 520px) {
  .player-transport-bar { padding: 8px 10px 8px; gap: 5px; }
  .player-controls-row { flex-wrap: wrap; gap: 6px; }
  .controls-left, .controls-right { gap: 3px; }
  .control-btn { width: 30px; height: 30px; }
  .rate-btn { width: auto; padding: 0 8px; font-size: 11px; }
  .time-readout { font-size: 11px; margin-left: 2px; }
}
@media (prefers-reduced-motion: reduce) {
  .player-center-status,.player-transport-bar,.timeline-rail,.timeline-buffered,.timeline-thumb,.control-btn,.volume-slider,.isle-pop-enter-active,.isle-pop-leave-active,.isle-cue-pop-enter-active,.isle-cue-pop-leave-active,.isle-hover-pop-enter-active,.isle-hover-pop-leave-active { transition: none; }
  .spin-icon { animation: none; }
}
</style>
