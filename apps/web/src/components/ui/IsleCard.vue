<script setup lang="ts">
export type IsleCardVariant = "card" | "item" | "glass";
export type IsleCardPadding = "none" | "sm" | "md" | "lg";

const props = withDefaults(
  defineProps<{
    variant?: IsleCardVariant;
    hover?: boolean;
    title?: string;
    subtitle?: string;
    padding?: IsleCardPadding;
  }>(),
  {
    variant: "card",
    hover: false,
    title: "",
    subtitle: "",
    padding: "md",
  }
);
</script>

<template>
  <div
    class="isle-card"
    :class="[
      `variant-${variant}`,
      `padding-${padding}`,
      {
        'is-interactive': hover,
      },
    ]"
  >
    <header v-if="$slots.header || title || $slots.actions" class="isle-card-header">
      <slot name="header">
        <div class="isle-card-header-main">
          <span v-if="$slots.icon" class="isle-card-icon-badge" aria-hidden="true">
            <slot name="icon" />
          </span>
          <div class="isle-card-headings">
            <h3 v-if="title" class="isle-card-title">{{ title }}</h3>
            <p v-if="subtitle" class="isle-card-subtitle">{{ subtitle }}</p>
          </div>
        </div>
        <div v-if="$slots.actions" class="isle-card-header-actions">
          <slot name="actions" />
        </div>
      </slot>
    </header>

    <div class="isle-card-body">
      <slot />
    </div>

    <footer v-if="$slots.footer" class="isle-card-footer">
      <slot name="footer" />
    </footer>
  </div>
</template>

<style scoped>
.isle-card {
  position: relative;
  display: flex;
  flex-direction: column;
  color: var(--text-primary);
  box-sizing: border-box;
  transition:
    transform 220ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    background-color var(--motion-fast, 160ms) ease,
    border-color var(--motion-fast, 160ms) ease;
}

/* Variants */
.isle-card.variant-card {
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  border-radius: var(--radius-lg, 18px);
  box-shadow: var(--fluid-card-shadow);
}

.isle-card.variant-item {
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  border-radius: var(--radius-md, 14px);
  box-shadow: var(--fluid-item-card-shadow);
}

.isle-card.variant-glass {
  background: var(--surface-glass, rgba(255, 255, 255, 0.76));
  -webkit-backdrop-filter: blur(18px) saturate(150%);
  backdrop-filter: blur(18px) saturate(150%);
  border: 1px solid var(--fluid-card-border);
  border-radius: var(--radius-lg, 18px);
  box-shadow: var(--fluid-card-shadow);
}

/* Hover effects */
.isle-card.is-interactive:hover {
  transform: translateY(-1.5px);
}
.isle-card.is-interactive:active {
  transform: scale(0.99);
}

.isle-card.variant-card.is-interactive:hover,
.isle-card.variant-glass.is-interactive:hover {
  box-shadow: var(--fluid-hover-shadow);
  border-color: var(--fluid-card-border-strong, rgba(15, 23, 42, 0.14));
}

.isle-card.variant-item.is-interactive:hover {
  box-shadow: var(--fluid-item-hover-shadow);
  border-color: var(--fluid-card-border-strong, rgba(15, 23, 42, 0.14));
}

/* Paddings — tightened for balanced density */
.isle-card.padding-none .isle-card-body {
  padding: 0;
}
.isle-card.padding-sm {
  padding: 10px 12px;
}
.isle-card.padding-sm .isle-card-header {
  margin-bottom: 8px;
}
.isle-card.padding-md {
  padding: 15px 18px;
}
.isle-card.padding-md .isle-card-header {
  margin-bottom: 12px;
}
.isle-card.padding-lg {
  padding: 20px 22px;
}
.isle-card.padding-lg .isle-card-header {
  margin-bottom: 14px;
}

/* Header */
.isle-card-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 10px 12px;
  flex-shrink: 0;
}

.isle-card-header-main {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
  flex: 1 1 190px;
}

.isle-card-icon-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 30px;
  height: 30px;
  border-radius: 9px;
  background: color-mix(in srgb, var(--accent-primary, #0E6B74) 10%, transparent);
  color: var(--accent-primary, #0E6B74);
  flex-shrink: 0;
}

.isle-card-headings {
  min-width: 0;
  flex: 1;
}

.isle-card-title {
  margin: 0;
  font-size: 15.5px;
  font-weight: 660;
  letter-spacing: -0.015em;
  color: var(--text-primary);
  line-height: 1.35;
}

.isle-card-subtitle {
  margin: 2px 0 0;
  font-size: 12.5px;
  color: var(--text-secondary, #64748b);
  line-height: 1.4;
}

.isle-card-header-actions {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
  max-width: 100%;
  flex-shrink: 0;
}

@media (max-width: 640px) {
  .isle-card-header-actions {
    flex: 1 1 100%;
    justify-content: flex-start;
  }
}

@media (prefers-reduced-transparency: reduce) {
  .isle-card.variant-glass {
    -webkit-backdrop-filter: none;
    backdrop-filter: none;
    background: var(--surface-elevated);
  }
}

/* Body */
.isle-card-body {
  min-width: 0;
  flex: 1;
}

/* Footer */
.isle-card-footer {
  margin-top: 12px;
  padding-top: 10px;
  border-top: 1px solid var(--fluid-divider, rgba(15, 23, 42, 0.065));
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 8px;
  flex-shrink: 0;
}
@media (prefers-reduced-motion: reduce) {
  .isle-card {
    transition: none;
  }
}
</style>
