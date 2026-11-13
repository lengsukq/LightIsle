<script setup lang="ts">
import { X } from "lucide-vue-next";

const props = withDefaults(
  defineProps<{
    selected?: boolean;
    label?: string;
    small?: boolean;
    removable?: boolean;
    disabled?: boolean;
    deleteTooltip?: string;
  }>(),
  {
    selected: false,
    label: "",
    small: false,
    removable: false,
    disabled: false,
    deleteTooltip: "移除",
  }
);

const emit = defineEmits<{
  (e: "click", event: MouseEvent): void;
  (e: "select"): void;
  (e: "remove", event: MouseEvent): void;
}>();

function handleClick(event: MouseEvent) {
  if (props.disabled) return;
  emit("click", event);
  emit("select");
}

function handleRemove(event: MouseEvent) {
  event.stopPropagation();
  if (props.disabled) return;
  emit("remove", event);
}
</script>

<template>
  <button
    type="button"
    class="isle-chip"
    :class="{
      'is-selected': selected,
      'is-small': small,
      'is-disabled': disabled,
      'is-removable': removable,
    }"
    :disabled="disabled"
    :aria-pressed="selected ? 'true' : 'false'"
    @click="handleClick"
  >
    <span v-if="$slots.icon" class="isle-chip-icon" aria-hidden="true">
      <slot name="icon" />
    </span>

    <span class="isle-chip-label">
      <slot>{{ label }}</slot>
    </span>

    <button
      v-if="removable"
      type="button"
      class="isle-chip-remove-btn"
      :title="deleteTooltip"
      :aria-label="deleteTooltip"
      tabindex="-1"
      @click="handleRemove"
    >
      <X :size="small ? 12 : 14" />
    </button>
  </button>
</template>

<style scoped>
.isle-chip {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  min-height: 36px;
  padding: 6px 14px;
  border-radius: 9999px;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-secondary, #64748b);
  font-family: inherit;
  font-size: 13px;
  font-weight: 500;
  letter-spacing: -0.1px;
  cursor: pointer;
  box-shadow: var(--fluid-item-card-shadow);
  transition:
    transform var(--motion-fast, 150ms) var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    opacity 0.18s ease;
  user-select: none;
  -webkit-tap-highlight-color: transparent;
  white-space: nowrap;
  box-sizing: border-box;
}

.isle-chip:focus-visible {
  outline: 2px solid var(--accent-primary, #2563eb);
  outline-offset: 2px;
}

.isle-chip:hover:not(.is-disabled) {
  background: var(--fluid-card-hover);
  color: var(--text-primary);
  border-color: color-mix(in srgb, var(--fluid-rim, #ffffff) 85%, transparent);
}

.isle-chip:active:not(.is-disabled) {
  transform: scale(0.96);
}

.isle-chip.is-small {
  min-height: 28px;
  padding: 4px 10px;
  font-size: 12px;
  gap: 4px;
}

.isle-chip.is-removable {
  padding-right: 6px;
}

.isle-chip.is-selected {
  background: color-mix(in srgb, var(--accent-primary, #2563eb) 12%, var(--fluid-card-top, #ffffff));
  border-color: var(--accent-primary, #2563eb);
  color: var(--accent-primary, #2563eb);
  font-weight: 600;
  box-shadow:
    0 2px 10px rgba(37, 99, 235, 0.18),
    inset 0 1px 1px rgba(255, 255, 255, 0.35);
}

.isle-chip.is-selected:hover:not(.is-disabled) {
  background: color-mix(in srgb, var(--accent-primary, #2563eb) 18%, var(--fluid-card-top, #ffffff));
}

.isle-chip.is-disabled {
  opacity: 0.45;
  cursor: not-allowed;
  pointer-events: none;
}

/* Icon */
.isle-chip-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

.isle-chip-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Remove button */
.isle-chip-remove-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 20px;
  height: 20px;
  border-radius: 9999px;
  border: none;
  background: transparent;
  color: currentColor;
  cursor: pointer;
  padding: 0;
  margin-left: 2px;
  transition: background 0.15s ease, opacity 0.15s ease;
  opacity: 0.7;
}

.isle-chip-remove-btn:hover {
  background: rgba(120, 136, 165, 0.2);
  opacity: 1;
}

@media (prefers-reduced-motion: reduce) {
  .isle-chip,
  .isle-chip-remove-btn {
    transition: none;
  }
}
</style>
