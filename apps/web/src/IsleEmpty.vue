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
withDefaults(
  defineProps<{
    title?: string;
    description?: string;
    icon?: any;
    iconSize?: number;
    compact?: boolean;
    card?: boolean;
  }>(),
  {
    title: '',
    description: '',
    icon: null,
    iconSize: 36,
    compact: false,
    card: false,
  }
);

defineSlots<{
  default?: (props: Record<string, never>) => any;
  icon?: (props: Record<string, never>) => any;
  title?: (props: Record<string, never>) => any;
  action?: (props: Record<string, never>) => any;
}>();
</script>

<style scoped>
.isle-empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  text-align: center;
  padding: 36px 20px;
  color: var(--text-secondary);
  box-sizing: border-box;
}

.isle-empty.compact {
  padding: 18px 12px;
}

.isle-empty.card-surface {
  background: var(--card-bg);
  border: 1px solid var(--card-border);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-sm);
  backdrop-filter: blur(var(--blur-md));
  -webkit-backdrop-filter: blur(var(--blur-md));
}

.isle-empty-icon-wrap {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 56px;
  height: 56px;
  border-radius: var(--radius-md);
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid var(--border-subtle);
  color: var(--text-secondary);
  margin-bottom: 12px;
  transition: transform 0.2s cubic-bezier(0.2, 0.8, 0.2, 1);
}

.isle-empty.compact .isle-empty-icon-wrap {
  width: 40px;
  height: 40px;
  margin-bottom: 8px;
}

.isle-empty-icon {
  opacity: 0.8;
}

.isle-empty-title {
  font-size: 15px;
  font-weight: 600;
  color: var(--text-primary);
  letter-spacing: -0.01em;
  margin-bottom: 4px;
}

.isle-empty.compact .isle-empty-title {
  font-size: 13px;
}

.isle-empty-desc {
  font-size: 13px;
  line-height: 1.5;
  color: var(--text-secondary);
  max-width: 420px;
  margin: 0 auto;
}

.isle-empty.compact .isle-empty-desc {
  font-size: 12px;
  max-width: 320px;
}

.isle-empty-action {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  margin-top: 18px;
}

.isle-empty.compact .isle-empty-action {
  margin-top: 12px;
}
</style>
