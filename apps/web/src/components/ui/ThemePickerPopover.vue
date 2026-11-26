<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import { Check, Moon, Sun } from "lucide-vue-next";
import { pushModalLayer, type ModalLayerHandle } from "../../utils/modalStack.ts";
import type { Theme, ThemePresetId, ThemePresetMeta } from "../../styles/theme.ts";

const props = defineProps<{
  theme: Theme;
  preset: ThemePresetId;
  presets: ReadonlyArray<ThemePresetMeta>;
}>();

const emit = defineEmits<{
  (e: "select-preset", id: ThemePresetId): void;
  (e: "switch-theme"): void;
}>();

const open = ref(false);
const triggerEl = ref<HTMLButtonElement | null>(null);
const popoverEl = ref<HTMLElement | null>(null);
const popoverStyle = ref<Record<string, string | number>>({
  position: "fixed",
  top: "64px",
  right: "12px",
  zIndex: 99999,
});
let escLayer: ModalLayerHandle | null = null;
let rafId: number | null = null;

const activePreset = computed(
  () => props.presets.find((item) => item.id === props.preset) ?? props.presets[0],
);

function updatePosition() {
  if (!open.value || !triggerEl.value || typeof window === "undefined") return;
  const rect = triggerEl.value.getBoundingClientRect();
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const width = Math.min(336, vw - 24);
  let left = rect.right - width;
  if (left < 12) left = 12;
  if (left + width > vw - 12) left = Math.max(12, vw - width - 12);
  const top = Math.min(Math.max(12, rect.bottom + 10), Math.max(12, vh - 120));
  popoverStyle.value = {
    position: "fixed",
    top: `${Math.round(top)}px`,
    left: `${Math.round(left)}px`,
    width: `${Math.round(width)}px`,
    maxHeight: `${Math.max(180, Math.round(vh - top - 14))}px`,
    zIndex: 99999,
  };
}

function closePopover(restoreFocus = false) {
  if (!open.value) return;
  open.value = false;
  if (restoreFocus) {
    void nextTick(() => triggerEl.value?.focus());
  }
}

function selectPreset(id: ThemePresetId) {
  emit("select-preset", id);
  closePopover(true);
}

function handlePointerDown(event: PointerEvent) {
  if (!open.value) return;
  const target = event.target as Node | null;
  if (triggerEl.value?.contains(target) || popoverEl.value?.contains(target)) return;
  closePopover(false);
}

function schedulePosition() {
  if (!open.value || rafId !== null) return;
  rafId = window.requestAnimationFrame(() => {
    rafId = null;
    updatePosition();
  });
}

function onPopoverKeydown(event: KeyboardEvent) {
  if (!popoverEl.value) return;
  const items = Array.from(
    popoverEl.value.querySelectorAll<HTMLElement>('button[role="menuitemradio"]:not([disabled])'),
  );
  if (!items.length) return;
  const idx = items.indexOf(document.activeElement as HTMLElement);
  if (event.key === "ArrowDown") {
    event.preventDefault();
    items[(idx + 1 + items.length) % items.length].focus();
  } else if (event.key === "ArrowUp") {
    event.preventDefault();
    items[(idx <= 0 ? items.length - 1 : idx - 1)].focus();
  } else if (event.key === "Home") {
    event.preventDefault();
    items[0].focus();
  } else if (event.key === "End") {
    event.preventDefault();
    items[items.length - 1].focus();
  }
}

watch(open, (isOpen) => {
  escLayer?.dispose();
  escLayer = null;
  if (isOpen) {
    escLayer = pushModalLayer({
      onEsc: () => closePopover(true),
      lockScroll: false,
    });
    updatePosition();
    void nextTick(updatePosition);
  } else if (rafId !== null) {
    window.cancelAnimationFrame(rafId);
    rafId = null;
  }
});

onMounted(() => {
  window.addEventListener("pointerdown", handlePointerDown, true);
  window.addEventListener("resize", schedulePosition, { passive: true });
  window.addEventListener("scroll", schedulePosition, { capture: true, passive: true });
});

