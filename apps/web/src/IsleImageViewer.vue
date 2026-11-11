<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import {
  ZoomIn,
  ZoomOut,
  Maximize2,
  RotateCw,
  ChevronLeft,
  ChevronRight,
  RefreshCw,
  Loader2,
} from "lucide-vue-next";
import {
  normalizeViewerTransform,
  pinchDistance,
  pinchScale,
  wheelZoomFactor,
  zoomAtAnchor,
  viewerMinScale,
  viewerMaxScale,
} from "./viewerGestures.ts";

const props = withDefaults(
  defineProps<{
    src: string;
    alt?: string;
    title?: string;
    hasPrev?: boolean;
    hasNext?: boolean;
    allowZoom?: boolean;
    allowRotate?: boolean;
  }>(),
  {
    alt: "",
    title: "",
    hasPrev: false,
    hasNext: false,
    allowZoom: true,
    allowRotate: true,
  }
);

const emit = defineEmits<{
  (e: "prev"): void;
  (e: "next"): void;
  (e: "close"): void;
}>();

const scale = ref(1);
const offset = ref({ x: 0, y: 0 });
const rotation = ref(0);
const isLoaded = ref(false);
const hasError = ref(false);
const animate = ref(true);

const pointers = new Map<number, { x: number; y: number }>();
let pinchStart: {
  distance: number;
  scale: number;
  offset: { x: number; y: number };
  anchor: { x: number; y: number };
} | null = null;
let panOrigin = { x: 0, y: 0 };
let isPanning = false;

const transformStyle = computed(() => {
  return `translate(${offset.value.x}px, ${offset.value.y}px) scale(${scale.value}) rotate(${rotation.value}deg)`;
});

const scalePercent = computed(() => Math.round(scale.value * 100));

function resetView() {
  animate.value = true;
  scale.value = 1;
  offset.value = { x: 0, y: 0 };
}

function fullReset() {
  resetView();
  rotation.value = 0;
}

watch(
  () => props.src,
  () => {
    isLoaded.value = false;
    hasError.value = false;
    fullReset();
  }
);

function zoomIn() {
  if (!props.allowZoom) return;
  animate.value = true;
  scale.value = Math.min(viewerMaxScale, scale.value * 1.3);
}

function zoomOut() {
  if (!props.allowZoom) return;
  animate.value = true;
  const nextScale = Math.max(viewerMinScale, scale.value / 1.3);
  if (nextScale <= viewerMinScale + 0.01) {
    resetView();
  } else {
    scale.value = nextScale;
  }
}

function toggleActualSize() {
  if (!props.allowZoom) return;
  animate.value = true;
  if (scale.value > 1.05) {
    resetView();
  } else {
    scale.value = 2.5;
  }
}

function rotate() {
  if (!props.allowRotate) return;
  animate.value = true;
  rotation.value = (rotation.value + 90) % 360;
}

function onImageLoad() {
  isLoaded.value = true;
  hasError.value = false;
}

function onImageError() {
  isLoaded.value = false;
  hasError.value = true;
}

function handlePointerDown(event: PointerEvent) {
  if (!props.allowZoom) return;
  const element = event.currentTarget as HTMLElement;
  pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
  try {
    element.setPointerCapture(event.pointerId);
  } catch {
    // Ignore pointer capture error
  }

  if (pointers.size === 2) {
    const [first, second] = [...pointers.values()];
    const rect = element.getBoundingClientRect();
    const midX = (first.x + second.x) / 2 - (rect.left + rect.width / 2);
    const midY = (first.y + second.y) / 2 - (rect.top + rect.height / 2);
    pinchStart = {
      distance: pinchDistance(first, second),
      scale: scale.value,
      offset: { ...offset.value },
      anchor: { x: midX, y: midY },
    };
    animate.value = false;
  } else if (pointers.size === 1 && scale.value > 1.01) {
    isPanning = true;
    panOrigin = {
      x: event.clientX - offset.value.x,
      y: event.clientY - offset.value.y,
    };
    animate.value = false;
  }
}

function handlePointerMove(event: PointerEvent) {
  if (!pointers.has(event.pointerId) || !props.allowZoom) return;
  pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });

  if (pointers.size === 2 && pinchStart) {
    const [first, second] = [...pointers.values()];
    const currentDist = pinchDistance(first, second);
    const targetScale = pinchScale(
      pinchStart.scale,
      pinchStart.distance,
      currentDist
    );
    const factor = targetScale / pinchStart.scale;
    const transformed = zoomAtAnchor(
      { scale: pinchStart.scale, ...pinchStart.offset },
      factor,
      pinchStart.anchor
    );
    const normalized = normalizeViewerTransform(transformed);
    scale.value = normalized.scale;
    offset.value = { x: normalized.x, y: normalized.y };
  } else if (isPanning && pointers.size === 1) {
    offset.value = {
      x: event.clientX - panOrigin.x,
      y: event.clientY - panOrigin.y,
    };
  }
}

