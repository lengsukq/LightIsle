<script setup lang="ts">
import { AudioLines, Check, ChevronDown } from "lucide-vue-next";
import CinemaSubtitlePopover from "./CinemaSubtitlePopover.vue";
import { formatCinemaClock } from "./cinemaCatalogDisplay.ts";
import type { SubtitleSizePreset } from "./cinemaSubtitles.ts";
import type { ChapterInfo, Movie, TranscodeSession } from "./cinemaTypes.ts";

export type CinemaMenuKind = "caption" | "audio" | "quality" | "rate" | "chapters" | null;

defineProps<{
  openMenu: CinemaMenuKind;
  selected: Movie;
  dockInUpperHalf: boolean;
  displayPosition: number;
  caption: string;
  captionPillLabel: string;
  captionOptions: Array<{ value: string | number; label: string }>;
  subtitleSize: SubtitleSizePreset;
  subtitleOffset: number;
  localSubtitleName: string;
  localSubtitleError: string;
  chapters: ChapterInfo[];
  hlsSession: TranscodeSession | null;
  hlsStarting: boolean;
  audioTrackOptions: Array<{ value: string | number; label: string }>;
  audioPillLabel: string;
  qualityOptions: Array<{ value: string | number; label: string }>;
  currentQuality: string;
  qualityPillLabel: string;
  preferLocalDecode: boolean;
  autoplayNext: boolean;
  playbackRate: number;
  ratePillLabel: string;
  playbackRateOptions: ReadonlyArray<{ value: string | number; label: string }>;
}>();

const emit = defineEmits<{
  (e: "toggle-menu", kind: Exclude<CinemaMenuKind, null>): void;
  (e: "close-menus"): void;
  (e: "select-caption", val: string): void;
  (e: "select-local-subtitle", file: File): void;
  (e: "clear-local-subtitle"): void;
  (e: "update:subtitleSize", size: SubtitleSizePreset): void;
  (e: "adjust-subtitle-offset", delta: number): void;
  (e: "reset-subtitle-offset"): void;
  (e: "seek", pos: number): void;
  (e: "select-audio", index: number): void;
  (e: "select-quality", quality: string): void;
  (e: "toggle-local-decode", checked: boolean): void;
  (e: "toggle-autoplay", checked: boolean): void;
  (e: "select-rate", rate: number): void;
}>();
</script>

