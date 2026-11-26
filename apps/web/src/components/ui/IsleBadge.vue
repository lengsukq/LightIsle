<template>
  <span
    class="isle-badge"
    :class="[
      `badge-${variant}`,
      `size-${size}`,
      interactive ? 'interactive' : '',
    ]"
  >
    <span v-if="dot" class="isle-badge-dot" aria-hidden="true" />
    <span v-if="$slots.icon" class="isle-badge-icon">
      <slot name="icon" />
    </span>
    <span class="isle-badge-label">
      <slot />
    </span>
  </span>
</template>

<script setup lang="ts">
withDefaults(
  defineProps<{
    variant?: 'neutral' | 'online' | 'offline' | 'warning' | 'danger' | 'accent' | 'category';
    size?: 'sm' | 'md';
    dot?: boolean;
    interactive?: boolean;
  }>(),
  {
    variant: 'neutral',
    size: 'sm',
    dot: false,
    interactive: false,
  }
);

defineSlots<{
  default?: (props: Record<string, never>) => any;
  icon?: (props: Record<string, never>) => any;
}>();
</script>

<style scoped>
.isle-badge {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  max-width: 100%;
  border-radius: var(--radius-full);
  font-weight: 550;
  line-height: 1;
  white-space: nowrap;
  vertical-align: middle;
  box-sizing: border-box;
  transition: background-color 0.15s ease, border-color 0.15s ease;
}

.isle-badge-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Sizes */
.isle-badge.size-sm {
  padding: 3px 8px;
  font-size: 11px;
}

.isle-badge.size-md {
  padding: 4px 10px;
  font-size: 12px;
}

/* Dot */
.isle-badge-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background-color: currentColor;
  opacity: 0.9;
  flex-shrink: 0;
}

.isle-badge.size-sm .isle-badge-dot {
  width: 5px;
  height: 5px;
}

.isle-badge-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}

/* Variants */
.isle-badge.badge-neutral {
  background: var(--fluid-card-item-fill);
  color: var(--text-secondary);
  border: 1px solid var(--fluid-card-border);
}

.isle-badge.badge-online {
  background: color-mix(in srgb, var(--success, #1F7A56) 11%, transparent);
  color: var(--success, #1F7A56);
  border: 1px solid color-mix(in srgb, var(--success, #1F7A56) 26%, transparent);
}

.isle-badge.badge-offline {
  background: color-mix(in srgb, var(--text-secondary) 10%, transparent);
  color: var(--text-secondary);
  border: 1px solid color-mix(in srgb, var(--text-secondary) 22%, transparent);
}

.isle-badge.badge-warning {
  background: color-mix(in srgb, var(--warning, #B86B19) 12%, transparent);
  color: var(--warning, #B86B19);
  border: 1px solid color-mix(in srgb, var(--warning, #B86B19) 28%, transparent);
}

.isle-badge.badge-danger {
  background: color-mix(in srgb, var(--error, #B94032) 12%, transparent);
  color: var(--error, #B94032);
  border: 1px solid color-mix(in srgb, var(--error, #B94032) 28%, transparent);
}

.isle-badge.badge-accent {
  background: color-mix(in srgb, var(--accent-primary, #1F5162) 10%, transparent);
  color: var(--accent-primary, #1F5162);
  border: 1px solid color-mix(in srgb, var(--accent-primary, #1F5162) 24%, transparent);
}

.isle-badge.badge-category {
  background: var(--fluid-card-fill);
  color: var(--text-primary);
  border: 1px solid var(--fluid-card-border);
}

:global([data-theme="dark"]) .isle-badge.badge-online {
  color: #34d399;
  background: rgba(16, 185, 129, 0.16);
}
:global([data-theme="dark"]) .isle-badge.badge-warning {
  color: #fbbf24;
  background: rgba(245, 158, 11, 0.16);
}
:global([data-theme="dark"]) .isle-badge.badge-danger {
  color: #f87171;
  background: rgba(239, 68, 68, 0.16);
}

@media (prefers-reduced-motion: reduce) {
  .isle-badge {
    transition: none;
  }
}
</style>
