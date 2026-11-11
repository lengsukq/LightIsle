<script setup lang="ts">
import { computed, onMounted, onUnmounted } from "vue";
import { X } from "lucide-vue-next";

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

function onKeydown(e: KeyboardEvent) {
  if (!isOpen.value || !props.closeOnEsc) return;
  if (e.key === "Escape") {
    e.preventDefault();
    e.stopPropagation();
    handleClose();
  }
}

onMounted(() => {
  window.addEventListener("keydown", onKeydown);
});

onUnmounted(() => {
  window.removeEventListener("keydown", onKeydown);
});
</script>

<template>
  <Teleport to="body">
    <div
      v-if="isOpen"
      class="isle-modal-backdrop"
      :style="zIndex ? { zIndex: typeof zIndex === 'number' ? zIndex : zIndex } : undefined"
      tabindex="-1"
      @click.self="onBackdropClick"
    >
      <div
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
                <X :size="16" />
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
  </Teleport>
</template>

<style scoped>
.isle-modal-backdrop {
  position: fixed;
  inset: 0;
  z-index: var(--z-modal, 1300);
  background: rgba(12, 16, 28, 0.52);
  -webkit-backdrop-filter: blur(14px) saturate(160%);
  backdrop-filter: blur(14px) saturate(160%);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 20px;
}

.isle-modal-card {
  width: 100%;
  max-height: min(88vh, 860px);
  display: flex;
  flex-direction: column;
  background: var(--fluid-card-fill, var(--surface-elevated));
  border: 1px solid var(--fluid-card-border, var(--stroke-glass));
  border-radius: var(--radius-lg, 22px);
  box-shadow:
    var(--shadow-float, 0 24px 54px rgba(0, 0, 0, 0.28)),
    0 0 0 1px var(--stroke-subtle, rgba(0, 0, 0, 0.05));
  color: var(--text-primary);
  overflow: hidden;
  animation: isleModalZoomIn 0.28s cubic-bezier(0.16, 1, 0.3, 1) both;
}

.isle-modal-card.size-sm {
  max-width: 420px;
}
.isle-modal-card.size-md {
  max-width: 540px;
}
.isle-modal-card.size-lg,
.isle-modal-card.size-wide {
  max-width: 740px;
}

.isle-modal-header {
  padding: 18px 22px 14px;
  border-bottom: 1px solid color-mix(in srgb, var(--fluid-card-border) 45%, transparent);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 14px;
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
  width: 32px;
  height: 32px;
  border-radius: 10px;
  background: color-mix(in srgb, var(--accent-primary) 12%, transparent);
  color: var(--accent-primary);
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.isle-modal-headings {
  display: grid;
  gap: 2px;
  min-width: 0;
}

.isle-modal-title {
  margin: 0;
  font-size: 16px;
  font-weight: 700;
  letter-spacing: -0.2px;
  line-height: 1.35;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.isle-modal-desc {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary);
  line-height: 1.4;
}

.isle-modal-header-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-shrink: 0;
}

.isle-modal-close-btn {
  width: 28px;
  height: 28px;
  border-radius: 999px;
  border: 1px solid transparent;
  background: color-mix(in srgb, var(--text-primary) 6%, transparent);
  color: var(--text-secondary);
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  transition: background 0.16s ease, color 0.16s ease, transform 0.16s var(--motion-spring);
}
.isle-modal-close-btn:hover {
  background: color-mix(in srgb, var(--text-primary) 12%, transparent);
  color: var(--text-primary);
  transform: scale(1.04);
}
.isle-modal-close-btn:active {
  transform: scale(0.96);
}

.isle-modal-body {
  padding: 20px 22px;
  min-height: 0;
  overflow-y: auto;
  overflow-x: hidden;
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.isle-modal-footer {
  padding: 14px 22px 18px;
  border-top: 1px solid color-mix(in srgb, var(--fluid-card-border) 45%, transparent);
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 10px;
  flex-shrink: 0;
}

@keyframes isleModalZoomIn {
  from {
    opacity: 0;
    transform: scale(0.96) translateY(8px);
  }
  to {
    opacity: 1;
    transform: scale(1) translateY(0);
  }
}

@keyframes isleModalSlideUp {
  from {
    opacity: 0;
    transform: translateY(100%);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

@media (max-width: 768px) {
  .isle-modal-backdrop {
    padding: 0;
    align-items: flex-end;
  }
  .isle-modal-card {
    max-height: 86vh;
    border-radius: 24px 24px 0 0;
    border-bottom: none;
    animation: isleModalSlideUp 0.3s cubic-bezier(0.16, 1, 0.3, 1) both;
  }
  .isle-modal-header {
    padding: 16px 18px 12px;
  }
  .isle-modal-body {
    padding: 16px 18px;
  }
  .isle-modal-footer {
    padding: 12px 18px max(16px, env(safe-area-inset-bottom));
  }
}

@media (prefers-reduced-motion: reduce) {
  .isle-modal-card {
    animation: none !important;
  }
  .isle-modal-close-btn {
    transition: none !important;
  }
}
</style>
