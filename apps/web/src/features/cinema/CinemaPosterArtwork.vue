<script setup lang="ts">
import { computed } from "vue";
import { Clapperboard, Film, Tv } from "lucide-vue-next";
import { cinemaPosterPalette } from "./cinemaCatalogDisplay.ts";

const props = withDefaults(
  defineProps<{
    title: string;
    kind?: string;
    year?: number;
    seed?: string | number;
    kicker?: string;
    compact?: boolean;
  }>(),
  {
    kind: "movie",
    year: 0,
    seed: "",
    kicker: "",
    compact: false,
  },
);

const palette = computed(() => cinemaPosterPalette(props.seed || props.title));

const monogram = computed(() => {
  const clean = (props.title || "").trim();
  if (!clean) return "L";
  return clean.charAt(0).toUpperCase();
});

const badgeText = computed(() => {
  if (props.kicker) return props.kicker;
  const parts: string[] = [];
  if (props.kind === "series") parts.push("剧集");
  else parts.push("电影");
  if (props.year && props.year > 0) parts.push(String(props.year));
  return parts.join(" · ");
});
</script>

<template>
  <span
    class="cinema-poster-art"
    :class="{ 'is-compact': compact }"
    :style="{
      '--poster-bg': palette.bg,
      '--poster-glow': palette.glow,
      '--poster-accent': palette.accent,
    }"
  >
    <span class="cinema-poster-art-glow" aria-hidden="true"></span>
    <span class="cinema-poster-art-frame" aria-hidden="true"></span>
    <span class="cinema-poster-art-monogram" aria-hidden="true">{{ monogram }}</span>
    <span class="cinema-poster-art-top">
      <Tv v-if="kind === 'series'" :size="compact ? 13 : 15" aria-hidden="true" />
      <Clapperboard v-else-if="kicker" :size="compact ? 13 : 15" aria-hidden="true" />
      <Film v-else :size="compact ? 13 : 15" aria-hidden="true" />
      <span class="cinema-poster-art-kicker">{{ badgeText }}</span>
    </span>
    <span class="cinema-poster-art-body">
      <span class="cinema-poster-art-rule" aria-hidden="true"></span>
      <span class="cinema-poster-art-title">{{ title || "未命名影片" }}</span>
    </span>
  </span>
</template>

<style scoped>
.cinema-poster-art {
  position: relative;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  width: 100%;
  height: 100%;
  padding: 12px;
  box-sizing: border-box;
  background: var(--poster-bg, linear-gradient(155deg, #161c28 0%, #243044 55%, #12151c 100%));
  color: #f6f4ee;
  text-align: left;
  overflow: hidden;
  user-select: none;
}
.cinema-poster-art.is-compact {
  padding: 9px;
}
.cinema-poster-art-glow {
  position: absolute;
  inset: 0;
  background: var(--poster-glow);
  pointer-events: none;
}
.cinema-poster-art-frame {
  position: absolute;
  inset: 6px;
  border-radius: 7px;
  border: 1px solid rgba(255, 255, 255, 0.09);
  pointer-events: none;
}
.cinema-poster-art.is-compact .cinema-poster-art-frame {
  inset: 4px;
  border-radius: 5px;
}
.cinema-poster-art-monogram {
  position: absolute;
  right: -6px;
  top: 50%;
  transform: translateY(-54%);
  font-size: clamp(64px, 8vw, 96px);
  font-weight: 800;
  line-height: 0.9;
  letter-spacing: -0.04em;
  color: rgba(255, 255, 255, 0.055);
  pointer-events: none;
}
.cinema-poster-art.is-compact .cinema-poster-art-monogram {
  font-size: 56px;
}
.cinema-poster-art-top {
  position: relative;
  z-index: 1;
  display: inline-flex;
  align-items: center;
  gap: 5px;
  color: var(--poster-accent, #67d4e0);
  font-size: 10.5px;
  font-weight: 650;
  letter-spacing: 0.03em;
  font-variant-numeric: tabular-nums;
  max-width: 100%;
}
.cinema-poster-art.is-compact .cinema-poster-art-top {
  font-size: 10px;
}
.cinema-poster-art-kicker {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: rgba(246, 244, 238, 0.78);
}
.cinema-poster-art-body {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  gap: 6px;
  min-width: 0;
}
.cinema-poster-art-rule {
  width: 22px;
  height: 2px;
  border-radius: 999px;
  background: var(--poster-accent, #67d4e0);
  opacity: 0.85;
}
.cinema-poster-art.is-compact .cinema-poster-art-rule {
  width: 16px;
}
.cinema-poster-art-title {
  font-size: 13.5px;
  font-weight: 720;
  line-height: 1.28;
  letter-spacing: -0.015em;
  color: #f8f6f0;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 3;
  overflow: hidden;
  overflow-wrap: anywhere;
  text-shadow: 0 2px 10px rgba(0, 0, 0, 0.42);
}
.cinema-poster-art.is-compact .cinema-poster-art-title {
  font-size: 12px;
  -webkit-line-clamp: 2;
}
</style>
