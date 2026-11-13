<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { Search, X } from "lucide-vue-next";
import RecentSearchPopover from "./RecentSearchPopover.vue";

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

onMounted(() => window.addEventListener("pointerdown", onOutsidePointerDown, true));
onUnmounted(() => window.removeEventListener("pointerdown", onOutsidePointerDown, true));
</script>

<template>
  <div ref="rootRef" class="file-search-wrap">
    <form class="file-inline-search" @submit.prevent="onSubmit">
      <Search :size="15" />
      <input
        ref="inputRef"
        v-model="localQuery"
        type="search"
        maxlength="128"
        :placeholder="localSpotlight ? '搜索文件名或正文内容（支持单字/多词）…' : '搜索文件名（支持单字、空格多词）…'"
        aria-label="搜索授权目录文件"
        @focus="focused = true"
        @blur="focused = false"
        @compositionstart="isComposing = true"
        @compositionend="isComposing = false"
        @keydown="onInputKeydown"
      />
      <label class="file-spotlight-pill" :class="{ active: localSpotlight }" title="使用 macOS Spotlight 搜索文件内容；未建立索引时自动回退文件名搜索">
        <input v-model="localSpotlight" type="checkbox" aria-label="使用 macOS Spotlight 全文搜索" @change="onSpotlightChange" />
        <span>全文搜索</span>
      </label>
      <button v-if="searching || query" type="button" class="file-search-clear" title="清除搜索并回到原目录（Esc）" aria-label="清除搜索" @click="emit('clear')">
        <X :size="14" />
      </button>
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
</style>
