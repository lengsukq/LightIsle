<script setup lang="ts">
import { ref, watch } from "vue";
import { Volume2, VolumeX } from "lucide-vue-next";

const props = defineProps<{
  liveVideoSrc: string;
}>();

const playing = ref(false);
const muted = ref(false);
const videoRef = ref<HTMLVideoElement | null>(null);

watch(
  () => props.liveVideoSrc,
  () => {
    stopLive();
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
      });
    });
  });
}

function stopLive() {
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
}

function toggleMute() {
  muted.value = !muted.value;
  if (videoRef.value) {
    videoRef.value.muted = muted.value;
  }
}
</script>

<template>
  <div class="live-photo-layer" @dblclick.stop @pointerdown.stop>
    <video
      v-if="playing"
      ref="videoRef"
      :src="liveVideoSrc"
      class="live-photo-video"
      playsinline
      preload="auto"
      @ended="playing = false"
      @error="playing = false"
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
  background: #000;
  pointer-events: auto;
}
.live-photo-controls {
  position: absolute;
  top: 14px;
  left: 14px;
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
  padding: 5px 10px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.24);
  background: rgba(24, 24, 28, 0.68);
  color: #fff;
  font-size: 11.5px;
  font-weight: 700;
  letter-spacing: 0.5px;
  backdrop-filter: blur(14px);
  -webkit-backdrop-filter: blur(14px);
  cursor: pointer;
  transition: background 0.18s ease, transform 0.15s ease;
}
.live-pill-btn:hover,
.live-mute-btn:hover {
  background: rgba(40, 40, 48, 0.85);
}
.live-pill-btn.is-playing {
  background: rgba(255, 204, 0, 0.92);
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
</style>
