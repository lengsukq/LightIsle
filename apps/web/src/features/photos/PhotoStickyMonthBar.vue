<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from "vue";
import { ArrowUp, Calendar, Check, ChevronDown } from "lucide-vue-next";
import type { TimelineYearEntry } from "./photoTimelineJump.ts";

export interface StickyMonthGroup {
  startIndex: number;
  top: number;
  title: string;
  count: number;
}

const props = defineProps<{
  visible: boolean;
  group: StickyMonthGroup | null;
  selected: boolean;
  busy: boolean;
  hasMore: boolean;
  timelineYears: TimelineYearEntry[];
  jumpYear: number;
  jumpMonth: number;
}>();

const emit = defineEmits<{
  (e: "toggle-month", group: StickyMonthGroup): void;
  (e: "jump-month", year: number, month: number): void;
  (e: "scroll-top"): void;
}>();

const menuOpen = ref(false);
const containerRef = ref<HTMLElement | null>(null);

function handlePointerDown(event: PointerEvent) {
  if (!menuOpen.value) return;
  if (event.target instanceof Node && !containerRef.value?.contains(event.target)) {
    menuOpen.value = false;
  }
}

function handleKeydown(event: KeyboardEvent) {
  if (event.key === "Escape" && menuOpen.value) {
    event.stopPropagation();
    menuOpen.value = false;
  }
}

function pickMonth(year: number, month: number) {
  menuOpen.value = false;
  emit("jump-month", year, month);
}

onMounted(() => {
  document.addEventListener("pointerdown", handlePointerDown, true);
  document.addEventListener("keydown", handleKeydown);
});

onBeforeUnmount(() => {
  document.removeEventListener("pointerdown", handlePointerDown, true);
  document.removeEventListener("keydown", handleKeydown);
});
</script>

