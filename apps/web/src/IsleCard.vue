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
    transform var(--motion-normal, 260ms) var(--motion-spring, cubic-bezier(0.16, 1, 0.3, 1)),
    box-shadow var(--motion-normal, 260ms) ease,
    border-color var(--motion-normal, 260ms) ease;
}

/* Variants */
.isle-card.variant-card {
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  border-radius: var(--radius-lg, 22px);
  box-shadow: var(--fluid-card-shadow);
}

.isle-card.variant-item {
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  border-radius: var(--radius-md, 16px);
  box-shadow: var(--fluid-item-card-shadow);
}

.isle-card.variant-glass {
  background: var(--fluid-card-fill, rgba(255, 255, 255, 0.65));
  -webkit-backdrop-filter: blur(16px) saturate(140%);
  backdrop-filter: blur(16px) saturate(140%);
  border: 1px solid var(--fluid-card-border, rgba(120, 136, 165, 0.22));
  border-radius: var(--radius-lg, 22px);
  box-shadow: var(--fluid-card-shadow);
}

/* Hover effects */
.isle-card.is-interactive:hover {
  transform: translateY(-2px);
}

.isle-card.variant-card.is-interactive:hover,
.isle-card.variant-glass.is-interactive:hover {
  box-shadow: var(--fluid-hover-shadow);
  border-color: color-mix(in srgb, var(--fluid-rim, #ffffff) 90%, transparent);
}

.isle-card.variant-item.is-interactive:hover {
  box-shadow: var(--fluid-item-hover-shadow);
  border-color: color-mix(in srgb, var(--fluid-rim, #ffffff) 90%, transparent);
}

/* Paddings */
.isle-card.padding-none .isle-card-body {
  padding: 0;
}
.isle-card.padding-sm {
  padding: 12px;
}
.isle-card.padding-sm .isle-card-header {
  margin-bottom: 10px;
}
.isle-card.padding-md {
  padding: 18px 20px;
}
.isle-card.padding-md .isle-card-header {
  margin-bottom: 14px;
}
.isle-card.padding-lg {
  padding: 24px 28px;
}
.isle-card.padding-lg .isle-card-header {
  margin-bottom: 18px;
}

/* Header */
.isle-card-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-shrink: 0;
}

.isle-card-header-main {
  display: flex;
  align-items: center;
  gap: 12px;
  min-width: 0;
  flex: 1;
}

.isle-card-icon-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 38px;
  height: 38px;
  border-radius: var(--radius-sm, 12px);
  background: color-mix(in srgb, var(--accent-primary, #2563eb) 12%, var(--fluid-card-top, #ffffff));
  color: var(--accent-primary, #2563eb);
  border: 1px solid color-mix(in srgb, var(--accent-primary, #2563eb) 20%, transparent);
  flex-shrink: 0;
}

.isle-card-headings {
  min-width: 0;
  flex: 1;
}

.isle-card-title {
  margin: 0;
  font-size: 16px;
  font-weight: 600;
  letter-spacing: -0.2px;
  color: var(--text-primary);
  line-height: 1.35;
}

.isle-card-subtitle {
  margin: 3px 0 0;
  font-size: 13px;
  color: var(--text-secondary, #64748b);
  line-height: 1.4;
}

.isle-card-header-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-shrink: 0;
}

/* Body */
.isle-card-body {
  min-width: 0;
  flex: 1;
}

/* Footer */
.isle-card-footer {
  margin-top: 14px;
  padding-top: 12px;
  border-top: 1px solid color-mix(in srgb, var(--fluid-card-border, rgba(120, 136, 165, 0.2)) 60%, transparent);
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 10px;
  flex-shrink: 0;
}
</style>
