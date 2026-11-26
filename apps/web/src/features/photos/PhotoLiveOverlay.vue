<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from "vue";
import { Volume2, VolumeX } from "lucide-vue-next";

const props = defineProps<{
  liveVideoSrc: string;
}>();

const playing = ref(false);
const videoReady = ref(false);
const muted = ref(false);
const videoRef = ref<HTMLVideoElement | null>(null);
let fadeOutTimer: number | undefined;

function clearFadeTimer() {
  if (fadeOutTimer !== undefined) {
    window.clearTimeout(fadeOutTimer);
    fadeOutTimer = undefined;
  }
}

watch(
  () => props.liveVideoSrc,
  () => {
    stopLive(true);
  },
);

function toggleLive() {
  if (playing.value) {
    stopLive();
  } else {
    startLive();
  }
}

function startLive() {
  clearFadeTimer();
  videoReady.value = false;
  playing.value = true;
  requestAnimationFrame(() => {
    const el = videoRef.value;
    if (!el) return;
    el.currentTime = 0;
    el.muted = muted.value;
    void el.play().catch(() => {
      // Fallback to muted playback if browser autoplay policy blocks audio.
      muted.value = true;
      el.muted = true;
      void el.play().catch(() => {
        playing.value = false;
        videoReady.value = false;
      });
    });
  });
}

function onVideoReady() {
  if (playing.value) {
    videoReady.value = true;
  }
}

function onVideoEnded() {
  videoReady.value = false;
  clearFadeTimer();
  fadeOutTimer = window.setTimeout(() => {
    fadeOutTimer = undefined;
    playing.value = false;
  }, 240);
}

function stopLive(immediate = false) {
  clearFadeTimer();
  videoReady.value = false;
  const finish = () => {
    playing.value = false;
    const el = videoRef.value;
    if (el) {
      el.pause();
      try {
        el.currentTime = 0;
      } catch {
        /* Ignore seek reset before metadata loads */
      }
    }
  };
  if (immediate) {
    finish();
  } else {
    fadeOutTimer = window.setTimeout(() => {
      fadeOutTimer = undefined;
      finish();
    }, 200);
  }
}

function toggleMute() {
  muted.value = !muted.value;
  if (videoRef.value) {
    videoRef.value.muted = muted.value;
  }
}

onBeforeUnmount(() => {
  clearFadeTimer();
});
</script>

<template>
  <div class="live-photo-layer" @dblclick.stop @pointerdown.stop>
    <video
      v-if="playing"
      ref="videoRef"
      :src="liveVideoSrc"
      class="live-photo-video"
      :class="{ 'is-ready': videoReady }"
      playsinline
      preload="auto"
      @loadeddata="onVideoReady"
      @playing="onVideoReady"
      @ended="onVideoEnded"
      @error="stopLive(true)"
    />
    <div class="live-photo-controls">
      <button
        type="button"
        class="live-pill-btn"
        :class="{ 'is-playing': playing }"
        :title="playing ? '停止实况播放' : '播放实况动态照片'"
        @click.stop="toggleLive"
      >
        <span class="live-ring-dot" />
        <span>LIVE</span>
      </button>
      <button
        v-if="playing"
        type="button"
        class="live-mute-btn"
        :title="muted ? '开启实况声音' : '静音'"
        @click.stop="toggleMute"
      >
        <VolumeX v-if="muted" :size="13" />
        <Volume2 v-else :size="13" />
      </button>
    </div>
  </div>
</template>

<style scoped>
.live-photo-layer {
  position: absolute;
  inset: 0;
  pointer-events: none;
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 4;
}
.live-photo-video {
  max-width: 100%;
  max-height: 100%;
  width: 100%;
  height: 100%;
  object-fit: contain;
  background: transparent;
  opacity: 0;
  pointer-events: auto;
  transition: opacity 0.26s cubic-bezier(0.22, 1, 0.36, 1);
}
.live-photo-video.is-ready {
  opacity: 1;
}
.live-photo-controls {
  position: absolute;
  top: var(--viewer-live-top, 14px);
  left: max(16px, env(safe-area-inset-left));
  display: inline-flex;
  align-items: center;
  gap: 6px;
  pointer-events: auto;
  z-index: 5;
}
.live-pill-btn,
.live-mute-btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 5px 11px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.24);
  background: rgba(18, 18, 22, 0.72);
  color: #fff;
  font-size: 11.5px;
  font-weight: 700;
  letter-spacing: 0.5px;
  backdrop-filter: blur(16px) saturate(160%);
  -webkit-backdrop-filter: blur(16px) saturate(160%);
  cursor: pointer;
  transition: transform 0.15s var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)), opacity 0.15s ease, background-color 0.15s ease;
}
.live-pill-btn:active,
.live-mute-btn:active {
  transform: scale(0.96);
}
.live-pill-btn:hover,
.live-mute-btn:hover {
  background: rgba(34, 34, 40, 0.88);
}
.live-pill-btn.is-playing {
  background: rgba(255, 204, 0, 0.94);
  color: #1c1c1e;
  border-color: rgba(255, 214, 10, 0.95);
}
.live-ring-dot {
  width: 9px;
  height: 9px;
  border-radius: 50%;
  border: 1.8px dotted currentColor;
  display: inline-block;
}
@media (prefers-reduced-motion: reduce) {
  .live-photo-video,
  .live-pill-btn,
  .live-mute-btn {
    transition: none;
  }
}
</style>
