<script setup lang="ts">
withDefaults(
  defineProps<{
    title?: string;
    subtitle?: string;
    variant?: "card" | "item";
    flush?: boolean;
  }>(),
  {
    title: "",
    subtitle: "",
    variant: "card",
    flush: false,
  },
);
</script>

<template>
  <section class="isle-grouped-section">
    <div v-if="title || subtitle || $slots.header || $slots.actions" class="isle-grouped-head">
      <slot name="header">
        <div class="isle-grouped-titles">
          <h3 v-if="title">{{ title }}</h3>
          <p v-if="subtitle">{{ subtitle }}</p>
        </div>
      </slot>
      <div v-if="$slots.actions" class="isle-grouped-actions">
        <slot name="actions" />
      </div>
    </div>

    <div class="isle-grouped-card" :class="[`is-${variant}`, { 'is-flush': flush }]">
      <slot />
    </div>

    <p v-if="$slots.footnote" class="isle-grouped-foot">
      <slot name="footnote" />
    </p>
  </section>
</template>

<style scoped>
.isle-grouped-section {
  display: flex;
  flex-direction: column;
  gap: 9px;
  min-width: 0;
}

.isle-grouped-head {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 8px 14px;
  padding: 0 4px;
}

.isle-grouped-titles {
  display: grid;
  gap: 3px;
  min-width: 0;
  flex: 1 1 200px;
}

.isle-grouped-titles h3 {
  margin: 0;
  font-size: 13.5px;
  font-weight: 650;
  letter-spacing: -0.01em;
  color: var(--text-primary);
}

.isle-grouped-titles p {
  margin: 0;
  font-size: 12px;
  line-height: 1.45;
  color: var(--text-secondary);
}

.isle-grouped-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.isle-grouped-card {
  display: flex;
  flex-direction: column;
  border-radius: var(--radius-lg, 18px);
  border: var(--theme-border-width, 1px) solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  box-shadow: var(--fluid-card-shadow);
  overflow: hidden;
  min-width: 0;
}

.isle-grouped-card.is-item {
  border-radius: var(--radius-md, 14px);
  background: var(--fluid-card-item-fill);
  box-shadow: var(--fluid-item-card-shadow);
}

.isle-grouped-card:not(.is-flush) > :slotted(*) {
  padding: 13px 16px;
  margin: 0;
  border-radius: 0;
  border: 0;
  background: transparent;
  box-shadow: none;
  transition: background-color var(--motion-fast, 160ms) ease;
}

.isle-grouped-card.is-flush > :slotted(*) {
  margin: 0;
}

.isle-grouped-card > :slotted(* + *) {
  border-top: 1px solid var(--fluid-divider, rgba(20, 19, 17, 0.06));
}

.isle-grouped-foot {
  margin: 0;
  padding: 0 4px;
  font-size: 11.5px;
  line-height: 1.45;
  color: var(--text-tertiary);
}

@media (prefers-reduced-motion: reduce) {
  .isle-grouped-card:not(.is-flush) > :slotted(*) {
    transition: none;
  }
}
</style>
