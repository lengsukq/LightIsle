<script setup lang="ts">
defineProps<{
  ready?: boolean;
  pillRect: Record<string, string | number>;
  variant?: "nav" | "segment";
}>();
</script>

<template>
  <span
    class="isle-sliding-indicator"
    :class="[variant ? `variant-${variant}` : 'variant-segment', { 'is-ready': ready }]"
    :style="pillRect"
    aria-hidden="true"
  ></span>
</template>

<style scoped>
.isle-sliding-indicator {
  position: absolute;
  left: 0;
  top: 0;
  pointer-events: none;
  z-index: 0;
  border-radius: var(--radius-sm, 9px);
}

.isle-sliding-indicator.variant-segment {
  background: var(--fluid-card-top);
  border: 1px solid var(--fluid-card-border);
  box-shadow: 0 1px 4px color-mix(in srgb, var(--text-primary) 8%, transparent);
}

.isle-sliding-indicator.variant-nav {
  background: color-mix(in srgb, var(--accent-primary) 10.5%, var(--fluid-card-top));
  border: 1px solid color-mix(in srgb, var(--accent-primary) 18%, transparent);
}

.isle-sliding-indicator.is-ready {
  transition:
    transform 0.3s var(--motion-spring-snappy, cubic-bezier(0.2, 0.9, 0.22, 1.05)),
    width 0.24s var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    height 0.24s var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    opacity 0.16s ease;
}

@media (prefers-reduced-motion: reduce) {
  .isle-sliding-indicator.is-ready {
    transition: none;
  }
}
</style>
