<script setup lang="ts">
import { computed, ref } from "vue";
import { CalendarHeart, Film, MapPin, Sparkles } from "lucide-vue-next";
import type { SmartMemoryItem } from "./usePhotoMemories.ts";

const props = withDefaults(
  defineProps<{
    memories: SmartMemoryItem[];
    mediaPath: (path: string) => string;
    compact?: boolean;
  }>(),
  {
    compact: false,
  },
);

const emit = defineEmits<{
  (e: "select", memory: SmartMemoryItem): void;
}>();

const failedIds = ref<Record<string, boolean>>({});
const loadedIds = ref<Record<string, boolean>>({});

const visibleMemories = computed(() => props.memories.slice(0, 6));

function coverSrc(mem: SmartMemoryItem): string {
  if (!mem.coverAssetId) return "";
  return props.mediaPath(`/api/v2/photos/${mem.coverAssetId}/thumbnail`);
}

function onCoverLoad(event: Event, id: string) {
  const img = event.target as HTMLImageElement | null;
  if (img && img.naturalWidth === 0) {
    failedIds.value = { ...failedIds.value, [id]: true };
    return;
  }
  loadedIds.value = { ...loadedIds.value, [id]: true };
}

function onCoverError(id: string) {
  failedIds.value = { ...failedIds.value, [id]: true };
}
</script>

<template>
  <div
    v-if="visibleMemories.length > 0"
    class="photos-memories-strip"
    :class="{ 'is-compact': compact }"
    role="region"
    aria-label="智能回忆与精选"
  >
    <button
      v-for="mem in visibleMemories"
      :key="mem.id"
      type="button"
      class="memory-card memory-banner-card"
      @click="emit('select', mem)"
    >
      <span class="memory-banner-media" :class="`tone-${mem.kind}`" aria-hidden="true">
        <img
          v-if="coverSrc(mem) && !failedIds[mem.id]"
          :src="coverSrc(mem)"
          :alt="mem.title"
          loading="lazy"
          decoding="async"
          :class="{ 'is-loaded': loadedIds[mem.id] }"
          @load="onCoverLoad($event, mem.id)"
          @error="onCoverError(mem.id)"
        />
        <span v-else class="memory-banner-fallback">
          <Film v-if="mem.kind === 'live'" :size="24" />
          <MapPin v-else-if="mem.kind === 'trip'" :size="24" />
          <CalendarHeart v-else-if="mem.kind === 'yearly'" :size="24" />
          <Sparkles v-else :size="24" />
        </span>
      </span>
      <span class="memory-banner-scrim" aria-hidden="true" />
      <span class="memory-banner-copy">
        <span class="memory-banner-eyebrow">
          <Sparkles :size="11" />
          <span>{{ mem.kind === "live" ? "动态实况" : mem.kind === "trip" ? "旅途足迹" : mem.kind === "yearly" ? "年度精选" : "周末拾光" }}</span>
        </span>
        <strong>{{ mem.title }}</strong>
        <small>{{ mem.subtitle }}</small>
      </span>
    </button>
  </div>
</template>

<style scoped>
.photos-memories-strip {
  display: flex;
  align-items: stretch;
  gap: 10px;
  overflow-x: auto;
  scrollbar-width: none;
  padding: 2px 1px 6px;
  margin: 0 0 10px;
  scroll-snap-type: x proximity;
}
.photos-memories-strip::-webkit-scrollbar {
  display: none;
}
.memory-banner-card {
  position: relative;
  flex: 0 0 clamp(216px, 24vw, 276px);
  height: 124px;
  padding: 0;
  border: 0;
  border-radius: 16px;
  overflow: hidden;
  display: flex;
  align-items: flex-end;
  text-align: left;
  cursor: pointer;
  scroll-snap-align: start;
  background: var(--surface-raised);
  box-shadow: 0 6px 20px rgba(20, 16, 12, 0.12);
  transition: transform var(--motion-fast) var(--motion-spring), box-shadow var(--motion-fast) ease;
}
.photos-memories-strip.is-compact .memory-banner-card {
  flex: 0 0 clamp(200px, 22vw, 252px);
  height: 112px;
}
.memory-banner-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 12px 26px rgba(20, 16, 12, 0.18);
}
.memory-banner-card:active {
  transform: scale(0.985);
}
.memory-banner-card:focus-visible {
  outline: 2.5px solid var(--accent-primary);
  outline-offset: 2px;
}
.memory-banner-media {
  position: absolute;
  inset: 0;
  display: grid;
  place-items: center;
}
.memory-banner-media.tone-live {
  background: linear-gradient(135deg, #2d2118 0%, #5e3b1f 100%);
}
.memory-banner-media.tone-trip {
  background: linear-gradient(135deg, #172726 0%, #244a42 100%);
}
.memory-banner-media.tone-yearly {
  background: linear-gradient(135deg, #2a1e24 0%, #55303d 100%);
}
.memory-banner-media.tone-weekend {
  background: linear-gradient(135deg, #1f2432 0%, #37435e 100%);
}
.memory-banner-media img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  opacity: 0;
  transition: opacity 0.35s ease, transform 0.55s cubic-bezier(0.22, 1, 0.36, 1);
}
.memory-banner-media img.is-loaded {
  opacity: 1;
}
.memory-banner-card:hover .memory-banner-media img.is-loaded {
  transform: scale(1.04);
}
.memory-banner-fallback {
  color: rgba(255, 246, 234, 0.84);
  display: grid;
  place-items: center;
  transform: translateY(-10px);
}
.memory-banner-scrim {
  position: absolute;
  inset: 0;
  background: linear-gradient(
    to top,
    rgba(20, 14, 10, 0.84) 0%,
    rgba(28, 19, 12, 0.42) 48%,
    rgba(28, 19, 12, 0.06) 100%
  );
  pointer-events: none;
}
.memory-banner-copy {
  position: relative;
  z-index: 1;
  display: grid;
  gap: 2px;
  width: 100%;
  min-width: 0;
  padding: 10px 13px;
  color: #fffaf3;
}
.memory-banner-eyebrow {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 10.5px;
  font-weight: 650;
  letter-spacing: 0.02em;
  color: rgba(255, 244, 228, 0.86);
}
.memory-banner-copy strong {
  font-size: 14px;
  font-weight: 700;
  letter-spacing: -0.015em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  text-shadow: 0 1px 6px rgba(0, 0, 0, 0.32);
}
.memory-banner-copy small {
  font-size: 11.5px;
  font-variant-numeric: tabular-nums;
  color: rgba(255, 247, 236, 0.84);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
@media (max-width: 680px) {
  .memory-banner-card {
    flex: 0 0 clamp(196px, 64vw, 240px);
    height: 112px;
  }
}
@media (prefers-reduced-motion: reduce) {
  .memory-banner-card,
  .memory-banner-media img {
    transition: none;
  }
}
</style>
