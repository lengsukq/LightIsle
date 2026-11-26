<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { LayoutDashboard, Maximize2, Minimize2, Moon, Pause, Play, Shuffle, Sparkles, X } from "lucide-vue-next";
import { capturedLabel } from "./photoPresentation.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";
import PhotoFrameDashboardWidgets from "./PhotoFrameDashboardWidgets.vue";
import {
  isNightDimHour,
  readPhotoFrameMode,
  savePhotoFrameMode,
  type PhotoFrameDisplayMode,
} from "../overview/familyRemindersApi.ts";

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
const displayMode = ref<PhotoFrameDisplayMode>(readPhotoFrameMode());
const nightDimAuto = ref(isNightDimHour());
const nightDimOverride = ref<boolean | null>(null);

const nightDimActive = computed(() =>
  nightDimOverride.value !== null ? nightDimOverride.value : nightDimAuto.value,
);

type BufferSlot = { url: string; alt: string };
const slots = ref<[BufferSlot, BufferSlot]>([
  { url: "", alt: "" },
  { url: "", alt: "" },
]);
const activeSlot = ref<0 | 1>(0);

let slideTimer: number | undefined;
let clockTimer: number | undefined;
let hideTimer: number | undefined;
let wakeLockSentinel: { release: () => Promise<void> } | null = null;
let loadToken = 0;
let activeImgLoader: HTMLImageElement | null = null;
let warmImgLoader: HTMLImageElement | null = null;
let swapRafId = 0;
const stageRef = ref<HTMLElement | null>(null);

const photoAssets = computed(() => props.assets.filter((a) => a.type === "photo"));
const currentAsset = computed(() => {
  const list = photoAssets.value;
  if (!list.length) return null;
  return list[currentIndex.value % list.length] ?? list[0];
});

const currentCaptionText = computed(() => {
  const asset = currentAsset.value;
  if (!asset) return "";
  const parts: string[] = [];
  if (props.title) parts.push(props.title);
  parts.push(capturedLabel(asset) || asset.name);
  const count = photoAssets.value.length > 1 ? ` (${(currentIndex.value % photoAssets.value.length) + 1} / ${photoAssets.value.length})` : "";
  return parts.join(" · ") + count;
});

function setDisplayMode(mode: PhotoFrameDisplayMode) {
  displayMode.value = mode;
  savePhotoFrameMode(mode);
}

function toggleNightDim() {
  nightDimOverride.value = !nightDimActive.value;
}

function imageUrlFor(asset: BatchAsset | null): string {
  if (!asset) return "";
  return props.mediaPath(`/api/v2/files/content?path=${encodeURIComponent(asset.path)}`);
}

function cancelImageLoaders() {
  loadToken += 1;
  if (swapRafId) {
    window.cancelAnimationFrame(swapRafId);
    swapRafId = 0;
  }
  if (activeImgLoader) {
    activeImgLoader.onload = null;
    activeImgLoader.onerror = null;
    activeImgLoader.removeAttribute("src");
    activeImgLoader = null;
  }
  if (warmImgLoader) {
    warmImgLoader.onload = null;
    warmImgLoader.onerror = null;
    warmImgLoader.removeAttribute("src");
    warmImgLoader = null;
  }
}

function preloadUpcomingPhoto() {
  const list = photoAssets.value;
  if (!props.open || list.length <= 1 || shuffled.value) return;
  const nextAsset = list[(currentIndex.value + 1) % list.length];
  const nextUrl = imageUrlFor(nextAsset);
  if (!nextUrl) return;
  if (warmImgLoader) {
    warmImgLoader.removeAttribute("src");
    warmImgLoader = null;
  }
  const warm = new Image();
  warm.decoding = "async";
  warm.src = nextUrl;
  warmImgLoader = warm;
}

function loadBufferedImage(asset: BatchAsset | null) {
  cancelImageLoaders();
  if (!props.open || !asset) return;
  const url = imageUrlFor(asset);
  if (!url) return;
  const currentUrl = slots.value[activeSlot.value].url;
  if (currentUrl === url) {
    preloadUpcomingPhoto();
    return;
  }

  const token = loadToken;
  const img = new Image();
  img.decoding = "async";
  activeImgLoader = img;

  const commitSlot = () => {
    if (token !== loadToken || !props.open) return;
    activeImgLoader = null;
    const isInitial = !slots.value[0].url && !slots.value[1].url;
    if (isInitial) {
      slots.value = [{ url, alt: asset.name }, { url: "", alt: "" }];
      activeSlot.value = 0;
      preloadUpcomingPhoto();
      return;
    }
    const targetSlot: 0 | 1 = activeSlot.value === 0 ? 1 : 0;
    const updated: [BufferSlot, BufferSlot] = [slots.value[0], slots.value[1]];
    updated[targetSlot] = { url, alt: asset.name };
    slots.value = updated;
    swapRafId = window.requestAnimationFrame(() => {
      swapRafId = 0;
      if (token !== loadToken || !props.open) return;
      activeSlot.value = targetSlot;
      preloadUpcomingPhoto();
    });
  };

  img.onload = () => {
    if (token !== loadToken || !props.open) return;
    if (typeof img.decode === "function") {
      void img.decode().then(commitSlot, commitSlot);
    } else {
      commitSlot();
    }
  };
  img.onerror = () => {
    if (token !== loadToken) return;
    activeImgLoader = null;
    preloadUpcomingPhoto();
  };
  img.src = url;
}

