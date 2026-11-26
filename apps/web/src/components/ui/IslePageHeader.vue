<script setup lang="ts">
withDefaults(
  defineProps<{
    title: string;
    subtitle?: string;
    eyebrow?: string;
    compact?: boolean;
    showAccentBar?: boolean;
  }>(),
  {
    subtitle: "",
    eyebrow: "",
    compact: false,
    showAccentBar: false,
  }
);
</script>

<template>
  <header class="isle-page-header" :class="{ 'is-compact': compact }">
    <div class="isle-page-header-main">
      <span v-if="showAccentBar" class="isle-page-header-bar" aria-hidden="true" />
      <div class="isle-page-header-copy">
        <p v-if="eyebrow" class="isle-page-header-eyebrow">{{ eyebrow }}</p>
        <div class="isle-page-header-title-row">
          <h2 class="isle-page-header-title">{{ title }}</h2>
          <slot name="title-extra" />
        </div>
        <p v-if="subtitle" class="isle-page-header-subtitle">{{ subtitle }}</p>
      </div>
    </div>

    <div v-if="$slots.actions" class="isle-page-header-actions">
      <slot name="actions" />
    </div>
  </header>
</template>

<style scoped>
.isle-page-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  margin: 4px 0 12px;
}

.isle-page-header.is-compact {
  margin: 2px 0 8px;
}

.isle-page-header-main {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
  flex: 1 1 220px;
}

.isle-page-header-bar {
  width: 3.5px;
  align-self: stretch;
  min-height: 18px;
  max-height: 28px;
  margin: auto 0;
  border-radius: var(--radius-pill, 9999px);
  background: var(--accent-primary, #1f5162);
  flex-shrink: 0;
}

.isle-page-header-copy {
  display: grid;
  gap: 2px;
  min-width: 0;
  flex: 1;
}

.isle-page-header-eyebrow {
  margin: 0;
  font-size: 10.5px;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--accent-primary, #1f5162);
}

.isle-page-header-title-row {
  display: flex;
  align-items: center;
  gap: 7px;
  flex-wrap: wrap;
  min-width: 0;
}

.isle-page-header-title {
  margin: 0;
  font-size: 20px;
  font-weight: 700;
  letter-spacing: -0.025em;
  line-height: 1.25;
  color: var(--text-primary);
}

.isle-page-header.is-compact .isle-page-header-title {
  font-size: 16.5px;
  font-weight: 680;
  letter-spacing: -0.018em;
}

.isle-page-header-subtitle {
  margin: 2px 0 0;
  font-size: 13px;
  line-height: 1.48;
  color: var(--text-secondary);
}

.isle-page-header-actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 8px;
  flex-wrap: wrap;
  max-width: 100%;
  flex-shrink: 0;
}

@media (max-width: 820px) {
  .isle-page-header-actions {
    width: 100%;
    justify-content: flex-start;
  }
}
</style>