onUnmounted(() => {
  escLayer?.dispose();
  escLayer = null;
  if (rafId !== null) window.cancelAnimationFrame(rafId);
  window.removeEventListener("pointerdown", handlePointerDown, true);
  window.removeEventListener("resize", schedulePosition);
  window.removeEventListener("scroll", schedulePosition, { capture: true });
});
</script>

<template>
  <div class="theme-picker-root">
    <button
      ref="triggerEl"
      class="atmosphere-capsule"
      type="button"
      :aria-expanded="open"
      aria-haspopup="menu"
      :aria-label="'切换主题风格，当前：' + (activePreset?.name ?? '温润画廊')"
      :title="'切换主题风格（当前：' + (activePreset?.name ?? '温润画廊') + '）'"
      @click="open = !open"
    >
      <span class="atmosphere-swatch" aria-hidden="true">
        <span :style="{ background: activePreset?.swatches[theme][2] }" />
        <span :style="{ background: activePreset?.swatches[theme][3] }" />
      </span>
      <span class="atmosphere-text">{{ activePreset?.name }}</span>
    </button>

    <Teleport to="body">
      <Transition name="isle-pop">
        <div
          v-if="open"
          ref="popoverEl"
          class="theme-picker-popover"
          :style="popoverStyle"
          role="menu"
          aria-label="选择主题风格"
          @keydown="onPopoverKeydown"
        >
        <div class="theme-picker-head">
          <div>
            <strong>界面氛围</strong>
            <small>5 套空间主题与外观切换</small>
          </div>
          <button
            type="button"
            class="theme-mode-pill"
            @click="emit('switch-theme')"
          >
            <Sun v-if="theme === 'dark'" :size="13" />
            <Moon v-else :size="13" />
            <span>{{ theme === "dark" ? "浅色" : "深色" }}</span>
          </button>
        </div>

        <div class="theme-picker-list">
          <button
            v-for="item in presets"
            :key="item.id"
            type="button"
            role="menuitemradio"
            :aria-checked="item.id === preset"
            class="theme-preset-option"
            :class="{ 'is-active': item.id === preset }"
            @click="selectPreset(item.id)"
          >
            <span class="theme-preset-swatches" aria-hidden="true">
              <span
                v-for="(hex, idx) in item.swatches[theme]"
                :key="idx"
                class="theme-swatch-dot"
                :style="{ background: hex }"
              />
            </span>
            <span class="theme-preset-copy">
              <span class="theme-preset-title">
                <span>{{ item.name }}</span>
                <span v-if="item.id === 'warm_gallery'" class="theme-preset-badge">{{ item.badge }}</span>
              </span>
              <small>{{ item.tagline }}</small>
            </span>
            <Check
              v-if="item.id === preset"
              :size="15"
              class="theme-preset-check"
            />
          </button>
        </div>
      </div>
      </Transition>
    </Teleport>
  </div>
</template>

<style scoped>
.theme-picker-root {
  position: relative;
  display: inline-flex;
  align-items: center;
}

.atmosphere-swatch {
  display: inline-flex;
  align-items: center;
  flex-shrink: 0;
}

.atmosphere-swatch > span {
  width: 9px;
  height: 9px;
  border-radius: 50%;
  border: 1px solid rgba(128, 128, 128, 0.25);
}

.atmosphere-swatch > span + span {
  margin-left: -3px;
}

