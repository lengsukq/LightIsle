<script setup lang="ts" generic="T extends SelectOptionValue = SelectOptionValue">
import { computed, ref, watch, onMounted, onUnmounted, nextTick } from "vue";
import { ChevronsUpDown, Check } from "lucide-vue-next";
import { pushModalLayer, type ModalLayerHandle } from "../../utils/modalStack.ts";

export type SelectOptionValue = string | number | boolean | null;

export interface SelectOption<V extends SelectOptionValue = SelectOptionValue> {
  value: V;
  label?: string;
  hint?: string;
  disabled?: boolean;
}

const props = withDefaults(
  defineProps<{
    modelValue?: T;
    options: Array<SelectOption<T> | (T & (string | number))>;
    placeholder?: string;
    disabled?: boolean;
    size?: "sm" | "md" | "lg";
    ariaLabel?: string;
    block?: boolean;
    id?: string;
    name?: string;
  }>(),
  {
    modelValue: undefined,
    placeholder: "请选择…",
    disabled: false,
    size: "md",
    ariaLabel: "",
    block: false,
    id: undefined,
    name: undefined,
  }
);

const emit = defineEmits<{
  (e: "update:modelValue", value: T): void;
  (e: "change", value: T): void;
}>();

const isOpen = ref(false);
const highlightedIndex = ref(-1);
const triggerRef = ref<HTMLButtonElement | null>(null);
const menuRef = ref<HTMLElement | null>(null);
let escLayer: ModalLayerHandle | null = null;

const normalizedOptions = computed<Array<SelectOption<T>>>(() => {
  return (props.options || []).map((item) => {
    if (typeof item === "object" && item !== null && "value" in item) {
      return {
        value: item.value,
        label: item.label !== undefined ? String(item.label) : String(item.value ?? ""),
        hint: item.hint ? String(item.hint) : undefined,
        disabled: Boolean(item.disabled),
      };
    }
    return {
      value: item as T,
      label: String(item),
      hint: undefined,
      disabled: false,
    };
  });
});

const selectedOption = computed(() => {
  return normalizedOptions.value.find((opt) => opt.value === props.modelValue);
});

const displayText = computed(() => {
  if (selectedOption.value) {
    return selectedOption.value.label || String(selectedOption.value.value ?? "");
  }
  return props.placeholder;
});

const isPlaceholder = computed(() => !selectedOption.value);

interface MenuPlacementStyle {
  position: "fixed";
  top?: string;
  bottom?: string;
  left: string;
  minWidth: string;
  maxWidth: string;
  maxHeight: string;
  zIndex: number;
}

const placementStyle = ref<MenuPlacementStyle>({
  position: "fixed",
  left: "0px",
  minWidth: "120px",
  maxWidth: "380px",
  maxHeight: "260px",
  zIndex: 99999,
});

const isDroppingUp = ref(false);

function updatePosition() {
  if (!isOpen.value || !triggerRef.value) return;
  const rect = triggerRef.value.getBoundingClientRect();
  const viewportWidth = window.innerWidth;
  const viewportHeight = window.innerHeight;

  const estimatedMenuHeight = Math.min(260, normalizedOptions.value.length * 32 + 12);
  const spaceBelow = viewportHeight - rect.bottom - 10;
  const spaceAbove = rect.top - 10;

  const dropUp = spaceBelow < 180 && spaceAbove > spaceBelow;
  isDroppingUp.value = dropUp;

  const minWidth = Math.max(rect.width, 120);
  const maxWidth = Math.min(Math.max(rect.width, 280), viewportWidth - 24);

  let left = rect.left;
  if (left + minWidth > viewportWidth - 12) {
    left = Math.max(12, viewportWidth - minWidth - 12);
  } else if (left < 12) {
    left = 12;
  }

  const newStyle: MenuPlacementStyle = {
    position: "fixed",
    left: `${Math.round(left)}px`,
    minWidth: `${Math.round(minWidth)}px`,
    maxWidth: `${Math.round(maxWidth)}px`,
    maxHeight: `${Math.round(dropUp ? Math.min(estimatedMenuHeight, spaceAbove) : Math.min(estimatedMenuHeight, spaceBelow))}px`,
    zIndex: 99999,
  };

  if (dropUp) {
    newStyle.bottom = `${Math.round(viewportHeight - rect.top + 4)}px`;
    newStyle.top = undefined;
  } else {
    newStyle.top = `${Math.round(rect.bottom + 4)}px`;
    newStyle.bottom = undefined;
  }

  placementStyle.value = newStyle;
}

