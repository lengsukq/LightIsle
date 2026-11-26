<script setup lang="ts">
import { computed, ref, useId, watch } from "vue";
import type { Component } from "vue";
import { ChevronRight } from "lucide-vue-next";

const props = withDefaults(
  defineProps<{
    title: string;
    subtitle?: string;
    modelValue?: boolean;
    defaultOpen?: boolean;
    icon?: Component | null;
    variant?: "card" | "inline";
  }>(),
  {
    subtitle: "",
    modelValue: undefined,
    defaultOpen: false,
    icon: null,
    variant: "card",
  },
);

const emit = defineEmits<{
  (e: "update:modelValue", open: boolean): void;
  (e: "toggle", open: boolean): void;
}>();

const panelId = `isle-disc-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
const localOpen = ref(props.defaultOpen);

watch(
  () => props.defaultOpen,
  (next) => {
    if (props.modelValue === undefined) localOpen.value = next;
  },
);

const isOpen = computed(() =>
  typeof props.modelValue === "boolean" ? props.modelValue : localOpen.value,
);

function toggle() {
  const next = !isOpen.value;
  if (props.modelValue === undefined) localOpen.value = next;
  emit("update:modelValue", next);
  emit("toggle", next);
}
</script>

<template>
  <div class="isle-disclosure" :class="[`is-${variant}`, { 'is-open': isOpen }]">
    <button
      type="button"
      class="isle-disclosure-trigger"
      :aria-expanded="isOpen ? 'true' : 'false'"
      :aria-controls="panelId"
      @click="toggle"
    >
      <span class="isle-disclosure-head">
        <span v-if="$slots.icon || icon" class="isle-disclosure-icon" aria-hidden="true">
          <slot name="icon">
            <component :is="icon" :size="16" />
          </slot>
        </span>
        <span class="isle-disclosure-copy">
          <strong>{{ title }}</strong>
          <small v-if="subtitle">{{ subtitle }}</small>
        </span>
      </span>
      <span class="isle-disclosure-end">
        <slot name="meta" />
        <ChevronRight :size="15" class="isle-disclosure-chevron" aria-hidden="true" />
      </span>
    </button>

    <div
      :id="panelId"
      class="isle-disclosure-panel"
      :class="{ 'is-open': isOpen }"
      :aria-hidden="isOpen ? 'false' : 'true'"
      :inert="!isOpen || undefined"
    >
      <div class="isle-disclosure-inner">
        <div class="isle-disclosure-body">
          <slot />
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.isle-disclosure {
  border-radius: var(--radius-md, 14px);
  border: var(--theme-border-width, 1px) solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  box-shadow: var(--fluid-item-card-shadow);
  overflow: hidden;
}

.isle-disclosure.is-inline {
  border-radius: 0;
  border: 0;
  background: transparent;
  box-shadow: none;
}

.isle-disclosure-trigger {
  width: 100%;
  min-height: 44px;
  padding: 11px 15px;
  border: 0;
  background: transparent;
  color: var(--text-primary);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  text-align: left;
  cursor: pointer;
  transition: background-color var(--motion-fast, 160ms) ease;
}

.isle-disclosure-trigger:hover {
  background: var(--fluid-card-hover);
}

.isle-disclosure.is-inline .isle-disclosure-trigger {
  padding: 9px 2px;
  border-radius: 8px;
}

.isle-disclosure-head {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
  flex: 1;
}

.isle-disclosure-icon {
  display: inline-grid;
  place-items: center;
  color: var(--accent-primary);
  flex-shrink: 0;
}

.isle-disclosure-copy {
  display: grid;
  gap: 1px;
  min-width: 0;
}

.isle-disclosure-copy strong {
  font-size: 13.5px;
  font-weight: 620;
  color: var(--text-primary);
  overflow-wrap: anywhere;
}

.isle-disclosure-copy small {
  font-size: 12px;
  color: var(--text-secondary);
  line-height: 1.4;
}

.isle-disclosure-end {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  flex-shrink: 0;
  color: var(--text-tertiary);
}

.isle-disclosure-chevron {
  transition: transform 240ms var(--motion-spring-snappy, cubic-bezier(0.22, 1, 0.36, 1));
}

.isle-disclosure.is-open .isle-disclosure-chevron {
  transform: rotate(90deg);
  color: var(--accent-primary);
}

.isle-disclosure-panel {
  display: grid;
  grid-template-rows: 0fr;
  opacity: 0;
  transition:
    grid-template-rows 260ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    opacity 200ms ease;
}

.isle-disclosure-panel.is-open {
  grid-template-rows: 1fr;
  opacity: 1;
}

.isle-disclosure-inner {
  min-height: 0;
  overflow: hidden;
}

.isle-disclosure-body {
  padding: 12px 15px 15px;
  border-top: 1px solid var(--fluid-divider, rgba(20, 19, 17, 0.06));
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.isle-disclosure.is-inline .isle-disclosure-body {
  padding: 8px 0 4px;
}

@media (prefers-reduced-motion: reduce) {
  .isle-disclosure-trigger,
  .isle-disclosure-chevron,
  .isle-disclosure-panel {
    transition: none;
  }
}
</style>
