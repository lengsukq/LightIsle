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
    <span class="isle-btn-content">
      <Transition name="isle-btn-glyph" mode="out-in">
        <span v-if="loading" key="spin" class="isle-btn-spinner" aria-hidden="true">
          <Loader2 :size="resolvedSize === 'sm' ? 13 : resolvedSize === 'lg' ? 17 : 15" class="spin-icon" />
        </span>
        <span v-else-if="$slots.icon" key="icon" class="isle-btn-icon" aria-hidden="true">
          <slot name="icon" />
        </span>
      </Transition>
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
  font-weight: 550;
  font-variant-numeric: tabular-nums;
  letter-spacing: -0.01em;
  cursor: pointer;
  border: 1px solid transparent;
  transition:
    transform 240ms var(--motion-spring-snappy, cubic-bezier(0.2, 0.9, 0.22, 1.05)),
    background-color 0.16s ease,
    border-color 0.16s ease,
    color 0.16s ease,
    opacity 0.18s ease;
  user-select: none;
  -webkit-tap-highlight-color: transparent;
  white-space: nowrap;
  text-decoration: none;
  box-sizing: border-box;
  width: auto;
  max-width: 100%;
}

.isle-btn-content {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  min-width: 0;
}

.isle-btn:focus-visible {
  outline: 2px solid var(--accent-primary, #1f5162);
  outline-offset: 2px;
}

.isle-btn:active:not(.is-disabled) {
  transform: scale(0.96);
  transition-duration: 95ms;
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
  min-height: 30px;
  padding: 4px 11px;
  font-size: 12px;
  gap: 5px;
}

.isle-btn.size-md {
  min-height: 34px;
  padding: 5px 14px;
  font-size: 13px;
  gap: 6px;
}

.isle-btn.size-lg {
  min-height: 40px;
  padding: 7px 18px;
  font-size: 14px;
  gap: 7px;
}

/* Variants */
.isle-btn.variant-primary {
  background: linear-gradient(180deg, var(--accent-primary-solid-top, var(--accent-primary)) 0%, var(--accent-primary-solid, var(--accent-primary)) 100%);
  color: var(--on-accent-primary, #ffffff);
  border-color: color-mix(in srgb, var(--accent-primary-solid, var(--accent-primary)) 82%, #000000);
  box-shadow:
    0 2px 8px color-mix(in srgb, var(--accent-primary-solid, var(--accent-primary)) 24%, transparent),
    inset 0 1px 0 rgba(255, 255, 255, 0.20);
}

.isle-btn.variant-primary:hover:not(.is-disabled) {
  background: linear-gradient(180deg, color-mix(in srgb, var(--accent-primary-solid-top, var(--accent-primary)) 86%, #ffffff) 0%, var(--accent-primary-solid-top, var(--accent-primary)) 100%);
  box-shadow:
    0 4px 12px color-mix(in srgb, var(--accent-primary-solid, var(--accent-primary)) 28%, transparent),
    inset 0 1px 0 rgba(255, 255, 255, 0.28);
}

.isle-btn.variant-tonal {
  background: color-mix(in srgb, var(--accent-primary) 10%, var(--fluid-card-top, #ffffff));
  color: var(--accent-primary);
  border-color: color-mix(in srgb, var(--accent-primary) 24%, var(--fluid-card-border));
}

.isle-btn.variant-tonal:hover:not(.is-disabled) {
  background: color-mix(in srgb, var(--accent-primary) 16%, var(--fluid-card-top, #ffffff));
  border-color: color-mix(in srgb, var(--accent-primary) 38%, var(--fluid-card-border));
}

.isle-btn.variant-danger {
  background: color-mix(in srgb, var(--error, #C93B3B) 10%, var(--fluid-card-top, #ffffff));
  color: var(--error, #C93B3B);
  border-color: color-mix(in srgb, var(--error, #C93B3B) 26%, var(--fluid-card-border));
}

.isle-btn.variant-danger:hover:not(.is-disabled) {
  background: color-mix(in srgb, var(--error, #C93B3B) 16%, var(--fluid-card-top, #ffffff));
  border-color: color-mix(in srgb, var(--error, #C93B3B) 40%, var(--fluid-card-border));
}

.isle-btn.variant-glass,
.isle-btn.variant-secondary {
  background: color-mix(in srgb, var(--fluid-card-top, #ffffff) 74%, transparent);
  color: var(--text-primary, #1e293b);
  border-color: var(--fluid-card-border, rgba(15, 23, 42, 0.1));
  box-shadow:
    0 1px 2px rgba(20, 19, 17, 0.03),
    inset 0 1px 0 rgba(255, 255, 255, 0.72);
}

.isle-btn.variant-glass:hover:not(.is-disabled),
.isle-btn.variant-secondary:hover:not(.is-disabled) {
  background: var(--fluid-card-hover, #f8fafc);
  border-color: var(--fluid-card-border-strong, rgba(15, 23, 42, 0.16));
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
  background: color-mix(in srgb, var(--accent-primary, #2563eb) 14%, var(--fluid-card-top, #ffffff));
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

.isle-btn-glyph-enter-active,
.isle-btn-glyph-leave-active {
  transition: opacity 130ms ease, transform 160ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1));
}
.isle-btn-glyph-enter-from,
.isle-btn-glyph-leave-to {
  opacity: 0;
  transform: scale(0.8);
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
  .isle-btn,
  .isle-btn-glyph-enter-active,
  .isle-btn-glyph-leave-active {
    transition: none;
  }
  .isle-btn-spinner,
  .spin-icon {
    animation: none;
  }
}
</style>
