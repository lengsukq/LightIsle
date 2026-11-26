<script setup lang="ts">
import { computed, ref } from "vue";

export interface ScrubberMonthItem {
  year: number;
  month: number;
  title: string;
  firstIndex: number;
}

const props = defineProps<{
  visible: boolean;
  scrubMonths: ScrubberMonthItem[];
  scrubbing: boolean;
  scrubPreview: number;
  scrubCurrentIndex: number;
  scrolling: boolean;
}>();

const emit = defineEmits<{
  (e: "start", event: PointerEvent): void;
  (e: "move", event: PointerEvent): void;
  (e: "stop", event: PointerEvent, commit?: boolean): void;
  (e: "keydown", event: KeyboardEvent): void;
}>();

const hovered = ref(false);
const focused = ref(false);

const activeIndex = computed(() => {
  const max = Math.max(0, props.scrubMonths.length - 1);
  const raw = props.scrubbing ? props.scrubPreview : props.scrubCurrentIndex;
  return Math.max(0, Math.min(max, raw));
});

const activeTopPercent = computed(() => {
  if (!props.scrubMonths.length) return "50%";
  return `${((activeIndex.value + 0.5) / props.scrubMonths.length) * 100}%`;
});

const activeLabel = computed(() => props.scrubMonths[activeIndex.value]?.title ?? "");
const showGlassPill = computed(() =>
  Boolean(activeLabel.value && (props.scrubbing || props.scrolling || hovered.value || focused.value)),
);
</script>

<template>
  <Teleport to="body">
    <div
      v-if="visible && scrubMonths.length > 1"
      class="photo-timeline-scrubber"
      :class="{ 'is-dragging': scrubbing, 'is-scrolling': scrolling }"
      @pointerenter="hovered = true"
      @pointerleave="hovered = false"
    >
      <Transition name="photo-scrubber-pill-fade">
        <div
          v-if="showGlassPill"
          class="photo-scrubber-preview"
          :class="{ 'is-dragging': scrubbing }"
          aria-live="off"
          :style="{ top: activeTopPercent }"
        >
          {{ activeLabel }}
        </div>
      </Transition>
      <div
        class="photo-scrubber-track"
        role="slider"
        tabindex="0"
        aria-label="按年月快速浏览照片"
        aria-orientation="vertical"
        :aria-valuemin="0"
        :aria-valuemax="scrubMonths.length - 1"
        :aria-valuenow="scrubCurrentIndex"
        :aria-valuetext="scrubMonths[scrubCurrentIndex]?.title"
        title="拖动选择年月，松手跳转"
        @focus="focused = true"
        @blur="focused = false"
        @pointerdown="emit('start', $event)"
        @pointermove="emit('move', $event)"
        @pointerup="emit('stop', $event, true)"
        @pointercancel="emit('stop', $event, false)"
        @keydown="emit('keydown', $event)"
      >
        <span class="photo-scrubber-line" />
        <template v-for="(month, i) in scrubMonths" :key="month.year + '-' + month.month">
          <span
            v-if="i === 0 || scrubMonths[i - 1]?.year !== month.year"
            class="photo-scrubber-year-tick"
            :style="{ top: ((i + 0.5) / scrubMonths.length) * 100 + '%' }"
          />
        </template>
        <span class="photo-scrubber-thumb" :style="{ top: activeTopPercent }" />
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.photo-scrubber-pill-fade-enter-active,
.photo-scrubber-pill-fade-leave-active {
  transition: opacity 0.2s ease, transform 0.2s cubic-bezier(0.22, 1, 0.36, 1);
}
.photo-scrubber-pill-fade-enter-from,
.photo-scrubber-pill-fade-leave-to {
  opacity: 0;
  transform: translate3d(6px, -50%, 0) scale(0.95);
}
@media (prefers-reduced-motion: reduce) {
  .photo-scrubber-pill-fade-enter-active,
  .photo-scrubber-pill-fade-leave-active {
    transition: none;
  }
}
</style>
