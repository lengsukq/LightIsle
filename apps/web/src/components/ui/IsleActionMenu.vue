<script setup lang="ts">
import { nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import { MoreHorizontal } from "lucide-vue-next";

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

function onGlobalKeydown(event: KeyboardEvent) {
  if (open.value && event.key === "Escape") {
    event.stopPropagation();
    close();
    triggerRef.value?.focus();
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
  if (isOpen) {
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
  border-radius: 13px;
  border: 1px solid var(--fluid-card-border-strong, rgba(34, 29, 23, 0.14));
  background: rgba(255, 253, 249, 0.97);
  -webkit-backdrop-filter: blur(22px) saturate(145%);
  backdrop-filter: blur(22px) saturate(145%);
  box-shadow:
    0 14px 32px -6px rgba(34, 29, 23, 0.16),
    0 3px 8px rgba(34, 29, 23, 0.06);
  display: flex;
  flex-direction: column;
  gap: 2px;
  transform-origin: top right;
}

[data-theme="dark"] .isle-action-popover {
  background: rgba(29, 28, 26, 0.97);
  border-color: rgba(244, 241, 234, 0.14);
  box-shadow:
    0 16px 36px -4px rgba(0, 0, 0, 0.54),
    0 4px 10px rgba(0, 0, 0, 0.28);
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
    transform 180ms cubic-bezier(0.22, 1, 0.36, 1);
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

@media (prefers-reduced-motion: reduce) {
  .isle-action-popover button,
  .isle-action-popover a,
  .isle-menu-pop-enter-active,
  .isle-menu-pop-leave-active {
    transition: none;
  }
}
</style>
