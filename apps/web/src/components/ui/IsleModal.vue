<script setup lang="ts">
import { computed, nextTick, onUnmounted, ref, watch } from "vue";
import { X } from "lucide-vue-next";
import { pushModalLayer, type ModalLayerHandle } from "../../utils/modalStack.ts";

const props = withDefaults(
  defineProps<{
    modelValue?: boolean;
    open?: boolean;
    title?: string;
    description?: string;
    size?: "sm" | "md" | "lg" | "wide";
    zIndex?: number | string;
    closeOnBackdrop?: boolean;
    closeOnEsc?: boolean;
    showClose?: boolean;
    role?: string;
  }>(),
  {
    modelValue: undefined,
    open: undefined,
    title: "",
    description: "",
    size: "md",
    zIndex: undefined,
    closeOnBackdrop: true,
    closeOnEsc: true,
    showClose: true,
    role: "dialog",
  }
);

const emit = defineEmits<{
  (e: "close"): void;
  (e: "update:modelValue", val: boolean): void;
  (e: "update:open", val: boolean): void;
}>();

const cardRef = ref<HTMLElement | null>(null);
let layerHandle: ModalLayerHandle | null = null;
let previousFocus: HTMLElement | null = null;

const isOpen = computed(() => {
  if (typeof props.open === "boolean") return props.open;
  if (typeof props.modelValue === "boolean") return props.modelValue;
  return true;
});

function handleClose() {
  emit("close");
  emit("update:modelValue", false);
  emit("update:open", false);
}

function onBackdropClick() {
  if (props.closeOnBackdrop) {
    handleClose();
  }
}

function releaseLayer(restoreFocus = true) {
  if (layerHandle) {
    layerHandle.dispose();
    layerHandle = null;
  }
  if (restoreFocus && previousFocus && typeof previousFocus.focus === "function") {
    const target = previousFocus;
    previousFocus = null;
    if (target.isConnected) {
      void nextTick(() => target.focus());
    }
  } else {
    previousFocus = null;
  }
}

watch(
  isOpen,
  (openState) => {
    if (openState) {
      if (typeof document !== "undefined" && document.activeElement instanceof HTMLElement) {
        previousFocus = document.activeElement;
      }
      layerHandle?.dispose();
      layerHandle = pushModalLayer({
        onEsc: () => {
          if (props.closeOnEsc) {
            handleClose();
          }
        },
        lockScroll: true,
      });
      void nextTick(() => {
        const root = cardRef.value;
        if (!root) return;
        const autoTarget = root.querySelector<HTMLElement>("[autofocus]:not([disabled])");
        if (autoTarget) {
          autoTarget.focus();
        } else {
          root.focus();
        }
      });
    } else {
      releaseLayer(true);
    }
  },
  { immediate: true }
);

onUnmounted(() => {
  releaseLayer(false);
});
</script>

<template>
  <Teleport to="body">
    <Transition name="isle-modal">
      <div
        v-if="isOpen"
        class="isle-modal-backdrop"
        :style="zIndex ? { zIndex: typeof zIndex === 'number' ? zIndex : zIndex } : undefined"
        tabindex="-1"
        @click.self="onBackdropClick"
      >
        <div
          ref="cardRef"
          class="isle-modal-card"
          :class="[`size-${size}`]"
          :role="role"
          aria-modal="true"
          :aria-label="title || undefined"
          tabindex="-1"
        >
          <header v-if="$slots.header || title" class="isle-modal-header">
            <slot name="header">
              <div class="isle-modal-title-wrap">
                <span v-if="$slots.icon" class="isle-modal-icon-badge" aria-hidden="true">
                  <slot name="icon" />
                </span>
                <div class="isle-modal-headings">
                  <h3 class="isle-modal-title">{{ title }}</h3>
                  <p v-if="description" class="isle-modal-desc">{{ description }}</p>
                </div>
              </div>
              <div class="isle-modal-header-actions">
                <slot name="header-actions" />
                <button
                  v-if="showClose"
                  type="button"
                  class="isle-modal-close-btn"
                  title="关闭 (Esc)"
                  aria-label="关闭弹框"
                  @click="handleClose"
                >
                  <X :size="15" />
                </button>
              </div>
            </slot>
          </header>

          <div class="isle-modal-body">
            <slot />
          </div>

          <footer v-if="$slots.footer" class="isle-modal-footer">
            <slot name="footer" />
          </footer>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.isle-modal-backdrop {
  position: fixed;
  inset: 0;
  z-index: var(--z-modal, 1300);
  background: rgba(20, 18, 16, 0.48);
  -webkit-backdrop-filter: blur(12px) saturate(135%);
  backdrop-filter: blur(12px) saturate(135%);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 18px;
}

