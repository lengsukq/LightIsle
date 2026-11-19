<template>
  <div
    class="isle-empty"
    :class="[
      compact ? 'compact' : '',
      card ? 'card-surface' : '',
    ]"
    role="status"
  >
    <div v-if="$slots.icon || icon" class="isle-empty-icon-wrap">
      <slot name="icon">
        <component :is="icon" :size="iconSize" class="isle-empty-icon" />
      </slot>
    </div>

    <div v-if="$slots.title || title" class="isle-empty-title">
      <slot name="title">{{ title }}</slot>
    </div>

    <div v-if="$slots.default || description" class="isle-empty-desc">
      <slot>{{ description }}</slot>
    </div>

    <div v-if="$slots.action" class="isle-empty-action">
      <slot name="action" />
    </div>
  </div>
</template>

<script setup lang="ts">
import type { Component, VNode } from "vue";

withDefaults(
  defineProps<{
    title?: string;
    description?: string;
    icon?: Component | null;
    iconSize?: number;
    compact?: boolean;
    card?: boolean;
  }>(),
  {
    title: '',
    description: '',
    icon: null,
    iconSize: 24,
    compact: false,
    card: false,
  }
);

defineSlots<{
  default?: (props: Record<string, never>) => VNode[];
  icon?: (props: Record<string, never>) => VNode[];
  title?: (props: Record<string, never>) => VNode[];
  action?: (props: Record<string, never>) => VNode[];
}>();
</script>

<style scoped>
.isle-empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  text-align: center;
  padding: 24px 18px;
  color: var(--text-secondary);
  box-sizing: border-box;
}

.isle-empty.compact {
  padding: 14px 12px;
}

.isle-empty.card-surface {
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  border-radius: 16px;
  box-shadow: var(--fluid-item-card-shadow);
}

.isle-empty-icon-wrap {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 44px;
  height: 44px;
  border-radius: 12px;
  background: color-mix(in srgb, var(--accent-primary) 8%, var(--fluid-card-item-fill));
  border: 1px solid var(--fluid-card-border);
  color: var(--accent-primary);
  margin-bottom: 10px;
  transition: transform 0.2s cubic-bezier(0.2, 0.8, 0.2, 1);
}

.isle-empty.compact .isle-empty-icon-wrap {
  width: 34px;
  height: 34px;
  border-radius: 9px;
  margin-bottom: 6px;
}

.isle-empty-icon {
  opacity: 0.9;
}

.isle-empty-title {
  font-size: 14px;
  font-weight: 650;
  color: var(--text-primary);
  letter-spacing: -0.01em;
  margin-bottom: 3px;
}

.isle-empty.compact .isle-empty-title {
  font-size: 13px;
}

.isle-empty-desc {
  font-size: 12.5px;
  line-height: 1.5;
  color: var(--text-secondary);
  max-width: 400px;
  margin: 0 auto;
}

.isle-empty.compact .isle-empty-desc {
  font-size: 12px;
  max-width: 320px;
}

.isle-empty-action {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  margin-top: 12px;
}

.isle-empty.compact .isle-empty-action {
  margin-top: 10px;
}

@media (prefers-reduced-motion: reduce) {
  .isle-empty-icon-wrap {
    transition: none;
  }
}
</style>