function scrollToSelected() {
  nextTick(() => {
    if (!menuRef.value) return;
    const selectedEl = menuRef.value.querySelector<HTMLElement>(".apple-select-option.is-selected, .apple-select-option.is-highlighted");
    if (selectedEl) {
      selectedEl.scrollIntoView({ block: "nearest" });
    }
  });
}

function openMenu() {
  if (props.disabled) return;
  isOpen.value = true;
  const currentIndex = normalizedOptions.value.findIndex((opt) => opt.value === props.modelValue);
  highlightedIndex.value = currentIndex >= 0 ? currentIndex : 0;
  updatePosition();
  scrollToSelected();
}

function closeMenu() {
  if (!isOpen.value) return;
  isOpen.value = false;
  highlightedIndex.value = -1;
}

function toggleMenu() {
  if (isOpen.value) {
    closeMenu();
  } else {
    openMenu();
  }
}

function selectOption(option: SelectOption<T>) {
  if (option.disabled || props.disabled) return;
  emit("update:modelValue", option.value);
  emit("change", option.value);
  closeMenu();
  triggerRef.value?.focus();
}

function onTriggerKeydown(event: KeyboardEvent) {
  if (props.disabled) return;
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    if (!isOpen.value) {
      openMenu();
    } else {
      moveHighlight(event.key === "ArrowDown" ? 1 : -1);
    }
  } else if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    if (!isOpen.value) {
      openMenu();
    } else if (highlightedIndex.value >= 0 && highlightedIndex.value < normalizedOptions.value.length) {
      const opt = normalizedOptions.value[highlightedIndex.value];
      if (opt && !opt.disabled) {
        selectOption(opt);
      }
    }
  } else if (event.key === "Escape" && isOpen.value) {
    event.preventDefault();
    event.stopPropagation();
    closeMenu();
    triggerRef.value?.focus();
  } else if (event.key === "Tab" && isOpen.value) {
    closeMenu();
  }
}

function moveHighlight(step: number) {
  const count = normalizedOptions.value.length;
  if (count === 0) return;
  let next = highlightedIndex.value + step;
  if (next < 0) next = count - 1;
  if (next >= count) next = 0;

  for (let i = 0; i < count; i++) {
    const opt = normalizedOptions.value[next];
    if (opt && !opt.disabled) {
      highlightedIndex.value = next;
      scrollToSelected();
      break;
    }
    next = (next + step + count) % count;
  }
}

function onMenuPointerDown(event: PointerEvent) {
  event.stopPropagation();
}

function handleGlobalPointerDown(event: PointerEvent) {
  if (!isOpen.value) return;
  const target = event.target as Node | null;
  if (triggerRef.value?.contains(target)) return;
  if (menuRef.value?.contains(target)) return;
  closeMenu();
}

let positionRafId: number | null = null;

function cancelPositionUpdate() {
  if (positionRafId !== null) {
    window.cancelAnimationFrame(positionRafId);
    positionRafId = null;
  }
}

function handleScrollOrResize() {
  if (!isOpen.value || positionRafId !== null) return;
  positionRafId = window.requestAnimationFrame(() => {
    positionRafId = null;
    if (!isOpen.value) return;
    if (triggerRef.value) {
      const rect = triggerRef.value.getBoundingClientRect();
      if (rect.bottom < 0 || rect.top > window.innerHeight) {
        closeMenu();
        return;
      }
    }
    updatePosition();
  });
}

onMounted(() => {
  window.addEventListener("pointerdown", handleGlobalPointerDown, true);
  window.addEventListener("scroll", handleScrollOrResize, { capture: true, passive: true });
  window.addEventListener("resize", handleScrollOrResize, { passive: true });
});

