<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { Search, X } from "lucide-vue-next";
import RecentSearchPopover from "../../components/ui/RecentSearchPopover.vue";

const props = defineProps<{
  query: string;
  spotlight: boolean;
  searching: boolean;
  recentSearches: string[];
}>();

const emit = defineEmits<{
  "update:query": [value: string];
  "update:spotlight": [value: boolean];
  search: [];
  clear: [];
  "select-history": [term: string];
  "delete-history": [term: string];
  "clear-history": [];
}>();

const rootRef = ref<HTMLElement | null>(null);
const inputRef = ref<HTMLInputElement | null>(null);
const focused = ref(false);
const isComposing = ref(false);

const localQuery = computed({
  get: () => props.query,
  set: (v: string) => emit("update:query", v),
});
const localSpotlight = computed({
  get: () => props.spotlight,
  set: (v: boolean) => emit("update:spotlight", v),
});
const historyOpen = computed(() => focused.value && !props.query.trim() && props.recentSearches.length > 0);

function onSubmit() {
  if (isComposing.value) return;
  emit("search");
  focused.value = false;
}

function onInputKeydown(event: KeyboardEvent) {
  if (event.key === "Enter" && (isComposing.value || event.isComposing)) {
    event.preventDefault();
    return;
  }
  if (event.key === "Escape") {
    if (isComposing.value || event.isComposing) return;
    event.preventDefault();
    event.stopPropagation();
    focused.value = false;
    if (props.searching || props.query) {
      emit("clear");
    } else {
      inputRef.value?.blur();
    }
  }
}

function onSpotlightChange() {
  if (props.searching || props.query.trim().length >= 1) {
    emit("search");
  }
}

function selectHistoryTerm(term: string) {
  focused.value = false;
  emit("select-history", term);
}

function onOutsidePointerDown(event: PointerEvent) {
  const target = event.target as Node | null;
  if (focused.value && rootRef.value && target && !rootRef.value.contains(target)) {
    focused.value = false;
  }
}

function onContainerFocusOut(event: FocusEvent) {
  if (!rootRef.value?.contains(event.relatedTarget as Node | null)) {
    focused.value = false;
  }
}

onMounted(() => window.addEventListener("pointerdown", onOutsidePointerDown, true));
onUnmounted(() => window.removeEventListener("pointerdown", onOutsidePointerDown, true));
</script>

<template>
  <div ref="rootRef" class="file-search-wrap" @focusout="onContainerFocusOut">
    <form class="file-inline-search" :class="{ 'is-focused': focused, 'has-query': Boolean(query || searching) }" @submit.prevent="onSubmit">
      <Search :size="14" class="file-search-icon" aria-hidden="true" />
      <input
        ref="inputRef"
        v-model="localQuery"
        type="search"
        maxlength="128"
        :placeholder="localSpotlight ? '搜文件名或正文…' : '搜索文件名或目录…'"
        aria-label="搜索授权目录文件"
        @focus="focused = true"
        @compositionstart="isComposing = true"
        @compositionend="isComposing = false"
        @keydown="onInputKeydown"
      />
      <button v-if="searching || query" type="button" class="file-search-clear" title="清除搜索并回到原目录（Esc）" aria-label="清除搜索" @click="emit('clear')">
        <X :size="13" />
      </button>
      <label class="file-spotlight-pill" :class="{ active: localSpotlight }" title="使用 macOS Spotlight 搜索文件内容；未建立索引时自动回退文件名搜索">
        <input v-model="localSpotlight" type="checkbox" class="file-spotlight-checkbox" aria-label="使用 macOS Spotlight 全文搜索" @change="onSpotlightChange" />
        <span>全文</span>
      </label>
    </form>
    <RecentSearchPopover
      :open="historyOpen"
      :items="recentSearches"
      @select="selectHistoryTerm"
      @delete="emit('delete-history', $event)"
      @clear="emit('clear-history')"
    />
  </div>
</template>

<style scoped>
.file-search-wrap {
  position: relative;
  display: inline-flex;
  align-items: center;
}
.file-search-icon {
  flex-shrink: 0;
  color: var(--text-tertiary);
  transition: color 150ms ease;
}
.file-inline-search.is-focused .file-search-icon {
  color: var(--accent-primary);
}
.file-search-clear {
  width: 20px;
  height: 20px;
  border-radius: 999px;
  display: inline-grid;
  place-items: center;
  flex-shrink: 0;
  color: var(--text-tertiary);
  transition: background-color 140ms ease, color 140ms ease;
}
.file-search-clear:hover {
  background: color-mix(in srgb, var(--text-primary) 9%, transparent);
  color: var(--text-primary);
}
@media (prefers-reduced-motion: reduce) {
  .file-search-icon,
  .file-search-clear {
    transition: none;
  }
}
</style>
