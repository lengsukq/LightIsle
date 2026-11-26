<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import { Film, Images } from "lucide-vue-next";
import { formatDuration } from "./photoPresentation.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";

const props = defineProps<{
  assets: BatchAsset[];
  selectedIndex: number;
  visible: boolean;
  thumbFor: (asset: BatchAsset) => string;
}>();

const emit = defineEmits<{
  (e: "select", index: number): void;
}>();

const filmstripRef = ref<HTMLElement | null>(null);
const thumbFailed = ref<Record<number, boolean>>({});

function markFailed(id: number) {
  if (!thumbFailed.value[id]) {
    thumbFailed.value = { ...thumbFailed.value, [id]: true };
  }
}

const filmstripWindow = computed(() => {
  const list = props.assets;
  if (list.length <= 1) return [] as Array<{ asset: BatchAsset; index: number }>;
  const start = Math.max(0, props.selectedIndex - 18);
  const end = Math.min(list.length, props.selectedIndex + 19);
  const items: Array<{ asset: BatchAsset; index: number }> = [];
  for (let i = start; i < end; i += 1) {
    items.push({ asset: list[i], index: i });
  }
  return items;
});

watch(
  () => props.selectedIndex,
  async (idx) => {
    if (idx < 0 || !props.visible) return;
    await nextTick();
    const strip = filmstripRef.value;
    if (!strip) return;
    const activeThumb = strip.querySelector<HTMLElement>(`[data-film-index="${idx}"]`);
    const reduced = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    activeThumb?.scrollIntoView({ inline: "center", block: "nearest", behavior: reduced ? "auto" : "smooth" });
  },
);

watch(
  () => props.visible,
  (isVisible) => {
    if (!isVisible) thumbFailed.value = {};
  },
);
</script>

<template>
  <nav v-if="filmstripWindow.length" ref="filmstripRef" class="viewer-filmstrip" aria-label="相邻照片胶片缩略图导航">
    <button
      v-for="item in filmstripWindow"
      :key="item.asset.id"
      type="button"
      class="viewer-filmstrip-thumb"
      :class="{ active: item.index === selectedIndex }"
      :data-film-index="item.index"
      :aria-current="item.index === selectedIndex ? 'true' : undefined"
      :title="item.asset.name"
      @click="emit('select', item.index)"
    >
      <img
        v-if="thumbFor(item.asset) && !thumbFailed[item.asset.id]"
        :src="thumbFor(item.asset)"
        :alt="item.asset.name"
        loading="lazy"
        decoding="async"
        @error="markFailed(item.asset.id)"
      />
      <span v-else class="viewer-filmstrip-fallback">
        <Film v-if="item.asset.type === 'video'" :size="15" />
        <Images v-else :size="15" />
      </span>
      <span v-if="item.asset.type === 'video'" class="viewer-filmstrip-badge">
        <Film :size="9" />
        <template v-if="(item.asset.durationSeconds ?? 0) > 0">{{ formatDuration(item.asset.durationSeconds!) }}</template>
      </span>
      <span v-else-if="(item.asset.liveVideoAssetId ?? 0) > 0" class="viewer-filmstrip-badge">实况</span>
    </button>
  </nav>
</template>

<style scoped>
.viewer-filmstrip {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 14px 4px;
  overflow-x: auto;
  scrollbar-width: none;
}
.viewer-filmstrip::-webkit-scrollbar {
  display: none;
}
.viewer-filmstrip-thumb {
  position: relative;
  flex: 0 0 auto;
  width: 46px;
  height: 46px;
  padding: 0;
  border-radius: 8px;
  overflow: hidden;
  border: 2px solid transparent;
  background: rgba(255, 255, 255, 0.06);
  opacity: 0.64;
  cursor: pointer;
  transition: transform 0.2s cubic-bezier(0.22, 1, 0.36, 1), opacity 0.16s ease, border-color 0.16s ease;
}
.viewer-filmstrip-thumb:hover {
  opacity: 0.94;
}
.viewer-filmstrip-thumb.active {
  opacity: 1;
  border-color: var(--accent-primary);
  transform: scale(1.07);
}
.viewer-filmstrip-thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.viewer-filmstrip-fallback {
  width: 100%;
  height: 100%;
  display: grid;
  place-items: center;
  color: rgba(255, 255, 255, 0.72);
}
.viewer-filmstrip-badge {
  position: absolute;
  right: 2px;
  bottom: 2px;
  display: inline-flex;
  align-items: center;
  gap: 2px;
  padding: 1px 4px;
  border-radius: 4px;
  background: rgba(0, 0, 0, 0.72);
  color: #fff;
  font-size: 9px;
  font-weight: 650;
  font-variant-numeric: tabular-nums;
  line-height: 1.2;
}
@media (prefers-reduced-motion: reduce) {
  .viewer-filmstrip-thumb {
    transition: none;
  }
}
</style>