.isle-modal-card {
  width: 100%;
  max-height: min(88vh, 840px);
  display: flex;
  flex-direction: column;
  background: var(--fluid-card-fill, var(--surface-elevated));
  border: 1px solid var(--fluid-card-border, var(--stroke-glass));
  border-radius: 20px;
  box-shadow: var(--shadow-float, 0 22px 46px rgba(34, 29, 23, 0.2));
  color: var(--text-primary);
  overflow: hidden;
  outline: none;
}

.isle-modal-enter-active {
  transition: opacity 0.24s cubic-bezier(0.22, 1, 0.36, 1);
}
.isle-modal-leave-active {
  transition: opacity 0.15s cubic-bezier(0.32, 0, 0.67, 0);
}
.isle-modal-enter-active .isle-modal-card {
  transition:
    opacity 0.24s cubic-bezier(0.22, 1, 0.36, 1),
    transform 0.26s cubic-bezier(0.22, 1, 0.36, 1);
}
.isle-modal-leave-active .isle-modal-card {
  transition:
    opacity 0.15s cubic-bezier(0.32, 0, 0.67, 0),
    transform 0.15s cubic-bezier(0.32, 0, 0.67, 0);
}
.isle-modal-enter-from,
.isle-modal-leave-to {
  opacity: 0;
}
.isle-modal-enter-from .isle-modal-card {
  opacity: 0;
  transform: translate3d(0, 10px, 0) scale(0.968);
}
.isle-modal-leave-to .isle-modal-card {
  opacity: 0;
  transform: translate3d(0, 6px, 0) scale(0.985);
}

.isle-modal-card.size-sm {
  max-width: 400px;
}
.isle-modal-card.size-md {
  max-width: 520px;
}
.isle-modal-card.size-lg,
.isle-modal-card.size-wide {
  max-width: 720px;
}

.isle-modal-header {
  padding: 14px 18px 12px;
  border-bottom: 1px solid var(--fluid-divider, var(--fluid-card-border));
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-shrink: 0;
}

.isle-modal-title-wrap {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
  flex: 1;
}

.isle-modal-icon-badge {
  width: 30px;
  height: 30px;
  border-radius: 8px;
  background: color-mix(in srgb, var(--accent-primary) 12%, transparent);
  color: var(--accent-primary);
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.isle-modal-headings {
  display: grid;
  gap: 1px;
  min-width: 0;
}

.isle-modal-title {
  margin: 0;
  font-size: 15px;
  font-weight: 650;
  letter-spacing: -0.01em;
  line-height: 1.35;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.isle-modal-desc {
  margin: 0;
  font-size: 12px;
  color: var(--text-secondary);
  line-height: 1.4;
}

.isle-modal-header-actions {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-shrink: 0;
}

.isle-modal-close-btn {
  width: 28px;
  height: 28px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-secondary);
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  transition: background 0.15s ease, color 0.15s ease, transform 0.15s var(--motion-spring);
}
.isle-modal-close-btn:hover {
  background: var(--fluid-card-hover);
  color: var(--text-primary);
}
.isle-modal-close-btn:active {
  transform: scale(0.95);
}

.isle-modal-body {
  padding: 16px 18px;
  min-height: 0;
  overflow-y: auto;
  overflow-x: hidden;
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.isle-modal-footer {
  padding: 12px 18px 14px;
  border-top: 1px solid var(--fluid-divider, var(--fluid-card-border));
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 8px;
  flex-shrink: 0;
}

@media (max-width: 768px) {
  .isle-modal-backdrop {
    padding: 0;
    align-items: flex-end;
  }
  .isle-modal-card {
    max-height: 86vh;
    border-radius: 18px 18px 0 0;
    border-bottom: none;
  }
  .isle-modal-enter-from .isle-modal-card,
  .isle-modal-leave-to .isle-modal-card {
    transform: translate3d(0, 100%, 0);
  }
  .isle-modal-header {
    padding: 14px 16px 10px;
  }
  .isle-modal-body {
    padding: 14px 16px;
  }
  .isle-modal-footer {
    padding: 10px 16px max(14px, env(safe-area-inset-bottom));
  }
}

@media (prefers-reduced-motion: reduce) {
  .isle-modal-enter-active,
  .isle-modal-leave-active,
  .isle-modal-enter-active .isle-modal-card,
  .isle-modal-leave-active .isle-modal-card,
  .isle-modal-close-btn {
    transition: none !important;
  }
  .isle-modal-enter-from .isle-modal-card,
  .isle-modal-leave-to .isle-modal-card {
    transform: none !important;
  }
}
</style>
