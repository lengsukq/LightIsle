<script setup lang="ts">
import { computed, ref, watch, type Component } from "vue";
import { LogOut, Moon, MoreHorizontal, Sun, X } from "lucide-vue-next";
import type { ShellPage } from "../../utils/shellRouteGuard.ts";
import type { Theme, ThemePresetId, ThemePresetMeta } from "../../styles/theme.ts";
import { useSlidingIndicator } from "../../composables/useSlidingIndicator.ts";

export interface NavItemDef {
  key: ShellPage;
  title: string;
  shortTitle: string;
  icon: Component;
  color: string;
  group: string;
}

const props = defineProps<{
  items: NavItemDef[];
  active: ShellPage;
  moreMenuOpen: boolean;
  showComputerFilesNav: boolean;
  isAdmin: boolean;
  atmosphere: ThemePresetId;
  atmospheres: ReadonlyArray<ThemePresetMeta>;
  theme: Theme;
}>();

const emit = defineEmits<{
  (e: "select-page", page: ShellPage): void;
  (e: "toggle-more", open: boolean): void;
  (e: "select-atmosphere", id: ThemePresetId): void;
  (e: "switch-theme"): void;
  (e: "logout"): void;
}>();

const primaryKeys: ShellPage[] = ["overview", "files", "photos", "cinema"];
const overflowKeys: ShellPage[] = ["computer", "downloads", "apps", "settings"];

const mobileNavRef = ref<HTMLElement | null>(null);
const { indicatorStyle, indicatorReady } = useSlidingIndicator({
  containerRef: mobileNavRef,
  activeSelector: "button.chosen",
  watchSources: [() => props.active, () => props.moreMenuOpen, () => props.showComputerFilesNav],
});

const sheetDragY = ref(0);
const sheetDragging = ref(false);
let sheetDragStartY = 0;
let sheetDragStartAt = 0;
let sheetPointerId: number | null = null;

function onSheetPointerDown(e: PointerEvent) {
  const target = e.target as HTMLElement | null;
  if (target && !target.closest(".mobile-more-grabber") && target.closest("button, a, input")) {
    return;
  }
  sheetDragging.value = true;
  sheetDragStartY = e.clientY;
  sheetDragStartAt = performance.now();
  sheetPointerId = e.pointerId;
  try {
    (e.currentTarget as HTMLElement | null)?.setPointerCapture?.(e.pointerId);
  } catch {
    // Ignore pointer capture error on headless browsers.
  }
}

function onSheetPointerMove(e: PointerEvent) {
  if (!sheetDragging.value || e.pointerId !== sheetPointerId) return;
  const delta = e.clientY - sheetDragStartY;
  sheetDragY.value = delta < 0 ? Math.max(-14, delta * 0.14) : delta;
}

function onSheetPointerUp(e: PointerEvent) {
  if (!sheetDragging.value || e.pointerId !== sheetPointerId) return;
  const dy = Math.max(0, sheetDragY.value);
  const dt = Math.max(16, performance.now() - sheetDragStartAt);
  const velocity = dy / dt;
  sheetDragging.value = false;
  sheetPointerId = null;
  sheetDragY.value = 0;
  if (dy > 84 || (dy > 40 && velocity > 0.42)) {
    emit("toggle-more", false);
  }
}

const moreSheetStyle = computed<Record<string, string> | undefined>(() => {
  if (!sheetDragging.value && sheetDragY.value === 0) return undefined;
  return {
    transform: `translate3d(0, ${Math.round(sheetDragY.value)}px, 0)`,
    transition: sheetDragging.value ? "none" : "transform 0.28s cubic-bezier(0.2, 0.9, 0.22, 1.05)",
  };
});

watch(() => props.moreMenuOpen, () => {
  sheetDragY.value = 0;
  sheetDragging.value = false;
  sheetPointerId = null;
});

function visibleOverflowItems() {
  return props.items.filter(
    (item) =>
      overflowKeys.includes(item.key) &&
      (item.key !== "computer" || props.showComputerFilesNav),
  );
}
</script>

