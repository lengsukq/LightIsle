<script setup lang="ts">
import { computed } from "vue";
import { Loader2 } from "lucide-vue-next";

export type IsleButtonVariant = "primary" | "tonal" | "danger" | "glass" | "ghost" | "secondary";
export type IsleButtonSize = "sm" | "md" | "lg";

const props = withDefaults(
  defineProps<{
    variant?: IsleButtonVariant;
    size?: IsleButtonSize;
    compact?: boolean;
    loading?: boolean;
    disabled?: boolean;
    type?: "button" | "submit" | "reset";
    ariaLabel?: string;
    selected?: boolean;
    fullWidth?: boolean;
  }>(),
  {
    variant: "tonal",
    size: "md",
    compact: false,
    loading: false,
    disabled: false,
    type: "button",
    ariaLabel: undefined,
    selected: false,
    fullWidth: false,
  }
);

const emit = defineEmits<{
  (e: "click", event: MouseEvent): void;
}>();

const resolvedSize = computed(() => {
  if (props.compact) return "sm";
  return props.size;
});

const isDisabled = computed(() => props.disabled || props.loading);

function handleClick(event: MouseEvent) {
  if (isDisabled.value) {
    event.preventDefault();
    event.stopPropagation();
    return;
  }
  emit("click", event);
}
</script>

<template>
  <button
    :type="type"
    class="isle-btn"
    :class="[
      `variant-${variant}`,
      `size-${resolvedSize}`,
      {
        'is-loading': loading,
        'is-selected': selected,
        'is-full-width': fullWidth,
        'is-disabled': isDisabled,
      },
    ]"
    :disabled="isDisabled"
    :aria-disabled="isDisabled ? 'true' : undefined"
    :aria-busy="loading ? 'true' : undefined"
    :aria-label="ariaLabel"
    @click="handleClick"
  >
    <span v-if="loading" class="isle-btn-spinner" aria-hidden="true">
      <Loader2 :size="resolvedSize === 'sm' ? 14 : resolvedSize === 'lg' ? 18 : 16" class="spin-icon" />
    </span>
    <span v-else-if="$slots.icon" class="isle-btn-icon" aria-hidden="true">
      <slot name="icon" />
    </span>

    <span v-if="$slots.default" class="isle-btn-content">
      <slot />
    </span>

    <span v-if="$slots.suffix && !loading" class="isle-btn-suffix" aria-hidden="true">
      <slot name="suffix" />
    </span>
  </button>
</template>

<style scoped>
.isle-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  border-radius: 9999px;
  font-family: inherit;
  font-weight: 500;
  letter-spacing: -0.15px;
  cursor: pointer;
  border: 1px solid transparent;
  transition:
    transform var(--motion-fast, 150ms) var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    opacity 0.18s ease;
  user-select: none;
  -webkit-tap-highlight-color: transparent;
  white-space: nowrap;
  text-decoration: none;
  box-sizing: border-box;
}

.isle-btn:focus-visible {
  outline: 2px solid var(--accent-primary, #2563eb);
  outline-offset: 2px;
}

.isle-btn:active:not(.is-disabled) {
  transform: scale(0.96);
}

.isle-btn.is-full-width {
  width: 100%;
}

.isle-btn.is-disabled {
  opacity: 0.45;
  cursor: not-allowed;
  pointer-events: none;
}

/* Sizes */
.isle-btn.size-sm {
  min-height: 32px;
  padding: 4px 12px;
  font-size: 12.5px;
  gap: 5px;
}

.isle-btn.size-md {
  min-height: 38px;
  padding: 6px 16px;
  font-size: 13.5px;
  gap: 6px;
}

.isle-btn.size-lg {
  min-height: 44px;
  padding: 8px 20px;
  font-size: 15px;
  gap: 8px;
}

/* Variants */
.isle-btn.variant-primary {
  background: linear-gradient(135deg, #1b86ff 0%, var(--accent-primary, #0071e3) 100%);
  color: #ffffff;
  border-color: rgba(255, 255, 255, 0.22);
  box-shadow:
    0 3px 12px color-mix(in srgb, var(--accent-primary, #0071e3) 30%, transparent),
    inset 0 1px 1px rgba(255, 255, 255, 0.28);
}

.isle-btn.variant-primary:hover:not(.is-disabled) {
  filter: brightness(1.06);
  box-shadow:
    0 5px 16px color-mix(in srgb, var(--accent-primary, #0071e3) 38%, transparent),
    inset 0 1px 1px rgba(255, 255, 255, 0.32);
}

.isle-btn.variant-tonal {
  background: color-mix(in srgb, var(--accent-primary, #2563eb) 10%, var(--fluid-card-top, rgba(255, 255, 255, 0.8)));
  color: var(--accent-primary, #2563eb);
  border-color: color-mix(in srgb, var(--accent-primary, #2563eb) 22%, transparent);
}

.isle-btn.variant-tonal:hover:not(.is-disabled) {
  background: color-mix(in srgb, var(--accent-primary, #2563eb) 16%, var(--fluid-card-top, rgba(255, 255, 255, 0.9)));
  border-color: color-mix(in srgb, var(--accent-primary, #2563eb) 35%, transparent);
}

.isle-btn.variant-danger {
  background: color-mix(in srgb, #ef4444 10%, var(--fluid-card-top, rgba(255, 255, 255, 0.8)));
  color: #ef4444;
  border-color: color-mix(in srgb, #ef4444 26%, transparent);
}

.isle-btn.variant-danger:hover:not(.is-disabled) {
  background: color-mix(in srgb, #ef4444 18%, var(--fluid-card-top, rgba(255, 255, 255, 0.9)));
  border-color: color-mix(in srgb, #ef4444 40%, transparent);
}

.isle-btn.variant-glass,
.isle-btn.variant-secondary {
  background: var(--fluid-card-fill, rgba(255, 255, 255, 0.7));
  color: var(--text-primary, #1e293b);
  border-color: var(--fluid-card-border, rgba(120, 136, 165, 0.2));
  box-shadow: var(--fluid-item-card-shadow, 0 2px 6px rgba(0, 0, 0, 0.04));
}

.isle-btn.variant-glass:hover:not(.is-disabled),
.isle-btn.variant-secondary:hover:not(.is-disabled) {
  background: var(--fluid-card-hover, rgba(255, 255, 255, 0.9));
  border-color: color-mix(in srgb, var(--fluid-rim, #ffffff) 90%, transparent);
}

.isle-btn.variant-ghost {
  background: transparent;
  color: var(--text-secondary, #64748b);
  border-color: transparent;
}

.isle-btn.variant-ghost:hover:not(.is-disabled) {
  background: rgba(120, 136, 165, 0.12);
  color: var(--text-primary, #1e293b);
}

.isle-btn.is-selected {
  background: color-mix(in srgb, var(--accent-primary, #2563eb) 18%, var(--fluid-card-top, rgba(255, 255, 255, 0.9)));
  border-color: var(--accent-primary, #2563eb);
  color: var(--accent-primary, #2563eb);
}

/* Icons & Spinners */
.isle-btn-icon,
.isle-btn-suffix,
.isle-btn-spinner {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.spin-icon {
  animation: isleBtnSpin 1s linear infinite;
}

@keyframes isleBtnSpin {
  from {
    transform: rotate(0deg);
  }
  to {
    transform: rotate(360deg);
  }
}

@media (prefers-reduced-motion: reduce) {
  .isle-btn {
    transition: none;
  }
  .isle-btn-spinner {
    animation: none;
  }
}
</style>