function handlePointerUp(event: PointerEvent) {
  pointers.delete(event.pointerId);
  if (pointers.size < 2) {
    pinchStart = null;
  }
  if (pointers.size === 0) {
    isPanning = false;
    animate.value = true;
    if (scale.value <= viewerMinScale + 0.05) {
      resetView();
    }
  }
}

function handleWheel(event: WheelEvent) {
  if (!props.allowZoom) return;
  event.preventDefault();
  animate.value = false;
  const factor = wheelZoomFactor(event.deltaY);
  const element = event.currentTarget as HTMLElement;
  const rect = element.getBoundingClientRect();
  const anchor = {
    x: event.clientX - (rect.left + rect.width / 2),
    y: event.clientY - (rect.top + rect.height / 2),
  };
  const transformed = zoomAtAnchor(
    { scale: scale.value, ...offset.value },
    factor,
    anchor
  );
  const normalized = normalizeViewerTransform(transformed);
  scale.value = normalized.scale;
  offset.value = { x: normalized.x, y: normalized.y };
}

function handleKeydown(event: KeyboardEvent) {
  if (event.key === "ArrowLeft" && props.hasPrev) {
    emit("prev");
  } else if (event.key === "ArrowRight" && props.hasNext) {
    emit("next");
  } else if (event.key === "Escape") {
    emit("close");
  } else if (event.key === "+" || event.key === "=") {
    zoomIn();
  } else if (event.key === "-") {
    zoomOut();
  } else if (event.key === "0") {
    resetView();
  }
}

onMounted(() => {
  window.addEventListener("keydown", handleKeydown);
});

onUnmounted(() => {
  window.removeEventListener("keydown", handleKeydown);
});
</script>

<template>
  <div
    class="isle-image-viewer"
    tabindex="0"
    role="region"
    :aria-label="title || alt || '图片查看器'"
  >
    <!-- Loading spinner -->
    <div v-if="!isLoaded && !hasError" class="viewer-loader">
      <Loader2 :size="32" class="spin-icon" />
    </div>

    <!-- Error notice -->
    <div v-if="hasError" class="viewer-error">
      <p>图片加载失败，请检查网络或文件是否完整</p>
      <button type="button" class="viewer-btn" @click="isLoaded = false; hasError = false">
        <RefreshCw :size="14" /> 重试加载
      </button>
    </div>

    <!-- Main Viewport Canvas -->
    <div
      class="viewer-stage"
      :class="{
        'is-gesturing': !animate,
        'can-pan': scale > 1.05,
      }"
      @dblclick="toggleActualSize"
      @pointerdown="handlePointerDown"
      @pointermove="handlePointerMove"
      @pointerup="handlePointerUp"
      @pointercancel="handlePointerUp"
      @wheel="handleWheel"
    >
      <img
        :src="src"
        :alt="alt"
        class="viewer-img"
        :style="{ transform: transformStyle }"
        draggable="false"
        @load="onImageLoad"
        @error="onImageError"
      />
    </div>

    <!-- Navigation buttons -->
    <button
      v-if="hasPrev"
      type="button"
      class="nav-btn prev"
      title="上一张 (←)"
      aria-label="上一张图片"
      @click="emit('prev')"
    >
      <ChevronLeft :size="28" />
    </button>
    <button
      v-if="hasNext"
      type="button"
      class="nav-btn next"
      title="下一张 (→)"
      aria-label="下一张图片"
      @click="emit('next')"
    >
      <ChevronRight :size="28" />
    </button>

    <!-- Floating HUD Toolbar -->
    <div class="viewer-hud" role="toolbar" aria-label="看图控制栏">
      <button
        v-if="allowZoom"
        type="button"
        class="hud-btn"
        title="缩小 (-)"
        :disabled="scale <= 1.01"
        @click="zoomOut"
      >
        <ZoomOut :size="16" />
      </button>

      <span
        v-if="allowZoom"
        class="hud-scale-badge"
        title="双击图片或点击重置缩放"
        @click="resetView"
      >
        {{ scalePercent }}%
      </span>

      <button
        v-if="allowZoom"
        type="button"
        class="hud-btn"
        title="放大 (+)"
        :disabled="scale >= viewerMaxScale - 0.05"
        @click="zoomIn"
      >
        <ZoomIn :size="16" />
      </button>

      <button
        v-if="allowZoom"
        type="button"
        class="hud-btn"
        :class="{ active: scale > 1.05 }"
        title="1:1 / 适应窗口 (0)"
        @click="toggleActualSize"
      >
        <Maximize2 :size="15" />
      </button>

      <button
        v-if="allowRotate"
        type="button"
        class="hud-btn"
        title="顺时针旋转 90°"
        @click="rotate"
      >
        <RotateCw :size="15" />
      </button>
    </div>
  </div>
