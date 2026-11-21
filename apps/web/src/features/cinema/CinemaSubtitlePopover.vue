<script setup lang="ts">
import { computed, ref } from "vue";
import { Check, ChevronDown, RotateCcw, Subtitles, Upload, X } from "lucide-vue-next";
import { SUBTITLE_SIZE_OPTIONS, type SubtitleSizePreset } from "./cinemaSubtitles.ts";

const props = defineProps<{
  open: boolean;
  caption: string;
  captionPillLabel: string;
  captionOptions: Array<{ value: string | number; label: string }>;
  subtitleSize: SubtitleSizePreset;
  subtitleOffset: number;
  localSubtitleName: string;
  localSubtitleError: string;
}>();

const emit = defineEmits<{
  (e: "toggle"): void;
  (e: "close"): void;
  (e: "select-caption", value: string): void;
  (e: "select-local-file", file: File): void;
  (e: "clear-local-file"): void;
  (e: "update:subtitleSize", size: SubtitleSizePreset): void;
  (e: "adjust-offset", deltaSeconds: number): void;
  (e: "reset-offset"): void;
}>();

const fileInputRef = ref<HTMLInputElement | null>(null);

const offsetLabel = computed(() => {
  const val = Math.round(props.subtitleOffset * 10) / 10;
  if (Math.abs(val) < 0.05) return "0.0s";
  return `${val > 0 ? "+" : ""}${val.toFixed(1)}s`;
});

function pickFile() {
  fileInputRef.value?.click();
}

function onFileSelected(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = "";
  if (file) emit("select-local-file", file);
}
</script>

