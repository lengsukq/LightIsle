<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { Check, Moon, Sun } from "lucide-vue-next";
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
const rootEl = ref<HTMLElement | null>(null);

const activePreset = computed(
  () => props.presets.find((item) => item.id === props.preset) ?? props.presets[0],
);

function selectPreset(id: ThemePresetId) {
  emit("select-preset", id);
  open.value = false;
}

function handlePointerDown(event: PointerEvent) {
  if (!open.value) return;
  const target = event.target as Node | null;
  if (target && rootEl.value && !rootEl.value.contains(target)) {
    open.value = false;
  }
}

function handleKeydown(event: KeyboardEvent) {
  if (open.value && event.key === "Escape") {
    event.stopPropagation();
    open.value = false;
  }
}

onMounted(() => {
  window.addEventListener("pointerdown", handlePointerDown, true);
  window.addEventListener("keydown", handleKeydown);
});

onUnmounted(() => {
  window.removeEventListener("pointerdown", handlePointerDown, true);
  window.removeEventListener("keydown", handleKeydown);
});
</script>

<template>
  <div ref="rootEl" class="theme-picker-root">
    <button
      class="atmosphere-capsule"
      type="button"
      :aria-expanded="open"
      aria-haspopup="menu"
      :aria-label="'切换主题风格，当前：' + (activePreset?.name ?? '温润画廊')"
      :title="'切换主题风格（当前：' + (activePreset?.name ?? '温润画廊') + '）'"
      @click="open = !open"
    >
      <span class="atmosphere-icon">{{ activePreset?.icon }}</span>
      <span class="atmosphere-text">{{ activePreset?.name }}</span>
    </button>

    <Transition name="isle-overlay-fade">
      <div
        v-if="open"
        class="theme-picker-popover"
        role="menu"
        aria-label="选择主题风格"
      >
        <div class="theme-picker-head">
          <div>
            <strong>主题风格</strong>
            <small>与 Flutter 客户端 5 套主题同步</small>
          </div>
          <button
            type="button"
            class="theme-mode-pill"
            @click="emit('switch-theme')"
          >
            <Sun v-if="theme === 'dark'" :size="13" />
            <Moon v-else :size="13" />
            <span>{{ theme === "dark" ? "切浅色" : "切深色" }}</span>
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
                <span>{{ item.icon }} {{ item.name }}</span>
                <span class="theme-preset-badge">{{ item.badge }}</span>
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
  </div>
</template>

<style scoped>
.theme-picker-root {
  position: relative;
  display: inline-flex;
  align-items: center;
}

.theme-picker-popover {
  position: absolute;
  top: calc(100% + 10px);
  right: 0;
  width: min(336px, calc(100vw - 28px));
  padding: 13px;
  border-radius: var(--radius-lg, 18px);
  background: var(--fluid-card-fill, var(--surface-elevated));
  border: var(--theme-border-width, 1px) solid var(--fluid-card-border-strong, var(--stroke-strong));
  box-shadow: var(--shadow-float, 0 20px 44px rgba(0, 0, 0, 0.16));
  z-index: var(--z-dropdown, 99999);
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
  .theme-preset-option {
    transition: none;
  }
}
</style>