<template>
  <CinemaSubtitlePopover
    :open="openMenu === 'caption'"
    :caption="caption"
    :caption-pill-label="captionPillLabel"
    :caption-options="captionOptions"
    :subtitle-size="subtitleSize"
    :subtitle-offset="subtitleOffset"
    :local-subtitle-name="localSubtitleName"
    :local-subtitle-error="localSubtitleError"
    :flip-down="dockInUpperHalf"
    @toggle="emit('toggle-menu', 'caption')"
    @close="emit('close-menus')"
    @select-caption="(val) => emit('select-caption', val)"
    @select-local-file="(file) => emit('select-local-subtitle', file)"
    @clear-local-file="emit('clear-local-subtitle')"
    @update:subtitle-size="(s) => emit('update:subtitleSize', s)"
    @adjust-offset="(d) => emit('adjust-subtitle-offset', d)"
    @reset-offset="emit('reset-subtitle-offset')"
  />

  <div v-if="chapters.length > 0" class="cinema-menu-anchor">
    <button
      type="button"
      class="cinema-pill-btn"
      :class="{ active: openMenu === 'chapters' }"
      title="章节快速跳转"
      :aria-expanded="openMenu === 'chapters'"
      @click="emit('toggle-menu', 'chapters')"
    >
      <span class="cinema-tabular-meta">章节 ({{ chapters.length }})</span>
      <ChevronDown :size="13" class="cinema-pill-chevron" />
    </button>
    <Transition name="isle-pop">
      <div v-if="openMenu === 'chapters'" class="cinema-popover-menu" role="menu">
        <button
          v-for="ch in chapters"
          :key="ch.id"
          type="button"
          class="cinema-popover-item"
          :class="{ selected: displayPosition >= ch.startSeconds && displayPosition < ch.endSeconds }"
          role="menuitem"
          @click="emit('close-menus'); emit('seek', ch.startSeconds)"
        >
          <Check :size="14" class="cinema-popover-check" />
          <span class="cinema-tabular-meta">{{ formatCinemaClock(ch.startSeconds) }} · {{ ch.title || "章节" }}</span>
        </button>
      </div>
    </Transition>
  </div>

  <div v-if="(hlsSession || hlsStarting) && audioTrackOptions.length > 1" class="cinema-menu-anchor">
    <button
      type="button"
      class="cinema-pill-btn"
      :class="{ active: openMenu === 'audio' }"
      title="音轨切换"
      :aria-expanded="openMenu === 'audio'"
      @click="emit('toggle-menu', 'audio')"
    >
      <AudioLines :size="14" />
      <span class="cinema-pill-truncate">{{ audioPillLabel }}</span>
      <ChevronDown :size="13" class="cinema-pill-chevron" />
    </button>
    <Transition name="isle-pop">
      <div v-if="openMenu === 'audio'" class="cinema-popover-menu" role="menu">
        <button
          v-for="opt in audioTrackOptions"
          :key="String(opt.value)"
          type="button"
          class="cinema-popover-item"
          :class="{ selected: Number(opt.value) === (hlsSession?.audioTrack ?? 0) }"
          role="menuitemradio"
          :aria-checked="Number(opt.value) === (hlsSession?.audioTrack ?? 0)"
          @click="emit('close-menus'); emit('select-audio', Number(opt.value))"
        >
          <Check :size="14" class="cinema-popover-check" />
          <span>{{ opt.label }}</span>
        </button>
      </div>
    </Transition>
  </div>

  <div class="cinema-menu-anchor">
    <button
      type="button"
      class="cinema-pill-btn"
      :class="{ active: openMenu === 'quality' }"
      title="清晰度与解码方式"
      :disabled="hlsStarting"
      :aria-expanded="openMenu === 'quality'"
      @click="emit('toggle-menu', 'quality')"
    >
      <span>{{ qualityPillLabel }}</span>
      <ChevronDown :size="13" class="cinema-pill-chevron" />
    </button>
    <Transition name="isle-pop">
      <div v-if="openMenu === 'quality'" class="cinema-popover-menu" role="menu">
        <button
          v-for="opt in qualityOptions"
          :key="String(opt.value)"
          type="button"
          class="cinema-popover-item"
          :class="{ selected: String(opt.value) === currentQuality }"
          role="menuitemradio"
          :aria-checked="String(opt.value) === currentQuality"
          @click="emit('close-menus'); emit('select-quality', String(opt.value))"
        >
          <Check :size="14" class="cinema-popover-check" />
          <span>{{ opt.label }}</span>
        </button>
        <div class="cinema-popover-divider"></div>
        <button
          type="button"
          class="cinema-popover-item"
          :class="{ selected: preferLocalDecode }"
          role="menuitemcheckbox"
          :aria-checked="preferLocalDecode"
          @click="emit('close-menus'); emit('toggle-local-decode', !preferLocalDecode)"
        >
          <Check :size="14" class="cinema-popover-check" />
          <span>默认优先本地硬解</span>
        </button>
        <button
          v-if="selected.path"
          type="button"
          class="cinema-popover-item"
          :class="{ selected: autoplayNext }"
          role="menuitemcheckbox"
          :aria-checked="autoplayNext"
          @click="emit('close-menus'); emit('toggle-autoplay', !autoplayNext)"
        >
          <Check :size="14" class="cinema-popover-check" />
          <span>{{ selected.kind === "series" ? "播完自动下一集" : "播完自动连播" }}</span>
        </button>
      </div>
    </Transition>
  </div>

  <div class="cinema-menu-anchor">
    <button
      type="button"
      class="cinema-pill-btn cinema-tabular-meta"
      :class="{ active: playbackRate !== 1 || openMenu === 'rate' }"
      title="播放倍速"
      :aria-expanded="openMenu === 'rate'"
      @click="emit('toggle-menu', 'rate')"
    >
      <span>{{ ratePillLabel }}</span>
      <ChevronDown :size="13" class="cinema-pill-chevron" />
    </button>
    <Transition name="isle-pop">
      <div v-if="openMenu === 'rate'" class="cinema-popover-menu cinema-popover-menu--narrow" role="menu">
        <button
          v-for="opt in playbackRateOptions"
          :key="String(opt.value)"
          type="button"
          class="cinema-popover-item"
          :class="{ selected: Number(opt.value) === playbackRate }"
          role="menuitemradio"
          :aria-checked="Number(opt.value) === playbackRate"
          @click="emit('close-menus'); emit('select-rate', Number(opt.value))"
        >
          <Check :size="14" class="cinema-popover-check" />
          <span class="cinema-tabular-meta">{{ Number(opt.value) === 1 ? "1.0x（正常）" : opt.label }}</span>
        </button>
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.cinema-popover-menu {
  position: absolute;
  right: 0;
  bottom: calc(100% + 8px);
  min-width: 168px;
  max-width: min(272px, calc(100vw - 24px));
  max-height: min(250px, 46dvh);
  overflow-y: auto;
  touch-action: pan-y;
  transform: translate3d(var(--popover-shift-x, 0px), 0, 0);
  padding: 5px;
  border-radius: 13px;
  background: rgba(18, 19, 22, 0.94);
  border: 1px solid rgba(255, 255, 255, 0.16);
  -webkit-backdrop-filter: blur(22px) saturate(160%);
  backdrop-filter: blur(22px) saturate(160%);
  box-shadow: 0 18px 42px rgba(0, 0, 0, 0.72);
  display: flex;
  flex-direction: column;
  gap: 2px;
  z-index: 20;
}
:global(.cinema-dock--upper) .cinema-popover-menu {
  top: calc(100% + 8px);
  bottom: auto;
}
.cinema-popover-menu--narrow {
  min-width: 132px;
}
.cinema-popover-item {
  width: 100%;
  min-height: 32px;
  padding: 5px 9px;
  border-radius: 8px;
  border: 0;
  background: transparent;
  color: rgba(255, 255, 255, 0.86);
  font-size: 12px;
  font-weight: 500;
  text-align: left;
  display: flex;
  align-items: center;
  gap: 7px;
  cursor: pointer;
  transition: background-color 0.14s ease, color 0.14s ease;
}
.cinema-popover-item:hover {
  background: rgba(255, 255, 255, 0.1);
  color: #fff;
}
.cinema-popover-item.selected {
  background: color-mix(in srgb, var(--accent-primary, #67d4e0) 14%, transparent);
  color: #fff;
  font-weight: 600;
}
.cinema-popover-check {
  color: transparent;
  flex-shrink: 0;
}
.cinema-popover-item.selected .cinema-popover-check {
  color: var(--accent-primary, #67d4e0);
}
.cinema-popover-divider {
  height: 1px;
  margin: 3px 5px;
  background: rgba(255, 255, 255, 0.12);
}
.isle-pop-enter-active {
  transition:
    opacity 0.18s cubic-bezier(0.22, 1, 0.36, 1),
    transform 0.22s var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1));
}
.isle-pop-leave-active {
  transition:
    opacity 0.12s cubic-bezier(0.32, 0, 0.67, 0),
    transform 0.12s cubic-bezier(0.32, 0, 0.67, 0);
}
.isle-pop-enter-from,
.isle-pop-leave-to {
  opacity: 0;
  transform: translate3d(var(--popover-shift-x, 0px), 6px, 0) scale(0.95);
}
:global(.cinema-dock--upper) .isle-pop-enter-from,
:global(.cinema-dock--upper) .isle-pop-leave-to {
  transform: translate3d(var(--popover-shift-x, 0px), -6px, 0) scale(0.95);
}
@media (max-width: 680px) {
  .cinema-menu-anchor {
    position: static;
  }
  .cinema-popover-menu {
    left: 8px;
    right: 8px;
    min-width: 0;
    max-width: calc(100vw - 24px);
    max-height: min(240px, 44dvh);
    transform: translate3d(0, 0, 0);
  }
  .isle-pop-enter-from,
  .isle-pop-leave-to {
    transform: translate3d(0, 6px, 0) scale(0.96);
  }
}
@media (prefers-reduced-motion: reduce) {
  .cinema-popover-item,
  .isle-pop-enter-active,
  .isle-pop-leave-active {
    transition: none;
  }
}
</style>
