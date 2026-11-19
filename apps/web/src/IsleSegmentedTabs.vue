<script setup lang="ts">
export type IsleSegmentedOption = {
  value: string;
  label: string;
  count?: number;
  disabled?: boolean;
};

withDefaults(
  defineProps<{
    modelValue: string;
    options: IsleSegmentedOption[];
    size?: "sm" | "md";
    ariaLabel?: string;
  }>(),
  {
    size: "md",
    ariaLabel: "视图切换",
  }
);

const emit = defineEmits<{
  (e: "update:modelValue", value: string): void;
}>();
</script>

<template>
  <div
    class="isle-segmented-tabs"
    :class="[`size-${size}`]"
    role="tablist"
    :aria-label="ariaLabel"
  >
    <button
      v-for="opt in options"
      :key="opt.value"
      type="button"
      role="tab"
      class="isle-segmented-tab"
      :class="{ 'is-active': modelValue === opt.value }"
      :aria-selected="modelValue === opt.value ? 'true' : 'false'"
      :disabled="opt.disabled"
      @click="emit('update:modelValue', opt.value)"
    >
      <span class="isle-segmented-label">{{ opt.label }}</span>
      <span v-if="typeof opt.count === 'number'" class="isle-segmented-count">{{ opt.count }}</span>
    </button>
  </div>
</template>

<style scoped>
.isle-segmented-tabs {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  padding: 3px;
  border-radius: var(--radius-pill, 9999px);
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  max-width: 100%;
  overflow-x: auto;
  scrollbar-width: none;
}

.isle-segmented-tabs::-webkit-scrollbar {
  display: none;
}

.isle-segmented-tab {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  border-radius: var(--radius-pill, 9999px);
  border: 1px solid transparent;
  background: transparent;
  color: var(--text-secondary);
  font-family: inherit;
  font-weight: 550;
  white-space: nowrap;
  cursor: pointer;
  flex-shrink: 0;
  transition:
    transform 220ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    background var(--motion-fast, 160ms) ease,
    border-color var(--motion-fast, 160ms) ease,
    color var(--motion-fast, 160ms) ease;
}

.isle-segmented-tabs.size-sm .isle-segmented-tab {
  min-height: 26px;
  padding: 3px 10px;
  font-size: 11.5px;
}

.isle-segmented-tabs.size-md .isle-segmented-tab {
  min-height: 30px;
  padding: 4px 13px;
  font-size: 12.5px;
}

.isle-segmented-tab:hover:not(:disabled) {
  color: var(--text-primary);
  background: color-mix(in srgb, var(--text-primary) 5%, transparent);
}

.isle-segmented-tab:active:not(:disabled) {
  transform: scale(0.97);
}

.isle-segmented-tab.is-active {
  background: var(--fluid-card-top);
  color: var(--accent-primary, #1f5162);
  border-color: var(--fluid-card-border);
  box-shadow: 0 1px 4px rgb(var(--fluid-shadow-rgb) / 0.08);
  font-weight: 650;
}

:global([data-theme="dark"]) .isle-segmented-tab.is-active {
  background: color-mix(in srgb, var(--accent-primary) 16%, var(--fluid-card-top));
  border-color: color-mix(in srgb, var(--accent-primary) 34%, var(--fluid-card-border));
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.3);
}

.isle-segmented-count {
  font-size: 10.5px;
  font-weight: 650;
  padding: 1px 6px;
  border-radius: var(--radius-pill, 9999px);
  background: color-mix(in srgb, currentColor 12%, transparent);
  font-variant-numeric: tabular-nums;
}

@media (prefers-reduced-motion: reduce) {
  .isle-segmented-tab {
    transition: none;
  }
}
</style>