function updateClock() {
  const now = new Date();
  const hh = String(now.getHours()).padStart(2, "0");
  const mm = String(now.getMinutes()).padStart(2, "0");
  nowClock.value = `${hh}:${mm}`;
  const weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
  nowDate.value = `${now.getFullYear()}年${now.getMonth() + 1}月${now.getDate()}日 · ${weekdays[now.getDay()]}`;
  nightDimAuto.value = isNightDimHour(now);
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
      displayMode.value = readPhotoFrameMode();
      nightDimOverride.value = null;
      slots.value = [{ url: "", alt: "" }, { url: "", alt: "" }];
      activeSlot.value = 0;
      updateClock();
      clockTimer = window.setInterval(updateClock, 15000);
      restartTimer();
      revealControls();
      void acquireWakeLock();
      loadBufferedImage(currentAsset.value);
    } else {
      cancelImageLoaders();
      slots.value = [{ url: "", alt: "" }, { url: "", alt: "" }];
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

watch(currentAsset, (asset) => {
  if (props.open) loadBufferedImage(asset);
});

watch([playing, intervalMs, () => photoAssets.value.length], () => restartTimer());

onMounted(() => window.addEventListener("keydown", onKeyDown));
onBeforeUnmount(() => {
  window.removeEventListener("keydown", onKeyDown);
  cancelImageLoaders();
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
      :class="{ 'is-night-dim': nightDimActive && displayMode === 'dashboard' }"
      role="dialog"
      aria-modal="true"
      :aria-label="displayMode === 'dashboard' ? '旧 iPad 家庭看板模式' : '电子相框轮播模式'"
      @mousemove="revealControls"
      @click="revealControls"
    >
      <div class="photo-frame-backdrop" aria-hidden="true">
        <img
          v-for="(slot, idx) in slots"
          v-show="slot.url"
          :key="'bg-' + idx"
          :src="slot.url"
          alt=""
          class="photo-frame-bg-layer"
          :class="{ 'is-active': activeSlot === idx && Boolean(slot.url) }"
        />
      </div>
      <div class="photo-frame-stage">
        <template v-if="currentAsset">
          <img
            v-for="(slot, idx) in slots"
            v-show="slot.url"
            :key="'fg-' + idx"
            :src="slot.url"
            :alt="slot.alt || '家庭照片'"
            class="photo-frame-layer"
            :class="{ 'is-active': activeSlot === idx && Boolean(slot.url) }"
          />
        </template>
        <div v-else class="photo-frame-empty">当前列表暂无可轮播的照片</div>
      </div>

      <div class="photo-frame-scrim" aria-hidden="true" />

      <PhotoFrameDashboardWidgets
        v-if="displayMode === 'dashboard'"
        :active="open && displayMode === 'dashboard'"
        :now-clock="nowClock"
        :now-date="nowDate"
        :caption-text="currentCaptionText"
        :night-dim="nightDimActive"
      />

      <div v-else class="photo-frame-clock">
        <div class="photo-frame-time">{{ nowClock }}</div>
        <div class="photo-frame-date">{{ nowDate }}</div>
        <div v-if="currentAsset" class="photo-frame-caption">
          <span v-if="title">{{ title }} · </span>
          <span>{{ capturedLabel(currentAsset) || currentAsset.name }}</span>
          <span v-if="photoAssets.length > 1"> ({{ (currentIndex % photoAssets.length) + 1 }} / {{ photoAssets.length }})</span>
        </div>
      </div>

      <div class="photo-frame-controls" :class="{ visible: controlsVisible }" @click.capture="revealControls">
        <div class="frame-mode-group" role="tablist" aria-label="相框显示模式">
          <button
            type="button"
            role="tab"
            class="frame-interval-btn"
            :class="{ active: displayMode === 'frame' }"
            :aria-selected="displayMode === 'frame'"
            @click.stop="setDisplayMode('frame')"
          >
            <Sparkles :size="13" /> 纯净相框
          </button>
          <button
            type="button"
            role="tab"
            class="frame-interval-btn"
            :class="{ active: displayMode === 'dashboard' }"
            :aria-selected="displayMode === 'dashboard'"
            @click.stop="setDisplayMode('dashboard')"
          >
            <LayoutDashboard :size="13" /> 家庭看板
          </button>
        </div>

        <button
          v-if="displayMode === 'dashboard'"
          type="button"
          class="frame-ctrl-btn"
          :class="{ active: nightDimActive }"
          title="夜间柔光模式（22:00–07:00 自动开启，可手动切换）"
          @click.stop="toggleNightDim"
        >
          <Moon :size="14" />
          <span>柔光</span>
        </button>

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
  transition: filter 0.6s ease;
}
.photo-frame-overlay.is-night-dim .photo-frame-stage {
  filter: brightness(0.66) saturate(0.86);
}
.photo-frame-backdrop {
  position: absolute;
  inset: -40px;
  filter: blur(42px) brightness(0.32) saturate(1.25);
  pointer-events: none;
}
.photo-frame-bg-layer {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  object-fit: cover;
  opacity: 0;
  transition: opacity 0.8s cubic-bezier(0.22, 1, 0.36, 1);
  will-change: opacity;
}
.photo-frame-bg-layer.is-active {
  opacity: 1;
}
.photo-frame-stage {
  position: relative;
  width: 100%;
  height: 100%;
  display: grid;
  place-items: center;
  padding: 24px;
  box-sizing: border-box;
  transition: filter 0.6s ease;
}
.photo-frame-layer {
  position: absolute;
  inset: 24px;
  margin: auto;
  max-width: calc(100% - 48px);
  max-height: calc(100% - 48px);
  object-fit: contain;
  border-radius: 10px;
  box-shadow: 0 24px 64px rgba(0, 0, 0, 0.55);
  opacity: 0;
  transition: opacity 0.8s cubic-bezier(0.22, 1, 0.36, 1);
  will-change: opacity;
  pointer-events: none;
}
.photo-frame-layer.is-active {
  opacity: 1;
}
.photo-frame-empty {
  font-size: 16px;
  color: rgba(255, 255, 255, 0.72);
}
.photo-frame-scrim {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  height: clamp(140px, 28vh, 240px);
  background: linear-gradient(to top, rgba(0, 0, 0, 0.72) 0%, rgba(0, 0, 0, 0.34) 55%, transparent 100%);
  pointer-events: none;
}
.photo-frame-clock {
  position: absolute;
  left: max(24px, env(safe-area-inset-left));
  bottom: max(24px, env(safe-area-inset-bottom));
  max-width: calc(100vw - 32px);
  text-shadow: 0 2px 16px rgba(0, 0, 0, 0.75);
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
  font-variant-numeric: tabular-nums;
  opacity: 0.92;
}
.photo-frame-caption {
  margin-top: 6px;
  font-size: 12.5px;
  font-variant-numeric: tabular-nums;
  color: rgba(255, 255, 255, 0.86);
  word-break: break-word;
}
.photo-frame-controls {
  position: absolute;
  top: max(18px, env(safe-area-inset-top));
  right: max(20px, env(safe-area-inset-right));
  max-width: calc(100vw - 24px);
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 6px 10px;
  border-radius: 999px;
  background: rgba(18, 18, 22, 0.68);
  border: 1px solid rgba(255, 255, 255, 0.16);
  -webkit-backdrop-filter: blur(20px) saturate(160%);
  backdrop-filter: blur(20px) saturate(160%);
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.22s ease;
}
@media (max-width: 640px) {
  .photo-frame-stage { padding: 14px; }
  .photo-frame-layer { inset: 14px; max-width: calc(100% - 28px); max-height: calc(100% - 28px); }
  .photo-frame-clock { left: max(16px, env(safe-area-inset-left)); bottom: max(18px, env(safe-area-inset-bottom)); }
  .photo-frame-controls {
    top: max(14px, env(safe-area-inset-top)); left: 12px; right: 12px; width: fit-content;
    margin: 0 auto; border-radius: 18px; gap: 4px 6px; padding: 6px 8px;
  }
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
.frame-mode-group,
.frame-interval-group {
  display: inline-flex;
  gap: 2px;
  padding: 2px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.08);
}
@media (prefers-reduced-motion: reduce) {
  .photo-frame-overlay,
  .photo-frame-stage,
  .photo-frame-bg-layer,
  .photo-frame-layer,
  .photo-frame-controls {
    transition: none;
  }
}
</style>