</template>

<style scoped>
.isle-image-viewer {
  position: relative;
  width: 100%;
  height: 100%;
  min-height: 380px;
  max-height: 82vh;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
  background: rgba(0, 0, 0, 0.45);
  border-radius: var(--radius-lg);
  user-select: none;
  -webkit-user-select: none;
  touch-action: none;
  outline: none;
}

.viewer-loader {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--accent-primary);
  z-index: 2;
}

.spin-icon {
  animation: spin 1s linear infinite;
}

@keyframes spin {
  from {
    transform: rotate(0deg);
  }
  to {
    transform: rotate(360deg);
  }
}

.viewer-error {
  position: absolute;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
  color: #ff6b6b;
  font-size: 13px;
  text-align: center;
  z-index: 3;
  padding: 20px;
}

.viewer-stage {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: zoom-in;
}

.viewer-stage.can-pan {
  cursor: grab;
}

.viewer-stage.can-pan:active {
  cursor: grabbing;
}

.viewer-img {
  max-width: 96%;
  max-height: 96%;
  object-fit: contain;
  transition: transform 0.25s cubic-bezier(0.16, 1, 0.3, 1);
  will-change: transform;
}

.viewer-stage.is-gesturing .viewer-img {
  transition: none;
}

/* Navigation buttons */
.nav-btn {
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  width: 44px;
  height: 44px;
  border-radius: 50%;
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(20, 20, 25, 0.65);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  backdrop-filter: blur(16px);
  -webkit-backdrop-filter: blur(16px);
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
  transition: background 0.15s ease, transform 0.15s ease, opacity 0.15s ease;
  z-index: 10;
  opacity: 0.82;
}

.nav-btn:hover {
  background: rgba(35, 35, 45, 0.85);
  transform: translateY(-50%) scale(1.05);
  opacity: 1;
}

.nav-btn:active {
  transform: translateY(-50%) scale(0.95);
}

.nav-btn.prev {
  left: 14px;
}

.nav-btn.next {
  right: 14px;
}

/* Floating Bottom HUD Toolbar */
.viewer-hud {
  position: absolute;
  bottom: 16px;
  left: 50%;
  transform: translateX(-50%);
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 5px 8px;
  border-radius: var(--radius-full);
  background: rgba(24, 24, 30, 0.72);
  border: 1px solid rgba(255, 255, 255, 0.14);
  backdrop-filter: blur(20px);
  -webkit-backdrop-filter: blur(20px);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35);
  z-index: 10;
  opacity: 0.92;
  transition: opacity 0.2s ease, transform 0.2s ease;
}

.viewer-hud:hover {
  opacity: 1;
}

.hud-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 32px;
  height: 32px;
  border-radius: 50%;
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.85);
  cursor: pointer;
  transition: background-color 0.15s ease, color 0.15s ease;
}

.hud-btn:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.15);
  color: #fff;
}

.hud-btn:active:not(:disabled) {
  transform: scale(0.92);
}

.hud-btn:disabled {
  opacity: 0.35;
  cursor: not-allowed;
}

.hud-btn.active {
  background: rgba(255, 255, 255, 0.22);
  color: #fff;
}

.hud-scale-badge {
  padding: 0 8px;
  font-size: 11.5px;
  font-weight: 600;
  font-family: ui-monospace, SFMono-Regular, monospace;
  color: rgba(255, 255, 255, 0.9);
  cursor: pointer;
}

.hud-scale-badge:hover {
  color: #fff;
  text-decoration: underline;
}

@media (max-width: 640px) {
  .nav-btn {
    width: 38px;
    height: 38px;
  }
  .nav-btn.prev {
    left: 8px;
  }
  .nav-btn.next {
    right: 8px;
  }
  .viewer-hud {
    bottom: 10px;
  }
}
</style>