onUnmounted(() => {
  escLayer?.dispose();
  escLayer = null;
  cancelPositionUpdate();
  window.removeEventListener("pointerdown", handleGlobalPointerDown, true);
  window.removeEventListener("scroll", handleScrollOrResize, { capture: true });
  window.removeEventListener("resize", handleScrollOrResize);
});

watch(isOpen, (open) => {
  escLayer?.dispose();
  escLayer = null;
  if (open) {
    escLayer = pushModalLayer({
      onEsc: () => {
        closeMenu();
        triggerRef.value?.focus();
      },
      lockScroll: false,
    });
    nextTick(updatePosition);
  } else {
    cancelPositionUpdate();
  }
});
</script>

<template>
  <div
    class="apple-select-wrapper"
    :class="[
      `size-${size}`,
      { 'is-block': block, 'is-open': isOpen, 'is-disabled': disabled }
    ]"
  >
    <button
      :id="id"
      ref="triggerRef"
      type="button"
      class="apple-select-trigger"
      :class="{ 'is-placeholder': isPlaceholder, 'is-active': isOpen }"
      :disabled="disabled"
      :aria-label="ariaLabel || placeholder"
      :aria-expanded="isOpen"
      aria-haspopup="listbox"
      role="combobox"
      @click="toggleMenu"
      @keydown="onTriggerKeydown"
    >
      <span class="apple-select-label-text">{{ displayText }}</span>
      <span class="apple-select-chevron" aria-hidden="true">
        <ChevronsUpDown :size="size === 'sm' ? 12 : 13" :stroke-width="2" />
      </span>
    </button>

    <Teleport to="body">
      <Transition :name="isDroppingUp ? 'apple-select-up' : 'apple-select-down'">
        <div
          v-if="isOpen"
          ref="menuRef"
          class="apple-select-menu"
          :class="[`size-${size}`, { 'drop-up': isDroppingUp }]"
          :style="placementStyle"
          role="listbox"
          tabindex="-1"
          @pointerdown="onMenuPointerDown"
          @keydown="onTriggerKeydown"
        >
          <div class="apple-select-scroll">
            <div
              v-for="(option, index) in normalizedOptions"
              :key="String(option.value)"
              class="apple-select-option"
              :class="{
                'is-selected': option.value === modelValue,
                'is-highlighted': index === highlightedIndex,
                'is-disabled': option.disabled,
              }"
              role="option"
              :aria-selected="option.value === modelValue"
              :aria-disabled="option.disabled"
              @pointerenter="highlightedIndex = index"
              @click="selectOption(option)"
            >
              <span class="apple-select-check" aria-hidden="true">
                <Check v-if="option.value === modelValue" :size="size === 'sm' ? 12 : 13" :stroke-width="2.5" />
              </span>
              <span class="apple-select-option-label">{{ option.label }}</span>
              <span v-if="option.hint" class="apple-select-option-hint">{{ option.hint }}</span>
            </div>
            <div v-if="!normalizedOptions.length" class="apple-select-empty">
              暂无可用选项
            </div>
          </div>
        </div>
      </Transition>
    </Teleport>
  </div>
</template>

<style scoped>
.apple-select-wrapper {
  position: relative;
  display: inline-flex;
  vertical-align: middle;
}
.apple-select-wrapper.is-block {
  display: flex;
  width: 100%;
}

.apple-select-trigger {
  box-sizing: border-box;
  display: inline-flex;
  align-items: center;
  justify-content: space-between;
  gap: 6px;
  width: 100%;
  font-family: inherit;
  font-weight: 550;
  color: var(--text-primary, #181715);
  cursor: pointer;
  user-select: none;
  background-color: var(--fluid-card-top, #ffffff);
  border: 1px solid var(--fluid-card-border, rgba(34, 29, 23, 0.1));
  box-shadow: 0 1px 2px rgba(34, 29, 23, 0.03);
  transition:
    transform 220ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)),
    border-color var(--motion-fast, 0.16s) ease,
    background-color var(--motion-fast, 0.16s) ease;
  outline: none;
}

