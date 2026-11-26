<script setup lang="ts">
import { computed, ref } from "vue";
import { CircleHelp } from "lucide-vue-next";
import IsleModal from "./IsleModal.vue";
import IsleButton from "./IsleButton.vue";

export type HelpItem = string | { title?: string; body: string };

const props = withDefaults(
  defineProps<{
    title: string;
    description?: string;
    label?: string;
    ariaLabel?: string;
    items?: HelpItem[];
    size?: "sm" | "md";
    modalSize?: "sm" | "md" | "lg";
    zIndex?: number;
  }>(),
  {
    description: "",
    label: "",
    ariaLabel: "",
    items: () => [],
    size: "sm",
    modalSize: "sm",
    zIndex: undefined,
  }
);

const open = ref(false);

const normalizedItems = computed(() =>
  (props.items ?? []).map((entry) =>
    typeof entry === "string" ? { title: "", body: entry } : entry
  )
);

const resolvedAriaLabel = computed(
  () => props.ariaLabel || (props.label ? `${props.label}说明` : `查看${props.title}`)
);
</script>

<template>
  <button
    type="button"
    class="isle-help-trigger"
    :class="[`size-${size}`, { 'has-label': Boolean(label) }]"
    :title="resolvedAriaLabel"
    :aria-label="resolvedAriaLabel"
    aria-haspopup="dialog"
    :aria-expanded="open"
    @click.stop="open = true"
  >
    <CircleHelp :size="size === 'sm' ? 14 : 15" :stroke-width="2" />
    <span v-if="label" class="isle-help-label">{{ label }}</span>
  </button>

  <IsleModal
    :open="open"
    :title="title"
    :description="description"
    :size="modalSize"
    :z-index="zIndex ?? 1360"
    @close="open = false"
  >
    <template #icon>
      <CircleHelp :size="16" />
    </template>

    <div class="isle-help-content">
      <slot>
        <div
          v-for="(item, idx) in normalizedItems"
          :key="idx"
          class="isle-help-item"
        >
          <strong v-if="item.title" class="isle-help-item-title">{{ item.title }}</strong>
          <p class="isle-help-item-body">{{ item.body }}</p>
        </div>
      </slot>
    </div>

    <template #footer>
      <IsleButton variant="primary" size="sm" @click="open = false">知道了</IsleButton>
    </template>
  </IsleModal>
</template>

<style scoped>
.isle-help-trigger {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  border-radius: 9999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-secondary);
  cursor: pointer;
  flex-shrink: 0;
  padding: 0;
  font-family: inherit;
  font-size: 12px;
  font-weight: 550;
  box-shadow: var(--fluid-item-card-shadow);
  transition:
    transform 240ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    background-color 160ms ease,
    border-color 160ms ease,
    color 160ms ease;
}

.isle-help-trigger.size-sm {
  width: 26px;
  height: 26px;
}

.isle-help-trigger.size-md {
  width: 30px;
  height: 30px;
}

.isle-help-trigger.has-label {
  width: auto;
  padding: 0 10px;
}

.isle-help-trigger:hover {
  color: var(--accent-primary);
  background: var(--fluid-card-hover);
  border-color: var(--fluid-card-border-strong);
}

.isle-help-trigger:active {
  transform: scale(0.93);
  transition-duration: 95ms;
}

.isle-help-label {
  line-height: 1;
  white-space: nowrap;
}

.isle-help-content {
  display: flex;
  flex-direction: column;
  gap: 10px;
  font-size: 13px;
  line-height: 1.6;
  color: var(--text-secondary);
}

.isle-help-item {
  padding: 10px 12px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.isle-help-item-title {
  font-size: 13px;
  font-weight: 650;
  color: var(--text-primary);
}

.isle-help-item-body {
  margin: 0;
  font-size: 12.5px;
  line-height: 1.55;
  color: var(--text-secondary);
}

@media (prefers-reduced-motion: reduce) {
  .isle-help-trigger {
    transition: none;
  }
}
</style>