.theme-picker-popover {
  box-sizing: border-box;
  overflow-y: auto;
  padding: 13px;
  border-radius: var(--radius-lg, 18px);
  background: color-mix(in srgb, var(--surface-glass, rgba(252, 251, 249, 0.84)) 86%, var(--surface-elevated, #ffffff) 14%);
  -webkit-backdrop-filter: blur(26px) saturate(170%);
  backdrop-filter: blur(26px) saturate(170%);
  border: var(--theme-border-width, 1px) solid var(--fluid-card-border-strong, var(--stroke-strong));
  box-shadow: var(--shadow-float, 0 20px 44px rgba(0, 0, 0, 0.16)), var(--fluid-card-rim, inset 0 1px 0 rgba(255, 255, 255, 0.72));
  transform-origin: top right;
  z-index: var(--z-dropdown, 99999);
}

.isle-pop-enter-active {
  transition:
    opacity 190ms cubic-bezier(0.22, 1, 0.36, 1),
    transform 230ms var(--motion-spring-snappy, cubic-bezier(0.2, 0.9, 0.22, 1.05));
}
.isle-pop-leave-active {
  transition:
    opacity 130ms var(--motion-exit, cubic-bezier(0.32, 0, 0.67, 0)),
    transform 130ms var(--motion-exit, cubic-bezier(0.32, 0, 0.67, 0));
}
.isle-pop-enter-from {
  opacity: 0;
  transform: scale(0.94) translate3d(0, -6px, 0);
}
.isle-pop-leave-to {
  opacity: 0;
  transform: scale(0.97) translate3d(0, -3px, 0);
}

@media (prefers-reduced-transparency: reduce) {
  .theme-picker-popover {
    backdrop-filter: none;
    -webkit-backdrop-filter: none;
    background: var(--surface-elevated);
  }
}

.theme-picker-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 2px 3px 11px;
  margin-bottom: 8px;
  border-bottom: 1px solid var(--fluid-divider, var(--stroke-subtle));
}

.theme-picker-head strong {
  display: block;
  font-size: 13.5px;
  font-weight: 700;
  letter-spacing: -0.015em;
  color: var(--text-primary);
}

.theme-picker-head small {
  display: block;
  font-size: 11px;
  color: var(--text-tertiary);
  margin-top: 1px;
}

.theme-mode-pill {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  height: 28px;
  padding: 0 11px;
  border-radius: var(--radius-pill, 999px);
  border: 1px solid var(--fluid-card-border, var(--stroke-subtle));
  background: var(--fluid-card-item-fill, var(--surface-base));
  color: var(--text-primary);
  font-size: 11.5px;
  font-weight: 600;
  flex-shrink: 0;
}

.theme-mode-pill:hover {
  border-color: var(--accent-primary);
  color: var(--accent-primary);
}

.theme-picker-list {
  display: flex;
  flex-direction: column;
  gap: 5px;
}

.theme-preset-option {
  display: flex;
  align-items: center;
  gap: 11px;
  width: 100%;
  padding: 9px 10px;
  text-align: left;
  border-radius: var(--radius-md, 12px);
  border: 1px solid transparent;
  background: transparent;
  color: var(--text-primary);
  transition: background var(--motion-fast, 160ms) ease, border-color var(--motion-fast, 160ms) ease;
}

.theme-preset-option:hover {
  background: var(--fluid-card-hover, var(--accent-muted));
  border-color: var(--fluid-card-border, var(--stroke-subtle));
}

.theme-preset-option.is-active {
  background: var(--accent-muted);
  border-color: color-mix(in srgb, var(--accent-primary) 55%, transparent);
}

.theme-preset-swatches {
  display: grid;
  grid-template-columns: repeat(2, 13px);
  gap: 3px;
  padding: 4px;
  border-radius: var(--radius-sm, 8px);
  background: var(--surface-base);
  border: 1px solid var(--fluid-card-border, var(--stroke-subtle));
  flex-shrink: 0;
}

.theme-swatch-dot {
  width: 13px;
  height: 13px;
  border-radius: 4px;
  border: 1px solid rgba(128, 128, 128, 0.22);
}

.theme-preset-copy {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.theme-preset-title {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 13px;
  font-weight: 650;
  letter-spacing: -0.01em;
  color: var(--text-primary);
}

.theme-preset-badge {
  font-size: 10px;
  font-weight: 650;
  padding: 1px 6.5px;
  border-radius: var(--radius-pill, 999px);
  background: var(--accent-muted);
  color: var(--accent-primary);
}

.theme-preset-copy small {
  font-size: 11px;
  color: var(--text-secondary);
  line-height: 1.38;
}

.theme-preset-check {
  color: var(--accent-primary);
  flex-shrink: 0;
}

@media (prefers-reduced-motion: reduce) {
  .theme-preset-option,
  .isle-pop-enter-active,
  .isle-pop-leave-active {
    transition: none;
  }
}
</style>