.apple-select-trigger:active:not(:disabled) {
  transform: scale(0.98);
  transition-duration: 95ms;
}

.apple-select-wrapper.size-sm .apple-select-trigger {
  height: 28px;
  padding: 0 8px 0 9px;
  font-size: 12px;
  border-radius: 8px;
}
.apple-select-wrapper.size-md .apple-select-trigger {
  height: 33px;
  padding: 0 9px 0 11px;
  font-size: 12.5px;
  border-radius: 9px;
}
.apple-select-wrapper.size-lg .apple-select-trigger {
  height: 38px;
  padding: 0 11px 0 13px;
  font-size: 13.5px;
  border-radius: 10px;
}

.apple-select-label-text {
  flex: 1;
  text-align: left;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  min-width: 0;
}

.apple-select-trigger.is-placeholder .apple-select-label-text {
  color: var(--text-secondary, #635e57);
  font-weight: normal;
}

.apple-select-chevron {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--text-secondary, #635e57);
  flex-shrink: 0;
  transition:
    color 0.15s ease,
    transform 220ms var(--motion-spring-snappy, cubic-bezier(0.2, 0.9, 0.22, 1.05));
}

.apple-select-wrapper.is-open .apple-select-chevron {
  transform: scale(1.08) rotate(180deg);
  color: var(--accent-primary, #0E6B74);
}

.apple-select-trigger:hover:not(:disabled) {
  border-color: var(--fluid-card-border-strong, rgba(34, 29, 23, 0.16));
  background-color: var(--fluid-card-hover, #f5f2ea);
}
.apple-select-trigger:hover:not(:disabled) .apple-select-chevron {
  color: var(--accent-primary, #1f5162);
}

.apple-select-trigger:focus-visible {
  border-color: var(--accent-primary, #1f5162) !important;
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary, #1f5162) 18%, transparent) !important;
}

.apple-select-trigger.is-active {
  border-color: var(--accent-primary, #1f5162);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary, #1f5162) 16%, transparent);
}

.apple-select-trigger:disabled {
  opacity: 0.45;
  cursor: not-allowed;
  box-shadow: none !important;
}

:global([data-theme="dark"]) .apple-select-trigger {
  background-color: var(--fluid-card-top, #1e1d1b);
  border: 1px solid var(--fluid-card-border, rgba(244, 241, 234, 0.11));
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.28);
}

@media (prefers-reduced-motion: reduce) {
  .apple-select-trigger,
  .apple-select-chevron {
    transition: none;
  }
}
</style>

<style>
.apple-select-menu {
  box-sizing: border-box;
  overflow: hidden;
  border-radius: var(--radius-md, 14px);
  padding: 5px;
  background-color: color-mix(in srgb, var(--surface-glass, rgba(252, 251, 249, 0.84)) 88%, var(--surface-elevated, #ffffff) 12%);
  backdrop-filter: blur(26px) saturate(170%);
  -webkit-backdrop-filter: blur(26px) saturate(170%);
  border: 1px solid var(--fluid-card-border-strong, rgba(20, 19, 17, 0.14));
  box-shadow: var(--shadow-float, 0 14px 30px -6px rgba(20, 19, 17, 0.15)), var(--fluid-card-rim, inset 0 1px 0 rgba(255, 255, 255, 0.72));
  font-family: inherit;
  color: var(--text-primary, #141413);
  outline: none;
  transform-origin: top center;
}

.apple-select-menu.drop-up {
  transform-origin: bottom center;
}

[data-theme="dark"] .apple-select-menu {
  background-color: color-mix(in srgb, var(--surface-glass, rgba(22, 22, 20, 0.80)) 86%, var(--surface-elevated, #1c1c1a) 14%);
  border: 1px solid var(--fluid-card-border-strong, rgba(244, 241, 234, 0.16));
  box-shadow: var(--shadow-float, 0 16px 36px -4px rgba(0, 0, 0, 0.52)), var(--fluid-card-rim, inset 0 1px 0 rgba(255, 255, 255, 0.08));
  color: var(--text-primary, #f4f1ea);
}

@media (prefers-reduced-transparency: reduce) {
  .apple-select-menu {
    backdrop-filter: none;
    -webkit-backdrop-filter: none;
    background-color: var(--surface-elevated, #ffffff);
  }
}

.apple-select-scroll {
  max-height: inherit;
  overflow-y: auto;
  overflow-x: hidden;
  scrollbar-width: thin;
  padding-right: 1px;
}
.apple-select-scroll::-webkit-scrollbar {
  width: 5px;
}
.apple-select-scroll::-webkit-scrollbar-thumb {
  background: rgba(34, 29, 23, 0.18);
  border-radius: 999px;
}
[data-theme="dark"] .apple-select-scroll::-webkit-scrollbar-thumb {
  background: rgba(244, 241, 234, 0.22);
}

.apple-select-option {
  display: flex;
  align-items: center;
  gap: 7px;
  width: 100%;
  box-sizing: border-box;
  padding: 5px 9px 5px 6px;
  border-radius: 7px;
  font-size: 12.5px;
  font-weight: 500;
  line-height: 1.35;
  cursor: pointer;
  user-select: none;
  transition: background-color 0.13s ease, color 0.13s ease;
  position: relative;
}

.apple-select-menu.size-sm .apple-select-option {
  font-size: 12px;
  padding: 4px 8px 4px 5px;
}

.apple-select-check {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 15px;
  height: 15px;
  flex-shrink: 0;
  color: var(--accent-primary, #1f5162);
}

.apple-select-option-label {
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.apple-select-option-hint {
  font-size: 11px;
  color: var(--text-secondary, #635e57);
  margin-left: 6px;
  flex-shrink: 0;
}

.apple-select-option.is-highlighted:not(.is-disabled) {
  background-color: var(--accent-primary-solid, var(--accent-primary, #1f5162));
  color: var(--on-accent-primary, #ffffff) !important;
}

[data-theme="dark"] .apple-select-option.is-highlighted:not(.is-disabled) {
  background-color: var(--accent-primary-solid, var(--accent-primary, #13747E));
  color: var(--on-accent-primary, #f8f6f1) !important;
}

.apple-select-option.is-highlighted:not(.is-disabled) .apple-select-check,
.apple-select-option.is-highlighted:not(.is-disabled) .apple-select-option-hint {
  color: var(--on-accent-primary, #ffffff) !important;
}

.apple-select-option.is-selected:not(.is-highlighted) {
  font-weight: 600;
  color: var(--accent-primary, #1f5162);
}

.apple-select-option.is-disabled {
  opacity: 0.35;
  cursor: not-allowed;
}

.apple-select-empty {
  padding: 8px 12px;
  font-size: 12px;
  color: var(--text-secondary, #635e57);
  text-align: center;
}

.apple-select-down-enter-active,
.apple-select-up-enter-active {
  transition:
    opacity 0.18s cubic-bezier(0.22, 1, 0.36, 1),
    transform 0.22s var(--motion-spring-snappy, cubic-bezier(0.2, 0.9, 0.22, 1.05));
}
.apple-select-down-leave-active,
.apple-select-up-leave-active {
  transition:
    opacity 0.12s cubic-bezier(0.32, 0, 0.67, 0),
    transform 0.12s cubic-bezier(0.32, 0, 0.67, 0);
}

.apple-select-down-enter-from {
  opacity: 0;
  transform: scale(0.96) translateY(-5px);
}
.apple-select-down-leave-to {
  opacity: 0;
  transform: scale(0.98) translateY(-2px);
}

.apple-select-up-enter-from {
  opacity: 0;
  transform: scale(0.96) translateY(5px);
}
.apple-select-up-leave-to {
  opacity: 0;
  transform: scale(0.98) translateY(2px);
}

@media (prefers-reduced-motion: reduce) {
  .apple-select-option,
  .apple-select-down-enter-active,
  .apple-select-up-enter-active,
  .apple-select-down-leave-active,
  .apple-select-up-leave-active {
    transition: none;
  }
}
</style>