<template>
  <Transition name="photo-sticky-fade">
    <div v-if="visible && group" ref="containerRef" class="photo-sticky-month-wrap">
      <div class="photo-sticky-month-bar" role="region" aria-label="当前浏览月份">
        <button
          type="button"
          class="photo-sticky-month-trigger"
          :disabled="!timelineYears.length"
          :aria-expanded="timelineYears.length ? menuOpen : undefined"
          title="点击切换年月"
          @click="timelineYears.length && (menuOpen = !menuOpen)"
        >
          <Calendar :size="13" />
          <span class="photo-sticky-month-title">{{ group.title }}</span>
          <small class="photo-sticky-month-count">{{ group.count }} 项<span v-if="hasMore"> · 已加载</span></small>
          <ChevronDown v-if="timelineYears.length" :size="13" class="photo-sticky-chevron" :class="{ open: menuOpen }" />
        </button>

        <div class="photo-sticky-actions">
          <button
            type="button"
            class="photo-sticky-btn"
            :class="{ chosen: selected }"
            :disabled="busy"
            @click="emit('toggle-month', group)"
          >
            <Check :size="12" />
            <span>{{ selected ? "已选当月" : "全选当月" }}</span>
          </button>
          <button type="button" class="photo-sticky-btn" title="回到最新照片" @click="emit('scroll-top')">
            <ArrowUp :size="12" />
            <span>最新</span>
          </button>
        </div>
      </div>

      <div v-if="menuOpen && timelineYears.length" class="photo-sticky-jump-popover" role="menu" aria-label="按年月快速跳转">
        <div v-for="yr in timelineYears" :key="yr.year" class="photo-sticky-year-block">
          <div class="photo-sticky-year-head">
            <strong>{{ yr.year }} 年</strong>
            <span>{{ yr.count }} 项</span>
          </div>
          <div class="photo-sticky-months-grid">
            <button
              v-for="mo in yr.months"
              :key="yr.year + '-' + mo.month"
              type="button"
              class="photo-sticky-month-chip"
              :class="{ active: jumpYear === yr.year && jumpMonth === mo.month }"
              @click="pickMonth(yr.year, mo.month)"
            >
              <span>{{ mo.month }}月</span>
              <small>{{ mo.count }}</small>
            </button>
          </div>
        </div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.photo-sticky-month-wrap {
  position: sticky;
  top: 62px;
  z-index: 22;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  margin: 0 0 8px;
  pointer-events: none;
}
.photo-sticky-month-bar {
  pointer-events: auto;
  display: inline-flex;
  align-items: center;
  gap: 8px;
  max-width: min(100%, 540px);
  padding: 5px 6px 5px 12px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border-strong, var(--fluid-card-border));
  background: color-mix(in srgb, var(--surface-glass, var(--surface-elevated)) 84%, transparent);
  -webkit-backdrop-filter: blur(22px) saturate(175%);
  backdrop-filter: blur(22px) saturate(175%);
  box-shadow: 0 10px 28px -8px rgba(15, 18, 24, 0.2);
}
.photo-sticky-month-trigger {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  border: 0;
  background: transparent;
  padding: 2px 4px 2px 0;
  color: var(--text-primary);
  font-size: 13px;
  font-weight: 700;
  cursor: pointer;
}
.photo-sticky-month-trigger:disabled {
  cursor: default;
}
.photo-sticky-month-title {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.photo-sticky-month-count {
  font-size: 11.5px;
  font-weight: 550;
  color: var(--text-secondary);
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.photo-sticky-chevron {
  color: var(--text-secondary);
  transition: transform 0.18s ease;
}
.photo-sticky-chevron.open {
  transform: rotate(180deg);
}
.photo-sticky-actions {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  flex-shrink: 0;
}
.photo-sticky-btn {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 4px 9px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: color-mix(in srgb, var(--fluid-card-top) 82%, transparent);
  color: var(--text-secondary);
  font-size: 11.5px;
  font-weight: 600;
  cursor: pointer;
  white-space: nowrap;
  transition: color 0.15s ease, background-color 0.15s ease, transform 0.15s ease;
}
.photo-sticky-btn:hover {
  color: var(--text-primary);
  background: var(--fluid-card-hover);
}
.photo-sticky-btn.chosen {
  background: var(--accent-primary-solid, var(--accent-primary));
  border-color: transparent;
  color: var(--on-accent-primary, #fff);
}
.photo-sticky-jump-popover {
  pointer-events: auto;
  margin-top: 6px;
  width: min(340px, calc(100vw - 32px));
  max-height: min(56vh, 360px);
  overflow-y: auto;
  padding: 10px 12px;
  border-radius: 16px;
  border: 1px solid var(--fluid-card-border-strong, var(--fluid-card-border));
  background: color-mix(in srgb, var(--surface-glass, var(--surface-elevated)) 90%, transparent);
  -webkit-backdrop-filter: blur(24px) saturate(175%);
  backdrop-filter: blur(24px) saturate(175%);
  box-shadow: var(--shadow-float, 0 16px 36px rgba(0, 0, 0, 0.22));
  display: grid;
  gap: 10px;
}
.photo-sticky-year-block {
  display: grid;
  gap: 5px;
}
.photo-sticky-year-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  font-size: 12px;
  font-variant-numeric: tabular-nums;
}
.photo-sticky-year-head strong {
  color: var(--text-primary);
}
.photo-sticky-year-head span {
  font-size: 11px;
  color: var(--text-secondary);
}
.photo-sticky-months-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 5px;
}
.photo-sticky-month-chip {
  display: inline-flex;
  align-items: center;
  justify-content: space-between;
  gap: 4px;
  padding: 5px 8px;
  border-radius: 9px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-primary);
  font-size: 11.5px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  cursor: pointer;
}
.photo-sticky-month-chip:hover {
  border-color: var(--accent-primary);
  color: var(--accent-primary);
}
.photo-sticky-month-chip.active {
  background: var(--accent-primary);
  border-color: transparent;
  color: var(--on-accent-primary, #fff);
}
.photo-sticky-month-chip small {
  font-size: 10.5px;
  opacity: 0.72;
}
.photo-sticky-fade-enter-active,
.photo-sticky-fade-leave-active {
  transition: opacity 0.18s ease, transform 0.2s cubic-bezier(0.22, 1, 0.36, 1);
}
.photo-sticky-fade-enter-from,
.photo-sticky-fade-leave-to {
  opacity: 0;
  transform: translate3d(0, -6px, 0);
}
@media (prefers-reduced-transparency: reduce) {
  .photo-sticky-month-bar,
  .photo-sticky-jump-popover {
    -webkit-backdrop-filter: none;
    backdrop-filter: none;
    background: var(--surface-elevated);
  }
}
@media (prefers-reduced-motion: reduce) {
  .photo-sticky-chevron,
  .photo-sticky-btn,
  .photo-sticky-fade-enter-active,
  .photo-sticky-fade-leave-active {
    transition: none;
  }
}
</style>
