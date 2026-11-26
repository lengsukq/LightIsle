<script setup lang="ts">
import { ref } from "vue";
import { Search, X } from "lucide-vue-next";

const props = withDefaults(
  defineProps<{
    modelValue: string;
    placeholder?: string;
    ariaLabel?: string;
    maxlength?: number;
    size?: "sm" | "md";
    disabled?: boolean;
  }>(),
  {
    placeholder: "搜索…",
    ariaLabel: "搜索",
    maxlength: 120,
    size: "sm",
    disabled: false,
  }
);

const emit = defineEmits<{
  (e: "update:modelValue", value: string): void;
  (e: "submit", value: string): void;
  (e: "clear"): void;
}>();

const composing = ref(false);

function onInput(event: Event) {
  if (composing.value) return;
  emit("update:modelValue", (event.target as HTMLInputElement).value);
}

function onCompositionEnd(event: CompositionEvent) {
  composing.value = false;
  emit("update:modelValue", (event.target as HTMLInputElement).value);
}

function onClear() {
  emit("update:modelValue", "");
  emit("clear");
}

function onEsc(event: KeyboardEvent) {
  if (composing.value || !props.modelValue) return;
  event.stopPropagation();
  onClear();
}
</script>

<template>
  <label
    class="isle-search-input"
    :class="[`size-${size}`, { 'is-disabled': disabled }]"
  >
    <Search :size="size === 'sm' ? 14 : 15" class="isle-search-icon" aria-hidden="true" />
    <input
      class="isle-search-field"
      :value="modelValue"
      :maxlength="maxlength"
      :placeholder="placeholder"
      :aria-label="ariaLabel"
      :disabled="disabled"
      type="search"
      @compositionstart="composing = true"
      @compositionend="onCompositionEnd"
      @input="onInput"
      @keydown.enter.prevent="emit('submit', modelValue)"
      @keydown.esc="onEsc"
    />
    <Transition name="isle-clear-pop">
      <button
        v-if="modelValue && !disabled"
        type="button"
        class="isle-search-clear"
        title="清除搜索"
        aria-label="清除搜索"
        @click="onClear"
      >
        <X :size="13" />
      </button>
    </Transition>
  </label>
</template>

<style scoped>
.isle-search-input {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  border-radius: var(--radius-pill, 9999px);
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill, var(--fluid-card-fill));
  color: var(--text-secondary);
  padding: 0 11px;
  box-sizing: border-box;
  min-width: 0;
  transition: border-color var(--motion-fast, 160ms) ease, background-color var(--motion-fast, 160ms) ease, box-shadow var(--motion-fast, 160ms) ease;
}

.isle-search-input.size-sm {
  height: 32px;
}

.isle-search-input.size-md {
  height: 36px;
}

.isle-search-input:focus-within {
  background: var(--fluid-card-top);
  border-color: var(--accent-primary, #0E6B74);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary, #0E6B74) 15%, transparent);
}

.isle-clear-pop-enter-active,
.isle-clear-pop-leave-active {
  transition: opacity 130ms ease, transform 180ms var(--motion-spring-snappy, cubic-bezier(0.2, 0.9, 0.22, 1.05));
}
.isle-clear-pop-enter-from,
.isle-clear-pop-leave-to {
  opacity: 0;
  transform: scale(0.7);
}

.isle-search-input.is-disabled {
  opacity: 0.55;
  cursor: not-allowed;
}

.isle-search-icon {
  color: var(--text-tertiary);
  flex-shrink: 0;
}

.isle-search-input input {
  flex: 1;
  min-width: 120px;
  width: min(210px, 36vw);
  border: 0;
  outline: 0;
  background: transparent;
  color: var(--text-primary);
  font: inherit;
  font-size: 12.5px;
  padding: 0;
}

.isle-search-input input::placeholder {
  color: var(--text-tertiary);
}

.isle-search-input input::-webkit-search-cancel-button {
  -webkit-appearance: none;
  appearance: none;
}

.isle-search-clear {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 20px;
  height: 20px;
  border-radius: 50%;
  border: 0;
  background: transparent;
  color: var(--text-secondary);
  padding: 0;
  cursor: pointer;
  flex-shrink: 0;
}

.isle-search-clear:hover {
  background: color-mix(in srgb, var(--text-primary) 8%, transparent);
  color: var(--text-primary);
}

@media (max-width: 640px) {
  .isle-search-input input {
    width: 100%;
  }
}

@media (prefers-reduced-motion: reduce) {
  .isle-search-input,
  .isle-clear-pop-enter-active,
  .isle-clear-pop-leave-active {
    transition: none;
  }
}
</style>