<template>
  <div class="cinema-menu-anchor">
    <button
      type="button"
      class="cinema-pill-btn"
      :class="{ active: caption !== 'off' || open }"
      title="字幕选择、本地外挂、字号与时间微调"
      :aria-expanded="open"
      @click="emit('toggle')"
    >
      <Subtitles :size="14" />
      <span>{{ captionPillLabel }}</span>
      <ChevronDown :size="13" class="cinema-pill-chevron" />
    </button>

    <input
      ref="fileInputRef"
      type="file"
      accept=".srt,.ass,.ssa,.vtt,text/vtt"
      class="cinema-sr-only"
      aria-label="选择本地字幕文件"
      @change="onFileSelected"
    />

    <div v-if="open" class="cinema-popover-menu cinema-subtitle-popover" role="menu">
      <button
        v-for="opt in captionOptions"
        :key="String(opt.value)"
        type="button"
        class="cinema-popover-item"
        :class="{ selected: String(opt.value) === caption }"
        role="menuitemradio"
        :aria-checked="String(opt.value) === caption"
        @click="emit('select-caption', String(opt.value)); emit('close')"
      >
        <Check :size="14" class="cinema-popover-check" />
        <span>{{ opt.value === "off" ? "关闭字幕" : opt.label }}</span>
      </button>

      <div v-if="localSubtitleName" class="cinema-local-sub-row">
        <button
          type="button"
          class="cinema-popover-item cinema-local-sub-btn"
          :class="{ selected: caption === 'local' }"
          role="menuitemradio"
          :aria-checked="caption === 'local'"
          @click="emit('select-caption', 'local'); emit('close')"
        >
          <Check :size="14" class="cinema-popover-check" />
          <span class="cinema-local-sub-name" :title="localSubtitleName">本地：{{ localSubtitleName }}</span>
        </button>
        <button
          type="button"
          class="cinema-sub-clear-btn"
          title="移除本地字幕"
          aria-label="移除本地字幕"
          @click="emit('clear-local-file')"
        >
          <X :size="13" />
        </button>
      </div>

      <button type="button" class="cinema-popover-item cinema-upload-sub-btn" @click="pickFile">
        <Upload :size="14" />
        <span>{{ localSubtitleName ? "更换本地字幕 (SRT/ASS/VTT)" : "加载本地字幕 (SRT/ASS/VTT)" }}</span>
      </button>

      <p v-if="localSubtitleError" class="cinema-sub-error" role="alert">{{ localSubtitleError }}</p>

      <div class="cinema-popover-divider"></div>

      <div class="cinema-sub-control-row">
        <span class="cinema-sub-control-label">字号</span>
        <div class="cinema-sub-chip-group" role="group" aria-label="字幕字号">
          <button
            v-for="opt in SUBTITLE_SIZE_OPTIONS"
            :key="opt.value"
            type="button"
            class="cinema-sub-chip"
            :class="{ active: subtitleSize === opt.value }"
            @click="emit('update:subtitleSize', opt.value)"
          >
            {{ opt.label }}
          </button>
        </div>
      </div>

      <div class="cinema-sub-control-row">
        <span class="cinema-sub-control-label">时间 {{ offsetLabel }}</span>
        <div class="cinema-sub-chip-group" role="group" aria-label="字幕时间同步">
          <button type="button" class="cinema-sub-chip" title="字幕提前 0.5 秒" @click="emit('adjust-offset', -0.5)">-0.5s</button>
          <button type="button" class="cinema-sub-chip" title="复位时间偏移" @click="emit('reset-offset')"><RotateCcw :size="11" /></button>
          <button type="button" class="cinema-sub-chip" title="字幕延后 0.5 秒" @click="emit('adjust-offset', 0.5)">+0.5s</button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.cinema-sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  border: 0;
}
.cinema-menu-anchor {
  position: relative;
}
.cinema-pill-btn {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  min-height: 30px;
  padding: 0 11px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.14);
  background: rgba(255, 255, 255, 0.09);
  color: rgba(255, 255, 255, 0.9);
  font-size: 12px;
  font-weight: 600;
  white-space: nowrap;
  cursor: pointer;
  transition: background 0.16s ease, border-color 0.16s ease, color 0.16s ease;
}
.cinema-pill-btn:hover {
  background: rgba(255, 255, 255, 0.18);
  color: #fff;
}
.cinema-pill-btn.active {
  background: rgba(229, 9, 20, 0.24);
  border-color: rgba(255, 92, 96, 0.55);
  color: #fff;
}
.cinema-pill-chevron {
  opacity: 0.72;
}
.cinema-subtitle-popover {
  position: absolute;
  right: 0;
  bottom: calc(100% + 10px);
  min-width: 242px;
  max-width: 296px;
  max-height: 340px;
  overflow-y: auto;
  padding: 6px;
  border-radius: 14px;
  background: rgba(22, 26, 36, 0.96);
  border: 1px solid rgba(255, 255, 255, 0.18);
  -webkit-backdrop-filter: blur(24px) saturate(160%);
  backdrop-filter: blur(24px) saturate(160%);
  box-shadow: 0 18px 44px rgba(0, 0, 0, 0.72);
  display: flex;
  flex-direction: column;
  gap: 2px;
  z-index: 20;
}
.cinema-popover-item {
  width: 100%;
  min-height: 32px;
  padding: 6px 10px;
  border-radius: 9px;
  border: 0;
  background: transparent;
  color: rgba(255, 255, 255, 0.86);
  font-size: 12.5px;
  font-weight: 500;
  text-align: left;
  display: flex;
  align-items: center;
  gap: 8px;
  cursor: pointer;
}
.cinema-popover-item:hover {
  background: rgba(255, 255, 255, 0.1);
  color: #fff;
}
.cinema-popover-item.selected {
  color: #fff;
  font-weight: 600;
}
.cinema-popover-check {
  color: transparent;
  flex-shrink: 0;
}
.cinema-popover-item.selected .cinema-popover-check {
  color: #e50914;
}
.cinema-local-sub-row {
  display: flex;
  align-items: center;
  gap: 4px;
}
.cinema-local-sub-btn {
  flex: 1;
  min-width: 0;
}
.cinema-local-sub-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cinema-sub-clear-btn {
  border: 0;
  background: transparent;
  color: rgba(255, 255, 255, 0.65);
  width: 26px;
  height: 26px;
  border-radius: 7px;
  display: grid;
  place-items: center;
  cursor: pointer;
  flex-shrink: 0;
}
.cinema-sub-clear-btn:hover {
  background: rgba(255, 255, 255, 0.14);
  color: #fff;
}
.cinema-upload-sub-btn {
  color: rgba(135, 198, 255, 0.96);
}
.cinema-sub-error {
  margin: 2px 8px;
  font-size: 11px;
  color: #ff8e8e;
}
.cinema-popover-divider {
  height: 1px;
  margin: 4px 6px;
  background: rgba(255, 255, 255, 0.12);
}
.cinema-sub-control-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 5px 8px;
}
.cinema-sub-control-label {
  font-size: 11.5px;
  color: rgba(255, 255, 255, 0.72);
  white-space: nowrap;
}
.cinema-sub-chip-group {
  display: flex;
  align-items: center;
  gap: 4px;
}
.cinema-sub-chip {
  border: 1px solid rgba(255, 255, 255, 0.18);
  background: rgba(255, 255, 255, 0.08);
  color: rgba(255, 255, 255, 0.88);
  border-radius: 7px;
  padding: 3px 8px;
  min-height: 24px;
  font-size: 11.5px;
  font-weight: 600;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
}
.cinema-sub-chip:hover {
  background: rgba(255, 255, 255, 0.18);
  color: #fff;
}
.cinema-sub-chip.active {
  background: #e50914;
  border-color: #e50914;
  color: #fff;
}
@media (prefers-reduced-motion: reduce) {
  .cinema-pill-btn {
    transition: none;
  }
}
</style>
