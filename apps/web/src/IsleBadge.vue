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
  border-radius: var(--radius-full);
  font-weight: 500;
  line-height: 1;
  white-space: nowrap;
  vertical-align: middle;
  box-sizing: border-box;
  transition: background-color 0.15s ease, border-color 0.15s ease;
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
  border-radius: var(--radius-full);
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
  background: rgba(255, 255, 255, 0.08);
  color: var(--text-secondary);
  border: 1px solid var(--border-subtle);
}

.isle-badge.badge-online {
  background: rgba(16, 185, 129, 0.12);
  color: #059669;
  border: 1px solid rgba(16, 185, 129, 0.22);
}

.isle-badge.badge-offline {
  background: rgba(148, 163, 184, 0.12);
  color: var(--text-secondary);
  border: 1px solid rgba(148, 163, 184, 0.2);
}

.isle-badge.badge-warning {
  background: rgba(245, 158, 11, 0.12);
  color: #d97706;
  border: 1px solid rgba(245, 158, 11, 0.25);
}

.isle-badge.badge-danger {
  background: rgba(239, 68, 68, 0.12);
  color: #dc2626;
  border: 1px solid rgba(239, 68, 68, 0.25);
}

.isle-badge.badge-accent {
  background: rgba(99, 102, 241, 0.12);
  color: var(--primary-color, #6366f1);
  border: 1px solid rgba(99, 102, 241, 0.25);
}

.isle-badge.badge-category {
  background: var(--card-bg);
  color: var(--text-primary);
  border: 1px solid var(--border-subtle);
}

/* Dark mode adjustments */
@media (prefers-color-scheme: dark) {
  .isle-badge.badge-online {
    color: #34d399;
    background: rgba(16, 185, 129, 0.16);
  }
  .isle-badge.badge-warning {
    color: #fbbf24;
    background: rgba(245, 158, 11, 0.16);
  }
  .isle-badge.badge-danger {
    color: #f87171;
    background: rgba(239, 68, 68, 0.16);
  }
}
</style>
