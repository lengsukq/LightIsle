<script setup lang="ts">
import { computed } from "vue";
import { ArrowLeft, Search } from "lucide-vue-next";
import { FILE_SEARCH_KIND_OPTIONS, folderLabelOfPath, type FileSearchKind, type FileSearchScope } from "./fileSearchUtils.ts";

const props = defineProps<{
  query: string;
  spotlight: boolean;
  kind: FileSearchKind;
  scope: FileSearchScope;
  folderBase: string;
  rootName: string;
  resultCount: number;
  truncated: boolean;
  loading: boolean;
}>();

const emit = defineEmits<{
  "select-kind": [kind: FileSearchKind];
  "select-scope": [scope: FileSearchScope];
  clear: [];
}>();

const inSubfolder = computed(() => Boolean(props.folderBase && props.folderBase !== "."));
const folderLabel = computed(() => folderLabelOfPath(props.folderBase, props.rootName || "共享根目录"));
</script>

<template>
  <div class="file-search-status" role="region" aria-label="搜索条件与筛选">
    <div class="file-search-summary">
      <span class="file-search-heading">
        <Search :size="13" aria-hidden="true" />
        <span>{{ spotlight ? "全文" : "文件名" }}搜索「<strong>{{ query }}</strong>」</span>
        <span v-if="!loading" class="file-search-count">{{ resultCount }} 项</span>
      </span>
      <div v-if="inSubfolder" class="file-search-scope" role="group" aria-label="搜索范围">
        <button
          type="button"
          class="scope-pill"
          :class="{ active: scope === 'folder' }"
          :title="'当前目录「' + folderLabel + '」'"
          @click="emit('select-scope', 'folder')"
        >仅「{{ folderLabel }}」</button>
        <button
          type="button"
          class="scope-pill"
          :class="{ active: scope === 'all' }"
          @click="emit('select-scope', 'all')"
        >当前整盘</button>
      </div>
      <span v-else class="file-search-scope-tag">当前整盘授权目录</span>
      <button type="button" class="file-search-back" @click="emit('clear')">
        <ArrowLeft :size="12" aria-hidden="true" />
        <span>返回目录</span>
        <span class="file-search-esc-hint">Esc</span>
      </button>
      <span v-if="truncated" class="file-search-truncated">结果已达遍历上限，可缩小目录或补充关键词。</span>
    </div>
    <div class="file-search-kinds" role="group" aria-label="按文件类型筛选">
      <button
        v-for="item in FILE_SEARCH_KIND_OPTIONS"
        :key="item.value || 'all'"
        type="button"
        class="kind-pill"
        :class="{ active: kind === item.value }"
        @click="emit('select-kind', item.value)"
      >{{ item.label }}</button>
    </div>
  </div>
</template>

<style scoped>
.file-search-status {
  padding: 10px 16px;
  border-bottom: 1px solid var(--fluid-divider);
  background: color-mix(in srgb, var(--accent-primary) 3.5%, var(--fluid-card-item-fill));
  display: grid;
  gap: 8px;
}
.file-search-summary {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px 10px;
  font-size: 12.5px;
  color: var(--text-secondary);
}
.file-search-heading {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  color: var(--text-primary);
}
.file-search-heading svg {
  color: var(--accent-primary);
  flex-shrink: 0;
}
.file-search-heading strong {
  overflow-wrap: anywhere;
}
.file-search-count {
  font-size: 11.5px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  padding: 1px 7px;
  border-radius: 999px;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-secondary);
}
.file-search-scope {
  display: inline-flex;
  align-items: center;
  gap: 2px;
  padding: 2px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  max-width: 100%;
  min-width: 0;
}
.scope-pill,
.kind-pill,
.file-search-back {
  border: 1px solid transparent;
  background: transparent;
  color: var(--text-secondary);
  font-size: 12px;
  font-weight: 560;
  padding: 3px 10px;
  border-radius: 999px;
  cursor: pointer;
  white-space: nowrap;
  transition: background-color 150ms ease, color 150ms ease, border-color 150ms ease;
}
.scope-pill {
  max-width: min(210px, 52vw);
  overflow: hidden;
  text-overflow: ellipsis;
}
.scope-pill:hover,
.kind-pill:hover,
.file-search-back:hover {
  color: var(--text-primary);
  background: color-mix(in srgb, var(--text-primary) 6%, transparent);
}
.scope-pill.active,
.kind-pill.active {
  background: color-mix(in srgb, var(--accent-primary) 15%, var(--fluid-card-top));
  border-color: color-mix(in srgb, var(--accent-primary) 40%, transparent);
  color: var(--accent-primary);
  font-weight: 650;
}
.file-search-scope-tag {
  font-size: 11.5px;
  color: var(--text-tertiary);
}
.file-search-back {
  margin-left: auto;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  border-color: var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: var(--text-primary);
}
.file-search-esc-hint {
  font-size: 10.5px;
  color: var(--text-tertiary);
  padding-left: 2px;
}
.file-search-truncated {
  width: 100%;
  font-size: 11.5px;
  color: var(--warning, #d97706);
}
.file-search-kinds {
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
}
.kind-pill {
  border-color: var(--fluid-card-border);
  background: var(--fluid-card-fill);
}
@media (max-width: 640px), (pointer: coarse) {
  .file-search-status {
    padding: 9px 12px;
  }
  .file-search-esc-hint {
    display: none;
  }
  .file-search-back {
    margin-left: 0;
  }
  .file-search-kinds {
    flex-wrap: nowrap;
    overflow-x: auto;
    scrollbar-width: none;
    padding-bottom: 2px;
  }
  .file-search-kinds::-webkit-scrollbar {
    display: none;
  }
}
@media (prefers-reduced-motion: reduce) {
  .scope-pill,
  .kind-pill,
  .file-search-back {
    transition: none;
  }
}
</style>
