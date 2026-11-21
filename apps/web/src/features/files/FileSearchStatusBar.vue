<script setup lang="ts">
import { computed } from "vue";
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
      <span>
        {{ spotlight ? "文件名与内容" : "按文件名" }}搜索「<strong>{{ query }}</strong>」
        <template v-if="!loading"> · {{ resultCount }} 项</template>
      </span>
      <div v-if="inSubfolder" class="file-search-scope" role="group" aria-label="搜索范围">
        <button
          type="button"
          class="scope-pill"
          :class="{ active: scope === 'folder' }"
          @click="emit('select-scope', 'folder')"
        >当前目录「{{ folderLabel }}」</button>
        <button
          type="button"
          class="scope-pill"
          :class="{ active: scope === 'all' }"
          @click="emit('select-scope', 'all')"
        >当前整盘</button>
      </div>
      <span v-else class="file-search-scope-tag">范围：当前整盘授权目录</span>
      <button type="button" class="account-action" @click="emit('clear')">返回原目录 (Esc)</button>
      <span v-if="truncated" class="file-search-truncated">结果已达遍历上限，可切换只搜当前目录或补充关键词缩小范围。</span>
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
  margin: 8px 14px 10px;
  padding: 10px 14px;
  border-radius: 14px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
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
.file-search-scope {
  display: inline-flex;
  align-items: center;
  gap: 2px;
  padding: 2px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
}
.scope-pill,
.kind-pill {
  border: 1px solid transparent;
  background: transparent;
  color: var(--text-secondary);
  font-size: 12px;
  font-weight: 550;
  padding: 3px 10px;
  border-radius: 999px;
  cursor: pointer;
  transition: background-color 0.16s ease, color 0.16s ease, border-color 0.16s ease;
}
.scope-pill:hover,
.kind-pill:hover {
  color: var(--text-primary);
  background: color-mix(in srgb, var(--text-primary) 6%, transparent);
}
.scope-pill.active,
.kind-pill.active {
  background: color-mix(in srgb, var(--accent-primary) 16%, transparent);
  border-color: color-mix(in srgb, var(--accent-primary) 42%, transparent);
  color: var(--accent-primary);
  font-weight: 650;
}
.file-search-scope-tag {
  font-size: 12px;
  color: var(--text-tertiary);
}
.file-search-truncated {
  font-size: 12px;
  color: var(--warning, #d97706);
}
.file-search-kinds {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
.kind-pill {
  border-color: var(--fluid-card-border);
  background: var(--fluid-card-fill);
}
@media (prefers-reduced-motion: reduce) {
  .scope-pill,
  .kind-pill {
    transition: none;
  }
}
</style>
