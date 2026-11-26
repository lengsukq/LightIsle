<script setup lang="ts">
import { nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import { MoreHorizontal } from "lucide-vue-next";
import { pushModalLayer, type ModalLayerHandle } from "../../utils/modalStack.ts";

const props = withDefaults(
  defineProps<{
    label?: string;
    ariaLabel?: string;
    align?: "left" | "right";
    size?: "sm" | "md";
  }>(),
  {
    label: "",
    ariaLabel: "更多操作",
    align: "right",
    size: "sm",
  }
);

const open = ref(false);
const triggerRef = ref<HTMLButtonElement | null>(null);
const menuRef = ref<HTMLElement | null>(null);
const isDroppingUp = ref(false);
let escLayer: ModalLayerHandle | null = null;
const popoverStyle = ref<Record<string, string | number>>({
  position: "fixed",
  top: "0px",
  left: "0px",
  zIndex: 99990,
});

function updatePosition() {
  if (!open.value || !triggerRef.value) return;
  const rect = triggerRef.value.getBoundingClientRect();
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const menuWidth = menuRef.value?.offsetWidth || 196;
  const menuHeight = menuRef.value?.offsetHeight || 132;

  const spaceBelow = vh - rect.bottom - 12;
  const spaceAbove = rect.top - 12;
  const dropUp = spaceBelow < menuHeight && spaceAbove > spaceBelow;
  isDroppingUp.value = dropUp;

  let left = props.align === "left" ? rect.left : rect.right - menuWidth;
  if (left + menuWidth > vw - 12) {
    left = Math.max(12, vw - menuWidth - 12);
  }
  if (left < 12) {
    left = 12;
  }

  const nextStyle: Record<string, string | number> = {
    position: "fixed",
    left: `${Math.round(left)}px`,
    zIndex: 99990,
  };
  if (dropUp) {
    nextStyle.bottom = `${Math.round(vh - rect.top + 6)}px`;
  } else {
    nextStyle.top = `${Math.round(rect.bottom + 6)}px`;
  }
  popoverStyle.value = nextStyle;
}

function toggle() {
  open.value = !open.value;
}

function close() {
  open.value = false;
}

function onPanelClick(event: MouseEvent) {
  const target = event.target as HTMLElement | null;
  if (target?.closest("button, a")) {
    close();
  }
}

function onGlobalPointerDown(event: PointerEvent) {
  if (!open.value) return;
  const target = event.target as Node | null;
  if (triggerRef.value?.contains(target)) return;
  if (menuRef.value?.contains(target)) return;
  close();
}

function focusMenuItem(deltaOrBound: number | "first" | "last") {
  const container = menuRef.value;
  if (!container) return;
  const items = Array.from(
    container.querySelectorAll<HTMLElement>("button:not([disabled]), a[href]"),
  );
  if (!items.length) return;
  if (deltaOrBound === "first") {
    items[0].focus();
    return;
  }
  if (deltaOrBound === "last") {
    items[items.length - 1].focus();
    return;
  }
  const currentIdx = items.indexOf(document.activeElement as HTMLElement);
  const nextIdx =
    currentIdx < 0
      ? deltaOrBound > 0
        ? 0
        : items.length - 1
      : (currentIdx + deltaOrBound + items.length) % items.length;
  items[nextIdx].focus();
}

function onGlobalKeydown(event: KeyboardEvent) {
  if (!open.value) return;
  if (event.key === "Escape") {
    event.stopPropagation();
    close();
    triggerRef.value?.focus();
    return;
  }
  if (event.key === "ArrowDown") {
    event.preventDefault();
    focusMenuItem(1);
  } else if (event.key === "ArrowUp") {
    event.preventDefault();
    focusMenuItem(-1);
  } else if (event.key === "Home") {
    event.preventDefault();
    focusMenuItem("first");
  } else if (event.key === "End") {
    event.preventDefault();
    focusMenuItem("last");
  }
}

let rafId: number | null = null;

function cancelPositionRaf() {
  if (rafId !== null) {
    window.cancelAnimationFrame(rafId);
    rafId = null;
  }
}

function handleScrollOrResize() {
  if (!open.value || rafId !== null) return;
  rafId = window.requestAnimationFrame(() => {
    rafId = null;
    if (!open.value || !triggerRef.value) return;
    const rect = triggerRef.value.getBoundingClientRect();
    if (rect.bottom < 0 || rect.top > window.innerHeight) {
      close();
      return;
    }
    updatePosition();
  });
}

watch(open, (isOpen) => {
  escLayer?.dispose();
  escLayer = null;
  if (isOpen) {
    escLayer = pushModalLayer({
      onEsc: () => {
        close();
        triggerRef.value?.focus();
      },
      lockScroll: false,
    });
    updatePosition();
    nextTick(updatePosition);
  } else {
    cancelPositionRaf();
  }
});

onMounted(() => {
  window.addEventListener("pointerdown", onGlobalPointerDown, true);
  window.addEventListener("keydown", onGlobalKeydown, true);
  window.addEventListener("scroll", handleScrollOrResize, { capture: true, passive: true });
  window.addEventListener("resize", handleScrollOrResize, { passive: true });
});

onUnmounted(() => {
  escLayer?.dispose();
  escLayer = null;
  cancelPositionRaf();
  window.removeEventListener("pointerdown", onGlobalPointerDown, true);
  window.removeEventListener("keydown", onGlobalKeydown, true);
  window.removeEventListener("scroll", handleScrollOrResize, { capture: true });
  window.removeEventListener("resize", handleScrollOrResize);
});

defineExpose({ close });
</script>

<template>
  <div class="isle-action-menu">
    <button
      ref="triggerRef"
      type="button"
      class="isle-action-trigger"
      :class="[`size-${size}`, { 'is-open': open, 'has-label': Boolean(label) }]"
      :title="ariaLabel"
      :aria-label="ariaLabel"
      aria-haspopup="menu"
      :aria-expanded="open"
      @click="toggle"
    >
      <MoreHorizontal :size="size === 'sm' ? 15 : 16" />
      <span v-if="label">{{ label }}</span>
    </button>

    <Teleport to="body">
      <Transition name="isle-menu-pop">
        <div
          v-if="open"
          ref="menuRef"
          class="isle-action-popover"
          :class="[`align-${align}`, { 'drop-up': isDroppingUp }]"
          :style="popoverStyle"
          role="menu"
          @pointerdown.stop
          @click="onPanelClick"
        >
          <slot :close="close" />
        </div>
      </Transition>
    </Teleport>
  </div>
</template>

<style scoped>
.isle-action-menu {
  position: relative;
  display: inline-flex;
  align-items: center;
}

.isle-action-trigger {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  border-radius: 9999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: var(--text-secondary);
  box-shadow: var(--fluid-item-card-shadow);
  font-family: inherit;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  padding: 0;
  transition:
    transform 240ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    background-color 160ms ease,
    border-color 160ms ease,
    color 160ms ease;
}

.isle-action-trigger.size-sm {
  width: 30px;
  height: 30px;
}

.isle-action-trigger.size-md {
  width: 32px;
  height: 32px;
}

.isle-action-trigger.has-label {
  width: auto;
  padding: 0 11px;
}

.isle-action-trigger:hover,
.isle-action-trigger.is-open {
  color: var(--text-primary);
  background: var(--fluid-card-hover);
  border-color: var(--fluid-card-border-strong);
}

.isle-action-trigger:active {
  transform: scale(0.94);
  transition-duration: 95ms;
}

@media (prefers-reduced-motion: reduce) {
  .isle-action-trigger {
    transition: none;
  }
}
</style>

<style>
.isle-action-popover {
  box-sizing: border-box;
  min-width: 184px;
  max-width: min(280px, calc(100vw - 24px));
  padding: 5px;
  border-radius: var(--radius-md, 14px);
  border: 1px solid var(--fluid-card-border-strong, rgba(20, 19, 17, 0.14));
  background: color-mix(in srgb, var(--surface-glass, rgba(252, 251, 249, 0.84)) 86%, var(--surface-elevated, #ffffff) 14%);
  -webkit-backdrop-filter: blur(26px) saturate(170%);
  backdrop-filter: blur(26px) saturate(170%);
  box-shadow: var(--shadow-float, 0 14px 32px -6px rgba(20, 19, 17, 0.16)), var(--fluid-card-rim, inset 0 1px 0 rgba(255, 255, 255, 0.72));
  display: flex;
  flex-direction: column;
  gap: 2px;
  transform-origin: top right;
}

[data-theme="dark"] .isle-action-popover {
  background: color-mix(in srgb, var(--surface-glass, rgba(22, 22, 20, 0.80)) 84%, var(--surface-elevated, #1c1c1a) 16%);
  border-color: var(--fluid-card-border-strong, rgba(244, 241, 234, 0.16));
  box-shadow: var(--shadow-float, 0 16px 36px -4px rgba(0, 0, 0, 0.54)), var(--fluid-card-rim, inset 0 1px 0 rgba(255, 255, 255, 0.08));
}

@media (prefers-reduced-transparency: reduce) {
  .isle-action-popover {
    -webkit-backdrop-filter: none;
    backdrop-filter: none;
    background: var(--surface-elevated, #ffffff);
  }
}

.isle-action-popover.align-left {
  transform-origin: top left;
}

.isle-action-popover.drop-up.align-right {
  transform-origin: bottom right;
}

.isle-action-popover.drop-up.align-left {
  transform-origin: bottom left;
}

.isle-action-popover button,
.isle-action-popover a {
  box-sizing: border-box;
  width: 100%;
  min-height: 34px;
  padding: 6px 10px;
  border: 0;
  border-radius: 9px;
  background: transparent;
  box-shadow: none;
  color: var(--text-primary);
  font-family: inherit;
  font-size: 12.5px;
  font-weight: 550;
  text-align: left;
  text-decoration: none;
  display: flex;
  align-items: center;
  justify-content: flex-start;
  gap: 8px;
  cursor: pointer;
  white-space: nowrap;
  transition: background-color 140ms ease, color 140ms ease;
}

.isle-action-popover button:hover:not(:disabled),
.isle-action-popover a:hover {
  background: var(--fluid-card-hover);
  color: var(--accent-primary);
}

.isle-action-popover button.danger {
  color: var(--error);
}

.isle-action-popover button.danger:hover:not(:disabled) {
  background: color-mix(in srgb, var(--error) 10%, transparent);
  color: var(--error);
}

.isle-menu-pop-enter-active {
  transition:
    opacity 180ms cubic-bezier(0.22, 1, 0.36, 1),
    transform 210ms var(--motion-spring-snappy, cubic-bezier(0.2, 0.9, 0.22, 1.05));
}

.isle-menu-pop-leave-active {
  transition:
    opacity 120ms cubic-bezier(0.32, 0, 0.67, 0),
    transform 120ms cubic-bezier(0.32, 0, 0.67, 0);
}

.isle-menu-pop-enter-from {
  opacity: 0;
  transform: scale(0.95) translateY(-5px);
}

.isle-menu-pop-leave-to {
  opacity: 0;
  transform: scale(0.97) translateY(-3px);
}

.isle-action-popover.drop-up.isle-menu-pop-enter-from {
  transform: scale(0.95) translateY(5px);
}

.isle-action-popover.drop-up.isle-menu-pop-leave-to {
  transform: scale(0.97) translateY(3px);
}

@media (prefers-reduced-motion: reduce) {
  .isle-action-popover button,
  .isle-action-popover a,
  .isle-menu-pop-enter-active,
  .isle-menu-pop-leave-active {
    transition: none;
  }
}
</style>