<template>
  <Transition name="mobile-drawer">
    <div v-if="moreMenuOpen" class="mobile-more-backdrop" @click.self="emit('toggle-more', false)">
      <div
        class="mobile-more-sheet glass"
        :style="moreSheetStyle"
        role="dialog"
        aria-modal="true"
        aria-label="更多功能与设置"
      >
        <div
          class="mobile-more-grabber"
          aria-hidden="true"
          @pointerdown="onSheetPointerDown"
          @pointermove="onSheetPointerMove"
          @pointerup="onSheetPointerUp"
          @pointercancel="onSheetPointerUp"
        >
          <span class="mobile-more-grabber-pill"></span>
        </div>
        <div
          class="mobile-more-head"
          @pointerdown="onSheetPointerDown"
          @pointermove="onSheetPointerMove"
          @pointerup="onSheetPointerUp"
          @pointercancel="onSheetPointerUp"
        >
          <strong>更多空间与设置</strong>
          <button type="button" class="circle-action" aria-label="关闭菜单" @click="emit('toggle-more', false)">
            <X :size="16" />
          </button>
        </div>
        <div class="mobile-more-grid">
          <button
            v-for="item in visibleOverflowItems()"
            :key="item.key"
            type="button"
            class="mobile-more-item"
            :class="{ chosen: active === item.key }"
            @click="emit('select-page', item.key); emit('toggle-more', false)"
          >
            <span class="nav-icon-box" :data-color="item.color"><component :is="item.icon" :size="18" /></span>
            <span>{{ item.title }}</span>
          </button>
        </div>
        <div class="mobile-theme-strip" role="radiogroup" aria-label="主题风格">
          <button
            v-for="preset in atmospheres"
            :key="preset.id"
            type="button"
            role="radio"
            :aria-checked="preset.id === atmosphere"
            class="mobile-theme-chip"
            :class="{ chosen: preset.id === atmosphere }"
            @click="emit('select-atmosphere', preset.id)"
          >
            <span class="mobile-theme-dots" aria-hidden="true">
              <span
                v-for="(hex, idx) in preset.swatches[theme].slice(2)"
                :key="idx"
                :style="{ background: hex }"
              />
            </span>
            <span>{{ preset.name }}</span>
          </button>
        </div>
        <div class="mobile-more-footer">
          <button type="button" class="mobile-more-action" @click="emit('switch-theme')">
            <Sun v-if="theme === 'dark'" :size="15" />
            <Moon v-else :size="15" />
            <span>{{ theme === "dark" ? "浅色模式" : "深色模式" }}</span>
          </button>
          <button type="button" class="mobile-more-action danger" @click="emit('toggle-more', false); emit('logout')">
            <LogOut :size="15" />
            <span>退出登录</span>
          </button>
        </div>
      </div>
    </div>
  </Transition>
  <nav ref="mobileNavRef" class="mobile-nav glass" aria-label="移动导航">
    <span
      class="mobile-nav-indicator"
      :class="{ 'is-ready': indicatorReady }"
      :style="indicatorStyle"
      aria-hidden="true"
    ></span>
    <button
      v-for="item in items.filter(i => primaryKeys.includes(i.key))"
      :key="item.key"
      type="button"
      :class="{ chosen: active === item.key && !moreMenuOpen }"
      :aria-label="item.title"
      @click="emit('select-page', item.key); emit('toggle-more', false)"
    >
      <component :is="item.icon" :size="20" />
      <span>{{ item.shortTitle }}</span>
    </button>
    <button
      type="button"
      :class="{ chosen: moreMenuOpen || overflowKeys.includes(active) }"
      aria-label="更多与设置"
      @click="emit('toggle-more', !moreMenuOpen)"
    >
      <MoreHorizontal :size="20" />
      <span>{{ overflowKeys.includes(active) ? items.find(i => i.key === active)?.shortTitle : "更多" }}</span>
    </button>
  </nav>
</template>

<style scoped>
.mobile-more-grabber {
  display: flex;
  justify-content: center;
  padding: 2px 0 8px;
  touch-action: none;
  cursor: grab;
}

.mobile-more-grabber-pill {
  width: 36px;
  height: 4px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--text-tertiary) 36%, transparent);
}

.mobile-more-head {
  touch-action: none;
}

.mobile-nav-indicator {
  position: absolute;
  left: 0;
  top: 0;
  border-radius: 18px;
  background: color-mix(in srgb, var(--fluid-card-top) 92%, transparent);
  border: 1px solid var(--fluid-card-border);
  box-shadow: 0 2px 8px color-mix(in srgb, var(--text-primary) 10%, transparent);
  pointer-events: none;
  z-index: 0;
}

.mobile-nav-indicator.is-ready {
  transition:
    transform 0.34s var(--motion-spring-snappy, cubic-bezier(0.2, 0.9, 0.22, 1.05)),
    width 0.28s var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    opacity 0.16s ease;
}

.mobile-theme-strip {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-bottom: 0;
}

.mobile-theme-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-height: 36px;
  padding: 6px 11px;
  border-radius: var(--radius-pill, 999px);
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-secondary);
  font-size: 11.5px;
  font-weight: 600;
}

.mobile-theme-chip.chosen {
  border-color: var(--accent-primary);
  background: var(--accent-muted);
  color: var(--accent-primary);
}

.mobile-theme-dots {
  display: inline-flex;
  align-items: center;
  gap: 2px;
}

.mobile-theme-dots span {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  border: 1px solid rgba(128, 128, 128, 0.25);
}

@media (prefers-reduced-motion: reduce) {
  .mobile-nav-indicator.is-ready {
    transition: none;
  }
}
</style>
