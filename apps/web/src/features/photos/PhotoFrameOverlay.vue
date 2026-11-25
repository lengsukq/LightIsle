<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { Maximize2, Minimize2, Pause, Play, Shuffle, X } from "lucide-vue-next";
import { capturedLabel } from "./photoPresentation.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";

const props = defineProps<{
  open: boolean;
  assets: BatchAsset[];
  title?: string;
  mediaPath: (path: string) => string;
}>();

const emit = defineEmits<{ close: [] }>();

const intervalOptions = [
  { ms: 5000, label: "5秒" },
  { ms: 10000, label: "10秒" },
  { ms: 30000, label: "30秒" },
  { ms: 60000, label: "60秒" },
];

const currentIndex = ref(0);
const playing = ref(true);
const shuffled = ref(false);
const intervalMs = ref(10000);
const controlsVisible = ref(true);
const isFullscreen = ref(false);
const nowClock = ref("");
const nowDate = ref("");

let slideTimer: number | undefined;
let clockTimer: number | undefined;
let hideTimer: number | undefined;
let wakeLockSentinel: { release: () => Promise<void> } | null = null;
const stageRef = ref<HTMLElement | null>(null);

const photoAssets = computed(() => props.assets.filter((a) => a.type === "photo"));
const currentAsset = computed(() => {
  const list = photoAssets.value;
  if (!list.length) return null;
  return list[currentIndex.value % list.length] ?? list[0];
});

const currentImageUrl = computed(() => {
  const asset = currentAsset.value;
  if (!asset) return "";
  return props.mediaPath(`/api/v2/files/content?path=${encodeURIComponent(asset.path)}`);
});

function updateClock() {
  const now = new Date();
  const hh = String(now.getHours()).padStart(2, "0");
  const mm = String(now.getMinutes()).padStart(2, "0");
  nowClock.value = `${hh}:${mm}`;
  const weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
  nowDate.value = `${now.getFullYear()}年${now.getMonth() + 1}月${now.getDate()}日 · ${weekdays[now.getDay()]}`;
}

function advance(step = 1) {
  const list = photoAssets.value;
  if (list.length <= 1) return;
  if (shuffled.value) {
    let next = currentIndex.value;
    for (let i = 0; i < 4 && next === currentIndex.value; i++) {
      next = Math.floor(Math.random() * list.length);
    }
    currentIndex.value = next;
  } else {
    currentIndex.value = (currentIndex.value + step + list.length) % list.length;
  }
}

function restartTimer() {
  if (slideTimer !== undefined) {
    window.clearInterval(slideTimer);
    slideTimer = undefined;
  }
  if (props.open && playing.value && photoAssets.value.length > 1) {
    slideTimer = window.setInterval(() => {
      if (!document.hidden) advance(1);
    }, intervalMs.value);
  }
}

function revealControls() {
  controlsVisible.value = true;
  if (hideTimer !== undefined) window.clearTimeout(hideTimer);
  hideTimer = window.setTimeout(() => {
    controlsVisible.value = false;
  }, 3500);
}

async function acquireWakeLock() {
  try {
    const nav = navigator as Navigator & { wakeLock?: { request: (t: "screen") => Promise<{ release: () => Promise<void> }> } };
    if (nav.wakeLock) {
      wakeLockSentinel = await nav.wakeLock.request("screen");
    }
  } catch {
    wakeLockSentinel = null;
  }
}

function releaseWakeLock() {
  if (wakeLockSentinel) {
    void wakeLockSentinel.release().catch(() => {});
    wakeLockSentinel = null;
  }
}

async function toggleFullscreen() {
  try {
    if (!document.fullscreenElement && stageRef.value) {
      await stageRef.value.requestFullscreen();
      isFullscreen.value = true;
    } else if (document.fullscreenElement) {
      await document.exitFullscreen();
      isFullscreen.value = false;
    }
  } catch {
    isFullscreen.value = Boolean(document.fullscreenElement);
  }
}

function onKeyDown(e: KeyboardEvent) {
  if (!props.open) return;
  if (e.key === "Escape") {
    e.preventDefault();
    emit("close");
  } else if (e.key === "ArrowRight") {
    advance(1);
    revealControls();
  } else if (e.key === "ArrowLeft") {
    advance(-1);
    revealControls();
  } else if (e.key === " ") {
    e.preventDefault();
    playing.value = !playing.value;
    revealControls();
  }
}

watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) {
      currentIndex.value = 0;
      playing.value = true;
      updateClock();
      clockTimer = window.setInterval(updateClock, 15000);
      restartTimer();
      revealControls();
      void acquireWakeLock();
    } else {
      if (slideTimer !== undefined) { window.clearInterval(slideTimer); slideTimer = undefined; }
      if (clockTimer !== undefined) { window.clearInterval(clockTimer); clockTimer = undefined; }
      if (hideTimer !== undefined) { window.clearTimeout(hideTimer); hideTimer = undefined; }
      releaseWakeLock();
      if (document.fullscreenElement) {
        void document.exitFullscreen().catch(() => {});
      }
      isFullscreen.value = false;
    }
  },
  { immediate: true },
);

watch([playing, intervalMs, () => photoAssets.value.length], () => restartTimer());

onMounted(() => window.addEventListener("keydown", onKeyDown));
onBeforeUnmount(() => {
  window.removeEventListener("keydown", onKeyDown);
  if (slideTimer !== undefined) window.clearInterval(slideTimer);
  if (clockTimer !== undefined) window.clearInterval(clockTimer);
  if (hideTimer !== undefined) window.clearTimeout(hideTimer);
  releaseWakeLock();
});
</script>

<template>
  <Teleport to="body">
    <div
      v-if="open"
      ref="stageRef"
      class="photo-frame-overlay"
      role="dialog"
      aria-modal="true"
      aria-label="电子相框轮播模式"
      @mousemove="revealControls"
      @click="revealControls"
    >
      <div class="photo-frame-backdrop">
        <img v-if="currentImageUrl" :key="'bg-' + currentAsset?.id" :src="currentImageUrl" alt="" aria-hidden="true" />
      </div>
      <div class="photo-frame-stage">
        <img
          v-if="currentImageUrl"
          :key="currentAsset?.id"
          :src="currentImageUrl"
          :alt="currentAsset?.name || '家庭照片'"
          class="photo-frame-img"
        />
        <div v-else class="photo-frame-empty">当前列表暂无可轮播的照片</div>
      </div>

      <div class="photo-frame-clock">
        <div class="photo-frame-time">{{ nowClock }}</div>
        <div class="photo-frame-date">{{ nowDate }}</div>
        <div v-if="currentAsset" class="photo-frame-caption">
          <span v-if="title">{{ title }} · </span>
          <span>{{ capturedLabel(currentAsset) || currentAsset.name }}</span>
          <span v-if="photoAssets.length > 1"> ({{ (currentIndex % photoAssets.length) + 1 }} / {{ photoAssets.length }})</span>
        </div>
      </div>

      <div class="photo-frame-controls" :class="{ visible: controlsVisible }">
        <button type="button" class="frame-ctrl-btn" :title="playing ? '暂停轮播' : '继续轮播'" @click.stop="playing = !playing">
          <Pause v-if="playing" :size="15" /><Play v-else :size="15" />
          <span>{{ playing ? "暂停" : "播放" }}</span>
        </button>
        <button type="button" class="frame-ctrl-btn" :class="{ active: shuffled }" title="随机顺序" @click.stop="shuffled = !shuffled">
          <Shuffle :size="15" />
        </button>
        <div class="frame-interval-group" role="group" aria-label="轮播间隔">
          <button
            v-for="opt in intervalOptions"
            :key="opt.ms"
            type="button"
            class="frame-interval-btn"
            :class="{ active: intervalMs === opt.ms }"
            @click.stop="intervalMs = opt.ms"
          >
            {{ opt.label }}
          </button>
        </div>
        <button type="button" class="frame-ctrl-btn" :title="isFullscreen ? '退出全屏' : '进入全屏'" @click.stop="toggleFullscreen">
          <Minimize2 v-if="isFullscreen" :size="15" /><Maximize2 v-else :size="15" />
        </button>
        <button type="button" class="frame-ctrl-btn" title="退出电子相框 (Esc)" @click.stop="emit('close')">
          <X :size="16" /> 退出
        </button>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.photo-frame-overlay {
  position: fixed;
  inset: 0;
  z-index: 9999;
  background: #050507;
  color: #ffffff;
  overflow: hidden;
  user-select: none;
}
.photo-frame-backdrop {
  position: absolute;
  inset: -40px;
  filter: blur(42px) brightness(0.32) saturate(1.25);
  pointer-events: none;
}
.photo-frame-backdrop img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.photo-frame-stage {
  position: relative;
  width: 100%;
  height: 100%;
  display: grid;
  place-items: center;
  padding: 24px;
}
.photo-frame-img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
  border-radius: 10px;
  box-shadow: 0 24px 64px rgba(0, 0, 0, 0.55);
  animation: frameFadeIn 0.55s ease;
}
.photo-frame-empty {
  font-size: 16px;
  color: rgba(255, 255, 255, 0.72);
}
.photo-frame-clock {
  position: absolute;
  left: 32px;
  bottom: 28px;
  text-shadow: 0 2px 16px rgba(0, 0, 0, 0.7);
  pointer-events: none;
}
.photo-frame-time {
  font-size: clamp(40px, 6vw, 72px);
  font-weight: 600;
  letter-spacing: -0.02em;
  line-height: 1;
  font-variant-numeric: tabular-nums;
}
.photo-frame-date {
  margin-top: 6px;
  font-size: 15px;
  opacity: 0.9;
}
.photo-frame-caption {
  margin-top: 6px;
  font-size: 12.5px;
  opacity: 0.72;
}
.photo-frame-controls {
  position: absolute;
  top: 20px;
  right: 24px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 10px;
  border-radius: 999px;
  background: rgba(18, 18, 22, 0.68);
  border: 1px solid rgba(255, 255, 255, 0.16);
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.22s ease;
}
.photo-frame-controls.visible {
  opacity: 1;
  pointer-events: auto;
}
.frame-ctrl-btn,
.frame-interval-btn {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  border: none;
  border-radius: 999px;
  padding: 6px 10px;
  background: transparent;
  color: rgba(255, 255, 255, 0.88);
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}
.frame-ctrl-btn:hover,
.frame-interval-btn:hover {
  background: rgba(255, 255, 255, 0.14);
}
.frame-ctrl-btn.active,
.frame-interval-btn.active {
  background: rgba(255, 255, 255, 0.24);
  color: #ffffff;
}
.frame-interval-group {
  display: inline-flex;
  gap: 2px;
  padding: 2px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.08);
}
@keyframes frameFadeIn {
  from { opacity: 0.18; }
  to { opacity: 1; }
}
@media (prefers-reduced-motion: reduce) {
  .photo-frame-img { animation: none; }
  .photo-frame-controls { transition: none; }
}
</style>
